<#
    iRacing Full Diagnostic Trace
    ---------------------------------------------------------------
    One-pass logger for everything this investigation flagged:
      * Power plan (confirm Balanced holds, no ParkControl flip)
      * Per-CCD CPU load  -> is the sim actually on CCD0 (0-15)?
      * CPU0 vs CPU16 interrupt/DPC time -> did the GPU-IRQ move work?
      * GPU util/power/clocks/temp/throttle (catch starvation freezes)
      * Sim CPU%/affinity, VR (pi_server) CPU%
      * Hard pagefaults/sec (guide's Defender/pagefault signal)
      * Free RAM; time gaps in the log = system-wide freezes

    Uses CIM (not Get-Counter) for per-core data so it populates.
    Run after reboot, launch iRacing, race. Ctrl+C to stop.
    CSV lands on your Desktop. No admin needed.
#>

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Csv = Join-Path ([Environment]::GetFolderPath('Desktop')) "iRacing-FullTrace-$stamp.csv"
$ncpu = [Environment]::ProcessorCount

'timestamp,power_plan,ccd0_cpu,ccd1_cpu,busy_core,busy_pct,cpu0_int,cpu0_dpc,cpu16_int,cpu16_dpc,tot_dpc,tot_int,gpu_util,gpu_power_w,gpu_gclk,gpu_mclk,gpu_temp,gpu_throttle,sim_run,sim_cpu,sim_aff,vr_pi_cpu,hardfaults_s,free_ram_mb' |
    Out-File $Csv -Encoding utf8

# baseline for per-process CPU delta
$prev = @{}; Get-Process | ForEach-Object { $prev[$_.Id] = $_.CPU }; $lastT = Get-Date

Write-Host ""
Write-Host "Full trace -> $Csv" -ForegroundColor Cyan
Write-Host "Launch iRacing and race. Ctrl+C to stop." -ForegroundColor Cyan
Write-Host "Watch: CCD0 busy / CCD1 idle = sim on V-cache | c0int low + c16int high = GPU IRQ moved" -ForegroundColor DarkGray
Write-Host ""

while($true){
    $t0 = Get-Date; $now = Get-Date

    # ---- per-core CPU / interrupt / DPC via CIM ----
    $ccd0='';$ccd1='';$busyIdx='';$busyPct='';$c0i='';$c0d='';$c16i='';$c16d='';$totDpc='';$totInt=''
    try {
        $cpu = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -ErrorAction Stop
        $by = @{}; foreach($c in $cpu){ $by[[string]$c.Name] = $c }
        $g0 = 0..15  | ForEach-Object { [double]$by["$_"].PercentProcessorTime }
        $g1 = 16..31 | ForEach-Object { [double]$by["$_"].PercentProcessorTime }
        $ccd0 = [math]::Round(($g0 | Measure-Object -Average).Average,0)
        $ccd1 = [math]::Round(($g1 | Measure-Object -Average).Average,0)
        $bi=-1;$bv=-1; foreach($n in 0..($ncpu-1)){ $v=[double]$by["$n"].PercentProcessorTime; if($v -gt $bv){$bv=$v;$bi=$n} }
        $busyIdx=$bi; $busyPct=[math]::Round($bv,0)
        $c0i=[math]::Round([double]$by['0'].PercentInterruptTime,1);  $c0d=[math]::Round([double]$by['0'].PercentDPCTime,1)
        $c16i=[math]::Round([double]$by['16'].PercentInterruptTime,1); $c16d=[math]::Round([double]$by['16'].PercentDPCTime,1)
        $totDpc=[math]::Round([double]$by['_Total'].PercentDPCTime,1); $totInt=[math]::Round([double]$by['_Total'].PercentInterruptTime,1)
    } catch {}

    # ---- power plan ----
    $plan=''
    try { $l=(powercfg /getactivescheme) -join ' '; if($l -match '\(([^)]+)\)'){ $plan=$Matches[1] } } catch {}

    # ---- GPU ----
    $gu='';$gp='';$gg='';$gm='';$gt='';$gthr=''
    try {
        $g=(& nvidia-smi --query-gpu=utilization.gpu,power.draw,clocks.current.graphics,clocks.current.memory,temperature.gpu --format=csv,noheader,nounits) -split ','
        $gu=$g[0].Trim();$gp=$g[1].Trim();$gg=$g[2].Trim();$gm=$g[3].Trim();$gt=$g[4].Trim()
    } catch {}
    try { $gthr=(& nvidia-smi --query-gpu=clocks_throttle_reasons.active --format=csv,noheader,nounits).Trim() }
    catch { try { $gthr=(& nvidia-smi --query-gpu=clocks_event_reasons.active --format=csv,noheader,nounits).Trim() } catch {} }

    # ---- per-process CPU delta (sim + VR) ----
    $dt=($now-$lastT).TotalSeconds; if($dt -le 0){$dt=1}
    $cur=Get-Process
    $simPct='';$piPct='';$simRun=0;$simAff=''
    $simP = $cur | Where-Object { $_.ProcessName -eq 'iRacingSim64DX11' } | Select-Object -First 1
    if($simP){ $simRun=1; $simAff='0x'+('{0:X}' -f [int64]$simP.ProcessorAffinity) }
    foreach($p in $cur){
        if($prev.ContainsKey($p.Id) -and $p.CPU -ne $null){
            $d=[math]::Round(((($p.CPU)-($prev[$p.Id]))/$dt/$ncpu*100),1)
            if($p.ProcessName -eq 'iRacingSim64DX11'){ $simPct=$d }
            elseif($p.ProcessName -eq 'pi_server'){ $piPct=$d }
        }
    }
    $prev=@{}; foreach($p in $cur){ $prev[$p.Id]=$p.CPU }; $lastT=$now

    # ---- hard pagefaults / free RAM ----
    $hf='';$ram=''
    try { $m=Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop; $hf=[int]$m.PagesInputPersec } catch {}
    try { $ram=[int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1024) } catch {}

    # ---- write row ----
    ($now.ToString('HH:mm:ss'),$plan,$ccd0,$ccd1,$busyIdx,$busyPct,$c0i,$c0d,$c16i,$c16d,$totDpc,$totInt,$gu,$gp,$gg,$gm,$gt,$gthr,$simRun,$simPct,$simAff,$piPct,$hf,$ram) -join ',' |
        Out-File $Csv -Append -Encoding utf8

    Write-Host ("{0:HH:mm:ss} {1} | CCD0 {2}% CCD1 {3}% busy#{4} {5}% | c0int {6} c16int {7} | GPU {8}% {9}W {10}C | sim {11}% aff {12} | pf {13}" -f `
        $now,$plan,$ccd0,$ccd1,$busyIdx,$busyPct,$c0i,$c16i,$gu,$gp,$gt,$simPct,$simAff,$hf)

    $e=((Get-Date)-$t0).TotalSeconds; if(1-$e -gt 0){ Start-Sleep -Milliseconds ([int]((1-$e)*1000)) }
}
