<#
    GamePerf-Logger.ps1  -  the recording half of GamePerf
    ================================================================
    Built on FullTrace's method (scripts\FullTrace.ps1), generalised to
    any game and to VR, and made cheaper to run:

      * One 1 Hz timeline (system.csv) covering CPU per CCD, CPU 0 vs the
        interrupt core, DPC/interrupt time, effective clock, the game's
        CPU and its BUSIEST THREAD (the main-thread bottleneck tell), VR
        runtime CPU, RAM / commit / hard faults, disk throughput, GPU load,
        clocks, power, temperature, VRAM, throttle reasons and Afterburner's
        limiter flags, timer resolution and the power plan.
      * Per-frame capture (frames-N.csv) from Intel PresentMon: every
        frame's time, how long the CPU and the GPU were busy on it, and
        whether it was displayed. This is what turns "it felt stuttery"
        into "frame 41,233 took 38 ms and the GPU was idle for 30 of them".
      * A marker hotkey (Scroll Lock by default): press it the moment you
        feel a hitch and the analysis looks there first.
      * A snapshot of the machine (session.json) and of the game's config
        files (configs\) so the analysis - yours or an AI's - knows what
        the frames were rendered with.

    COST
    ----
    Every per-second read is done by the compiled helpers in
    GamePerf.Native.cs: three counter-category reads, one long-running
    nvidia-smi (not one process launch a second), one Afterburner
    shared-memory read and a tail of PresentMon's file. The loop times
    itself into the loop_ms column, and session.json records the
    logger's own average CPU so you can see what it cost.

    On a dual-CCD X3D chip with V-Cache on CCD0 the logger, nvidia-smi
    and PresentMon pin themselves to the frequency die so they never
    compete with the game for V-Cache cores.

    SILENT BY DESIGN
    ----------------
    No window, ever, and no sound unless you ask for one (-Beep). It runs
    inside GamePerf.exe (or a hidden PowerShell), and everything it starts -
    nvidia-smi, PresentMon - is started with no console at all, so nothing
    flashes over the game or steals focus. The app shows its progress.

    RUNNING IT
    ----------
    From the app: Start logging. On its own:

        powershell -ExecutionPolicy Bypass -File GamePerf-Logger.ps1 -Game iRacingSim64DX11.exe -Mode VR -TargetFps 90

    Ctrl+C (console), the app's Stop button (it drops stop.flag in the
    session folder) or closing the app ends the session. The analysis
    runs automatically afterwards.

    Per-frame capture needs administrator rights (or membership of the
    "Performance Log Users" group). Without them the 1 Hz log still runs
    and the session says why the frame columns are empty.
#>

[CmdletBinding()]
param(
    [string]$SessionDir,
    # exe name, several separated by |, or 'auto' (the focused game)
    [string]$Game = 'auto',
    [ValidateSet('Monitor', 'VR')][string]$Mode = 'Monitor',
    # frame budget for "missed frame" stats; 0 = monitor refresh / none
    [double]$TargetFps = 0,
    [string]$Label = '',
    [switch]$NoFrames,
    [string]$PresentMon = '',
    [string]$MarkerKey = 'ScrollLock',
    # off by default: the logger is silent unless you want a confirmation sound
    [switch]$Beep,
    [switch]$StopWithGame,
    [int]$ParentPid = 0,
    [switch]$NoAnalyze,
    [switch]$Quiet,
    [string[]]$ConfigFiles = @(),
    [int]$MaxMinutes = 360
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'GamePerf-Common.ps1')
. (Join-Path $PSScriptRoot 'GamePerf-Games.ps1')

$Settings = Import-GpSettings
if (-not $SessionDir) { $SessionDir = New-GpSessionDir -Settings $Settings -Hint $Label }
if (-not (Test-Path -LiteralPath $SessionDir)) { New-Item -ItemType Directory -Force -Path $SessionDir | Out-Null }

# The app writes its choices to request.json - simpler and safer than
# quoting a list of paths through an elevated command line. Explicit
# parameters win over the request.
$req = Read-GpJson (Join-Path $SessionDir 'request.json')
if ($req) {
    foreach ($p in $req.PSObject.Properties) {
        if ($PSBoundParameters.ContainsKey($p.Name)) { continue }
        switch ($p.Name) {
            'Game'         { $Game = [string]$p.Value }
            'Mode'         { $Mode = [string]$p.Value }
            'TargetFps'    { $TargetFps = ConvertTo-GpDouble $p.Value }
            'Label'        { $Label = [string]$p.Value }
            'NoFrames'     { $NoFrames = [bool]$p.Value }
            'PresentMon'   { $PresentMon = [string]$p.Value }
            'MarkerKey'    { $MarkerKey = [string]$p.Value }
            'Beep'         { $Beep = [bool]$p.Value }
            'StopWithGame' { $StopWithGame = [bool]$p.Value }
            'ParentPid'    { $ParentPid = [int]$p.Value }
            'ConfigFiles'  { $ConfigFiles = @($p.Value | ForEach-Object { [string]$_ }) }
        }
    }
}
if ([double]::IsNaN($TargetFps)) { $TargetFps = 0 }
$IsVr = ($Mode -eq 'VR')

$SysCsv     = Join-Path $SessionDir 'system.csv'
$EvCsv      = Join-Path $SessionDir 'events.csv'
$StatusPath = Join-Path $SessionDir 'status.json'
$StopFlag   = Join-Path $SessionDir 'stop.flag'
$MetaPath   = Join-Path $SessionDir 'session.json'
$SmiCsv     = Join-Path $SessionDir 'gpu-smi.csv'
$LogPath    = Join-Path $SessionDir 'logger.log'
$ConfigDir  = Join-Path $SessionDir 'configs'

function Write-GpLog {
    param([string]$Message, [string]$Color = 'Gray')
    $line = '{0}  {1}' -f [DateTime]::Now.ToString('HH:mm:ss', $GpInv), $Message
    try { [IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine) } catch { }
    if (-not $Quiet) { Write-Host "  $Message" -ForegroundColor $Color }
}

$Warnings = New-Object System.Collections.ArrayList
function Add-GpWarning([string]$Text) {
    if ($Warnings -notcontains $Text) { [void]$Warnings.Add($Text); Write-GpLog "WARNING: $Text" 'Yellow' }
}

$Status = @{ state = 'starting'; session = $SessionDir; warnings = @(); pid = $PID }
function Publish-GpStatus {
    $Status.heartbeat = [DateTime]::Now.ToString('o', $GpInv)
    $Status.warnings = $Warnings.ToArray()
    try { Write-GpJson -Path $StatusPath -Object $Status -Depth 4 } catch { }
}

Write-GpLog "GamePerf logger $GamePerfVersion -> $SessionDir" 'Cyan'
Publish-GpStatus

if (-not (Initialize-GpNative)) {
    Add-GpWarning 'The native helpers failed to compile - nothing can be measured.'
    $Status.state = 'error'; Publish-GpStatus
    exit 1
}

# ---- clear up after a logger that was killed rather than stopped -------
# A killed logger cannot stop its children: its nvidia-smi loop would poll
# forever and its PresentMon would keep an ETW session open until the game
# quits. Both are recognisable by their command lines.
# Only true orphans: the logger that started them must be gone, so a
# second logger running alongside is never touched.
try {
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='nvidia-smi.exe'" -ErrorAction Stop)) {
        if ("$($p.CommandLine)" -notlike '*gpu-smi.csv*') { continue }
        if (Get-Process -Id $p.ParentProcessId -ErrorAction SilentlyContinue) { continue }
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Write-GpLog "Stopped an orphaned nvidia-smi (pid $($p.ProcessId))."
    }
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name LIKE 'PresentMon%'" -ErrorAction Stop)) {
        $cl = "$($p.CommandLine)"
        if ($cl -match '--session_name\s+(GamePerf_(\d+))') {
            $old = $Matches[1]
            if (Get-Process -Id ([int]$Matches[2]) -ErrorAction SilentlyContinue) { continue }
            try { $t = [GamePerf.Native.Run]::Start($p.ExecutablePath, "--terminate_existing_session --session_name $old"); [void]$t.WaitForExit(5000) } catch { }
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            Write-GpLog "Stopped an orphaned PresentMon capture ($old)."
        }
    }
} catch { }

$QpcFreq  = [GamePerf.Native.Win]::QpcFrequency()
$QpcStart = [GamePerf.Native.Win]::Qpc()
$Started  = Get-Date

# ================================================================
#  CPU TOPOLOGY  (the kit's single source of truth)
# ================================================================
$X3D = $null
$Split = 0
$ProfileModule = Join-Path $GpKitScripts 'X3D-Profiles.ps1'
if (Test-Path -LiteralPath $ProfileModule) {
    try { . $ProfileModule; $X3D = Get-X3DProfile; $Split = [int]$X3D.FreqFirst } catch { $X3D = $null }
}

$Cpu = [GamePerf.Native.CpuSampler]::new($Split)
$Sys = [GamePerf.Native.SysSampler]::new()
$NCpu = [Math]::Max(1, $Cpu.LogicalCount)
if (-not $Cpu.Ok) { Add-GpWarning "CPU counters unavailable ($($Cpu.Error)). If they stay blank, run scripts\Repair-PerfCounters.ps1." ; $NCpu = [Environment]::ProcessorCount }
if ($Sys.Error) { Add-GpWarning "Some memory/disk counters are unavailable: $($Sys.Error)" }

# Keep our own work off the V-Cache die on a dual-CCD X3D (not the X3D2,
# where both dies have V-Cache and there is no "other" die).
$BgMask = [long]0
if ($X3D -and $X3D.IsX3D -and $X3D.Topology -eq 'dual' -and $X3D.TopologyKnown -and $X3D.VCacheScope -ne 'both' -and $NCpu -le 63 -and $Split -ge 1) {
    for ($i = $Split; $i -lt $NCpu; $i++) { $BgMask = $BgMask -bor ([long]1 -shl $i) }
    try { (Get-Process -Id $PID).ProcessorAffinity = [IntPtr]$BgMask; Write-GpLog "Logger pinned to CPUs $Split-$($NCpu - 1) (frequency die), away from the V-Cache cores." }
    catch { $BgMask = [long]0 }
}
function Set-GpBackgroundAffinity($Process) {
    if ($BgMask -eq 0 -or -not $Process) { return }
    try { $Process.ProcessorAffinity = [IntPtr]$BgMask } catch { }
}

# ================================================================
#  MACHINE SNAPSHOT
# ================================================================
function Get-GpRegValue([string]$Key, [string]$Name) {
    try { return (Get-ItemProperty -LiteralPath $Key -ErrorAction Stop).$Name } catch { return $null }
}

function Get-GpPowerPlan {
    # The power API, not powercfg: no process start and no console window.
    try { return [GamePerf.Native.Win]::ActivePowerPlanName() } catch { return '' }
}

function Get-GpMachineSnapshot {
    $m = [ordered]@{}
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $m.os = "$($os.Caption) $($os.Version)"
        $m.os_build = [string]$os.BuildNumber
        $m.ram_gb = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    } catch { }
    try {
        $c = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $m.cpu = ([string]$c.Name).Trim()
        $m.cpu_cores = [int]$c.NumberOfCores
        $m.cpu_logical = [int]$c.NumberOfLogicalProcessors
        $m.cpu_base_mhz = [int]$c.MaxClockSpeed
    } catch { }
    try {
        $dimms = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
        $m.ram_modules = $dimms.Count
        $speeds = @($dimms | ForEach-Object { if ($_.ConfiguredClockSpeed) { $_.ConfiguredClockSpeed } else { $_.Speed } } | Where-Object { $_ })
        if ($speeds.Count) { $m.ram_mts = [int]($speeds | Measure-Object -Minimum).Minimum }
    } catch { }
    if ($X3D) {
        $m.x3d_model = [string]$X3D.Model
        $m.x3d_profile = [string]$X3D.Profile
        $m.topology = [string]$X3D.Topology
        $m.vcache_cores = [string]$X3D.VCacheRange
        $m.vcache_scope = [string]$X3D.VCacheScope
        $m.is_x3d = [bool]$X3D.IsX3D
    }
    $m.split_core = $Cpu.Split
    $m.counter_category = $Cpu.Category
    try {
        $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction Stop)
        $m.gpus = @($gpus | ForEach-Object {
            [ordered]@{ name = [string]$_.Name; driver = [string]$_.DriverVersion
                        resolution = "$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)"
                        refresh_hz = $_.CurrentRefreshRate }
        })
        $primary = $gpus | Where-Object { $_.CurrentRefreshRate } | Sort-Object CurrentRefreshRate -Descending | Select-Object -First 1
        if ($primary) { $m.display_refresh_hz = [int]$primary.CurrentRefreshRate; $m.display_resolution = "$($primary.CurrentHorizontalResolution)x$($primary.CurrentVerticalResolution)" }
    } catch { }
    $m.power_plan = Get-GpPowerPlan
    $hags = Get-GpRegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
    $m.hags = $(if ($hags -eq 2) { 'on' } elseif ($hags -eq 1) { 'off' } else { 'default' })
    $gm = Get-GpRegValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled'
    $m.game_mode = $(if ($gm -eq 0) { 'off' } else { 'on' })
    $dvr = Get-GpRegValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled'
    $m.game_dvr = $(if ($dvr -eq 0) { 'off' } elseif ($dvr -eq 1) { 'on' } else { 'default' })
    $m.windowed_optimizations = [string](Get-GpRegValue 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings')
    $m.global_timer_resolution_requests = Get-GpRegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests'
    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
        $m.vbs = $(if ($dg.VirtualizationBasedSecurityStatus -eq 2) { 'running' } elseif ($dg.VirtualizationBasedSecurityStatus -eq 1) { 'enabled, not running' } else { 'off' })
        $m.hvci = $(if (@($dg.SecurityServicesRunning) -contains 2) { 'running' } else { 'off' })
    } catch { }
    $m.timer_res_ms = [GamePerf.Native.Win]::TimerResolutionMs()
    $m.elevated = Test-GpAdmin
    return $m
}

# ================================================================
#  GPU: one long-running nvidia-smi, tailed
# ================================================================
$SmiExe = $null
$c = Get-Command nvidia-smi.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($c) { $SmiExe = $c.Source }
elseif (Test-Path -LiteralPath "$env:SystemRoot\System32\nvidia-smi.exe") { $SmiExe = "$env:SystemRoot\System32\nvidia-smi.exe" }

$SmiInfo = [ordered]@{}
$SmiProc = $null; $SmiTail = $null; $SmiFields = @(); $SmiLast = $null; $SmiLastSeen = $null; $SmiSpawnMode = $false
if ($SmiExe) {
    try {
        $probe = [string][GamePerf.Native.Run]::Capture($SmiExe, '-i 0 --query-gpu=name,driver_version,memory.total,pcie.link.gen.max,pcie.link.gen.current,pcie.link.width.current,pcie.link.width.max,power.limit,power.max_limit,clocks.max.graphics,clocks.max.memory --format=csv,noheader,nounits', 8000)
        $probe = $probe.Trim()
        $f = $probe -split ','
        if ($f.Count -ge 11) {
            $SmiInfo = [ordered]@{ name = $f[0].Trim(); driver = $f[1].Trim(); vram_mb = $f[2].Trim()
                                   pcie_gen_max = $f[3].Trim(); pcie_gen_now = $f[4].Trim(); pcie_width_now = $f[5].Trim(); pcie_width_max = $f[6].Trim()
                                   power_limit_w = $f[7].Trim(); power_max_w = $f[8].Trim(); max_gclk = $f[9].Trim(); max_mclk = $f[10].Trim() }
        }
    } catch { }
    $thr = ''
    foreach ($cand in 'clocks_event_reasons.active', 'clocks_throttle_reasons.active') {
        try {
            $p = [string][GamePerf.Native.Run]::Capture($SmiExe, "-i 0 --query-gpu=$cand --format=csv,noheader,nounits", 8000)
            if ($p -match '0x[0-9A-Fa-f]+') { $thr = $cand; break }
        } catch { }
    }
    $SmiFields = @('timestamp', 'utilization.gpu', 'utilization.memory', 'memory.used', 'memory.total', 'power.draw', 'clocks.gr', 'clocks.mem', 'temperature.gpu', 'fan.speed', 'pstate')
    if ($thr) { $SmiFields += $thr }
    try {
        $SmiArgs = "-i 0 --query-gpu=$($SmiFields -join ',') --format=csv,noheader,nounits -lms 1000 -f `"$SmiCsv`""
        $SmiProc = [GamePerf.Native.Run]::Start($SmiExe, $SmiArgs)
        Set-GpBackgroundAffinity $SmiProc
        $SmiTail = [GamePerf.Native.FileTail]::new($SmiCsv)
        $SmiLastSeen = Get-Date
    } catch { $SmiProc = $null; $SmiSpawnMode = $true }
}

function Read-GpSmi {
    <# Latest nvidia-smi values as a hashtable keyed by query field, or $null. #>
    if (-not $SmiExe) { return $null }
    $line = $null
    if (-not $script:SmiSpawnMode) {
        $lines = $SmiTail.ReadLines(65536)
        if ($lines.Count) { $line = $lines[$lines.Count - 1]; $script:SmiLastSeen = Get-Date }
        elseif (((Get-Date) - $script:SmiLastSeen).TotalSeconds -gt 6) {
            # The looping process is not writing (old driver, -f unsupported). Fall back to
            # FullTrace's one-call-per-sample, every other second to halve the cost.
            $script:SmiSpawnMode = $true
            try { if ($SmiProc -and -not $SmiProc.HasExited) { $SmiProc.Kill() } } catch { }
            Write-GpLog 'nvidia-smi stream not updating - switching to polled mode.' 'Yellow'
        }
    }
    if ($script:SmiSpawnMode -and ($script:Iter % 2 -eq 0)) {
        try { $line = ([string][GamePerf.Native.Run]::Capture($SmiExe, "-i 0 --query-gpu=$($SmiFields -join ',') --format=csv,noheader,nounits", 3000)).Trim() } catch { }
    }
    if ($line) {
        $v = $line -split ','
        if ($v.Count -ge $SmiFields.Count) {
            $h = @{}
            for ($i = 0; $i -lt $SmiFields.Count; $i++) {
                $x = $v[$i].Trim()
                if ($x -match 'N/?A|Not Supported|\[') { $x = '' }
                $h[$SmiFields[$i]] = $x
            }
            $script:SmiLast = $h
        }
    }
    return $script:SmiLast
}

$GpuEng = $null
if (-not $SmiExe) {
    $GpuEng = [GamePerf.Native.GpuEngineSampler]::new()
    if (-not $GpuEng.Ok) { $GpuEng = $null }
}

# ---- Afterburner: resolve sensor names once, refresh every 30 s ---------
$AbNames = @{}
function Update-GpAbNames($d) {
    $want = [ordered]@{
        volt = @('GPU voltage', 'Core voltage', '*ore voltage*', '*PU voltage*')
        fan = @('Fan speed', '*Fan*speed*'); fanrpm = @('Fan tachometer', '*Fan*tachomet*')
        memtemp = @('Memory temperature', '*emory*emp*'); fps = @('Framerate'); ftime = @('Frametime')
        voltlim = @('Voltage limit'); pwrlim = @('Power limit'); templim = @('Temp limit'); noload = @('No load limit')
        bus = @('BUS usage'); fb = @('FB usage')
        usage = @('GPU usage'); temp = @('GPU temperature'); gclk = @('Core clock'); mclk = @('Memory clock'); vram = @('Memory usage')
    }
    $names = @($d.Keys)
    $map = @{}
    foreach ($k in $want.Keys) {
        foreach ($pat in $want[$k]) {
            $hit = $names | Where-Object { $_ -like $pat } | Select-Object -First 1
            if ($hit) { $map[$k] = $hit; break }
        }
    }
    $script:AbNames = $map
}
function Get-GpAb($d, [string]$Key) {
    if (-not $AbNames.ContainsKey($Key)) { return [double]::NaN }
    $v = 0.0
    if ($d.TryGetValue($AbNames[$Key], [ref]$v)) { return $v }
    return [double]::NaN
}
function ConvertTo-GpMillivolts([double]$v) {
    if ([double]::IsNaN($v) -or $v -le 0) { return [double]::NaN }
    if ($v -lt 3) { return [math]::Round($v * 1000, 0) }
    return [math]::Round($v, 0)
}

# ================================================================
#  PRESENTMON
# ================================================================
$PmExe = $null
if (-not $NoFrames) {
    if ($PresentMon -and (Test-Path -LiteralPath $PresentMon)) { $PmExe = $PresentMon } else { $PmExe = Find-GpPresentMon $Settings }
    if (-not $PmExe) { Add-GpWarning 'PresentMon not found - per-frame capture is off. Use "Get PresentMon" in the app.' }
    elseif (-not (Test-GpAdmin) -and -not (Test-GpPerfLogUser)) { Add-GpWarning 'Not running as administrator - PresentMon will be refused. Settings > "Allow it for my account" fixes this for good.' }
}
$PmSession = "GamePerf_$PID"
$PmProc = $null; $PmIndex = 0; $PmStart = $null; $PmState = 'off'; $PmFailedForPid = 0
$Live = $null
$FrameFiles = New-Object System.Collections.ArrayList
$BudgetMs = 0.0

function Start-GpFrames([string]$Exe, [int]$GamePid) {
    if (-not $PmExe -or $PmFailedForPid -eq $GamePid) { return }
    $script:PmIndex++
    $out = Join-Path $SessionDir ('frames-{0}.csv' -f $PmIndex)
    $a = @('--process_name', "`"$Exe`"", '--output_file', "`"$out`"", '--session_name', $PmSession,
           '--stop_existing_session', '--terminate_on_proc_exit', '--no_console_stats', '--qpc_time')
    try {
        $script:PmProc = [GamePerf.Native.Run]::Start($PmExe, ($a -join ' '))
        Set-GpBackgroundAffinity $PmProc
        $script:PmStart = Get-Date
        $script:PmState = 'running'
        [void]$FrameFiles.Add((Split-Path -Leaf $out))
        $script:Live = [GamePerf.Native.LiveFrames]::new($out, $BudgetMs)
        Add-GpEvent 'presentmon_start' (Split-Path -Leaf $out)
        Write-GpLog "PresentMon capturing $Exe -> $(Split-Path -Leaf $out)" 'Green'
    } catch {
        $script:PmState = 'failed'
        Add-GpWarning "PresentMon could not start: $($_.Exception.Message)"
    }
}

function Stop-GpFrames {
    if (-not $PmProc) { return }
    try {
        if (-not $PmProc.HasExited) {
            # Stopping the ETW session makes the capturing PresentMon flush its CSV and exit.
            $t = [GamePerf.Native.Run]::Start($PmExe, "--terminate_existing_session --session_name $PmSession")
            [void]$t.WaitForExit(5000)
            if (-not $PmProc.WaitForExit(5000)) { $PmProc.Kill() }
        }
    } catch { }
    if ($Live) { [void]$Live.Poll() }
    Add-GpEvent 'presentmon_stop' ''
    $script:PmProc = $null
    if ($PmState -eq 'running') { $script:PmState = 'stopped' }
}

# ================================================================
#  EVENTS + CSV
# ================================================================
$EvWriter = New-Object IO.StreamWriter($EvCsv, $false, (New-Object Text.UTF8Encoding $false))
$EvWriter.AutoFlush = $true
$EvWriter.WriteLine('timestamp,t_s,qpc,event,detail')
function Add-GpEvent([string]$Kind, [string]$Detail) {
    $q = [GamePerf.Native.Win]::Qpc()
    $t = ($q - $QpcStart) / $QpcFreq
    try { $EvWriter.WriteLine(([DateTime]::Now.ToString('HH:mm:ss.fff', $GpInv)) + ',' + (Inv $t) + ',' + (Inv $q) + ',' + $Kind + ',' + (Txt $Detail)) } catch { }
}

$Columns = @(
    'timestamp', 't_s', 'qpc', 'phase', 'game_pid', 'fg_game', 'marker',
    'cpu_total', 'ccd0_cpu', 'ccd1_cpu', 'busy_core', 'busy_pct', 'cpu_eff_mhz', 'cpu0_int', 'cpu0_dpc', 'freqcore_int', 'freqcore_dpc', 'tot_int', 'tot_dpc',
    'game_cpu', 'game_cores', 'game_top_thread', 'game_threads', 'game_ws_mb', 'game_private_mb', 'game_aff', 'vr_cpu',
    'free_ram_mb', 'commit_pct', 'hardfaults_s', 'disk_read_mb_s', 'disk_write_mb_s', 'disk_busy_pct', 'disk_queue',
    'gpu_util', 'gpu_mem_util', 'vram_used_mb', 'vram_total_mb', 'gpu_power_w', 'gpu_gclk', 'gpu_mclk', 'gpu_temp', 'fan_pct', 'pstate', 'gpu_throttle',
    'gpu_volt_mv', 'volt_limit', 'power_limit', 'temp_limit', 'noload_limit', 'pcie_bus_pct', 'fb_usage_pct', 'mem_temp_c', 'fan_rpm', 'ab_fps', 'ab_frametime_ms',
    'pm_frames', 'pm_fps', 'pm_ft_avg_ms', 'pm_ft_max_ms', 'pm_gpu_busy_ms', 'pm_cpu_busy_ms', 'pm_over_budget',
    'timer_res_ms', 'power_plan', 'loop_ms'
)
$SysWriter = New-Object IO.StreamWriter($SysCsv, $false, (New-Object Text.UTF8Encoding $false))
$SysWriter.AutoFlush = $true
$SysWriter.WriteLine($Columns -join ',')

# ================================================================
#  SNAPSHOT + START
# ================================================================
$Machine = Get-GpMachineSnapshot
if ($SmiInfo.Count) { $Machine.nvidia = $SmiInfo }
if ($TargetFps -le 0 -and -not $IsVr -and $Machine.display_refresh_hz) { $TargetFps = [double]$Machine.display_refresh_hz }
if ($TargetFps -gt 0) { $BudgetMs = 1000.0 / $TargetFps }

$VrGroup = [GamePerf.Native.ProcGroup]::new([string[]]$GpVrProcesses, $NCpu)
$Census = [GamePerf.Native.CpuCensus]::new()
$OpenXr = $null
if ($IsVr) { try { $OpenXr = Get-GpOpenXrInfo } catch { } }

$Meta = [ordered]@{
    version        = $GamePerfVersion
    started        = $Started.ToString('o', $GpInv)
    label          = $Label
    mode           = $Mode
    target_fps     = $TargetFps
    budget_ms      = $BudgetMs
    game_request   = $Game
    qpc_start      = $QpcStart
    qpc_freq       = $QpcFreq
    marker_key     = $MarkerKey
    machine        = $Machine
    vr             = [ordered]@{ runtimes_running = @($VrGroup.Found); openxr = $OpenXr }
    tools          = [ordered]@{ presentmon = $(if ($PmExe) { Split-Path -Leaf $PmExe } else { '' }); nvidia_smi = [bool]$SmiExe; gpu_engine_fallback = [bool]$GpuEng }
    game_exe = ''; game_name = ''; game_path = ''; game_version = ''
}
Write-GpJson -Path $MetaPath -Object $Meta

# ================================================================
#  GAME DETECTION
# ================================================================
$WantNames = @()
if ($Game -and $Game -ne 'auto') { $WantNames = @($Game -split '\|' | ForEach-Object { ($_.Trim() -replace '\.exe$', '') } | Where-Object { $_ }) }
$CatalogNames = @{}
foreach ($g in $GpGameCatalog) { foreach ($e in $g.Exe) { $CatalogNames[($e -replace '\.exe$', '')] = $true } }
$FgCandidate = 0; $FgStreak = 0
$GameTracker = $null; $GamePid = 0; $GameExe = ''
$ConfigsTaken = $false

function Find-GpGameProcess {
    if ($WantNames.Count) {
        foreach ($n in $WantNames) {
            $p = @(Get-Process -Name $n -ErrorAction SilentlyContinue) | Sort-Object WorkingSet64 -Descending | Select-Object -First 1
            if ($p) { return $p }
        }
        return $null
    }
    # Auto: a catalogued game running anywhere wins...
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) { if ($CatalogNames.ContainsKey($p.ProcessName)) { return $p } }
    # ...otherwise the foreground app, once it has held focus for 4 s.
    $fg = [GamePerf.Native.Win]::ForegroundPid()
    if ($fg -le 0 -or $fg -eq $PID) { $script:FgStreak = 0; return $null }
    $p = Get-Process -Id $fg -ErrorAction SilentlyContinue
    if (-not $p -or ($GpNotGames -contains $p.ProcessName)) { $script:FgStreak = 0; return $null }
    if ($fg -eq $script:FgCandidate) { $script:FgStreak++ } else { $script:FgCandidate = $fg; $script:FgStreak = 1 }
    if ($script:FgStreak -ge 4) { return $p }
    return $null
}

function Save-GpConfigSnapshot([string]$Exe, [string]$ExePath) {
    if ($script:ConfigsTaken) { return }
    $script:ConfigsTaken = $true
    try {
        New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
        $found = @(Find-GpGameConfigFiles -Exe $Exe -ExePath $ExePath -Vr:$IsVr -Settings $Settings)
        foreach ($f in $ConfigFiles) {
            if ($f -and (Test-Path -LiteralPath $f) -and -not ($found | Where-Object { $_.Path -ieq $f })) {
                $found += [pscustomobject]@{ Path = $f; Source = 'pinned'; Note = 'added by you' }
            }
        }
        $manifest = New-Object System.Collections.ArrayList
        $n = 0
        foreach ($f in $found) {
            if ($n -ge 40) { break }
            try {
                $fi = Get-Item -LiteralPath $f.Path -ErrorAction Stop
                if ($fi.Length -gt 2MB) { continue }
                $n++
                $copy = ('{0:00}-{1}' -f $n, $fi.Name)
                Copy-Item -LiteralPath $fi.FullName -Destination (Join-Path $ConfigDir $copy) -Force
                [void]$manifest.Add([ordered]@{ file = $copy; original = $fi.FullName; source = $f.Source; note = $f.Note
                                                bytes = $fi.Length; modified = $fi.LastWriteTime.ToString('o', $GpInv) })
            } catch { }
        }
        if ($IsVr -and $OpenXr) {
            $sb = New-Object Text.StringBuilder
            [void]$sb.AppendLine("Active OpenXR runtime: $($OpenXr.ActiveRuntime)")
            foreach ($l in $OpenXr.Layers) { [void]$sb.AppendLine(('Implicit layer ({0}): {1}  [{2}]' -f $l.Scope, $l.Manifest, $(if ($l.Enabled) { 'ENABLED' } else { 'disabled' }))) }
            $tk = Export-GpRegistryText -Path 'HKCU:\Software\OpenXR_Toolkit' -Depth 2
            if ($tk) { [void]$sb.AppendLine(); [void]$sb.AppendLine('OpenXR Toolkit settings (registry):'); [void]$sb.Append($tk) }
            $n++
            $copy = ('{0:00}-openxr-runtime.txt' -f $n)
            Write-GpTextFile -Path (Join-Path $ConfigDir $copy) -Text $sb.ToString()
            [void]$manifest.Add([ordered]@{ file = $copy; original = 'registry: HKLM\SOFTWARE\Khronos\OpenXR\1'; source = 'vr'; note = 'OpenXR runtime and API layers' })
        }
        Write-GpJson -Path (Join-Path $ConfigDir 'manifest.json') -Object @($manifest.ToArray())
        Write-GpLog "Saved $($manifest.Count) config file(s) to configs\"
    } catch { Add-GpWarning "Config snapshot failed: $($_.Exception.Message)" }
}

function Connect-GpGame($Proc) {
    try { $script:GameTracker = [GamePerf.Native.ProcTracker]::new($Proc.Id, $NCpu) }
    catch { Add-GpWarning "Could not open $($Proc.ProcessName): $($_.Exception.Message)"; return }
    $script:GamePid = $Proc.Id
    $script:GameExe = "$($Proc.ProcessName).exe"
    # Lock onto this exe so a restart of the same game (iRacing relaunches the sim per session) is caught.
    $script:WantNames = @($Proc.ProcessName)
    $path = $GameTracker.Path
    $entry = Find-GpGameEntry $GameExe
    $name = $Proc.ProcessName
    $ver = ''
    if ($path) {
        try {
            $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($path)
            if ($vi.ProductName) { $name = $vi.ProductName.Trim() }
            $ver = [string]$vi.ProductVersion
        } catch { }
    }
    if ($entry) { $name = $entry.Name }
    $Meta.game_exe = $GameExe; $Meta.game_name = $name; $Meta.game_path = [string]$path; $Meta.game_version = $ver
    Write-GpJson -Path $MetaPath -Object $Meta
    Add-GpEvent 'game_start' "$GameExe pid $($Proc.Id)"
    Write-GpLog "Game: $name ($GameExe, pid $($Proc.Id))" 'Green'
    Save-GpConfigSnapshot $GameExe $path
    if (-not $NoFrames) { Start-GpFrames $GameExe $Proc.Id }
}

# ================================================================
#  CONSOLE  (only when run by hand)
# ================================================================
$CtrlCIsInput = $false
$PrevTreatCtrlC = $null
if (-not $Quiet) {
    try { $PrevTreatCtrlC = [Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput = $true; $CtrlCIsInput = $true } catch { }
    Write-Host ''
    Write-Host "  Marker key: $MarkerKey  (press it when you feel a hitch)" -ForegroundColor DarkGray
    Write-Host '  Ctrl+C to stop.' -ForegroundColor DarkGray
    Write-Host ''
}

$MarkerVk = 0x91
if ($GpMarkerKeys.Contains($MarkerKey)) { $MarkerVk = [int]$GpMarkerKeys[$MarkerKey] }

# ================================================================
#  SAMPLING LOOP
# ================================================================
$Iter = 0
$Markers = 0
$MarkerThisSecond = 0
$KeyWasDown = $false
$Plan = $Machine.power_plan
$LastTimerRes = $Machine.timer_res_ms
$LoopSum = 0.0
$LoopErrors = 0
$StopReason = 'stopped'
$LastFg = 0
$Status.state = 'waiting'

try {
while ($true) {
    $t0 = [Diagnostics.Stopwatch]::StartNew()
    # One bad sample must never end a recording (inside try, any .NET
    # exception would leave the loop): log it, sparingly, and carry on.
    try {
        $now = Get-Date
        $q = [GamePerf.Native.Win]::Qpc()
        $tS = ($q - $QpcStart) / $QpcFreq

        # ---- game attach / detach -----------------------------------------
        if (-not $GameTracker -and ($Iter % 2 -eq 0)) {
            $gp = Find-GpGameProcess
            if ($gp) { Connect-GpGame $gp }
        }
        $g = $null
        if ($GameTracker) {
            $g = $GameTracker.Sample()
            if (-not $g.Alive) {
                Add-GpEvent 'game_exit' $GameExe
                Write-GpLog "$GameExe exited." 'Yellow'
                Stop-GpFrames
                $GameTracker = $null; $GamePid = 0; $g = $null
                if ($StopWithGame) { $StopReason = 'game exited'; break }
            }
        }
        # PresentMon dying within seconds while the game lives = refused (no admin / not in Performance Log Users).
        if ($PmProc -and $PmProc.HasExited) {
            $life = ((Get-Date) - $PmStart).TotalSeconds
            if ($GameTracker -and $life -lt 10) {
                $script:PmFailedForPid = $GamePid
                $PmState = 'failed'
                Add-GpWarning 'PresentMon stopped immediately - per-frame capture needs the logger to run as administrator.'
            }
            $PmProc = $null
        }

        # ---- counters ------------------------------------------------------
        $c = $Cpu.Sample()
        $s = $Sys.Sample()
        $vrCpu = $VrGroup.Sample()
        if ($Iter % 10 -eq 5) { $VrGroup.Rescan() }

        $smi = Read-GpSmi
        $ab = [GamePerf.Native.Afterburner]::Read()
        if ($ab.Count -and ($AbNames.Count -eq 0 -or $Iter % 30 -eq 0)) { Update-GpAbNames $ab }

        $gpuUtil = ''; $gpuMem = ''; $vramUsed = ''; $vramTot = ''; $gpuW = ''; $gclk = ''; $mclk = ''; $gtemp = ''; $fan = ''; $pstate = ''; $thrHex = ''
        if ($smi) {
            $gpuUtil = $smi['utilization.gpu']; $gpuMem = $smi['utilization.memory']; $vramUsed = $smi['memory.used']; $vramTot = $smi['memory.total']
            $gpuW = $smi['power.draw']; $gclk = $smi['clocks.gr']; $mclk = $smi['clocks.mem']; $gtemp = $smi['temperature.gpu']; $fan = $smi['fan.speed']; $pstate = $smi['pstate']
            if ($SmiFields.Count -gt 11) { $thrHex = $smi[$SmiFields[11]] }
        } elseif ($ab.Count) {
            # AMD / Intel with Afterburner: its own sensors.
            $gpuUtil = Get-GpAb $ab 'usage'; $gtemp = Get-GpAb $ab 'temp'; $gclk = Get-GpAb $ab 'gclk'; $mclk = Get-GpAb $ab 'mclk'; $vramUsed = Get-GpAb $ab 'vram'
        } elseif ($GpuEng) {
            $ge = $GpuEng.Sample($GamePid)
            $gpuUtil = $ge[0]; $vramUsed = $ge[2]
        }

        # ---- frames since last sample -------------------------------------
        $fw = $null
        if ($Live) { $fw = $Live.Poll() }

        # ---- slow-changing state ------------------------------------------
        if ($Iter % 10 -eq 0) {
            $p2 = Get-GpPowerPlan
            if ($p2 -and $Plan -and $p2 -ne $Plan) { Add-GpEvent 'power_plan_changed' "$Plan -> $p2"; Add-GpWarning "Power plan changed mid-session: $Plan -> $p2" }
            if ($p2) { $Plan = $p2 }
        }
        $timerRes = [GamePerf.Native.Win]::TimerResolutionMs()
        if (-not [double]::IsNaN($timerRes) -and -not [double]::IsNaN([double]$LastTimerRes) -and [math]::Abs($timerRes - $LastTimerRes) -gt 0.05) {
            Add-GpEvent 'timer_resolution_changed' ('{0} -> {1} ms' -f (Inv $LastTimerRes), (Inv $timerRes))
        }
        $LastTimerRes = $timerRes
        $fgPid = [GamePerf.Native.Win]::ForegroundPid()
        $fgGame = ''
        if ($GamePid) {
            $fgGame = [int]($fgPid -eq $GamePid)
            if ($Iter -gt 0 -and $LastFg -eq $GamePid -and $fgPid -ne $GamePid) {
                $fgName = ''
                try { $fgName = (Get-Process -Id $fgPid -ErrorAction Stop).ProcessName } catch { }
                Add-GpEvent 'focus_lost' $fgName
            }
        }
        $LastFg = $fgPid
        if ($Iter % 30 -eq 29) {
            $top = $Census.Take()
            $list = @($top.GetEnumerator() | Where-Object { $_.Key -ne 'Idle' -and $_.Key -ne ($GameExe -replace '\.exe$', '') } | Sort-Object Value -Descending | Select-Object -First 5 |
                      ForEach-Object { '{0} {1}%' -f $_.Key, (Inv ([math]::Round($_.Value, 1))) })
            if ($list.Count) { Add-GpEvent 'background_cpu' ($list -join '; ') }
        }

        # ---- write the row ------------------------------------------------
        $phase = 'wait'
        if ($g) { $phase = 'game' }
        $abFps = Get-GpAb $ab 'fps'
        $row = @(
            $now.ToString('HH:mm:ss.fff', $GpInv), (Inv $tS), (Inv $q), $phase, (Inv $(if ($GamePid) { $GamePid } else { '' })), (Inv $fgGame), (Inv $MarkerThisSecond),
            (Inv $c.Total), (Inv $c.Group0), (Inv $c.Group1), (Inv $(if ($c.BusyCore -ge 0) { $c.BusyCore } else { '' })), (Inv $c.BusyPct), (Inv $c.EffMhz),
            (Inv $c.Cpu0Int), (Inv $c.Cpu0Dpc), (Inv $c.SplitInt), (Inv $c.SplitDpc), (Inv $c.TotInt), (Inv $c.TotDpc)
        )
        if ($g) {
            $aff = ''
            if ($g.Affinity) { $aff = '0x' + $g.Affinity.ToString('X') }
            $row += @((Inv $g.CpuPct), (Inv $g.Cores), (Inv $g.TopThreadPct), (Inv $g.Threads), (Inv $g.WorkingSetMb), (Inv $g.PrivateMb), $aff)
        } else { $row += @('', '', '', '', '', '', '') }
        $row += @((Inv $vrCpu),
            (Inv $s.AvailMb), (Inv $s.CommitPct), (Inv $s.HardFaults), (Inv $s.DiskReadMBs), (Inv $s.DiskWriteMBs), (Inv $s.DiskBusyPct), (Inv $s.DiskQueue),
            (Inv $gpuUtil), (Inv $gpuMem), (Inv $vramUsed), (Inv $vramTot), (Inv $gpuW), (Inv $gclk), (Inv $mclk), (Inv $gtemp), (Inv $fan), (Inv $pstate), (Inv $thrHex),
            (Inv (ConvertTo-GpMillivolts (Get-GpAb $ab 'volt'))), (Inv (Get-GpAb $ab 'voltlim')), (Inv (Get-GpAb $ab 'pwrlim')), (Inv (Get-GpAb $ab 'templim')), (Inv (Get-GpAb $ab 'noload')),
            (Inv (Get-GpAb $ab 'bus')), (Inv (Get-GpAb $ab 'fb')), (Inv (Get-GpAb $ab 'memtemp')), (Inv (Get-GpAb $ab 'fanrpm')), (Inv $abFps), (Inv (Get-GpAb $ab 'ftime')))
        if ($fw -and $fw.Frames -gt 0) {
            $row += @((Inv $fw.Frames), (Inv (1000.0 / $fw.FtAvg)), (Inv $fw.FtAvg), (Inv $fw.FtMax), (Inv $fw.GpuBusyAvg), (Inv $fw.CpuBusyAvg), (Inv $fw.OverBudget))
        } else { $row += @((Inv $(if ($fw) { 0 } else { '' })), '', '', '', '', '', '') }
        $loopMs = $t0.Elapsed.TotalMilliseconds
        $row += @((Inv $timerRes), (Txt $Plan), (Inv $loopMs))
        $SysWriter.WriteLine($row -join ',')
        $LoopSum += $loopMs

        # ---- live status for the app --------------------------------------
        $Status.state = $(if ($GameTracker) { 'logging' } else { 'waiting' })
        $Status.elapsed_s = [math]::Round($tS, 1)
        $Status.game = $Meta.game_name
        $Status.game_exe = $GameExe
        $Status.waiting_for = $(if ($WantNames.Count) { ($WantNames -join ', ') } else { 'the focused game' })
        $Status.presentmon = $PmState
        $Status.markers = $Markers
        $Status.frames_total = $(if ($Live) { $Live.TotalFrames } else { 0 })
        $Status.fps = $(if ($fw -and $fw.Frames -gt 0) { [math]::Round(1000.0 / $fw.FtAvg, 1) } elseif (-not [double]::IsNaN($abFps)) { [math]::Round($abFps, 1) } else { $null })
        $Status.ft_max = $(if ($fw -and $fw.Frames -gt 0) { [math]::Round($fw.FtMax, 1) } else { $null })
        $Status.gpu_busy = $(if ($fw -and -not [double]::IsNaN($fw.GpuBusyAvg)) { [math]::Round($fw.GpuBusyAvg, 1) } else { $null })
        $Status.budget_ms = $BudgetMs
        $Status.gpu_util = ConvertTo-GpDouble $gpuUtil
        $Status.gpu_temp = ConvertTo-GpDouble $gtemp
        $Status.gpu_power = ConvertTo-GpDouble $gpuW
        $Status.vram_used = ConvertTo-GpDouble $vramUsed
        $Status.vram_total = ConvertTo-GpDouble $vramTot
        $Status.cpu_total = [math]::Round($c.Total, 1)
        $Status.game_thread = $(if ($g) { [math]::Round($g.TopThreadPct, 0) } else { $null })
        $Status.loop_ms = [math]::Round($loopMs, 1)
        foreach ($k in @($Status.Keys)) { if ($Status[$k] -is [double] -and [double]::IsNaN($Status[$k])) { $Status[$k] = $null } }
        Publish-GpStatus

        if (-not $Quiet -and $Iter % 5 -eq 0) {
            Write-Host ('  {0}  {1,-9} fps {2,6}  ftmax {3,6}  GPU {4,4}%  CPU {5,4}%  thread {6,4}%  markers {7}' -f
                $now.ToString('HH:mm:ss', $GpInv), $Status.state, (Format-GpNum $Status.fps 1), (Format-GpNum $Status.ft_max 1),
                (Format-GpNum $Status.gpu_util 0), (Format-GpNum $Status.cpu_total 0), (Format-GpNum $Status.game_thread 0), $Markers) -ForegroundColor Gray
        }

        $Iter++
        $MarkerThisSecond = 0
    } catch {
        $LoopErrors++
        if ($LoopErrors -le 5 -or $LoopErrors % 60 -eq 0) { Write-GpLog "Sample $Iter failed: $($_.Exception.Message)" 'Yellow' }
        $Iter++
    }

    # ---- stop conditions ----------------------------------------------
    if (Test-Path -LiteralPath $StopFlag) { $StopReason = 'stopped from the app'; break }
    if ($ParentPid -gt 0 -and $Iter % 5 -eq 0 -and -not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { $StopReason = 'app closed'; break }
    if ($tS -gt $MaxMinutes * 60) { $StopReason = "reached the $MaxMinutes-minute limit"; break }

    # ---- wait out the second, watching the marker key and Ctrl+C -------
    $stopNow = $false
    while ($t0.Elapsed.TotalMilliseconds -lt 1000) {
        $down = [GamePerf.Native.Win]::KeyDown($MarkerVk)
        if ($down -and -not $KeyWasDown) {
            $Markers++; $MarkerThisSecond++
            Add-GpEvent 'marker' "#$Markers"
            if ($Beep) { try { [System.Media.SystemSounds]::Asterisk.Play() } catch { } }
            if (-not $Quiet) { Write-Host "  >> marker #$Markers" -ForegroundColor Magenta }
        }
        $KeyWasDown = $down
        if ($CtrlCIsInput) {
            try {
                if ([Console]::KeyAvailable) {
                    $k = [Console]::ReadKey($true)
                    if ($k.Key -eq 'C' -and ($k.Modifiers -band [ConsoleModifiers]::Control)) { $stopNow = $true; break }
                }
            } catch { }
        }
        Start-Sleep -Milliseconds 25
    }
    if ($stopNow) { $StopReason = 'Ctrl+C'; break }
}
}
finally {
    # ================================================================
    #  WRAP UP  - always runs, so PresentMon's ETW session and the
    #  nvidia-smi loop never outlive the logger.
    # ================================================================
    $Status.state = 'stopping'; Publish-GpStatus
    Write-GpLog "Stopping ($StopReason)..." 'Cyan'
    Stop-GpFrames
    try { if ($SmiProc -and -not $SmiProc.HasExited) { $SmiProc.Kill() } } catch { }
    try { $SysWriter.Dispose() } catch { }

    $ended = Get-Date
    $dur = ($ended - $Started).TotalSeconds
    $bg = @()
    try {
        [void]$Census.Take()
        $bg = @($Census.Total.GetEnumerator() |
                Where-Object { $_.Key -ne 'Idle' -and $_.Key -ne ($GameExe -replace '\.exe$', '') -and $_.Key -ne ($Meta.game_exe -replace '\.exe$', '') } |
                Sort-Object Value -Descending | Select-Object -First 12 |
                ForEach-Object { [ordered]@{ name = $_.Key; cpu_s = [math]::Round($_.Value, 1); avg_pct = [math]::Round($_.Value * 100.0 / [math]::Max(1, $dur) / $NCpu, 2) } })
    } catch { }
    $selfCpu = [double]::NaN
    try { $selfCpu = (Get-Process -Id $PID).TotalProcessorTime.TotalSeconds * 100.0 / [math]::Max(1, $dur) / $NCpu } catch { }

    $Meta.ended = $ended.ToString('o', $GpInv)
    $Meta.duration_s = [math]::Round($dur, 1)
    $Meta.stop_reason = $StopReason
    $Meta.frame_files = @($FrameFiles.ToArray())
    $Meta.presentmon_state = $PmState
    $Meta.markers = $Markers
    $Meta.background_top = $bg
    $Meta.logger_cpu_pct = $(if ([double]::IsNaN($selfCpu)) { $null } else { [math]::Round($selfCpu, 2) })
    $Meta.logger_avg_loop_ms = $(if ($Iter) { [math]::Round($LoopSum / $Iter, 1) } else { $null })
    $Meta.warnings = $Warnings.ToArray()
    Write-GpJson -Path $MetaPath -Object $Meta
    Add-GpEvent 'session_end' $StopReason
    try { $EvWriter.Dispose() } catch { }
    if ($null -ne $PrevTreatCtrlC) { try { [Console]::TreatControlCAsInput = $PrevTreatCtrlC } catch { } }
    Remove-Item -LiteralPath $StopFlag -Force -ErrorAction SilentlyContinue

    if (-not $NoAnalyze) {
        $Status.state = 'analyzing'; Publish-GpStatus
        Write-GpLog 'Analysing...' 'Cyan'
        try {
            & (Join-Path $PSScriptRoot 'GamePerf-Analyze.ps1') -SessionDir $SessionDir -Quiet:$Quiet
        } catch { Add-GpWarning "Analysis failed: $($_.Exception.Message). Re-run it from the Results page." }
    }
    $Status.state = 'done'
    Publish-GpStatus
    Write-GpLog "Session saved: $SessionDir" 'Green'
}
