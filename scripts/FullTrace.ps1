<#
    iRacing Full Diagnostic Trace  (INSTRUMENTED build, rev 3)
    ---------------------------------------------------------------
    DESIGN: log everything to the CSV, show only the readable stuff live.

    CSV (the firehose - for later analysis):
      Original 24 columns (power plan, per-CCD CPU, interrupts/DPC,
      GPU util/power/clock/mem/temp/throttle, sim & VR CPU, pagefaults,
      free RAM) PLUS:
        gpu_volt_mv, fan_pct, mem_ctrl_util, vram_used_mb, mem_temp_c,
        gpu_fps, gpu_frametime_ms, pstate,
        volt_limit, power_limit, temp_limit, noload_limit,   <- Afterburner limit flags
        fan_rpm, pcie_bus_pct, fb_usage_pct

    CONSOLE (the dashboard - only the useful, readable stuff):
      time | plan | CCD0/CCD1 | GPU util/W/clock/temp/fan | mem-ctrl% |
      LIMIT (what's holding the GPU back) | pagefaults
      Line turns yellow/red when something wants your attention.

    Afterburner-sourced sensors (voltage, mem-temp, fps, limit flags,
    fan rpm) need MSI Afterburner running. Anything your card doesn't
    expose stays blank - the rest still logs. Original columns keep
    their names/positions so older analysis still parses.

    Run after reboot, launch iRacing, race. Ctrl+C to stop.
    CSV lands on your Desktop. No admin needed.
#>

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Csv = Join-Path ([Environment]::GetFolderPath('Desktop')) "iRacing-FullTrace-$stamp.csv"
$ncpu = [Environment]::ProcessorCount

$FreqFirst = if ($env:X3D_FREQ_FIRST_CORE) { [int]$env:X3D_FREQ_FIRST_CORE } else {
    $cfgPath = Join-Path $env:APPDATA 'iRacingX3DTuning\config.json'
    $ff = 0
    if (Test-Path $cfgPath) { try { $ff = [int](Get-Content $cfgPath -Raw | ConvertFrom-Json).FreqFirst } catch {} }
    if ($ff -lt 1) { $ff = [int]($ncpu / 2) }
    $ff
}
if ($FreqFirst -ge $ncpu) { $FreqFirst = [int]($ncpu / 2) }

# ---- MSI Afterburner shared-memory reader ----
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
                '*ore voltage*'  { if ($o.volt -eq ''    -and $val -gt 0 -and $val -lt 2000)  { $o.volt    = [math]::Round($val,0) } }
                '*PU voltage*'   { if ($o.volt -eq ''    -and $val -gt 0 -and $val -lt 2000)  { $o.volt    = [math]::Round($val,0) } }
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

'timestamp,power_plan,ccd0_cpu,ccd1_cpu,busy_core,busy_pct,cpu0_int,cpu0_dpc,freqcore_int,freqcore_dpc,tot_dpc,tot_int,gpu_util,gpu_power_w,gpu_gclk,gpu_mclk,gpu_temp,gpu_throttle,sim_run,sim_cpu,sim_aff,vr_pi_cpu,hardfaults_s,free_ram_mb,gpu_volt_mv,fan_pct,mem_ctrl_util,vram_used_mb,mem_temp_c,gpu_fps,gpu_frametime_ms,pstate,volt_limit,power_limit,temp_limit,noload_limit,fan_rpm,pcie_bus_pct,fb_usage_pct' |
    Out-File $Csv -Encoding utf8

$prev = @{}; Get-Process | ForEach-Object { $prev[$_.Id] = $_.CPU }; $lastT = Get-Date

$abProbe = Get-AbSensors
Write-Host ""
Write-Host "Full trace -> $Csv" -ForegroundColor Cyan
if ($abProbe.fan -ne '' -or $abProbe.voltlim -ne '' -or $abProbe.fps -ne '') {
    Write-Host "Afterburner shared memory: CONNECTED" -ForegroundColor Green
} else {
    Write-Host "Afterburner shared memory: not found - start MSI Afterburner for fan/mem-temp/FPS/limit flags" -ForegroundColor Yellow
}
Write-Host "Logging ALL sensors to CSV. Live view below shows the readable stuff. Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""

$rowCount = 0
while($true){
    $t0 = Get-Date; $now = Get-Date

    $ccd0='';$ccd1='';$busyIdx='';$busyPct='';$c0i='';$c0d='';$c16i='';$c16d='';$totDpc='';$totInt=''
    try {
        $cpu = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -ErrorAction Stop
        $by = @{}; foreach($c in $cpu){ $by[[string]$c.Name] = $c }
        $g0 = 0..($FreqFirst-1)     | ForEach-Object { [double]$by["$_"].PercentProcessorTime }
        $g1 = $FreqFirst..($ncpu-1) | ForEach-Object { [double]$by["$_"].PercentProcessorTime }
        $ccd0 = [math]::Round(($g0 | Measure-Object -Average).Average,0)
        $ccd1 = [math]::Round(($g1 | Measure-Object -Average).Average,0)
        $bi=-1;$bv=-1; foreach($n in 0..($ncpu-1)){ $v=[double]$by["$n"].PercentProcessorTime; if($v -gt $bv){$bv=$v;$bi=$n} }
        $busyIdx=$bi; $busyPct=[math]::Round($bv,0)
        $c0i=[math]::Round([double]$by['0'].PercentInterruptTime,1);  $c0d=[math]::Round([double]$by['0'].PercentDPCTime,1)
        $c16i=[math]::Round([double]$by["$FreqFirst"].PercentInterruptTime,1); $c16d=[math]::Round([double]$by["$FreqFirst"].PercentDPCTime,1)
        $totDpc=[math]::Round([double]$by['_Total'].PercentDPCTime,1); $totInt=[math]::Round([double]$by['_Total'].PercentInterruptTime,1)
    } catch {}

    $plan=''
    try { $l=(powercfg /getactivescheme) -join ' '; if($l -match '\(([^)]+)\)'){ $plan=$Matches[1] } } catch {}

    $gu='';$gp='';$gg='';$gm='';$gt='';$gthr=''
    $gMemUtil='';$gVram='';$gFan='';$gMemT='';$gPstate=''
    try {
        $q='utilization.gpu,power.draw,clocks.current.graphics,clocks.current.memory,temperature.gpu,utilization.memory,memory.used,fan.speed,temperature.memory,pstate'
        $g=(& nvidia-smi --query-gpu=$q --format=csv,noheader,nounits) -split ','
        $gu=$g[0].Trim();$gp=$g[1].Trim();$gg=$g[2].Trim();$gm=$g[3].Trim();$gt=$g[4].Trim()
        $gMemUtil=NA $g[5].Trim(); $gVram=NA $g[6].Trim(); $gFan=NA $g[7].Trim(); $gMemT=NA $g[8].Trim(); $gPstate=NA $g[9].Trim()
    } catch {}
    try { $gthr=(& nvidia-smi --query-gpu=clocks_throttle_reasons.active --format=csv,noheader,nounits).Trim() }
    catch { try { $gthr=(& nvidia-smi --query-gpu=clocks_event_reasons.active --format=csv,noheader,nounits).Trim() } catch {} }

    $ab = Get-AbSensors
    $fVolt = $ab.volt
    $fFan  = if ($ab.fan -ne '')     { $ab.fan }     else { $gFan }
    $fMemT = if ($ab.memtemp -ne '') { $ab.memtemp } else { $gMemT }
    $fFps  = $ab.fps
    $fFt   = $ab.ftime

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

    $hf='';$ram=''
    try { $m=Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop; $hf=[int]$m.PagesInputPersec } catch {}
    try { $ram=[int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1024) } catch {}

    # ---- write EVERYTHING to CSV ----
    ($now.ToString('HH:mm:ss'),$plan,$ccd0,$ccd1,$busyIdx,$busyPct,$c0i,$c0d,$c16i,$c16d,$totDpc,$totInt,$gu,$gp,$gg,$gm,$gt,$gthr,$simRun,$simPct,$simAff,$piPct,$hf,$ram,
      $fVolt,$fFan,$gMemUtil,$gVram,$fMemT,$fFps,$fFt,$gPstate,
      $ab.voltlim,$ab.pwrlim,$ab.templim,$ab.noload,$ab.fanrpm,$ab.bus,$ab.fb) -join ',' |
        Out-File $Csv -Append -Encoding utf8

    # ---- CONSOLE: only the readable, useful stuff ----
    # What is holding the GPU back? (Afterburner flags, nvidia power-cap fallback)
    if     ($ab.voltlim -eq 1) { $lim='VOLT' }   # curve/voltage ceiling = undervolt is the limiter
    elseif ($ab.pwrlim  -eq 1) { $lim='PWR' }
    elseif ($ab.templim -eq 1) { $lim='TEMP' }
    elseif ($ab.noload  -eq 1) { $lim='idle' }
    elseif ($gthr -and $gthr -match '0x0*[0-9A-Fa-f]*[4CcDdEeFf]$' -and $gthr -notmatch '^0x0+$') { $lim='PWR' }
    else   { $lim='--' }

    $planShort = if ($plan -match 'Bitsum') { 'Bitsum' } elseif ($plan) { ($plan -split ' ')[0] } else { '?' }
    $gpI = try { [int][math]::Round([double]$gp) } catch { $gp }

    if ($rowCount % 25 -eq 0) {
        Write-Host ("{0,-8} {1,-7} {2,-9} {3,-22} {4,-6} {5,-6} {6}" -f `
            'time','plan','CCD0/CCD1','GPU util/W/clk/temp/fan','memctl','limit','pf') -ForegroundColor DarkGray
    }
    $rowCount++

    $line = "{0} {1,-7} {2,3}%/{3,-3}% GPU {4,3}% {5,4}W {6,4}MHz {7,3}C fan{8,3}% | mem {9,3}% | {10,-4} | pf {11}" -f `
        $now.ToString('HH:mm:ss'),$planShort,$ccd0,$ccd1,$gu,$gpI,$gg,$gt,$fFan,$gMemUtil,$lim,$hf

    $color = 'Gray'
    if ($planShort -ne 'Bitsum' -and $plan) { $color = 'Yellow' }
    if ($lim -eq 'PWR' -or $lim -eq 'TEMP') { $color = 'Yellow' }
    if (($hf -as [int]) -gt 50) { $color = 'Red' }
    Write-Host $line -ForegroundColor $color

    $e=((Get-Date)-$t0).TotalSeconds; if(1-$e -gt 0){ Start-Sleep -Milliseconds ([int]((1-$e)*1000)) }
}
