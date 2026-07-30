<#
    iRacing Full Diagnostic Trace  (v2)
    ---------------------------------------------------------------
    One-pass logger for everything this method tunes:
      * Power plan (confirm your plan holds - no mid-race flip from
        ParkControl/Dynamic Boost). Shown in the banner, not on every
        line; if it changes mid-session you get a loud alert row.
      * Per-CCD CPU load  -> is the sim actually on the V-Cache die?
      * CPU 0 vs the interrupt target core's interrupt/DPC time
        -> did the GPU-IRQ move work?
      * GPU util/power/clocks/temp/throttle (catch starvation freezes)
      * GPU core voltage, fan, PCIe bus load, and which limiter is
        actually holding the card back.
      * Sim CPU%/affinity, VR (pi_server) CPU%
      * Hard pagefaults/sec (the Defender/pagefault signal)
      * Free RAM

    ---------------------------------------------------------------
    WHAT CHANGED IN v2 - AND WHY IT MATTERS
    ---------------------------------------------------------------
    v1 read CPU and pagefault data from the WMI "cooked counter"
    classes (Win32_PerfFormattedData_PerfOS_Processor and
    ..._PerfOS_Memory). Those classes do not expose a raw counter -
    the WMI provider computes the per-second rate itself, dividing a
    counter delta by an interval it measures internally. When that
    interval collapses toward the 15.625 ms system timer granularity,
    two things happen at once:

      * percentages snap to a coarse grid (values appear only as
        0 / 6.25 / 12.5 / 18.75 / 25 ... and never in between), and
      * rate counters are divided by a near-zero denominator and
        blow up by three or four orders of magnitude.

    That is exactly what real v1 traces show: hardfaults_s sitting at
    a median of ~258,000/sec - about 1 GB/s of sustained paging - on
    an idle machine with 50 GB of free RAM, zero DPC time, and the
    sim not even running. The number was never real. It tripped the
    old red threshold (hf > 50) on literally every row, which is why
    the console went solid red the moment it started.

    v2 fixes the measurement rather than the threshold:

      1. All CPU and pagefault data now comes from live
         System.Diagnostics.PerformanceCounter objects created ONCE
         before the loop and polled with .NextValue() each second.
         The PDH query stays open, so the rate is computed from two
         real samples against a real interval. This is both correct
         and faster than Get-Counter, which reopens a query (and
         blocks ~1s) on every call.
      2. The pagefault alert is now sustained: it takes 3 consecutive
         samples above 500 hard faults/sec to go red. A single spike
         shows amber. 50/sec is normal file I/O and never deserved
         an alert.
      3. The console is a fixed-width table with a repeating header,
         so columns line up and stay readable while scrolling.
      4. The window is sized on startup so the line never wraps.

    NOTE ON CALIBRATION: because v1's CPU interrupt/DPC columns came
    from the same broken provider, any conclusion you drew from the
    old traces about IRQ placement or DPC load should be re-measured
    with v2. The GPU columns (nvidia-smi + Afterburner) were never
    affected and remain comparable.

    A word on timestamp gaps. A skipped second is not automatically a
    stall - this loop's own sampling can occasionally exceed its 1s
    budget. A gap only counts when the surrounding rows corroborate
    it: raised tot_dpc/tot_int, a real hardfaults_s spike, or a GPU
    util collapse.

    Afterburner-sourced sensors (voltage, mem temp, fps, limit flags,
    fan rpm) need MSI Afterburner running. Anything your card doesn't
    expose stays blank - the rest still logs.

    CSV columns are unchanged from v1, so old and new traces open in
    the same spreadsheet.

    Read-only. No admin needed. Run after reboot, launch iRacing,
    race, then Ctrl+C. CSV lands on your Desktop.
#>

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Csv = Join-Path ([Environment]::GetFolderPath('Desktop')) "iRacing-FullTrace-$stamp.csv"
$ncpu = [Environment]::ProcessorCount

# =================================================================
#  CONSOLE GEOMETRY - do this first so nothing wraps, ever
# =================================================================
# The trace line is 130 characters. If the buffer is narrower than
# that the console soft-wraps every row and the table turns to mush.
# Widen the BUFFER first, then the WINDOW - doing it the other way
# round throws when the window would exceed the buffer.
$LineWidth = 132
try {
    $rui = $Host.UI.RawUI
    $max = $rui.MaxPhysicalWindowSize

    $buf = $rui.BufferSize
    $buf.Width  = [Math]::Max($LineWidth, $buf.Width)
    $buf.Height = 9999                      # deep scrollback
    $rui.BufferSize = $buf

    $win = $rui.WindowSize
    $win.Width  = [Math]::Min($LineWidth, $max.Width)
    $win.Height = [Math]::Min(46, $max.Height)
    $rui.WindowSize = $win

    $rui.WindowTitle = 'iRacing Full Trace'
} catch {
    # Windows Terminal ignores programmatic resize. Not fatal - but
    # say so, because a narrow tab is the one thing that still
    # breaks the layout.
    Write-Host "Could not resize the window automatically (Windows Terminal blocks this)." -ForegroundColor Yellow
    Write-Host "Widen the tab to at least $LineWidth columns or the table will wrap." -ForegroundColor Yellow
}

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

# =================================================================
#  PERFORMANCE COUNTERS  (the v1 bug fix)
# =================================================================
# Created once, polled forever. Two design notes:
#
#  * "Processor Information" is preferred over "Processor". The old
#    "Processor" category cannot see past processor group 0, so on a
#    >64-thread machine it silently reports half your cores. Its
#    instances are named "group,core" (e.g. "0,13").
#  * The first .NextValue() on a rate counter is always garbage - PDH
#    has only one sample at that point. We prime every counter and
#    sleep 1s before the loop so the first logged row is already
#    valid, instead of writing one junk row to the CSV.
#
# Counter names are English. On a localised Windows install these
# lookups fail; we degrade to blank columns and warn rather than die.

$CountersOK = $false
$cPct = @(); $cInt = @(); $cDpc = @()
$cTotDpc = $null; $cTotInt = $null; $cHardFault = $null; $cAvailMB = $null

try {
    $catName = $null
    foreach ($cand in 'Processor Information', 'Processor') {
        if ([System.Diagnostics.PerformanceCounterCategory]::Exists($cand)) { $catName = $cand; break }
    }
    if (-not $catName) { throw 'no processor counter category' }

    $cat = New-Object System.Diagnostics.PerformanceCounterCategory($catName)
    $names = $cat.GetInstanceNames()

    # Order instances into true logical-CPU order.
    if ($catName -eq 'Processor Information') {
        $ordered = @($names |
            Where-Object { $_ -match '^\d+,\d+$' } |
            Sort-Object @{ Expression = { [int](($_ -split ',')[0]) } },
                        @{ Expression = { [int](($_ -split ',')[1]) } })
    } else {
        $ordered = @($names |
            Where-Object { $_ -match '^\d+$' } |
            Sort-Object @{ Expression = { [int]$_ } })
    }
    if (-not $ordered -or $ordered.Count -lt 1) { throw 'no processor instances' }

    # Trust the counter set over ProcessorCount if they disagree.
    if ($ordered.Count -ne $ncpu) { $ncpu = $ordered.Count }
    if ($FreqFirst -lt 1 -or $FreqFirst -ge $ncpu) { $FreqFirst = [int]($ncpu / 2) }

    foreach ($i in $ordered) {
        $cPct += New-Object System.Diagnostics.PerformanceCounter($catName, '% Processor Time',  $i, $true)
        $cInt += New-Object System.Diagnostics.PerformanceCounter($catName, '% Interrupt Time', $i, $true)
        $cDpc += New-Object System.Diagnostics.PerformanceCounter($catName, '% DPC Time',       $i, $true)
    }
    $cTotDpc = New-Object System.Diagnostics.PerformanceCounter($catName, '% DPC Time',       '_Total', $true)
    $cTotInt = New-Object System.Diagnostics.PerformanceCounter($catName, '% Interrupt Time', '_Total', $true)

    # Pages Input/sec == hard faults resolved from disk. This is the
    # counter v1 got wrong.
    $cHardFault = New-Object System.Diagnostics.PerformanceCounter('Memory', 'Pages Input/sec', '', $true)
    $cAvailMB   = New-Object System.Diagnostics.PerformanceCounter('Memory', 'Available MBytes', '', $true)

    # Prime every counter, then wait a full interval.
    foreach ($c in $cPct + $cInt + $cDpc) { $null = $c.NextValue() }
    $null = $cTotDpc.NextValue(); $null = $cTotInt.NextValue()
    $null = $cHardFault.NextValue(); $null = $cAvailMB.NextValue()
    Start-Sleep -Seconds 1

    $CountersOK = $true
} catch {
    Write-Host "Performance counters unavailable: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "CPU and pagefault columns will stay blank. If this is a localised Windows," -ForegroundColor Red
    Write-Host "or the counter registry is damaged, run:  lodctr /R" -ForegroundColor Red
}

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

# Blank cells print as a dash so an empty column is visibly empty
# rather than looking like a zero.
function Cell($s) { if ($null -eq $s -or "$s" -eq '') { '-' } else { "$s" } }

# ---- probe nvidia-smi once, not every second --------------------
$GpuQueryBase  = 'utilization.gpu,power.draw,clocks.current.graphics,clocks.current.memory,temperature.gpu,utilization.memory,memory.used,fan.speed,temperature.memory,pstate'
$ThrottleField = ''
foreach ($cand in @('clocks_throttle_reasons.active','clocks_event_reasons.active')) {
    try {
        $probe = (& nvidia-smi --query-gpu=$cand --format=csv,noheader,nounits 2>&1) -join ''
        if ($probe -match '0x[0-9A-Fa-f]+') { $ThrottleField = $cand; break }
    } catch {}
}
$GpuQuery = if ($ThrottleField) { "$GpuQueryBase,$ThrottleField" } else { $GpuQueryBase }

# ---- CSV header: unchanged from v1 ------------------------------
'timestamp,power_plan,ccd0_cpu,ccd1_cpu,busy_core,busy_pct,cpu0_int,cpu0_dpc,freqcore_int,freqcore_dpc,tot_dpc,tot_int,gpu_util,gpu_power_w,gpu_gclk,gpu_mclk,gpu_temp,gpu_throttle,sim_run,sim_cpu,sim_aff,vr_pi_cpu,hardfaults_s,free_ram_mb,gpu_volt_mv,fan_pct,mem_ctrl_util,vram_used_mb,mem_temp_c,gpu_fps,gpu_frametime_ms,pstate,volt_limit,power_limit,temp_limit,noload_limit,fan_rpm,pcie_bus_pct,fb_usage_pct' |
    Out-File $Csv -Encoding utf8

# baseline for per-process CPU delta
$prev = @{}; Get-Process | ForEach-Object { $prev[$_.Id] = $_.CPU }; $lastT = Get-Date

# ---- power plan: read once, then every 10th iteration -----------
$plan = ''
try { $l=(powercfg /getactivescheme) -join ' '; if ($l -match '\(([^)]+)\)') { $plan=$Matches[1] } } catch {}
$planBase = $plan

$abProbe = Get-AbSensors

# =================================================================
#  TABLE LAYOUT
# =================================================================
# One format string drives both the header and every data row, so
# they cannot drift apart. 20 fields, 130 columns.
$Fmt = '{0,8} {1,5} {2,5} {3,9} {4,6} {5,5} {6,5} {7,5} {8,5} {9,5} {10,5} {11,5} {12,6} {13,4} {14,5} {15,5} {16,6} {17,-5} {18,6} {19,6}'

$HeadB = $Fmt -f 'TIME','G0%','G1%','BUSIEST','PF/s','C0int','C0dpc','CNint','CNdpc','tDPC','tINT',
                 'GPU%','GPU-W','GPUC','mV','FAN%','PCIE%','LIM','SIM%','vrCPU%'
$RowWidth = $HeadB.Length
$Rule = '-' * $RowWidth

# Group banner. Built by column position rather than hand-counted
# spaces, so it cannot drift out of alignment if a width is tweaked.
function New-Band([int]$width, [object[]]$spans) {
    $a = New-Object 'char[]' $width
    for ($i = 0; $i -lt $width; $i++) { $a[$i] = ' ' }
    foreach ($s in $spans) {
        $len = [int]$s.Len
        if ($len -lt 4) { continue }
        $lbl   = [string]$s.Label
        $inner = $len - 2
        if ($lbl.Length -gt $inner) { $lbl = $lbl.Substring(0, $inner) }
        $pad   = $inner - $lbl.Length
        $left  = [int]($pad / 2)
        $txt   = '|' + ('-' * $left) + $lbl + ('-' * ($pad - $left)) + '|'
        for ($i = 0; $i -lt $txt.Length; $i++) {
            $p = [int]$s.Start + $i
            if ($p -ge 0 -and $p -lt $width) { $a[$p] = $txt[$i] }
        }
    }
    -join $a
}

$HeadA = New-Band $RowWidth @(
    @{ Start = 9;   Len = 21; Label = ' CPU LOAD % ' },
    @{ Start = 38;  Len = 35; Label = ' INTERRUPT / DPC % ' },
    @{ Start = 74;  Len = 42; Label = ' GPU ' },
    @{ Start = 117; Len = 13; Label = ' PROC % ' }
)

Write-Host ""
Write-Host "  iRacing Full Trace v2" -ForegroundColor Cyan
Write-Host "  CSV -> $Csv" -ForegroundColor Cyan
Write-Host ""
Write-Host "  $ncpu logical CPUs | split at CPU $FreqFirst | G0/G1 = $Label" -ForegroundColor DarkGray
if ($planBase) {
    Write-Host "  Power plan: $planBase" -ForegroundColor DarkGray
    Write-Host "  (an alert row prints if this changes mid-session)" -ForegroundColor DarkGray
}
if ($Topology -eq 'dual') {
    Write-Host "  Watch: G0 busy / G1 idle = sim on the right die | C0int low + CNint high = GPU IRQ moved" -ForegroundColor DarkGray
} else {
    Write-Host "  Watch: C0int low + CNint high = GPU IRQ moved (no pinning to check on a single-CCD chip)" -ForegroundColor DarkGray
}
if ($CountersOK) {
    Write-Host "  Perf counters: LIVE (PDH rate counters - v1's WMI cooked-counter bug is gone)" -ForegroundColor Green
}
if ($abProbe.fan -ne '' -or $abProbe.voltlim -ne '' -or $abProbe.volt -ne '') {
    Write-Host "  Afterburner shared memory: CONNECTED (voltage, fan, limit flags, PCIe load)" -ForegroundColor Green
} else {
    Write-Host "  Afterburner shared memory: not found - start MSI Afterburner for voltage/fan/limits" -ForegroundColor Yellow
}
if (-not $ThrottleField) {
    Write-Host "  nvidia-smi throttle reasons: unavailable on this driver - gpu_throttle stays blank" -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "  Colour: grey normal | amber GPU power/temp limited or a single PF spike" -ForegroundColor DarkGray
Write-Host "          red = 3+ consecutive seconds above 500 hard faults/sec" -ForegroundColor DarkGray

# Final width check. The buffer may be wide enough while the visible
# window is not - that leaves the table intact but scrolled off to
# the right, which reads as "broken" if you don't know to look.
try {
    $vis = $Host.UI.RawUI.WindowSize.Width
    if ($vis -lt $RowWidth) {
        Write-Host ""
        Write-Host "  NOTE: window is $vis columns, table is $RowWidth." -ForegroundColor Yellow
        Write-Host "  Rows are intact but the right-hand columns are off-screen - widen the" -ForegroundColor Yellow
        Write-Host "  window, or shrink the font (Ctrl+Minus), to see GPU/SIM columns." -ForegroundColor Yellow
    }
} catch {}

Write-Host ""
Write-Host "  Launch iRacing and race. Ctrl+C to stop." -ForegroundColor Cyan
Write-Host ""

# ---- pagefault alert state --------------------------------------
# v1 went red at >50/sec, which normal file I/O clears constantly.
# A real paging problem is sustained, so require both a meaningful
# rate and persistence before crying wolf.
$PF_WARN     = 500
$PF_SUSTAIN  = 3
$pfStreak    = 0

$iter = 0
while ($true) {
    $t0 = Get-Date; $now = Get-Date

    # ---- per-core CPU / interrupt / DPC via live PDH counters ----
    $ccd0='';$ccd1='';$busyIdx='';$busyPct='';$c0i='';$c0d='';$c16i='';$c16d='';$totDpc='';$totInt=''
    if ($CountersOK) {
        try {
            $pct = New-Object 'double[]' $ncpu
            for ($n = 0; $n -lt $ncpu; $n++) { $pct[$n] = $cPct[$n].NextValue() }

            $g0 = @(); $g1 = @()
            for ($n = 0; $n -lt $ncpu; $n++) {
                if ($n -lt $FreqFirst) { $g0 += $pct[$n] } else { $g1 += $pct[$n] }
            }
            if ($g0.Count) { $ccd0 = [math]::Round(($g0 | Measure-Object -Average).Average, 0) }
            if ($g1.Count) { $ccd1 = [math]::Round(($g1 | Measure-Object -Average).Average, 0) }

            $bi = 0
            for ($n = 1; $n -lt $ncpu; $n++) { if ($pct[$n] -gt $pct[$bi]) { $bi = $n } }
            $busyIdx = $bi
            $busyPct = [math]::Round($pct[$bi], 0)

            $c0i  = [math]::Round($cInt[0].NextValue(), 1)
            $c0d  = [math]::Round($cDpc[0].NextValue(), 1)
            $c16i = [math]::Round($cInt[$FreqFirst].NextValue(), 1)
            $c16d = [math]::Round($cDpc[$FreqFirst].NextValue(), 1)
            $totDpc = [math]::Round($cTotDpc.NextValue(), 1)
            $totInt = [math]::Round($cTotInt.NextValue(), 1)
        } catch {}
    }

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

    # ---- hard pagefaults / free RAM (live counters) ----
    $hf=''; $ram=''
    if ($CountersOK) {
        try { $hf  = [int][math]::Round($cHardFault.NextValue(), 0) } catch {}
        try { $ram = [int][math]::Round($cAvailMB.NextValue(), 0) }   catch {}
    }
    # String-coerce before the emptiness test. Once $ram holds an int,
    # a bare  $ram -eq ''  makes PowerShell try to cast '' to [int] and
    # throw, which would silently kill the fallback.
    if ("$ram" -eq '') {
        try { $ram=[int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1024) } catch {}
    }

    # ---- write row (CSV schema identical to v1) ----
    ($now.ToString('HH:mm:ss'),$plan,$ccd0,$ccd1,$busyIdx,$busyPct,$c0i,$c0d,$c16i,$c16d,$totDpc,$totInt,$gu,$gp,$gg,$gm,$gt,$gthr,$simRun,$simPct,$simAff,$piPct,$hf,$ram,
      $fVolt,$fFan,$gMemUtil,$gVram,$fMemT,$fFps,$fFt,$gPstate,
      $ab.voltlim,$ab.pwrlim,$ab.templim,$ab.noload,$ab.fanrpm,$ab.bus,$ab.fb) -join ',' |
        Out-File $Csv -Append -Encoding utf8

    # ---- which limiter is actually holding the GPU back? ----
    # "No load limit" is reported whenever nothing else binds,
    # including at 90%+ utilisation, so it is only meaningful when
    # the card really is idle.
    $guNum = 0; try { $guNum = [int]$gu } catch {}
    if     ($ab.voltlim -eq 1) { $lim='VOLT' }
    elseif ($ab.pwrlim  -eq 1) { $lim='PWR' }
    elseif ($ab.templim -eq 1) { $lim='TEMP' }
    elseif ($ab.noload  -eq 1 -and $guNum -lt 50) { $lim='idle' }
    elseif ($gthr -and $gthr -match '0x0*[0-9A-Fa-f]*[4CcDdEeFf]$' -and $gthr -notmatch '^0x0+$') { $lim='PWR' }
    else   { $lim='--' }

    # ---- pagefault streak ----
    $hfNum = 0; if ("$hf" -ne '') { $hfNum = [int]$hf }
    if ($hfNum -gt $PF_WARN) { $pfStreak++ } else { $pfStreak = 0 }

    # ---- power plan drift gets its own loud row, not a colour ----
    if ($planBase -and $plan -and $plan -ne $planBase) {
        Write-Host ("  *** POWER PLAN CHANGED: '{0}' -> '{1}' ***" -f $planBase, $plan) -ForegroundColor Magenta
        $planBase = $plan
    }

    # ---- repeating header so columns stay readable while scrolling ----
    if ($iter % 25 -eq 0) {
        Write-Host ""
        Write-Host $HeadA -ForegroundColor DarkGray
        Write-Host $HeadB -ForegroundColor White
        Write-Host $Rule  -ForegroundColor DarkGray
    }

    $busyCell = if ($busyIdx -ne '') { "#$busyIdx $busyPct%" } else { '-' }

    Write-Host ($Fmt -f `
        $now.ToString('HH:mm:ss'), (Cell $ccd0), (Cell $ccd1), $busyCell, (Cell $hf),
        (Cell $c0i), (Cell $c0d), (Cell $c16i), (Cell $c16d), (Cell $totDpc), (Cell $totInt),
        (Cell $gu), (Cell $gp), (Cell $gt), (Cell $fVolt), (Cell $fFan), (Cell $ab.bus), $lim,
        (Cell $simPct), (Cell $piPct)) `
        -ForegroundColor $(
            if     ($pfStreak -ge $PF_SUSTAIN)          { 'Red' }
            elseif ($hfNum -gt $PF_WARN)                { 'DarkYellow' }
            elseif ($lim -eq 'PWR' -or $lim -eq 'TEMP') { 'Yellow' }
            else                                        { 'Gray' }
        )

    $iter++
    $e=((Get-Date)-$t0).TotalSeconds; if (1-$e -gt 0) { Start-Sleep -Milliseconds ([int]((1-$e)*1000)) }
}
