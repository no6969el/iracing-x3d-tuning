<#
==============================================================================
 Test-UndervoltStability.ps1                                        v2
------------------------------------------------------------------------------
 A self-contained single-core stress + CORRECTNESS-VERIFICATION tester built
 to expose unstable Curve Optimizer / negative-offset undervolts on Ryzen
 (works on any x86 CPU, including every X3D). No downloads required.

 WHAT MAKES IT DIFFERENT FROM CoreCycler / Prime95 / y-cruncher / OCCT:
   * Verifies MATH, not just "did it crash." Every block is deterministic and
     hashed against a known-good value, so a single wrong bit on one core is
     caught as an ERROR immediately -- catching silent instability before a BSOD.
   * LIGHT / burst mode: short bursts with idle gaps so a single core keeps
     re-boosting to its MAX bin from idle -- the exact "crashes while browsing"
     condition that sustained stress tools miss (lowest volts live at max boost).
   * Per-core affinity pinning via child processes (rock-solid, race-free).
   * Live estimated per-core BOOST CLOCK (peak GHz) so you can see it's boosting.
   * WHEA hardware-error capture per core.
   * Crash forensics: the core under test is flushed to the log BEFORE it runs,
     and on the NEXT launch the tool tells you which core a prior crash died on.
   * Keeps the PC awake during the run; press Q to stop cleanly after a core.
   * CSV report export for sharing/comparing runs.

 QUICK START (elevated; PowerShell 7 only if you want AVX-512 coverage):
   pwsh -File .\Test-UndervoltStability.ps1                 # Standard preset
   pwsh -File .\Test-UndervoltStability.ps1 -Preset Thorough -Shuffle
   pwsh -File .\Test-UndervoltStability.ps1 -Preset Overnight
   pwsh -File .\Test-UndervoltStability.ps1 -Mode Light     # hunt max-boost fails
   pwsh -File .\Test-UndervoltStability.ps1 -Cores 3,11     # retest suspects

 NOTE: -SecondsPerCore is time PER PHASE. Mode 'Both' runs Light then Heavy,
       so a core takes 2 x SecondsPerCore.
==============================================================================
#>

param(
    [ValidateSet('Quick','Standard','Thorough','Overnight')]
    [string] $Preset,
    [int]    $SecondsPerCore,
    [int]    $Cycles,
    [ValidateSet('Heavy','Light','Both')]
    [string] $Mode,
    [int]    $ThreadsPerCore = 1,
    [int]    $BurstMs = 900,          # Light mode: work burst length
    [int]    $IdleMs  = 1800,         # Light mode: idle gap (lets the core drop then re-boost)
    [int[]]  $Cores,
    [switch] $Shuffle,
    [switch] $StopOnError,
    [switch] $NoClocks,               # disable live boost-clock estimate
    [string] $LogPath,
    [string] $ReportPath,

    # ---- worker parameters (used only when the script relaunches itself) ----
    [switch] $WorkerMode,
    [ValidateSet('Heavy','Light')]
    [string] $Phase = 'Heavy',
    [long]   $Affinity   = 0,
    [int]    $ThreadCount = 1,
    [int]    $BlockIters  = 0,
    [string] $Golden     = "",
    [int]    $Duration   = 0,
    [string] $Heartbeat  = "",
    [string] $ResultFile = "",
    [switch] $NoAvx512
)

# --- Auto-enable AVX-512: Vector<T> defaults to 256-bit even on AVX-512 CPUs, --
# --- so relaunch ONCE in a fresh process with the runtime width knob set to 512. --
if (-not $WorkerMode -and $env:UV_RELAUNCHED -ne '1' -and -not $NoAvx512 -and $PSVersionTable.PSEdition -eq 'Core') {
    $avx512 = $false
    try { $avx512 = [System.Runtime.Intrinsics.X86.Avx512F]::IsSupported } catch { $avx512 = $false }
    if ($avx512 -and $env:DOTNET_PreferredVectorBitWidth -ne '512') {
        if ($Cores) {
            # -Cores is an array and doesn't survive -File relaunch cleanly; do it manually instead.
            Write-Host "AVX-512 is available. To use it with -Cores, prefix the run once:" -ForegroundColor Yellow
            Write-Host ("  `$env:DOTNET_PreferredVectorBitWidth='512'; pwsh -File `"{0}`" -Cores {1}" -f $PSCommandPath, ($Cores -join ',')) -ForegroundColor Yellow
            Write-Host "  (continuing now at AVX2...)" -ForegroundColor DarkGray
        } else {
            $env:DOTNET_PreferredVectorBitWidth = '512'
            $env:UV_RELAUNCHED = '1'
            $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            $fwd = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $PSCommandPath)
            foreach ($kv in $PSBoundParameters.GetEnumerator()) {
                if ($kv.Value -is [System.Management.Automation.SwitchParameter]) { if ($kv.Value.IsPresent) { $fwd += "-$($kv.Key)" } }
                else { $fwd += "-$($kv.Key)"; $fwd += "$($kv.Value)" }
            }
            & $exe @fwd
            exit $LASTEXITCODE
        }
    }
}

# ---------------------------------------------------------------------------
#  Compile the compute kernel. SIMD (System.Numerics.Vector) is used when it
#  compiles; otherwise a fully portable scalar kernel is used. Orchestrator and
#  every worker use the same host exe -> same kernel -> the golden hash matches.
# ---------------------------------------------------------------------------
$template = @'
using System;
using System.Numerics;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

public static class UvKernel
{
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool   SetProcessAffinityMask(IntPtr h, IntPtr mask);
    [DllImport("kernel32.dll")] static extern uint   SetThreadExecutionState(uint f);

    public static void SetAffinity(long mask) { SetProcessAffinityMask(GetCurrentProcess(), (IntPtr)mask); }
    public static void KeepAwake(bool on)
    {
        uint ES_CONTINUOUS = 0x80000000; uint ES_SYSTEM = 0x00000001;
        SetThreadExecutionState(on ? (ES_CONTINUOUS | ES_SYSTEM) : ES_CONTINUOUS);
    }

    // One deterministic block of heavy FP work; returns an FNV-1a hash of the result.
    public static ulong Block(int iters)
    {
//__BLOCK_BODY__
    }

    public static volatile bool Stop;
    public static long  Blocks;
    public static int   ErrorBlock = -1;
    public static ulong ErrGot, ErrWant;

    // Sustained load on 'threads' threads until durationSec (or an error).
    public static int Run(int threads, int iters, ulong golden, int durationSec, string hbPath)
    {
        Stop = false; Blocks = 0; ErrorBlock = -1;
        var sw = Stopwatch.StartNew();
        var ts = new Thread[threads];
        for (int t = 0; t < threads; t++)
        {
            ts[t] = new Thread(() => {
                while (!Stop) {
                    ulong h = Block(iters);
                    long b = Interlocked.Increment(ref Blocks);
                    if (h != golden) { ErrGot = h; ErrWant = golden; ErrorBlock = (int)b; Stop = true; break; }
                    if (sw.Elapsed.TotalSeconds >= durationSec) { Stop = true; break; }
                }
            });
            ts[t].IsBackground = true;
        }
        foreach (var th in ts) th.Start();
        while (!Stop) {
            try { System.IO.File.WriteAllText(hbPath, sw.Elapsed.Ticks + " " + Interlocked.Read(ref Blocks)); } catch {}
            if (sw.Elapsed.TotalSeconds >= durationSec) Stop = true;
            Thread.Sleep(250);
        }
        foreach (var th in ts) th.Join(5000);
        try { System.IO.File.WriteAllText(hbPath, sw.Elapsed.Ticks + " " + Blocks); } catch {}
        return ErrorBlock;
    }

    // Burst/idle load: short bursts separated by idle gaps so the core keeps
    // re-boosting from idle to its highest bin (lowest voltage -> best at
    // exposing an undervolt that only fails at light load / high boost).
    public static int RunLight(int threads, int iters, ulong golden, int durationSec, int burstMs, int idleMs, string hbPath)
    {
        Stop = false; Blocks = 0; ErrorBlock = -1;
        var total = Stopwatch.StartNew();
        var ts = new Thread[threads];
        for (int t = 0; t < threads; t++)
        {
            ts[t] = new Thread(() => {
                var burst = new Stopwatch();
                while (!Stop) {
                    burst.Restart();
                    while (burst.Elapsed.TotalMilliseconds < burstMs && !Stop) {
                        ulong h = Block(iters);
                        long b = Interlocked.Increment(ref Blocks);
                        if (h != golden) { ErrGot = h; ErrWant = golden; ErrorBlock = (int)b; Stop = true; break; }
                        if (total.Elapsed.TotalSeconds >= durationSec) { Stop = true; break; }
                    }
                    if (Stop) break;
                    int slept = 0;
                    while (slept < idleMs && !Stop) { Thread.Sleep(50); slept += 50;
                        if (total.Elapsed.TotalSeconds >= durationSec) { Stop = true; break; } }
                }
            });
            ts[t].IsBackground = true;
        }
        foreach (var th in ts) th.Start();
        while (!Stop) {
            try { System.IO.File.WriteAllText(hbPath, total.Elapsed.Ticks + " " + Interlocked.Read(ref Blocks)); } catch {}
            if (total.Elapsed.TotalSeconds >= durationSec) Stop = true;
            Thread.Sleep(200);
        }
        foreach (var th in ts) th.Join(5000);
        try { System.IO.File.WriteAllText(hbPath, total.Elapsed.Ticks + " " + Blocks); } catch {}
        return ErrorBlock;
    }
}
'@

$simdBlock = @'
        int w = Vector<double>.Count;
        var a0 = new Vector<double>(1.0000001); var a1 = new Vector<double>(1.0000002);
        var a2 = new Vector<double>(1.0000003); var a3 = new Vector<double>(1.0000004);
        var a4 = new Vector<double>(0.9999999); var a5 = new Vector<double>(0.9999998);
        var a6 = new Vector<double>(0.9999997); var a7 = new Vector<double>(0.9999996);
        var c  = new Vector<double>(1.0000000007); var d = new Vector<double>(0.0000000003);
        for (int i = 0; i < iters; i++) {
            a0 = a0 * c + d; a1 = a1 * c + d; a2 = a2 * c + d; a3 = a3 * c + d;
            a4 = a4 * c + d; a5 = a5 * c + d; a6 = a6 * c + d; a7 = a7 * c + d;
            if ((i & 1023) == 0) {
                a0 = Vector.SquareRoot(a0); a1 = Vector.SquareRoot(a1);
                a2 = Vector.SquareRoot(a2); a3 = Vector.SquareRoot(a3);
                a4 = Vector.SquareRoot(a4); a5 = Vector.SquareRoot(a5);
                a6 = Vector.SquareRoot(a6); a7 = Vector.SquareRoot(a7);
            }
        }
        var sum = a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7;
        double s = 0.0; for (int k = 0; k < w; k++) s += sum[k];
        long bits = BitConverter.DoubleToInt64Bits(s);
        ulong h = 1469598103934665603UL;
        for (int b = 0; b < 8; b++) { h ^= (ulong)((bits >> (b * 8)) & 0xff); h *= 1099511628211UL; }
        return h;
'@

$scalarBlock = @'
        double a0=1.0000001, a1=1.0000002, a2=1.0000003, a3=1.0000004;
        double a4=0.9999999, a5=0.9999998, a6=0.9999997, a7=0.9999996;
        double c=1.0000000007, d=0.0000000003;
        for (int i = 0; i < iters; i++) {
            a0 = a0 * c + d; a1 = a1 * c + d; a2 = a2 * c + d; a3 = a3 * c + d;
            a4 = a4 * c + d; a5 = a5 * c + d; a6 = a6 * c + d; a7 = a7 * c + d;
            if ((i & 1023) == 0) {
                a0 = Math.Sqrt(a0); a1 = Math.Sqrt(a1); a2 = Math.Sqrt(a2); a3 = Math.Sqrt(a3);
                a4 = Math.Sqrt(a4); a5 = Math.Sqrt(a5); a6 = Math.Sqrt(a6); a7 = Math.Sqrt(a7);
            }
        }
        double s = a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7;
        long bits = BitConverter.DoubleToInt64Bits(s);
        ulong h = 1469598103934665603UL;
        for (int b = 0; b < 8; b++) { h ^= (ulong)((bits >> (b * 8)) & 0xff); h *= 1099511628211UL; }
        return h;
'@

$kernelKind = 'SIMD'
$refs = @()
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    try { $refs += [System.Numerics.Vector[double]].Assembly.Location } catch {}
}
try {
    if ($refs.Count -gt 0) { Add-Type -TypeDefinition ($template.Replace('//__BLOCK_BODY__', $simdBlock)) -ReferencedAssemblies $refs -ErrorAction Stop }
    else                   { Add-Type -TypeDefinition ($template.Replace('//__BLOCK_BODY__', $simdBlock)) -ErrorAction Stop }
} catch {
    Add-Type -TypeDefinition ($template.Replace('//__BLOCK_BODY__', $scalarBlock)) -ErrorAction Stop
    $kernelKind = 'scalar'
}

# ===========================================================================
#  WORKER MODE  -- runs inside each affinity-pinned child process.
# ===========================================================================
if ($WorkerMode) {
    try {
        [UvKernel]::SetAffinity($Affinity)
        try { (Get-Process -Id $PID).PriorityClass = 'AboveNormal' } catch {}
        $gv = [uint64]$Golden
        if ($Phase -eq 'Light') { $fb = [UvKernel]::RunLight($ThreadCount, $BlockIters, $gv, $Duration, $BurstMs, $IdleMs, $Heartbeat) }
        else                    { $fb = [UvKernel]::Run($ThreadCount, $BlockIters, $gv, $Duration, $Heartbeat) }
        if ($fb -lt 0) { "OK $([UvKernel]::Blocks)" | Set-Content -Path $ResultFile -Encoding ASCII; exit 0 }
        else {
            "ERROR block=$fb got=$([UvKernel]::ErrGot) want=$([UvKernel]::ErrWant) blocks=$([UvKernel]::Blocks)" |
                Set-Content -Path $ResultFile -Encoding ASCII
            exit 2
        }
    } catch { "EXC $($_.Exception.Message)" | Set-Content -Path $ResultFile -Encoding ASCII; exit 3 }
}

# ===========================================================================
#  ORCHESTRATOR MODE
# ===========================================================================
$ErrorActionPreference = 'Stop'

if (-not $PSCommandPath) {
    Write-Host "Save this script to a .ps1 file and run it from that file (it relaunches" -ForegroundColor Red
    Write-Host "itself to pin each core, which needs a file path)." -ForegroundColor Red
    return
}

# ---- Preset defaults (only fill in what the user did not explicitly set) --
switch ($Preset) {
    'Quick'     { $d = @{ Mode='Heavy'; SecondsPerCore=120; Cycles=1; Shuffle=$false } }
    'Standard'  { $d = @{ Mode='Both';  SecondsPerCore=180; Cycles=1; Shuffle=$false } }
    'Thorough'  { $d = @{ Mode='Both';  SecondsPerCore=300; Cycles=2; Shuffle=$true  } }
    'Overnight' { $d = @{ Mode='Both';  SecondsPerCore=600; Cycles=6; Shuffle=$true  } }
    default     { $d = @{ Mode='Both';  SecondsPerCore=180; Cycles=1; Shuffle=$false } }
}
if (-not $PSBoundParameters.ContainsKey('Mode'))           { $Mode           = $d.Mode }
if (-not $PSBoundParameters.ContainsKey('SecondsPerCore'))  { $SecondsPerCore = $d.SecondsPerCore }
if (-not $PSBoundParameters.ContainsKey('Cycles'))          { $Cycles         = $d.Cycles }
if (-not $PSBoundParameters.ContainsKey('Shuffle') -and $d.Shuffle) { $Shuffle = [switch]$true }

$stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$scriptDir = Split-Path $PSCommandPath -Parent
if (-not $LogPath)    { $LogPath    = Join-Path $scriptDir 'undervolt_test_log.txt' }
if (-not $ReportPath) { $ReportPath = Join-Path $scriptDir "undervolt_results_$stamp.csv" }

$hostExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$script:showClocks = -not $NoClocks
$canKeys = $false; try { $null = [Console]::KeyAvailable; $canKeys = $true } catch { $canKeys = $false }

function Write-Log { param([string]$Text)
    $line = "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $Text
    try { $sw = [System.IO.StreamWriter]::new($LogPath, $true); $sw.WriteLine($line); $sw.Flush(); $sw.Close() } catch {}
}
function Format-HMS { param([double]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $t = [TimeSpan]::FromSeconds([math]::Round($Seconds))
    '{0:00}:{1:00}:{2:00}' -f [int]$t.TotalHours, $t.Minutes, $t.Seconds
}
function Get-CoreClockMHz { param([int]$Lp)
    if (-not $script:showClocks) { return 0 }
    try {
        $c = Get-Counter -Counter "\Processor Information(0,$Lp)\% Processor Performance" -ErrorAction Stop
        return [int]($script:baseMHz * $c.CounterSamples[0].CookedValue / 100)
    } catch { $script:showClocks = $false; return 0 }
}

# ---- Topology ------------------------------------------------------------
$cpu       = Get-CimInstance Win32_Processor | Select-Object -First 1
$physCores = [int]$cpu.NumberOfCores
$logCores  = [int]$cpu.NumberOfLogicalProcessors
$smtOn     = ($logCores -ge ($physCores * 2))
$script:baseMHz = [int]$cpu.MaxClockSpeed
if ($kernelKind -eq 'SIMD') { try { $vecWidth = [System.Numerics.Vector[double]]::Count } catch { $vecWidth = 4 } } else { $vecWidth = 1 }
$vecName = switch ($vecWidth) { 1 {'scalar FP (portable)'} 2 {'SSE2 128-bit'} 4 {'AVX2 256-bit'} 8 {'AVX-512 512-bit'} default {"${vecWidth}x64-bit"} }

# physical core -> affinity mask, and the primary logical index (for clock readout)
$coreMasks = @{}; $corePrimaryLp = @{}
for ($i = 0; $i -lt $physCores; $i++) {
    if ($smtOn) {
        $lo = 2 * $i; $corePrimaryLp[$i] = $lo
        if ($ThreadsPerCore -ge 2) { $coreMasks[$i] = ([long]1 -shl $lo) -bor ([long]1 -shl ($lo + 1)) }
        else                       { $coreMasks[$i] =  [long]1 -shl $lo }
    } else { $corePrimaryLp[$i] = $i; $coreMasks[$i] = [long]1 -shl $i }
}
$effThreads = if ($smtOn) { [math]::Min($ThreadsPerCore, 2) } else { 1 }

$coreList = if ($Cores) { @($Cores | Where-Object { $coreMasks.ContainsKey($_) }) } else { @(0..($physCores - 1)) }
if (-not $coreList -or $coreList.Count -eq 0) { Write-Host "No valid cores selected." -ForegroundColor Red; return }

$phases = switch ($Mode) { 'Heavy' { @('Heavy') } 'Light' { @('Light') } default { @('Light','Heavy') } }

# ---- Crash forensics from a previous run ---------------------------------
if (Test-Path $LogPath) {
    try {
        $tail = Get-Content $LogPath -Tail 100
        $suspect = $null; $idx = -1
        for ($j = $tail.Count - 1; $j -ge 0; $j--) {
            if ($tail[$j] -match 'begin core (\d+)') { $suspect = $matches[1]; $idx = $j; break }
        }
        if ($null -ne $suspect) {
            $after = $tail[$idx..($tail.Count - 1)]
            $resolved = ($after -match ("core {0}\b.*(PASS|FAIL|WHEA)" -f $suspect)) -or ($after -match 'RUN END')
            if (-not $resolved) {
                Write-Host ""
                Write-Host "  !! A previous run stopped while testing Core $suspect and never recorded a result." -ForegroundColor Magenta
                Write-Host "     If that was a hard lock/BSOD, Core $suspect is your prime suspect." -ForegroundColor Magenta
            }
        }
    } catch {}
}

# ---- Calibrate block size (~100 ms) and compute the golden hash ----------
Write-Host ""
Write-Host "  Undervolt Stability Tester v2" -ForegroundColor Cyan
Write-Host "  =============================" -ForegroundColor Cyan
Write-Host ("  CPU          : {0}" -f $cpu.Name.Trim())
Write-Host ("  Cores        : {0} physical / {1} logical (SMT {2})" -f $physCores, $logCores, ($(if($smtOn){'on'}else{'off'})))
Write-Host ("  Kernel       : {0}  [{1}]" -f $vecName, $kernelKind)
if ($vecWidth -lt 8) {
    Write-Host "                 (AVX-512 not active: needs PowerShell 7.4+/.NET 8+ on an AVX-512 CPU." -ForegroundColor DarkGray
    Write-Host "                  The script auto-enables it; if it still says AVX2, update PowerShell.)" -ForegroundColor DarkGray
} else {
    Write-Host "                 (AVX-512 512-bit engaged -- maximum current draw for undervolt testing.)" -ForegroundColor DarkGray
}
Write-Host ("  PowerShell   : {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
Write-Host "  Calibrating..." -NoNewline
$probe = 200000
$t = Measure-Command { [void][UvKernel]::Block($probe) }
$perIter = $t.TotalSeconds / $probe
$blockIters = [int][math]::Max(50000, [math]::Round(0.100 / [math]::Max($perIter, 1e-9)))
$g = @([UvKernel]::Block($blockIters), [UvKernel]::Block($blockIters), [UvKernel]::Block($blockIters))
$golden = if ($g[0] -eq $g[1] -or $g[0] -eq $g[2]) { $g[0] } elseif ($g[1] -eq $g[2]) { $g[1] } else { $g[0] }
$goldenReliable = -not (($g[0] -ne $g[1]) -and ($g[0] -ne $g[2]) -and ($g[1] -ne $g[2]))
Write-Host " done." -ForegroundColor Green
if (-not $goldenReliable) {
    Write-Host "  WARNING: reference hash was inconsistent -- the core running this script may" -ForegroundColor Yellow
    Write-Host "           itself be unstable, or RAM/EXPO is at fault. Investigate before trusting results." -ForegroundColor Yellow
}

$subTotal    = $coreList.Count * $Cycles * $phases.Count
$estTotalSec = $subTotal * ($SecondsPerCore + 2)
$finishAt    = (Get-Date).AddSeconds($estTotalSec)
Write-Host ("  Mode         : {0}   (phases/core: {1})" -f $Mode, ($phases -join '+'))
Write-Host ("  Plan         : {0} core(s) x {1} cycle(s) x {2} phase(s) x {3}s = ~{4}   (ETA {5:HH:mm})" -f `
    $coreList.Count, $Cycles, $phases.Count, $SecondsPerCore, (Format-HMS $estTotalSec), $finishAt)
Write-Host ("  Threads/core : {0}   Log: {1}" -f $effThreads, $LogPath)
if ($canKeys) { Write-Host "  Press Q at any time to stop cleanly after the current core." -ForegroundColor DarkGray }
Write-Host ""

[UvKernel]::KeepAwake($true)
Write-Log "=== RUN START === $($cpu.Name.Trim()) | $vecName/$kernelKind | blockIters=$blockIters | golden=$golden | mode=$Mode | $($coreList.Count)c x $Cycles cy x $($phases.Count)ph x ${SecondsPerCore}s"

# ---- Result accumulators -------------------------------------------------
$results = @{}
foreach ($c in $coreList) { $results[$c] = [pscustomobject]@{ Core=$c; Pass=0; Fail=0; Whea=0; PeakMHz=0; Status='pending'; Detail='' } }

$tmp = [System.IO.Path]::GetTempPath()
$script:runStart     = Get-Date
$script:completedSubs = 0
$script:currentProc  = $null
$script:abort        = $false

function Invoke-CoreTest {
    param([int]$Core,[int]$Cycle,[string]$Phase,[int]$CorePos,[int]$CoreCount)

    $mask    = $coreMasks[$Core]
    $primeLp = $corePrimaryLp[$Core]
    $hbFile  = Join-Path $tmp ("uv_hb_{0}_{1}.txt"  -f $Core, $Phase)
    $resFile = Join-Path $tmp ("uv_res_{0}_{1}.txt" -f $Core, $Phase)
    Remove-Item $hbFile, $resFile -ErrorAction SilentlyContinue

    $siblings = if ($smtOn) { if ($effThreads -ge 2) { "CPU$([int](2*$Core)),$([int](2*$Core+1))" } else { "CPU$([int](2*$Core))" } } else { "CPU$Core" }
    Write-Log ("CYCLE $Cycle : begin core $Core [$Phase] ($siblings) mask=0x{0:X}" -f $mask)   # flushed BEFORE the test

    $wheaRef = Get-Date
    $argStr = @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$PSCommandPath`"",
        '-WorkerMode','-Phase',$Phase,'-Affinity',$mask,'-ThreadCount',$effThreads,
        '-BlockIters',$blockIters,'-Golden',"$golden",'-Duration',$SecondsPerCore,
        '-BurstMs',$BurstMs,'-IdleMs',$IdleMs,'-Heartbeat',"`"$hbFile`"",'-ResultFile',"`"$resFile`""
    ) -join ' '
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $hostExe; $psi.Arguments = $argStr
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $script:currentProc = $proc

    $coreStart = Get-Date
    $graceSec  = [math]::Max(25, ($BurstMs + $IdleMs) / 1000 * 3)
    $stallSec  = [math]::Max(15, ($BurstMs + $IdleMs) / 1000 * 3)
    $peakMHz = 0; $lastClock = Get-Date

    while ($true) {
        Start-Sleep -Milliseconds 250
        $elapsed   = ((Get-Date) - $coreStart).TotalSeconds
        $remaining = $SecondsPerCore - $elapsed

        $blocks = 0; $hbAge = 999
        if (Test-Path $hbFile) {
            try {
                $blocks = [int64]((Get-Content $hbFile -Raw).Trim().Split(' ')[1])
                $hbAge  = ((Get-Date) - [System.IO.File]::GetLastWriteTime($hbFile)).TotalSeconds
            } catch {}
        }
        $stalled = ($elapsed -gt 6 -and $hbAge -gt $stallSec -and -not $proc.HasExited)

        if ($script:showClocks -and ((Get-Date) - $lastClock).TotalSeconds -ge 2) {
            $mhz = Get-CoreClockMHz -Lp $primeLp; $lastClock = Get-Date
            if ($mhz -gt $peakMHz) { $peakMHz = $mhz }
        }

        # adaptive overall time-left
        $progUnits = $script:completedSubs + [math]::Min($elapsed / $SecondsPerCore, 1)
        $ovElapsed = ((Get-Date) - $script:runStart).TotalSeconds
        $ovLeft = if ($progUnits -gt 0.05) { ($ovElapsed / $progUnits) * ($subTotal - $progUnits) } else { ($subTotal - $progUnits) * $SecondsPerCore }

        $clk  = if ($peakMHz -gt 0) { ('~{0:0.00}GHz' -f ($peakMHz/1000)) } else { '--' }
        $flag = if ($stalled) { ' [!! no heartbeat]' } else { '' }
        $line = ("[C{0}/{1} S{2}/{3}] Core {4,2} {5} {6,-5} | {7}/{8} | {9} pk | blk {10} | left {11}{12}" -f `
            $Cycle,$Cycles,($script:completedSubs+1),$subTotal,$Core,$siblings,$Phase.ToUpper(),`
            (Format-HMS $remaining),(Format-HMS $SecondsPerCore),$clk,$blocks,(Format-HMS $ovLeft),$flag)
        [Console]::Write("`r" + $line.PadRight(118).Substring(0,[math]::Min(118,$line.PadRight(118).Length)))

        if ($canKeys -and [Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'Q') { $script:abort = $true }
        }
        if ($proc.HasExited) { break }
        if ($hbAge -gt 45 -and $elapsed -gt 6) { break }          # dead heartbeat 45s+ => real soft-lock, don't wait it out
        if ($elapsed -gt ($SecondsPerCore + $graceSec)) { break }
        if ($script:abort) { break }
    }
    [Console]::Write("`r" + (' ' * 118) + "`r")

    # ---- outcome ----
    $outcome = 'pass'; $detail = ''
    if (-not $proc.HasExited) {
        try { $proc.Kill(); $proc.WaitForExit(3000) } catch {}
        if ($script:abort) { $outcome = 'aborted'; $detail = 'stopped by user' }
        else { $outcome = 'hang'; $detail = 'HANG / no-exit (killed)' }
    } else {
        $code = $proc.ExitCode
        $res  = if (Test-Path $resFile) { (Get-Content $resFile -Raw).Trim() } else { "no-result (exit $code)" }
        if     ($res -like 'OK*')    { $outcome = 'pass';    $detail = $res }
        elseif ($res -like 'ERROR*') { $outcome = 'miscalc'; $detail = $res }
        elseif ($res -like 'EXC*')   { $outcome = 'exc';     $detail = $res }
        else                         { $outcome = 'hang';    $detail = $res }
    }

    # ---- WHEA in this window ----
    $wheaN = 0
    try { $w = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=$wheaRef } -ErrorAction Stop; $wheaN = @($w).Count } catch { $wheaN = 0 }

    Remove-Item $hbFile, $resFile -ErrorAction SilentlyContinue
    $script:currentProc = $null
    [pscustomobject]@{ Outcome=$outcome; Detail=$detail; Whea=$wheaN; PeakMHz=$peakMHz }
}

# ---- Main loop -----------------------------------------------------------
try {
    for ($cycle = 1; $cycle -le $Cycles -and -not $script:abort; $cycle++) {
        $order = @($coreList)
        if ($Shuffle) { $order = @($order | Get-Random -Count $order.Count) }

        for ($p = 0; $p -lt $order.Count -and -not $script:abort; $p++) {
            $core = $order[$p]
            foreach ($phase in $phases) {
                if ($script:abort) { break }
                $o = Invoke-CoreTest -Core $core -Cycle $cycle -Phase $phase -CorePos ($p+1) -CoreCount $order.Count
                $r = $results[$core]
                if ($o.PeakMHz -gt $r.PeakMHz) { $r.PeakMHz = $o.PeakMHz }
                $tag = "$phase"
                switch ($o.Outcome) {
                    'pass' {
                        $r.Pass++
                        if ($r.Status -notin 'FAIL','WHEA') { $r.Status = 'pass' }
                        $pk = if ($o.PeakMHz -gt 0) { (' peak ~{0:0.00} GHz' -f ($o.PeakMHz/1000)) } else { '' }
                        Write-Host ("  Core {0,2} [{1,-5}] : pass{2}" -f $core,$tag,$pk) -ForegroundColor Green
                        Write-Log ("CYCLE $cycle : core $core [$phase] PASS $($o.Detail)")
                    }
                    'aborted' {
                        Write-Host ("  Core {0,2} [{1,-5}] : stopped by user" -f $core,$tag) -ForegroundColor DarkGray
                        Write-Log ("CYCLE $cycle : core $core [$phase] ABORTED")
                    }
                    default {
                        $r.Fail++; $r.Status = 'FAIL'; $r.Detail = $o.Detail
                        $label = switch ($o.Outcome) { 'miscalc' {'FAIL - wrong result (undervolt miscalc)'} 'hang' {'FAIL - hang / soft-lock'} 'exc' {'FAIL - worker exception'} default {'FAIL'} }
                        Write-Host ("  Core {0,2} [{1,-5}] : {2}" -f $core,$tag,$label) -ForegroundColor Red
                        Write-Host ("             {0}" -f $o.Detail) -ForegroundColor DarkRed
                        Write-Log ("CYCLE $cycle : core $core [$phase] FAIL $($o.Detail)")
                    }
                }
                if ($o.Whea -gt 0) {
                    $r.Whea += $o.Whea
                    if ($r.Status -ne 'FAIL') { $r.Status = 'WHEA' }
                    Write-Host ("             +{0} WHEA hardware error(s) during this core!" -f $o.Whea) -ForegroundColor Yellow
                    Write-Log ("CYCLE $cycle : core $core [$phase] WHEA x$($o.Whea)")
                }
                $script:completedSubs++
                if ($StopOnError -and $o.Outcome -in 'miscalc','hang','exc') { $script:abort = $true; Write-Host "  -StopOnError: halting." -ForegroundColor Yellow }
            }
        }
    }
}
finally {
    if ($script:currentProc -and -not $script:currentProc.HasExited) { try { $script:currentProc.Kill() } catch {} }
    [UvKernel]::KeepAwake($false)
}

# ---- Summary -------------------------------------------------------------
Write-Host ""
Write-Host "  ==============================  SUMMARY  ==============================" -ForegroundColor Cyan
$failed = @()
foreach ($c in ($results.Keys | Sort-Object)) {
    $r = $results[$c]
    $color = switch ($r.Status) { 'pass' {'Green'} 'FAIL' {'Red'} 'WHEA' {'Yellow'} default {'Gray'} }
    $tag   = switch ($r.Status) { 'pass' {'PASS'} 'FAIL' {'*** FAIL ***'} 'WHEA' {'WHEA (passed calc)'} default {$r.Status} }
    $pk = if ($r.PeakMHz -gt 0) { ('peak ~{0:0.00}GHz' -f ($r.PeakMHz/1000)) } else { '' }
    Write-Host ("  Core {0,2}: {1,-18} pass:{2} fail:{3} whea:{4}  {5}  {6}" -f $c,$tag,$r.Pass,$r.Fail,$r.Whea,$pk,$r.Detail) -ForegroundColor $color
    if ($r.Status -eq 'FAIL' -or $r.Whea -gt 0) { $failed += $c }
}
Write-Host "  =====================================================================" -ForegroundColor Cyan

try { $results.Values | Sort-Object Core | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8; Write-Host ("  Report: {0}" -f $ReportPath) -ForegroundColor DarkGray } catch {}

$totalElapsed = ((Get-Date) - $script:runStart).TotalSeconds
Write-Host ("  Total run time: {0}{1}" -f (Format-HMS $totalElapsed), $(if($script:abort){'  (stopped early)'}else{''}))
Write-Log ("=== RUN END === elapsed $(Format-HMS $totalElapsed) | failed: $($failed -join ',')")

if ($failed.Count -eq 0 -and -not $script:abort) {
    Write-Host ""
    Write-Host "  All tested cores passed. To be sure, go longer and overnight:" -ForegroundColor Green
    Write-Host "     -Preset Overnight -Shuffle" -ForegroundColor Green
} elseif ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host ("  Unstable core(s): {0}" -f ($failed -join ', ')) -ForegroundColor Red
    if ($failed.Count -ge $coreList.Count -and $coreList.Count -gt 1) {
        Write-Host "  NOTE: every core failed -> suspect RAM/EXPO or a systemic issue, not one weak" -ForegroundColor Yellow
        Write-Host "        core. Re-test with EXPO/DOCP OFF to isolate CPU vs memory." -ForegroundColor Yellow
    }
    Write-Host "  Fix: make the Curve Optimizer offset LESS negative on those cores." -ForegroundColor Yellow
    Write-Host "       From -20 all-core, raise the failing cores toward -15 / -10 (per-core CO)," -ForegroundColor Yellow
    Write-Host "       or back off the all-core value. On a dual-CCD X3D the V-Cache" -ForegroundColor Yellow
    Write-Host "       CCD usually tolerates the least undervolt." -ForegroundColor Yellow
    Write-Host ("  Then re-test just those:  -Cores {0} -Preset Thorough" -f ($failed -join ',')) -ForegroundColor Yellow
}
Write-Host ""
