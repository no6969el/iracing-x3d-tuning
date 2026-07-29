<#
    iRacing Full Diagnostic Trace
    ---------------------------------------------------------------
    One-pass logger for everything this method tunes:
      * Power plan (confirm your plan holds - no mid-race flip from
        ParkControl/Dynamic Boost). The console goes yellow if the
        plan changes from whatever was active on the first sample,
        so it is correct whether you run Bitsum or Balanced.
      * Per-CCD CPU load  -> is the sim actually on the V-Cache die?
      * CPU 0 vs the interrupt target core's interrupt/DPC time
        -> did the GPU-IRQ move work?
      * GPU util/power/clocks/temp/throttle (catch starvation freezes)
      * GPU core voltage, fan, PCIe bus load, and which limiter is
        actually holding the card back - the numbers you need when
        tuning an undervolt rather than guessing from clocks alone.
      * Sim CPU%/affinity, VR (pi_server) CPU%
      * Hard pagefaults/sec (the Defender/pagefault signal)
      * Free RAM

    Core numbers come from X3D-Profiles.ps1 (every X3D SKU, validated
    against the CPUs Windows reports). On a single-CCD chip the two
    "ccd" columns are simply the low and high halves of your cores -
    the column names are kept for compatibility with older traces.

    The CSV logs everything; the console shows the readable subset.
    Line colour: grey normal, yellow when the power plan drifted or
    the GPU is power/temp limited, red when hard pagefaults spike.

    A word on timestamp gaps. Earlier versions of this guide treated
    any skipped second as a system-wide stall. That was too strong:
    this loop's own sampling work can occasionally exceed one second
    and skip a row on a perfectly healthy machine. A gap only counts
    as a real stall when the surrounding rows corroborate it - raised
    tot_dpc/tot_int, a hardfaults_s spike, or a GPU util collapse. A
    bare 2-second gap with clean counters either side is this script,
    not your system.

    Afterburner-sourced sensors (voltage, mem temp, fps, limit flags,
    fan rpm) need MSI Afterburner running. Anything your card doesn't
    expose stays blank - the rest still logs.

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

if ($Topology -eq 'dual')       { $Label = 'CCD0 / CCD1' }
elseif ($Topology -eq 'single') { $Label = 'low half / high half (single CCD)' }

# ---- MSI Afterburner shared-memory reader -----------------------
# Optional. Absent Afterburner, every column it feeds stays blank and
# the rest of the trace is unaffected.
if (-not ([System.Management.Automation.PSTypeName]'MahmReader').Type) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public class MahmReader {
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr OpenFileMapping(uint dwDesiredAccess, bool bInheritHandle, string lpName);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr MapViewOfFile(IntPtr hFileMappingObject, uint dwDesiredAccess, uint hi, uint lo, UIntPtr bytes);
    [DllImport("kernel32.dll")] static extern bool UnmapViewOfFile(IntPtr addr);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    const uint FILE_MAP_READ = 0x0004;
    public static byte[] Read() {
        IntPtr hMap = OpenFileMapping(FILE_MAP_READ, false, "MAHMSharedMemory");
        if (hMap == IntPtr.Zero) return null;
        IntPtr pView = MapViewOfFile(hMap, FILE_MAP_READ, 0, 0, UIntPtr.Zero);
        if (pView == IntPtr.Zero) { CloseHandle(hMap); return null; }
        try {
            int headerSize = Marshal.ReadInt32(pView, 8);
            int numEntries = Marshal.ReadInt32(pView, 12);
            int entrySize  = Marshal.ReadInt32(pView, 16);
            long total = (long)headerSize + (long)numEntries * (long)entrySize;
            if (total <= 0 || total > 8L*1024*1024) return null;
            byte[] buf = new byte[total];
            Marshal.Copy(pView, buf, 0, (int)total);
            return buf;
        } catch { return null; }
        finally { UnmapViewOfFile(pView); CloseHandle(hMap); }
    }
}
'@
}

# Afterburner publishes core voltage in volts on some cards and in
# millivolts on others. Detect by magnitude rather than trusting the
# units string, which is not consistently populated.
function ConvertTo-Millivolts([double]$v) {
    if ($v -lt 3) { [math]::Round($v * 1000, 0) } else { [math]::Round($v, 0) }
}

function Get-AbSensors {
    $o = @{ volt=''; fan=''; fanrpm=''; memtemp=''; fps=''; ftime='';
            voltlim=''; pwrlim=''; templim=''; noload=''; bus=''; fb='' }
    try {
        $buf = [MahmReader]::Read()
        if (-not $buf -or $buf.Length -lt 32) { return $o }
        $headerSize = [BitConverter]::ToInt32($buf,8)
        $numEntries = [BitConverter]::ToInt32($buf,12)
        $entrySize  = [BitConverter]::ToInt32($buf,16)
        if ($entrySize -lt 1304 -or $numEntries -le 0) { return $o }
        for ($i=0; $i -lt $numEntries; $i++) {
            $base = $headerSize + $i*$entrySize
            if ($base + 1304 -gt $buf.Length) { break }
            $name = [Text.Encoding]::ASCII.GetString($buf, $base, 260)
            $z = $name.IndexOf([char]0); if ($z -ge 0) { $name = $name.Substring(0,$z) }
            $val = [BitConverter]::ToSingle($buf, $base + 1300)
            if ([double]::IsNaN($val) -or [math]::Abs([double]$val) -ge 1e37) { continue }
            switch -Wildcard ($name) {
                '*ore voltage*'  { if ($o.volt -eq ''    -and $val -gt 0 -and $val -lt 2000)  { $o.volt    = ConvertTo-Millivolts $val } }
                '*PU voltage*'   { if ($o.volt -eq ''    -and $val -gt 0 -and $val -lt 2000)  { $o.volt    = ConvertTo-Millivolts $val } }
                '*Fan*speed*'    { if ($o.fan  -eq ''    -and $val -ge 0 -and $val -le 100)   { $o.fan     = [math]::Round($val,0) } }
                '*Fan*tachomet*' { if ($o.fanrpm -eq ''  -and $val -ge 0 -and $val -lt 20000) { $o.fanrpm  = [math]::Round($val,0) } }
                '*emory*emp*'    { if ($o.memtemp -eq '' -and $val -gt 0 -and $val -lt 150)   { $o.memtemp = [math]::Round($val,0) } }
                'Framerate'      { if ($o.fps  -eq ''    -and $val -gt 0 -and $val -lt 1000)  { $o.fps     = [math]::Round($val,1) } }
                'Frametime'      { if ($o.ftime -eq ''   -and $val -gt 0 -and $val -lt 1000)  { $o.ftime   = [math]::Round($val,2) } }
                'Voltage limit'  { if ($o.voltlim -eq '') { $o.voltlim = [int][math]::Round($val,0) } }
                'Power limit'    { if ($o.pwrlim  -eq '') { $o.pwrlim  = [int][math]::Round($val,0) } }
                'Temp limit'     { if ($o.templim -eq '') { $o.templim = [int][math]::Round($val,0) } }
                'No load limit'  { if ($o.noload  -eq '') { $o.noload  = [int][math]::Round($val,0) } }
                'BUS usage'      { if ($o.bus -eq ''      -and $val -ge 0 -and $val -le 100) { $o.bus = [math]::Round($val,0) } }
                'FB usage'       { if ($o.fb  -eq ''      -and $val -ge 0 -and $val -le 100) { $o.fb  = [math]::Round($val,0) } }
            }
        }
    } catch {}
    return $o
}

function NA($s) { if ($null -eq $s -or $s -match 'N/?A|Not Supported') { '' } else { $s } }
function Pad($s, $n) { if ($null -eq $s -or "$s" -eq '') { ('-' * 1).PadLeft($n) } else { "$s".PadLeft($n) } }

# ---- probe nvidia-smi once, not every second --------------------
# Older drivers expose clocks_throttle_reasons.active, newer ones
# renamed it to clocks_event_reasons.active. Resolving the name here
# lets the loop make a single nvidia-smi call instead of two, which
# is the main reason the old loop occasionally overran its 1s budget
# and skipped a row.
$GpuQueryBase  = 'utilization.gpu,power.draw,clocks.current.graphics,clocks.current.memory,temperature.gpu,utilization.memory,memory.used,fan.speed,temperature.memory,pstate'
$ThrottleField = ''
foreach ($cand in @('clocks_throttle_reasons.active','clocks_event_reasons.active')) {
    try {
        $probe = (& nvidia-smi --query-gpu=$cand --format=csv,noheader,nounits 2>&1) -join ''
        if ($probe -match '0x[0-9A-Fa-f]+') { $ThrottleField = $cand; break }
    } catch {}
}
$GpuQuery = if ($ThrottleField) { "$GpuQueryBase,$ThrottleField" } else { $GpuQueryBase }

'timestamp,power_plan,ccd0_cpu,ccd1_cpu,busy_core,busy_pct,cpu0_int,cpu0_dpc,freqcore_int,freqcore_dpc,tot_dpc,tot_int,gpu_util,gpu_power_w,gpu_gclk,gpu_mclk,gpu_temp,gpu_throttle,sim_run,sim_cpu,sim_aff,vr_pi_cpu,hardfaults_s,free_ram_mb,gpu_volt_mv,fan_pct,mem_ctrl_util,vram_used_mb,mem_temp_c,gpu_fps,gpu_frametime_ms,pstate,volt_limit,power_limit,temp_limit,noload_limit,fan_rpm,pcie_bus_pct,fb_usage_pct' |
    Out-File $Csv -Encoding utf8

# baseline for per-process CPU delta
$prev = @{}; Get-Process | ForEach-Object { $prev[$_.Id] = $_.CPU }; $lastT = Get-Date

# ---- power plan: read once here, then every 10th iteration ------
# The plan cannot change between samples without something actively
# changing it, and polling it every second cost a process spawn.
$plan = ''
try { $l=(powercfg /getactivescheme) -join ' '; if ($l -match '\(([^)]+)\)') { $plan=$Matches[1] } } catch {}
$planBase = $plan

$abProbe = Get-AbSensors

Write-Host ""
Write-Host "Full trace -> $Csv" -ForegroundColor Cyan
Write-Host "Launch iRacing and race. Ctrl+C to stop." -ForegroundColor Cyan
Write-Host "$ncpu logical CPUs | split at CPU $FreqFirst | columns ccd0/ccd1 = $Label" -ForegroundColor DarkGray
if ($Topology -eq 'dual') {
    Write-Host "Watch: CCD0 busy / CCD1 idle = sim on the right die | CPU0 int low + CPU$FreqFirst int high = GPU IRQ moved" -ForegroundColor DarkGray
} else {
    Write-Host "Watch: CPU0 int low + CPU$FreqFirst int high = GPU IRQ moved (no pinning to check on a single-CCD chip)" -ForegroundColor DarkGray
}
if ($planBase) { Write-Host "Power plan at start: $planBase - the line turns yellow if this changes mid-session" -ForegroundColor DarkGray }
if ($abProbe.fan -ne '' -or $abProbe.voltlim -ne '' -or $abProbe.volt -ne '') {
    Write-Host "Afterburner shared memory: CONNECTED (voltage, fan, limit flags, PCIe load available)" -ForegroundColor Green
} else {
    Write-Host "Afterburner shared memory: not found - start MSI Afterburner for voltage/fan/limit flags" -ForegroundColor Yellow
}
if (-not $ThrottleField) {
    Write-Host "nvidia-smi throttle reasons: unavailable on this driver - gpu_throttle will stay blank" -ForegroundColor DarkGray
}
Write-Host ""

$iter = 0
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

    # ---- power plan (cached; refreshed every 10th sample) ----
    if ($iter % 10 -eq 0) {
        try { $l=(powercfg /getactivescheme) -join ' '; if ($l -match '\(([^)]+)\)') { $plan=$Matches[1] } } catch {}
        if (-not $planBase -and $plan) { $planBase = $plan }
    }

    # ---- GPU: one nvidia-smi call per sample ----
    $gu='';$gp='';$gg='';$gm='';$gt='';$gthr=''
    $gMemUtil='';$gVram='';$gFan='';$gMemT='';$gPstate=''
    try {
        $g=(& nvidia-smi --query-gpu=$GpuQuery --format=csv,noheader,nounits) -split ','
        if ($g.Count -ge 10) {
            $gu=$g[0].Trim();$gp=$g[1].Trim();$gg=$g[2].Trim();$gm=$g[3].Trim();$gt=$g[4].Trim()
            $gMemUtil=NA $g[5].Trim(); $gVram=NA $g[6].Trim(); $gFan=NA $g[7].Trim()
            $gMemT=NA $g[8].Trim(); $gPstate=NA $g[9].Trim()
        }
        if ($g.Count -ge 11) { $gthr=$g[10].Trim() }
    } catch {}

    # ---- Afterburner sensors ----
    $ab = Get-AbSensors
    $fVolt = $ab.volt
    $fFan  = if ($ab.fan -ne '')     { $ab.fan }     else { $gFan }
    $fMemT = if ($ab.memtemp -ne '') { $ab.memtemp } else { $gMemT }
    $fFps  = $ab.fps
    $fFt   = $ab.ftime

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
    ($now.ToString('HH:mm:ss'),$plan,$ccd0,$ccd1,$busyIdx,$busyPct,$c0i,$c0d,$c16i,$c16d,$totDpc,$totInt,$gu,$gp,$gg,$gm,$gt,$gthr,$simRun,$simPct,$simAff,$piPct,$hf,$ram,
      $fVolt,$fFan,$gMemUtil,$gVram,$fMemT,$fFps,$fFt,$gPstate,
      $ab.voltlim,$ab.pwrlim,$ab.templim,$ab.noload,$ab.fanrpm,$ab.bus,$ab.fb) -join ',' |
        Out-File $Csv -Append -Encoding utf8

    # ---- which limiter is actually holding the GPU back? ----
    # "No load limit" is reported by both Afterburner and nvidia-smi
    # whenever nothing else binds, including at 90%+ utilisation, so
    # it is only meaningful when the card really is idle. Above that
    # it is reported as "--" rather than a misleading "idle".
    $guNum = 0; try { $guNum = [int]$gu } catch {}
    if     ($ab.voltlim -eq 1) { $lim='VOLT' }
    elseif ($ab.pwrlim  -eq 1) { $lim='PWR' }
    elseif ($ab.templim -eq 1) { $lim='TEMP' }
    elseif ($ab.noload  -eq 1 -and $guNum -lt 50) { $lim='idle' }
    elseif ($gthr -and $gthr -match '0x0*[0-9A-Fa-f]*[4CcDdEeFf]$' -and $gthr -notmatch '^0x0+$') { $lim='PWR' }
    else   { $lim='--' }

    Write-Host ("{0:HH:mm:ss} {1} | grp0 {2}% grp1 {3}% busy#{4} {5}% | c0int {6} c{7}int {8} | GPU {9}% {10}W {11}C {12}mV fan {13}% | pcie {14}% | lim {15} | sim {16}% aff {17} | pf {18}" -f `
        $now,$plan,$ccd0,$ccd1,$busyIdx,$busyPct,$c0i,$FreqFirst,$c16i,$gu,$gp,$gt,(Pad $fVolt 4),(Pad $fFan 3),(Pad $ab.bus 3),$lim,$simPct,$simAff,$hf) `
        -ForegroundColor $(
            if (($hf -as [int]) -gt 50) { 'Red' }
            elseif ($planBase -and $plan -and $plan -ne $planBase) { 'Yellow' }
            elseif ($lim -eq 'PWR' -or $lim -eq 'TEMP') { 'Yellow' }
            else { 'Gray' }
        )

    $iter++
    $e=((Get-Date)-$t0).TotalSeconds; if (1-$e -gt 0) { Start-Sleep -Milliseconds ([int]((1-$e)*1000)) }
}
