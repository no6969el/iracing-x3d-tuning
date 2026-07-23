<#
    iRacing Full Diagnostic Trace
    ---------------------------------------------------------------
    One-pass logger for everything this method tunes:
      * Power plan (confirm your all-cores-unparked plan holds - no
        mid-race flip from ParkControl/Dynamic Boost)
      * Per-CCD CPU load  -> is the sim actually on the V-Cache die?
      * CPU 0 vs the interrupt target core's interrupt/DPC time
        -> did the GPU-IRQ move work?
      * GPU util/power/clocks/temp/throttle (catch starvation freezes)
      * Sim CPU%/affinity, VR (pi_server) CPU%
      * Hard pagefaults/sec (the Defender/pagefault signal)
      * Free RAM; time gaps in the log = system-wide freezes

    Core numbers come from X3D-Profiles.ps1 (every X3D SKU, validated
    against the CPUs Windows reports). On a single-CCD chip the two
    "ccd" columns are simply the low and high halves of your cores -
    the column names are kept for compatibility with older traces.

    Read-only. No admin needed. Run after reboot, launch iRacing,
    race, then Ctrl+C. CSV lands on your Desktop.
#>

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Csv = Join-Path ([Environment]::GetFolderPath('Desktop')) "iRacing-FullTrace-$stamp.csv"
$ncpu = [Environment]::ProcessorCount

# ---- resolve the split point ------------------------------------
$mod = Join-Path $PSScriptRoot 'X3D-Profiles.ps1'
$Topology = 'unknown'
$Label    = 'core group'
if (Test-Path $mod) {
    . $mod
    $r = Resolve-X3DTarget -Quiet
    $FreqFirst = $r.FreqFirst
    if ($r.Profile) {
        $ncpu     = [int]$r.Profile.ActualLogical
        $Topology = $r.Profile.Topology
    }
} else {
    $FreqFirst = [int]($ncpu / 2)
}

# Never index a core that does not exist - this is a read-only tool,
# so degrade to a sane split rather than aborting.
if ($FreqFirst -lt 1 -or $FreqFirst -ge $ncpu) { $FreqFirst = [int]($ncpu / 2) }
if ($FreqFirst -lt 1) { $FreqFirst = 0 }

if ($Topology -eq 'dual')   { $Label = 'CCD0 / CCD1' }
elseif ($Topology -eq 'single') { $Label = 'low half / high half (single CCD)' }

'timestamp,power_plan,ccd0_cpu,ccd1_cpu,busy_core,busy_pct,cpu0_int,cpu0_dpc,freqcore_int,freqcore_dpc,tot_dpc,tot_int,gpu_util,gpu_power_w,gpu_gclk,gpu_mclk,gpu_temp,gpu_throttle,sim_run,sim_cpu,sim_aff,vr_pi_cpu,hardfaults_s,free_ram_mb' |
    Out-File $Csv -Encoding utf8

# baseline for per-process CPU delta
$prev = @{}; Get-Process | ForEach-Object { $prev[$_.Id] = $_.CPU }; $lastT = Get-Date

Write-Host ""
Write-Host "Full trace -> $Csv" -ForegroundColor Cyan
Write-Host "Launch iRacing and race. Ctrl+C to stop." -ForegroundColor Cyan
Write-Host "$ncpu logical CPUs | split at CPU $FreqFirst | columns ccd0/ccd1 = $Label" -ForegroundColor DarkGray
if ($Topology -eq 'dual') {
    Write-Host "Watch: CCD0 busy / CCD1 idle = sim on the right die | CPU0 int low + CPU$FreqFirst int high = GPU IRQ moved" -ForegroundColor DarkGray
} else {
    Write-Host "Watch: CPU0 int low + CPU$FreqFirst int high = GPU IRQ moved (no pinning to check on a single-CCD chip)" -ForegroundColor DarkGray
}
Write-Host ""

while ($true) {
    $t0 = Get-Date; $now = Get-Date

    # ---- per-core CPU / interrupt / DPC via CIM ----
    $ccd0='';$ccd1='';$busyIdx='';$busyPct='';$c0i='';$c0d='';$c16i='';$c16d='';$totDpc='';$totInt=''
    try {
        $cpu = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -ErrorAction Stop
        $by = @{}; foreach ($c in $cpu) { $by[[string]$c.Name] = $c }

        # safe accessors - a core missing from the counter set must not kill the loop
        $val = { param($n,$prop) if ($by.ContainsKey("$n") -and $by["$n"].$prop -ne $null) { [double]$by["$n"].$prop } else { $null } }

        $g0 = @(); $g1 = @()
        foreach ($n in 0..($ncpu-1)) {
            $v = & $val $n 'PercentProcessorTime'
            if ($v -eq $null) { continue }
            if ($n -lt $FreqFirst) { $g0 += $v } else { $g1 += $v }
        }
        if ($g0.Count) { $ccd0 = [math]::Round(($g0 | Measure-Object -Average).Average,0) }
        if ($g1.Count) { $ccd1 = [math]::Round(($g1 | Measure-Object -Average).Average,0) }

        $bi=-1;$bv=-1
        foreach ($n in 0..($ncpu-1)) {
            $v = & $val $n 'PercentProcessorTime'
            if ($v -ne $null -and $v -gt $bv) { $bv=$v; $bi=$n }
        }
        if ($bi -ge 0) { $busyIdx=$bi; $busyPct=[math]::Round($bv,0) }

        $t = & $val 0 'PercentInterruptTime'; if ($t -ne $null) { $c0i=[math]::Round($t,1) }
        $t = & $val 0 'PercentDPCTime';       if ($t -ne $null) { $c0d=[math]::Round($t,1) }
        $t = & $val $FreqFirst 'PercentInterruptTime'; if ($t -ne $null) { $c16i=[math]::Round($t,1) }
        $t = & $val $FreqFirst 'PercentDPCTime';       if ($t -ne $null) { $c16d=[math]::Round($t,1) }
        $t = & $val '_Total' 'PercentDPCTime';         if ($t -ne $null) { $totDpc=[math]::Round($t,1) }
        $t = & $val '_Total' 'PercentInterruptTime';   if ($t -ne $null) { $totInt=[math]::Round($t,1) }
    } catch {}

    # ---- power plan ----
    $plan=''
    try { $l=(powercfg /getactivescheme) -join ' '; if ($l -match '\(([^)]+)\)') { $plan=$Matches[1] } } catch {}

    # ---- GPU ----
    $gu='';$gp='';$gg='';$gm='';$gt='';$gthr=''
    try {
        $g=(& nvidia-smi --query-gpu=utilization.gpu,power.draw,clocks.current.graphics,clocks.current.memory,temperature.gpu --format=csv,noheader,nounits) -split ','
        $gu=$g[0].Trim();$gp=$g[1].Trim();$gg=$g[2].Trim();$gm=$g[3].Trim();$gt=$g[4].Trim()
    } catch {}
    try { $gthr=(& nvidia-smi --query-gpu=clocks_throttle_reasons.active --format=csv,noheader,nounits).Trim() }
    catch { try { $gthr=(& nvidia-smi --query-gpu=clocks_event_reasons.active --format=csv,noheader,nounits).Trim() } catch {} }

    # ---- per-process CPU delta (sim + VR) ----
    $dt=($now-$lastT).TotalSeconds; if ($dt -le 0) { $dt=1 }
    $cur=Get-Process
    $simPct='';$piPct='';$simRun=0;$simAff=''
    $simP = $cur | Where-Object { $_.ProcessName -eq 'iRacingSim64DX11' } | Select-Object -First 1
    if ($simP) { $simRun=1; $simAff='0x'+('{0:X}' -f [int64]$simP.ProcessorAffinity) }
    foreach ($p in $cur) {
        if ($prev.ContainsKey($p.Id) -and $p.CPU -ne $null) {
            $d=[math]::Round(((($p.CPU)-($prev[$p.Id]))/$dt/$ncpu*100),1)
            if ($p.ProcessName -eq 'iRacingSim64DX11') { $simPct=$d }
            elseif ($p.ProcessName -eq 'pi_server') { $piPct=$d }
        }
    }
    $prev=@{}; foreach ($p in $cur) { $prev[$p.Id]=$p.CPU }; $lastT=$now

    # ---- hard pagefaults / free RAM ----
    $hf='';$ram=''
    try { $m=Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop; $hf=[int]$m.PagesInputPersec } catch {}
    try { $ram=[int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1024) } catch {}

    # ---- write row ----
    ($now.ToString('HH:mm:ss'),$plan,$ccd0,$ccd1,$busyIdx,$busyPct,$c0i,$c0d,$c16i,$c16d,$totDpc,$totInt,$gu,$gp,$gg,$gm,$gt,$gthr,$simRun,$simPct,$simAff,$piPct,$hf,$ram) -join ',' |
        Out-File $Csv -Append -Encoding utf8

    Write-Host ("{0:HH:mm:ss} {1} | grp0 {2}% grp1 {3}% busy#{4} {5}% | c0int {6} c{7}int {8} | GPU {9}% {10}W {11}C | sim {12}% aff {13} | pf {14}" -f `
        $now,$plan,$ccd0,$ccd1,$busyIdx,$busyPct,$c0i,$FreqFirst,$c16i,$gu,$gp,$gt,$simPct,$simAff,$hf)

    $e=((Get-Date)-$t0).TotalSeconds; if (1-$e -gt 0) { Start-Sleep -Milliseconds ([int]((1-$e)*1000)) }
}
