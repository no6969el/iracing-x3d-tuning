<#
    GamePerf-Analyze.ps1  -  turn a recorded session into answers
    ================================================================
    Reads a session folder written by GamePerf-Logger.ps1 and writes:

      summary.json   every number below, plus chart data for the app
      report.md      the readable report: verdict, frame pacing, what
                     limited each frame, the worst stutters with what the
                     machine was doing at that moment, findings, configs
      ai-prompt.md   the same report packaged for an AI analyst: your
                     goals, how to read the data, a 10-second timeline,
                     the game's config files, and the previous session for
                     comparison. Paste it into Grok / ChatGPT / Claude /
                     Gemini, or let the app send it.

    HOW A FRAME IS JUDGED
    ---------------------
    PresentMon reports, per frame, the time between frames and how long
    the GPU was busy (and on 2.x, how long the CPU was busy) producing it.
      * GPU busy for >= 90% of the frame         -> GPU-bound
      * CPU busy for >= 85% of the frame         -> CPU-bound
      * neither, and the frame met its budget   -> capped (headroom)
      * neither, and it did not                  -> CPU-side / sync limited
    A STUTTER is a frame >= 2x the median of the 60 frames around it and
    >= 6 ms slower. Each one is tagged by the same logic - a GPU spike, a
    game-thread spike, or a STALL where neither was busy (I/O, shader
    compilation, a lock, the OS) - and the 1 Hz system log around it is
    checked for what changed: disk bursts, hard faults, DPC spikes, clock
    dips, power/thermal limits, VRAM, focus changes, background CPU.

    READ THIS BEFORE BLAMING STORAGE  (FullTrace's lesson, still true)
    hardfaults_s counts hard page faults for the WHOLE MACHINE. A traced
    25-minute iRacing session attributed 14 of 4,712 to the sim. A burst
    near a stutter is a lead, not a verdict; FullTrace's elevated "Hard
    faults" run names the process and file.

        powershell -ExecutionPolicy Bypass -File GamePerf-Analyze.ps1 -SessionDir <folder>
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SessionDir,
    [switch]$Quiet,
    [switch]$NoPrevious,
    # per config file, in the AI prompt
    [int]$MaxConfigChars = 60000,
    # all config files together, in the AI prompt
    [int]$MaxAllConfigChars = 200000
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'GamePerf-Common.ps1')
. (Join-Path $PSScriptRoot 'GamePerf-Games.ps1')
if (-not (Initialize-GpNative)) { throw 'The GamePerf native helpers could not be compiled.' }
$Settings = Import-GpSettings
if (-not $Settings.IncludePrevious) { $NoPrevious = $true }

function Say([string]$m) { if (-not $Quiet) { Write-Host "  $m" -ForegroundColor Gray } }
function N([object]$v, [int]$d = 1) { Format-GpNum $v $d }
function Pct([double]$part, [double]$whole, [int]$d = 1) {
    if ($whole -le 0 -or [double]::IsNaN($part)) { return '-' }
    return (Format-GpNum ($part * 100.0 / $whole) $d) + '%'
}
function IsNum($v) { $d = ConvertTo-GpDouble $v; return -not [double]::IsNaN($d) }
function Clean([string]$s) { if (-not $s) { return '' }; return ($s -replace '\|', '/' -replace '[\r\n]+', ' ') }

$Meta = Read-GpJson (Join-Path $SessionDir 'session.json')
if (-not $Meta) { throw "No session.json in $SessionDir - is this a GamePerf session folder?" }

$Q0 = ConvertTo-GpDouble $Meta.qpc_start
$QF = ConvertTo-GpDouble $Meta.qpc_freq
if ([double]::IsNaN($QF) -or $QF -le 0) { $QF = 10000000.0 }
$Budget = ConvertTo-GpDouble $Meta.budget_ms
if ([double]::IsNaN($Budget)) { $Budget = 0.0 }
$TargetFps = ConvertTo-GpDouble $Meta.target_fps
if ([double]::IsNaN($TargetFps)) { $TargetFps = 0.0 }
$IsVr = ($Meta.mode -eq 'VR')
$Machine = $Meta.machine
$GameName = [string]$Meta.game_name
if (-not $GameName) { $GameName = [string]$Meta.game_exe }
if (-not $GameName) { $GameName = '(game not detected)' }
$Notes = New-Object System.Collections.ArrayList
foreach ($w in @($Meta.warnings)) { if ($w) { [void]$Notes.Add([string]$w) } }

# ================================================================
#  SYSTEM LOG
# ================================================================
Say 'Reading system log...'
$Sys = [GamePerf.Native.CsvTable]::Load((Join-Path $SessionDir 'system.csv'))
$NumCols = @('t_s', 'fg_game', 'marker', 'cpu_total', 'ccd0_cpu', 'ccd1_cpu', 'busy_pct', 'cpu_eff_mhz', 'cpu0_int', 'cpu0_dpc', 'freqcore_int', 'freqcore_dpc',
             'tot_int', 'tot_dpc', 'game_cpu', 'game_cores', 'game_top_thread', 'game_threads', 'game_ws_mb', 'game_private_mb', 'vr_cpu', 'free_ram_mb', 'commit_pct',
             'hardfaults_s', 'disk_read_mb_s', 'disk_write_mb_s', 'disk_busy_pct', 'disk_queue', 'gpu_util', 'gpu_mem_util', 'vram_used_mb', 'vram_total_mb',
             'gpu_power_w', 'gpu_gclk', 'gpu_mclk', 'gpu_temp', 'fan_pct', 'gpu_volt_mv', 'volt_limit', 'power_limit', 'temp_limit', 'noload_limit',
             'pcie_bus_pct', 'fb_usage_pct', 'mem_temp_c', 'ab_fps', 'ab_frametime_ms', 'pm_fps', 'pm_ft_avg_ms', 'pm_ft_max_ms', 'timer_res_ms', 'loop_ms')
$SysCol = @{}
foreach ($c in $NumCols) { $SysCol[$c] = $Sys.Num($c) }
$TS = $SysCol['t_s']
$Phase = $Sys.Str('phase')
$Throttle = $Sys.Str('gpu_throttle')
$AffStr = $Sys.Str('game_aff')

$GameRowsList = New-Object 'System.Collections.Generic.List[int]'
for ($i = 0; $i -lt $Sys.Count; $i++) { if ($Phase[$i] -eq 'game') { $GameRowsList.Add($i) } }
if ($GameRowsList.Count -eq 0) { for ($i = 0; $i -lt $Sys.Count; $i++) { $GameRowsList.Add($i) } }
$GameRows = $GameRowsList.ToArray()

function Get-Col([string]$Name) {
    $r = [GamePerf.Native.Stats]::Summary([GamePerf.Native.Stats]::Pick($SysCol[$Name], $GameRows))
    [ordered]@{ n = $r[0]; avg = $r[1]; p50 = $r[2]; p95 = $r[3]; max = $r[4]; min = $r[5] }
}
function Get-Frac([string]$Name, [double]$AtLeast) {
    [GamePerf.Native.Stats]::FractionAtLeast([GamePerf.Native.Stats]::Pick($SysCol[$Name], $GameRows), $AtLeast)
}

$Sum = [ordered]@{}
foreach ($c in $NumCols) { if ($c -ne 't_s') { $Sum[$c] = Get-Col $c } }

# Logger gaps: a skipped second is a lead, never a verdict on its own (FullTrace v3.2.0).
$Gaps = New-Object System.Collections.ArrayList
for ($i = 1; $i -lt $TS.Length; $i++) {
    $d = $TS[$i] - $TS[$i - 1]
    if ($d -gt 1.6) { [void]$Gaps.Add([ordered]@{ t = [math]::Round($TS[$i - 1], 1); seconds = [math]::Round($d, 1) }) }
}

# NVIDIA clock-event reasons (nvidia-smi bit flags)
$ThrBits = [ordered]@{ power_cap = 0x4; hw_slowdown = 0x8; sw_thermal = 0x20; hw_thermal = 0x40; power_brake = 0x80 }
$ThrCount = @{}; foreach ($k in $ThrBits.Keys) { $ThrCount[$k] = 0 }
$ThrRows = 0
foreach ($i in $GameRows) {
    $h = $Throttle[$i]
    if ($h -notmatch '^0x[0-9A-Fa-f]+$') { continue }
    $ThrRows++
    $v = [Convert]::ToInt64($h.Substring(2), 16)
    foreach ($k in $ThrBits.Keys) { if ($v -band $ThrBits[$k]) { $ThrCount[$k]++ } }
}

# ================================================================
#  EVENTS
# ================================================================
$Ev = [GamePerf.Native.CsvTable]::Load((Join-Path $SessionDir 'events.csv'))
$EvT = $Ev.Num('t_s'); $EvKind = $Ev.Str('event'); $EvDetail = $Ev.Str('detail')
$Markers = New-Object System.Collections.ArrayList
$PmStarts = @{}
for ($i = 0; $i -lt $Ev.Count; $i++) {
    if ($EvKind[$i] -eq 'marker') { [void]$Markers.Add($EvT[$i]) }
    if ($EvKind[$i] -eq 'presentmon_start') { $PmStarts[$EvDetail[$i]] = $EvT[$i] }
}
function Get-EventsNear([double]$t, [double]$before, [double]$after, [string[]]$Kinds) {
    $out = @()
    for ($i = 0; $i -lt $Ev.Count; $i++) {
        if ($Kinds -notcontains $EvKind[$i]) { continue }
        if ($EvT[$i] -ge $t - $before -and $EvT[$i] -le $t + $after) { $out += ('{0}{1}' -f $EvKind[$i], $(if ($EvDetail[$i]) { ': ' + $EvDetail[$i] } else { '' })) }
    }
    return $out
}

# ================================================================
#  FRAMES
# ================================================================
Say 'Reading frames...'
$FrameFiles = @()
if ($Meta.frame_files) { $FrameFiles = @($Meta.frame_files | ForEach-Object { Join-Path $SessionDir $_ } | Where-Object { Test-Path -LiteralPath $_ }) }
if (-not $FrameFiles.Count) {
    $FrameFiles = @(Get-ChildItem -LiteralPath $SessionDir -Filter 'frames-*.csv' -ErrorAction SilentlyContinue |
                    Sort-Object { [int](($_.BaseName -split '-')[-1]) } | ForEach-Object { $_.FullName })
}
$FdList = New-Object 'System.Collections.Generic.List[GamePerf.Native.FrameData]'
$TList = New-Object 'System.Collections.Generic.List[double[]]'
$StartList = New-Object 'System.Collections.Generic.List[int]'
$Duration = ConvertTo-GpDouble $Meta.duration_s
if ([double]::IsNaN($Duration) -and $TS.Length) { $Duration = $TS[$TS.Length - 1] }
$FrameSource = [ordered]@{ files = @(); time_base = ''; present_mode = ''; sync_interval = $null; application = ''; swap_chains = 0; ft_column = ''; gpu_column = ''; cpu_column = '' }
foreach ($f in $FrameFiles) {
    $fd = $null
    try { $fd = [GamePerf.Native.FrameLog]::Load($f) } catch { [void]$Notes.Add("Could not read $(Split-Path -Leaf $f): $($_.Exception.Message)"); continue }
    $leaf = Split-Path -Leaf $f
    if ($fd.Count -lt 20) { [void]$Notes.Add("$leaf holds only $($fd.Count) frames - skipped."); continue }
    $off = 0.0
    if ($PmStarts.ContainsKey($leaf)) { $off = [double]$PmStarts[$leaf] }
    $t = $null; $timeBase = ''
    if ($fd.HasQpc -and $fd.Qpc[0] -gt 0 -and -not [double]::IsNaN($Q0)) {
        $t = [GamePerf.Native.Stats]::QpcToSeconds($fd.Qpc, $Q0, $QF)
        $timeBase = 'qpc'
        if ($t[0] -lt -5 -or (-not [double]::IsNaN($Duration) -and $t[0] -gt $Duration + 60)) { $t = $null }   # not the same clock after all
    }
    if (-not $t -and $fd.HasTime -and -not [double]::IsNaN($fd.TimeS[0])) {
        $t = [GamePerf.Native.Stats]::AddOffset($fd.TimeS, $off - $fd.TimeS[0]); $timeBase = 'relative'
    }
    if (-not $t) { $t = [GamePerf.Native.Stats]::CumulativeSeconds($fd.Ft, $off); $timeBase = 'synthesised' }
    $FdList.Add($fd); $TList.Add($t); $StartList.Add([GamePerf.Native.Stats]::SettleIndex($fd.Ft, 8))
    $FrameSource.files += $leaf
    $FrameSource.time_base = $timeBase
    if (-not $FrameSource.application) {
        $FrameSource.application = $fd.Application; $FrameSource.present_mode = $fd.PresentMode
        if ($fd.SyncInterval -ge 0) { $FrameSource.sync_interval = $fd.SyncInterval }
        $FrameSource.ft_column = $fd.FtColumn; $FrameSource.gpu_column = $fd.GpuBusyColumn; $FrameSource.cpu_column = $fd.CpuBusyColumn
    }
    $FrameSource.swap_chains = [math]::Max($FrameSource.swap_chains, $fd.SwapChains)
}
$FA = [GamePerf.Native.FrameAnalyzer]::Analyze($FdList.ToArray(), $TList.ToArray(), $StartList.ToArray(), $Budget)
$HasFrames = $FA.Frames -gt 0
if (-not $HasFrames) {
    if ($FrameFiles.Count) { [void]$Notes.Add('Per-frame capture produced no usable frames.') }
    else { [void]$Notes.Add('No per-frame capture in this session (PresentMon off, missing or refused). Frame numbers below come from Afterburner, if it was running.') }
}

# Without PresentMon, fall back to Afterburner's 1 Hz framerate so there is still a verdict.
$AbOnly = $null
if (-not $HasFrames) {
    $fpsCol = Get-Col 'ab_fps'
    if ($fpsCol.n -gt 0) { $AbOnly = $fpsCol }
}

# ================================================================
#  STUTTER INCIDENTS + CONTEXT
# ================================================================
$Base = @{}
foreach ($c in 'hardfaults_s', 'disk_read_mb_s', 'tot_dpc', 'cpu0_dpc', 'gpu_util', 'gpu_gclk', 'cpu_eff_mhz') { $Base[$c] = $Sum[$c].p50 }
$BaseFrac = @{ power = (Get-Frac 'power_limit' 1); temp = (Get-Frac 'temp_limit' 1) }
$VramTotal = $Sum['vram_total_mb'].max
if (-not (IsNum $VramTotal) -and $Meta.machine.nvidia) { $VramTotal = ConvertTo-GpDouble $Meta.machine.nvidia.vram_mb }

function Get-WindowStat([string]$Col, [double]$t, [double]$before = 2.5, [double]$after = 1.0) {
    [GamePerf.Native.Stats]::Window($TS, $SysCol[$Col], $t - $before, $t + $after)
}
function Max-Or([double]$a, [double]$b) { if ([double]::IsNaN($a)) { return $b }; return [math]::Max($a, $b) }

function Get-GpContext([double]$t) {
    $n = New-Object System.Collections.ArrayList
    $w = Get-WindowStat 'hardfaults_s' $t
    if ($w[0] -gt 0 -and $w[2] -gt (Max-Or (5 * $Base.hardfaults_s) 500)) { [void]$n.Add("hard faults (system-wide) peaked at $(N $w[2] 0)/s") }
    $w = Get-WindowStat 'disk_read_mb_s' $t
    if ($w[0] -gt 0 -and $w[2] -gt (Max-Or (5 * $Base.disk_read_mb_s) 40)) { [void]$n.Add("disk reads burst to $(N $w[2] 0) MB/s") }
    $w = Get-WindowStat 'tot_dpc' $t
    if ($w[0] -gt 0 -and $w[2] -gt (Max-Or (3 * $Base.tot_dpc) 2)) { [void]$n.Add("DPC time spiked to $(N $w[2] 1)% (all CPUs)") }
    $w = Get-WindowStat 'cpu0_dpc' $t
    if ($w[0] -gt 0 -and $w[2] -gt (Max-Or (3 * $Base.cpu0_dpc) 10)) { [void]$n.Add("CPU 0 DPC at $(N $w[2] 1)%") }
    $w = Get-WindowStat 'game_top_thread' $t
    if ($w[0] -gt 0 -and $w[2] -ge 95) { [void]$n.Add("game's busiest thread at $(N $w[2] 0)% of a core") }
    $w = Get-WindowStat 'gpu_util' $t
    if ($w[0] -gt 0 -and $Base.gpu_util -gt 50 -and $w[3] -lt 0.6 * $Base.gpu_util) { [void]$n.Add("GPU load fell to $(N $w[3] 0)% (starved)") }
    $w = Get-WindowStat 'gpu_gclk' $t
    if ($w[0] -gt 0 -and $Base.gpu_gclk -gt 0 -and $w[3] -lt 0.85 * $Base.gpu_gclk) { [void]$n.Add("GPU clock dipped to $(N $w[3] 0) MHz") }
    $w = Get-WindowStat 'cpu_eff_mhz' $t
    if ($w[0] -gt 0 -and $Base.cpu_eff_mhz -gt 0 -and $w[3] -lt 0.8 * $Base.cpu_eff_mhz) { [void]$n.Add("CPU effective clock dipped to $(N $w[3] 0) MHz") }
    # Limiter flags only count as context when they are unusual for this session.
    $w = Get-WindowStat 'power_limit' $t
    if ($w[2] -ge 1 -and -not ($BaseFrac.power -ge 0.3)) { [void]$n.Add('GPU power limit active') }
    $w = Get-WindowStat 'temp_limit' $t
    if ($w[2] -ge 1 -and -not ($BaseFrac.temp -ge 0.3)) { [void]$n.Add('GPU thermal limit active') }
    $w = Get-WindowStat 'vram_used_mb' $t
    if ((IsNum $VramTotal) -and $w[0] -gt 0 -and $w[2] -ge 0.97 * $VramTotal) { [void]$n.Add("VRAM full ($(N $w[2] 0) of $(N $VramTotal 0) MB)") }
    $w = Get-WindowStat 'free_ram_mb' $t
    if ($w[0] -gt 0 -and $w[3] -lt 1500) { [void]$n.Add("free RAM down to $(N $w[3] 0) MB") }
    foreach ($e in (Get-EventsNear $t 3 1 @('focus_lost', 'timer_resolution_changed', 'power_plan_changed', 'game_start', 'presentmon_start'))) { [void]$n.Add($e) }
    foreach ($g in $Gaps) { if ($g.t -ge $t - 3 -and $g.t -le $t + 1) { [void]$n.Add("the logger itself missed $($g.seconds) s here (system-wide stall?)"); break } }
    return ,($n.ToArray())
}

function Get-GpBackgroundNear([double]$t) {
    $best = $null; $bestD = 1e9
    for ($i = 0; $i -lt $Ev.Count; $i++) {
        if ($EvKind[$i] -ne 'background_cpu') { continue }
        $d = $EvT[$i] - $t
        if ($d -ge -2 -and $d -lt 32 -and $d -lt $bestD) { $bestD = $d; $best = $EvDetail[$i] }
    }
    return $best
}

$KindText = @{ gpu = 'GPU spike'; cpu = 'game-thread spike'; stall = 'stall (CPU and GPU both waiting)'; unknown = 'unclassified' }
$Incidents = New-Object System.Collections.ArrayList
if ($FA.Stutters.Count) {
    $sorted = @($FA.Stutters | Sort-Object T)
    $cur = $null
    foreach ($s in $sorted) {
        if ($cur -and $s.T - $cur.end -le 2.0) {
            $cur.end = $s.T; $cur.count++
            $cur.kinds[$s.Kind] = 1 + [int]$cur.kinds[$s.Kind]
            if ($s.Ft -gt $cur.worst.Ft) { $cur.worst = $s }
        } else {
            if ($cur) { [void]$Incidents.Add($cur) }
            $cur = @{ start = $s.T; end = $s.T; count = 1; worst = $s; kinds = @{ $s.Kind = 1 } }
        }
    }
    if ($cur) { [void]$Incidents.Add($cur) }
}
$TopIncidents = @($Incidents | Sort-Object @{ Expression = { $_.worst.Ft }; Descending = $true }, @{ Expression = { $_.count }; Descending = $true } | Select-Object -First 15)
$IncidentOut = New-Object System.Collections.ArrayList
$CtxTally = @{}
foreach ($inc in $TopIncidents) {
    $ctx = Get-GpContext $inc.worst.T
    foreach ($c in $ctx) { $k = ($c -replace '[\d.,]+', '#'); $CtxTally[$k] = 1 + [int]$CtxTally[$k] }
    $dominant = ($inc.kinds.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
    [void]$IncidentOut.Add([ordered]@{
        t = [math]::Round($inc.worst.T, 2)
        clock = $(if ($TS.Length) { $idx = [array]::BinarySearch($TS, $inc.worst.T); if ($idx -lt 0) { $idx = [math]::Max(0, [math]::Min($TS.Length - 1, (-bnot $idx) - 1)) }; ($Sys.Str('timestamp'))[$idx] } else { '' })
        frames = $inc.count
        worst_ms = [math]::Round($inc.worst.Ft, 1)
        typical_ms = [math]::Round($inc.worst.Median, 1)
        gpu_busy_ms = $(if ([double]::IsNaN($inc.worst.GpuBusy)) { $null } else { [math]::Round($inc.worst.GpuBusy, 1) })
        cpu_busy_ms = $(if ([double]::IsNaN($inc.worst.CpuBusy)) { $null } else { [math]::Round($inc.worst.CpuBusy, 1) })
        kind = $dominant
        context = $ctx
        background = (Get-GpBackgroundNear $inc.worst.T)
    })
}

$MarkerOut = New-Object System.Collections.ArrayList
$mi = 0
foreach ($mt in $Markers) {
    $mi++
    $worst = [double]::NaN; $n = 0
    if ($HasFrames) {
        $w = [GamePerf.Native.Stats]::Window($FA.T, $FA.Ft, $mt - 4.0, $mt + 0.5)
        $n = $w[0]; $worst = $w[2]
    }
    $near = @($FA.Stutters | Where-Object { $_.T -ge $mt - 4.0 -and $_.T -le $mt + 0.5 })
    [void]$MarkerOut.Add([ordered]@{
        marker = $mi; t = [math]::Round($mt, 2)
        worst_frame_ms = $(if ([double]::IsNaN($worst)) { $null } else { [math]::Round($worst, 1) })
        stutters_in_window = $near.Count
        kinds = @($near | ForEach-Object { $_.Kind } | Select-Object -Unique)
        context = (Get-GpContext $mt)
        background = (Get-GpBackgroundNear $mt)
    })
}

# ================================================================
#  PREVIOUS SESSION (same game) + CONFIG FILES
# ================================================================
$Prev = $null; $PrevDir = $null
if (-not $NoPrevious -and $Meta.game_exe) {
    $root = Split-Path -Parent $SessionDir
    $me = Split-Path -Leaf $SessionDir
    foreach ($d in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        if ($d.Name -ge $me) { continue }
        $m = Read-GpJson (Join-Path $d.FullName 'session.json')
        if (-not $m -or $m.game_exe -ne $Meta.game_exe -or $m.mode -ne $Meta.mode) { continue }
        $ps = Read-GpJson (Join-Path $d.FullName 'summary.json')
        if (-not $ps) { continue }
        $Prev = $ps; $PrevDir = $d.FullName; break
    }
}

$ConfigDir = Join-Path $SessionDir 'configs'
$Manifest = @()
$mf = Read-GpJson (Join-Path $ConfigDir 'manifest.json')
if ($mf) { $Manifest = @($mf) }

function Get-GpConfigLines([string]$Text) {
    <#
        Flatten a config file into "key -> value" pairs, tolerant of the
        formats games actually use: ini sections, key=value, key: value,
        "key": value (JSON), ["key"] = value (Lua), <tag attr="..."> (XML).
        Anything else is kept as a whole line.
    #>
    $d = [ordered]@{}
    $sec = ''
    $i = 0
    foreach ($line in ($Text -split "`r?`n")) {
        $l = $line.Trim()
        if (-not $l -or $l -match '^(;|#|//|--)') { continue }
        if ($l -match '^\[([^\]=]+)\]$') { $sec = $Matches[1] + '/'; continue }
        if ($l -match '^\[?"?([^"=:\[\]<>{}]+?)"?\]?\s*[=:]\s*(.*?)\s*,?$') { $k = $sec + $Matches[1].Trim(); $d[$k] = $Matches[2]; continue }
        if ($l -match '^<([\w.\-]+)((?:\s+(?:name|id|key)="[^"]*")?)') { $k = $sec + $Matches[1] + $Matches[2]; if ($d.Contains($k)) { $k = "$k#$i" }; $d[$k] = $l; $i++; continue }
        $d["line#$i"] = $l; $i++
    }
    return $d
}

$ConfigChanges = New-Object System.Collections.ArrayList
if ($PrevDir -and $Manifest.Count) {
    $pm = Read-GpJson (Join-Path $PrevDir 'configs\manifest.json')
    if ($pm) {
        foreach ($cur in $Manifest) {
            $old = @($pm) | Where-Object { $_.original -eq $cur.original } | Select-Object -First 1
            if (-not $old) { continue }
            $a = Read-GpTextFile -Path (Join-Path $PrevDir "configs\$($old.file)")
            $b = Read-GpTextFile -Path (Join-Path $ConfigDir $cur.file)
            if ($null -eq $a -or $null -eq $b -or $a -eq $b) { continue }
            $da = Get-GpConfigLines $a; $db = Get-GpConfigLines $b
            $ch = New-Object System.Collections.ArrayList
            foreach ($k in $db.Keys) {
                if ($ch.Count -ge 60) { break }
                if (-not $da.Contains($k)) { if ($k -notlike 'line#*') { [void]$ch.Add("+ $k = $($db[$k])") } }
                elseif ($da[$k] -ne $db[$k]) { [void]$ch.Add("$k : $($da[$k]) -> $($db[$k])") }
            }
            foreach ($k in $da.Keys) { if ($ch.Count -lt 60 -and -not $db.Contains($k) -and $k -notlike 'line#*') { [void]$ch.Add("- $k") } }
            if ($ch.Count) { [void]$ConfigChanges.Add([ordered]@{ file = (Split-Path -Leaf $cur.original); original = $cur.original; changes = $ch.ToArray() }) }
        }
    }
}

# ================================================================
#  FINDINGS
# ================================================================
$Findings = New-Object System.Collections.ArrayList
function Add-Finding([string]$Severity, [string]$Area, [string]$Title, [string]$Detail) {
    [void]$Findings.Add([ordered]@{ severity = $Severity; area = $Area; title = $Title; detail = $Detail })
}

$Minutes = 0.0
if ($HasFrames) { $Minutes = $FA.Seconds / 60.0 }
$StutterRate = $(if ($Minutes -gt 0) { $FA.StutterCount / $Minutes } else { [double]::NaN })
$GpuShare = $(if ($FA.Classified) { $FA.GpuBound / $FA.Classified } else { [double]::NaN })
$CpuShare = $(if ($FA.Classified) { $FA.CpuBound / $FA.Classified } else { [double]::NaN })
$CapShare = $(if ($FA.Classified) { $FA.Capped / $FA.Classified } else { [double]::NaN })
$GpuHeadroom = [double]::NaN; $CpuHeadroom = [double]::NaN
if ($Budget -gt 0 -and $HasFrames) {
    if (-not [double]::IsNaN($FA.GpuBusyP90)) { $GpuHeadroom = (1 - $FA.GpuBusyP90 / $Budget) * 100 }
    if (-not [double]::IsNaN($FA.CpuBusyP90)) { $CpuHeadroom = (1 - $FA.CpuBusyP90 / $Budget) * 100 }
}
$MissedPct = $(if ($HasFrames -and $Budget -gt 0) { $FA.Missed * 100.0 / $FA.Frames } else { [double]::NaN })
$TargetText = $(if ($TargetFps -gt 0) { "$(N $TargetFps 0) fps ($(N $Budget 1) ms per frame)" } else { 'no target set' })

# -- frame pacing
if ($HasFrames) {
    if (-not [double]::IsNaN($MissedPct)) {
        $sev = $(if ($MissedPct -ge 5) { 'high' } elseif ($MissedPct -ge 1) { 'medium' } else { 'info' })
        $vrNote = $(if ($IsVr) { ' In VR every missed frame is a reprojected (or dropped) frame.' } else { '' })
        $missWhy = ''
        if ($FA.Missed -gt 0 -and ($FA.MissedGpuBound + $FA.MissedCpuSide) -gt 0) {
            $missWhy = " Of the missed frames, $(Pct $FA.MissedGpuBound $FA.Missed 0) were GPU-bound and $(Pct $FA.MissedCpuSide $FA.Missed 0) were held up on the CPU side."
        }
        Add-Finding $sev 'pacing' ("{0}% of frames missed the {1} budget" -f (N $MissedPct 1), $TargetText) `
            ("$($FA.Missed) of $($FA.Frames) frames took longer than 1.25x $(N $Budget 1) ms.$vrNote$missWhy 1% low is $(N $FA.Low1Fps 1) fps, 0.1% low $(N $FA.Low01Fps 1) fps, average $(N $FA.FpsAvg 1) fps.")
        if ($FA.Missed -ge 20 -and $MissedPct -ge 1) {
            if ($FA.MissedGpuBound -ge 0.6 * $FA.Missed) {
                Add-Finding 'high' 'bottleneck' 'Missed frames are GPU-bound' "When frames miss the budget the GPU is busy for the whole frame (GPU busy p90 $(N $FA.GpuBusyP90 1) ms vs $(N $Budget 1) ms). The GPU-heaviest settings in the scenes where it happens are the lever - see the timeline for when."
            } elseif ($FA.MissedCpuSide -ge 0.6 * $FA.Missed) {
                Add-Finding 'high' 'bottleneck' 'Missed frames are held up on the CPU side' "When frames miss the budget the GPU is waiting. CPU-heavy settings (opponents, draw distance, mirrors, crowds, physics/AI) or a background interruption are the lever; lowering GPU settings will not fix it."
            }
        }
    }
    if (-not [double]::IsNaN($StutterRate)) {
        $sev = $(if ($StutterRate -ge 6) { 'high' } elseif ($StutterRate -ge 1) { 'medium' } else { 'info' })
        $mix = @()
        if ($FA.StutterGpu) { $mix += "$($FA.StutterGpu) GPU spikes" }
        if ($FA.StutterCpu) { $mix += "$($FA.StutterCpu) game-thread spikes" }
        if ($FA.StutterStall) { $mix += "$($FA.StutterStall) stalls" }
        $mixText = $(if ($mix.Count) { ' Mix: ' + ($mix -join ', ') + '.' } else { '' })
        Add-Finding $sev 'pacing' ("{0} stutters ({1} per minute, {2} major)" -f $FA.StutterCount, (N $StutterRate 1), $FA.MajorStutters) `
            ("A stutter is a frame at least 2x the local median and 6 ms slower; major means 3x and at least 50 ms.$mixText Worst frame $(N $FA.Max 1) ms; 99.9th percentile $(N $FA.P999 1) ms.")
        if ($FA.StutterCount -ge 5) {
            if ($FA.StutterStall -ge 0.5 * $FA.StutterCount) {
                Add-Finding 'medium' 'pacing' 'Most hitches are stalls, not heavy frames' 'Neither the CPU nor the GPU was busy for most of the slow frames: the game was waiting - typically on disk/asset streaming, shader compilation, a lock or the OS. Settings that raise the load (resolution, shadows) are rarely the cause; look at the context listed for each stutter.'
            } elseif ($FA.StutterGpu -ge 0.5 * $FA.StutterCount) {
                Add-Finding 'medium' 'pacing' 'Hitches are GPU spikes' 'The GPU was busy for the whole of most slow frames: specific moments (more cars on screen, mirrors, rain/reflections, a busy grandstand) exceed the budget. The GPU-heaviest per-scene settings are the lever, not the average load.'
            } elseif ($FA.StutterCpu -ge 0.5 * $FA.StutterCount) {
                Add-Finding 'medium' 'pacing' 'Hitches are game-thread spikes' 'The CPU was busy for most slow frames: AI/physics, opponent count, draw distance and draw calls (mirrors, crowds, dynamic objects) are the usual levers.'
            }
        }
    }
} elseif ($AbOnly) {
    Add-Finding 'info' 'pacing' "Average $(N $AbOnly.avg 1) fps (Afterburner, 1 Hz)" 'Afterburner only reports a per-second average, which hides single slow frames. Enable per-frame capture (PresentMon) to measure stutter.'
}

# -- what limits the frames
if ($HasFrames -and $FA.Classified -gt 0) {
    $boundDetail = "GPU-bound $(Pct $FA.GpuBound $FA.Classified 0) / CPU-side $(Pct $FA.CpuBound $FA.Classified 0) / capped $(Pct $FA.Capped $FA.Classified 0) of frames. GPU busy $(N $FA.GpuBusyAvg 1) ms avg, $(N $FA.GpuBusyP90 1) ms p90"
    if (-not [double]::IsNaN($FA.CpuBusyP90)) { $boundDetail += "; CPU busy $(N $FA.CpuBusyAvg 1) ms avg, $(N $FA.CpuBusyP90 1) ms p90" }
    if ($Budget -gt 0) { $boundDetail += "; budget $(N $Budget 1) ms" }
    $boundDetail += '.'
    if ($GpuShare -ge 0.6) {
        $sev = $(if (-not [double]::IsNaN($MissedPct) -and $MissedPct -ge 1) { 'high' } else { 'info' })
        Add-Finding $sev 'bottleneck' 'The GPU is the limiter' "$boundDetail When frames are missed while GPU-bound, the GPU-heaviest settings are the lever."
    } elseif ($CpuShare -ge 0.4) {
        $tt = $Sum['game_top_thread']
        $main = $(if ($tt.p95 -ge 90) { " The game's busiest thread ran at $(N $tt.p95 0)% of a core (p95): a main-thread bottleneck." } else { '' })
        $sev = $(if (-not [double]::IsNaN($MissedPct) -and $MissedPct -ge 1) { 'high' } else { 'medium' })
        Add-Finding $sev 'bottleneck' 'Frames are limited on the CPU side' "$boundDetail$main CPU-heavy settings (opponents, draw distance, mirrors, crowds, physics/AI detail) are the lever; GPU settings will not help."
    } elseif ($CapShare -ge 0.5 -and ([double]::IsNaN($MissedPct) -or $MissedPct -lt 1)) {
        Add-Finding 'info' 'bottleneck' 'Frame cap reached most of the time' "$boundDetail The target is being held with time to spare."
    } elseif ($CapShare -ge 0.5) {
        Add-Finding 'info' 'bottleneck' 'Mostly at the target, with heavy stretches' "$boundDetail The target holds most of the time; the misses come from specific stretches (see the timeline)."
    }
    if (-not [double]::IsNaN($GpuHeadroom)) {
        if ($GpuHeadroom -ge 25) {
            Add-Finding 'info' 'headroom' ("About {0}% GPU headroom" -f (N $GpuHeadroom 0)) "The GPU's p90 busy time is $(N $FA.GpuBusyP90 1) ms of a $(N $Budget 1) ms budget: room to raise GPU-side quality (MSAA, shadows, reflections, texture filtering) while staying at native resolution. Raise one setting at a time and re-record."
        } elseif ($GpuHeadroom -lt 5) {
            Add-Finding 'medium' 'headroom' 'No GPU headroom' "The GPU's p90 busy time ($(N $FA.GpuBusyP90 1) ms) is at or over the $(N $Budget 1) ms budget: any heavier scene will miss frames."
        }
    }
}

# -- GPU memory, power, heat
$vr = $Sum['vram_used_mb']
if ((IsNum $VramTotal) -and $vr.n -gt 0 -and $vr.p95 -ge 0.95 * $VramTotal) {
    Add-Finding 'high' 'gpu' 'VRAM is nearly full' "VRAM use reached $(N $vr.max 0) of $(N $VramTotal 0) MB (p95 $(N $vr.p95 0)). Running out of VRAM causes hitches when assets swap over PCIe: texture quality, MSAA level and render resolution are the biggest users."
}
$pwrFrac = Get-Frac 'power_limit' 1
$tmpFrac = Get-Frac 'temp_limit' 1
if ($ThrRows -gt 0) {
    $pwrFrac = Max-Or $pwrFrac ($ThrCount.power_cap / $ThrRows)
    $tmpFrac = Max-Or $tmpFrac (($ThrCount.sw_thermal + $ThrCount.hw_thermal) / $ThrRows)
    if ($ThrCount.hw_slowdown + $ThrCount.power_brake -gt 0) {
        Add-Finding 'high' 'gpu' 'GPU hardware slowdown events' "The driver reported hardware slowdown / power-brake clock events in $($ThrCount.hw_slowdown + $ThrCount.power_brake) samples - usually a PSU, power-cable or temperature protection problem, not a setting."
    }
}
if (-not [double]::IsNaN($tmpFrac) -and $tmpFrac -ge 0.05) {
    Add-Finding 'high' 'gpu' ("GPU thermal-limited {0}% of the time" -f (N ($tmpFrac * 100) 0)) "Peak GPU temperature $(N $Sum['gpu_temp'].max 0) C. Thermal limiting lowers clocks unpredictably; improve case airflow or the fan curve before trading quality."
}
if (-not [double]::IsNaN($pwrFrac) -and $pwrFrac -ge 0.3) {
    Add-Finding 'info' 'gpu' ("GPU power-limited {0}% of the time" -f (N ($pwrFrac * 100) 0)) "Average draw $(N $Sum['gpu_power_w'].avg 0) W. Normal for a fully loaded GPU; it only matters if clocks dip in the stutter context below."
}
if ($Sum['gpu_temp'].max -ge 83 -and ([double]::IsNaN($tmpFrac) -or $tmpFrac -lt 0.05)) {
    Add-Finding 'low' 'gpu' "GPU reached $(N $Sum['gpu_temp'].max 0) C" 'Close to where most cards start to throttle.'
}

# -- CPU placement and system latency
$m = $Meta.machine
if ($m.topology -eq 'dual' -and $m.is_x3d -and $m.vcache_scope -ne 'both' -and $Sum['game_cpu'].n -gt 0) {
    $split = [int]$m.split_core
    $outside = 0; $seen = 0
    foreach ($i in $GameRows) {
        $a = $AffStr[$i]
        if ($a -notmatch '^0x[0-9A-Fa-f]+$') { continue }
        $seen++
        $mask = [Convert]::ToInt64($a.Substring(2), 16)
        if ($split -gt 0 -and ($mask -shr $split) -ne 0) { $outside++ }
    }
    $c0 = $Sum['ccd0_cpu'].avg; $c1 = $Sum['ccd1_cpu'].avg
    if ($c1 -gt $c0 + 5 -and $Sum['game_cpu'].avg -gt 3) {
        Add-Finding 'high' 'cpu' 'The game looks like it is running on the frequency die' "CCD1 averaged $(N $c1 0)% vs CCD0 $(N $c0 0)% while the game ran. On a dual-CCD X3D the game belongs on the V-Cache cores ($($m.vcache_cores)). The kit's Optimize step shows the Process Lasso CPU Set to apply."
    } elseif ($seen -gt 0 -and $outside -eq $seen) {
        Add-Finding 'medium' 'cpu' 'The game is not limited to the V-Cache cores' "Its affinity allows CPUs beyond $($split - 1). Windows usually keeps it on CCD0, but a CPU Set to $($m.vcache_cores) (Process Lasso, see the kit's Optimize step) removes the chance of a cross-CCD move mid-session."
    }
}
$dpc = $Sum['tot_dpc']; $c0d = $Sum['cpu0_dpc']; $c0i = $Sum['cpu0_int']
if ($dpc.p95 -ge 2 -or $c0d.p95 -ge 10 -or $c0i.p95 -ge 10) {
    Add-Finding 'medium' 'latency' 'High interrupt / DPC load' "DPC p95 $(N $dpc.p95 1)% (all CPUs), CPU 0 DPC p95 $(N $c0d.p95 1)%, CPU 0 interrupts p95 $(N $c0i.p95 1)%. Drivers doing work at high priority steal time from the game in bursts. The kit's GPU-IRQ and NIC/USB interrupt steering move this off the cores the game uses."
}
$hf = $SysCol['hardfaults_s']; $streak = 0; $maxStreak = 0
foreach ($i in $GameRows) { if ($hf[$i] -gt 500) { $streak++; if ($streak -gt $maxStreak) { $maxStreak = $streak } } else { $streak = 0 } }
if ($maxStreak -ge 3) {
    Add-Finding 'medium' 'memory' "Sustained hard faults ($maxStreak s above 500/s)" 'This counter is SYSTEM-WIDE and is usually Windows (Store updates, Search, NTFS metadata), not the game - a traced iRacing session attributed 14 of 4,712 faults to the sim. Run the kit''s FullTrace "Hard faults (Admin)" to name the process before changing storage or memory settings.'
}
$ram = $Sum['free_ram_mb']; $com = $Sum['commit_pct']
if ($ram.n -gt 0 -and $ram.min -lt 2048) {
    Add-Finding 'medium' 'memory' "Free RAM fell to $(N $ram.min 0) MB" "Low free memory forces paging. Close background apps; commit charge peaked at $(N $com.max 0)%."
}
$diskCtx = 0
foreach ($k in $CtxTally.Keys) { if ($k -like 'disk reads burst*') { $diskCtx += $CtxTally[$k] } }
if ($TopIncidents.Count -ge 3 -and $diskCtx -ge [math]::Ceiling($TopIncidents.Count / 3)) {
    Add-Finding 'medium' 'storage' 'Stutters coincide with disk reads' "$diskCtx of the $($TopIncidents.Count) worst stutter incidents had a disk read burst around them: asset streaming. Faster storage, a Defender exclusion for the game folder (the kit's Add-Defender-Exclusions) and the game's own preload / texture-streaming options help."
}
$plans = @(Get-EventsNear 0 0 1e9 @('power_plan_changed'))
if ($plans.Count) { Add-Finding 'medium' 'system' 'Power plan changed during the session' ($plans -join '; ') }
$focus = @(Get-EventsNear 0 0 1e9 @('focus_lost'))
if ($focus.Count) { Add-Finding 'info' 'system' "The game lost focus $($focus.Count) time(s)" ("Alt-tab, an overlay or a notification took the foreground: " + (($focus | Select-Object -First 5) -join '; ') + '. Frames around these moments are not representative.') }
$tr = $Sum['timer_res_ms']
if ($tr.n -gt 0 -and $tr.p50 -gt 1.5) {
    Add-Finding 'low' 'system' "System timer resolution was $(N $tr.p50 2) ms" 'Most games raise it to 0.5-1 ms themselves; when it stays at 15.6 ms, frame limiters and sleeps get coarse. The kit''s Enable-GlobalTimerResolution addresses this.'
}
$bgHeavy = @()
foreach ($b in @($Meta.background_top)) {
    if (-not $b) { continue }
    $nm = [string]$b.name
    if ($GpVrProcesses -contains $nm -or $nm -match '^(PresentMon|nvidia-smi|powershell|pwsh|System|Registry|MemCompression|Secure System|dwm|audiodg|csrss)') { continue }
    if ((ConvertTo-GpDouble $b.avg_pct) -ge 1.0) { $bgHeavy += ('{0} ({1}% avg)' -f $nm, (N $b.avg_pct 1)) }
}
if ($bgHeavy.Count) {
    Add-Finding 'medium' 'system' 'Background apps used noticeable CPU' ("$($bgHeavy -join ', '). Close what you do not need while playing; the kit's Pre-Race-Quiet handles Windows' own background services.")
}
if ($m.hvci -eq 'running') { Add-Finding 'low' 'system' 'Memory Integrity (HVCI) is on' 'VBS/HVCI typically costs a few percent in CPU-limited games. It is a security feature: turning it off is a trade-off for you to decide, not a free win.' }
if ($m.game_dvr -eq 'on') { Add-Finding 'low' 'system' 'Game Bar background recording is on' 'Captures in the background cost GPU encoder time and disk writes. The kit''s Apply-Guide-Extras turns Game Bar off.' }
if (-not $IsVr -and $FrameSource.present_mode -like 'Composed*') {
    Add-Finding 'low' 'display' "Presented through desktop composition ($($FrameSource.present_mode))" 'The game is windowed/borderless without independent flip, which adds latency and can add pacing jitter. Exclusive fullscreen, or Windows'' "Optimizations for windowed games", usually moves it to an independent-flip mode.'
}
if ($IsVr -and $Meta.vr.openxr) {
    $on = @($Meta.vr.openxr.Layers | Where-Object { $_.Enabled })
    $bad = @($on | Where-Object { $_.Manifest -match 'quad|foveat|fov' })
    if ($bad.Count) {
        Add-Finding 'high' 'vr' 'A quad-views / foveated-rendering OpenXR layer is ENABLED' ("Your goals rule these out, but this layer loads into every OpenXR game: " + (($bad | ForEach-Object { Split-Path -Leaf $_.Manifest }) -join ', ') + '. Disable it in its own app or remove the registry entry.')
    }
    if ($on.Count) {
        Add-Finding 'info' 'vr' "$($on.Count) OpenXR API layer(s) enabled" ((($on | ForEach-Object { Split-Path -Leaf $_.Manifest }) -join ', ') + '. Each one runs on every frame; check none of them is doing upscaling or foveation.')
    }
}
if ($Gaps.Count) {
    Add-Finding 'info' 'logger' "The logger missed $($Gaps.Count) second(s)" 'A gap is only a system stall if the rows around it agree (DPC, hard faults, GPU load). Otherwise the logger itself was delayed.'
}
if (-not $HasFrames -and -not $AbOnly) {
    Add-Finding 'high' 'data' 'No frame data in this session' 'Neither PresentMon nor Afterburner provided frame times. Get PresentMon from the app (Settings) and keep "Run logger as administrator" on.'
}

$SevOrder = @{ high = 0; medium = 1; low = 2; info = 3 }
$FindingsSorted = @($Findings | Sort-Object @{ Expression = { $SevOrder[$_.severity] } })

# ---- verdict ------------------------------------------------------
$Verdict = ''
if ($HasFrames) {
    $parts = @("Average $(N $FA.FpsAvg 1) fps, 1% low $(N $FA.Low1Fps 1)")
    if ($TargetFps -gt 0) { $parts += "target $(N $TargetFps 0)" }
    if (-not [double]::IsNaN($MissedPct)) { $parts += "$(N $MissedPct 1)% of frames over budget" }
    $parts += "$($FA.StutterCount) stutters"
    if ($FA.Classified) {
        $lim = 'mixed'
        if (-not [double]::IsNaN($MissedPct) -and $MissedPct -ge 1 -and $FA.Missed -gt 0) {
            if ($FA.MissedGpuBound -ge 0.6 * $FA.Missed) { $lim = 'misses are GPU-bound' }
            elseif ($FA.MissedCpuSide -ge 0.6 * $FA.Missed) { $lim = 'misses are CPU-side' }
            else { $lim = 'misses are mixed GPU/CPU' }
        }
        elseif ($GpuShare -ge 0.6) { $lim = 'GPU-bound' } elseif ($CpuShare -ge 0.4) { $lim = 'CPU-side limited' } elseif ($CapShare -ge 0.5) { $lim = 'holding the target' }
        $parts += $lim
    }
    $Verdict = ($parts -join ' | ')
} elseif ($AbOnly) { $Verdict = "Average $(N $AbOnly.avg 1) fps (Afterburner). No per-frame data." }
else { $Verdict = 'No frame data captured.' }

# ================================================================
#  CHART DATA (for the app)
# ================================================================
$Chart = [ordered]@{ width = 1; t = @(); ft_avg = @(); ft_max = @(); gpu_busy = @(); budget = $Budget; stutters = @(); markers = @($Markers | ForEach-Object { [math]::Round($_, 1) }); source = '' }
$span = 0.0
if ($HasFrames) { $span = $FA.T[$FA.T.Length - 1] - $FA.T[0] }
if ($HasFrames -and $span -gt 0) {
    $wdt = [math]::Max(1, [math]::Ceiling($span / 900))
    $Chart.width = $wdt
    $bft = [GamePerf.Native.Stats]::Buckets($FA.T, $FA.Ft, $wdt)
    $bg = $null
    if ($FA.HasGpuBusy) { $bg = [GamePerf.Native.Stats]::Buckets($FA.T, $FA.Gpu, $wdt) }
    $gmap = @{}
    if ($bg) { foreach ($r in $bg) { $gmap[[string]$r[0]] = $r[1] } }
    $Chart.t = @($bft | ForEach-Object { [math]::Round($_[0], 1) })
    $Chart.ft_avg = @($bft | ForEach-Object { [math]::Round($_[1], 2) })
    $Chart.ft_max = @($bft | ForEach-Object { [math]::Round($_[2], 2) })
    $Chart.gpu_busy = @($bft | ForEach-Object { $k = [string]$_[0]; if ($gmap.ContainsKey($k)) { [math]::Round($gmap[$k], 2) } else { $null } })
    $Chart.stutters = @($FA.Stutters | Sort-Object Ft -Descending | Select-Object -First 300 | ForEach-Object { [math]::Round($_.T, 1) })
    $Chart.source = 'presentmon'
} else {
    $src = 'ab_frametime_ms'
    if ($Sum['pm_ft_avg_ms'].n -gt 0) { $src = 'pm_ft_avg_ms' }
    $Chart.t = @($GameRows | ForEach-Object { [math]::Round($TS[$_], 1) })
    $Chart.ft_avg = @($GameRows | ForEach-Object { $v = $SysCol[$src][$_]; if ([double]::IsNaN($v)) { $null } else { [math]::Round($v, 2) } })
    $Chart.ft_max = $Chart.ft_avg
    $Chart.source = $src
}

# ================================================================
#  SUMMARY.JSON
# ================================================================
function Round-Or([double]$v, [int]$d = 2) { if ([double]::IsNaN($v) -or [double]::IsInfinity($v)) { return $null }; return [math]::Round($v, $d) }

$FramesOut = [ordered]@{
    captured = $HasFrames
    frames = $FA.Frames; seconds = Round-Or $FA.Seconds 1; excluded_frames = $FA.ExcludedFrames; long_pauses = $FA.LongPauses; segments = $FA.Segments
    fps_avg = Round-Or $FA.FpsAvg 1; low1_fps = Round-Or $FA.Low1Fps 1; low01_fps = Round-Or $FA.Low01Fps 1
    ft_p50 = Round-Or $FA.P50; ft_p90 = Round-Or $FA.P90; ft_p95 = Round-Or $FA.P95; ft_p99 = Round-Or $FA.P99; ft_p999 = Round-Or $FA.P999; ft_max = Round-Or $FA.Max
    stutters = $FA.StutterCount; major_stutters = $FA.MajorStutters; stutters_per_min = Round-Or $StutterRate 2
    stutter_gpu = $FA.StutterGpu; stutter_cpu = $FA.StutterCpu; stutter_stall = $FA.StutterStall
    missed = $FA.Missed; missed_pct = Round-Or $MissedPct 2; missed_gpu_bound = $FA.MissedGpuBound; missed_cpu_side = $FA.MissedCpuSide; dropped = $FA.Dropped
    gpu_busy_avg = Round-Or $FA.GpuBusyAvg; gpu_busy_p90 = Round-Or $FA.GpuBusyP90; cpu_busy_avg = Round-Or $FA.CpuBusyAvg; cpu_busy_p90 = Round-Or $FA.CpuBusyP90
    gpu_bound_pct = Round-Or ($GpuShare * 100) 1; cpu_bound_pct = Round-Or ($CpuShare * 100) 1; capped_pct = Round-Or ($CapShare * 100) 1
    gpu_headroom_pct = Round-Or $GpuHeadroom 1; cpu_headroom_pct = Round-Or $CpuHeadroom 1
    source = $FrameSource
}
$SysOut = [ordered]@{}
foreach ($k in $Sum.Keys) {
    $v = $Sum[$k]
    if ($v.n -le 0) { continue }
    $SysOut[$k] = [ordered]@{ avg = Round-Or $v.avg; p50 = Round-Or $v.p50; p95 = Round-Or $v.p95; max = Round-Or $v.max; min = Round-Or $v.min }
}
$PrevOut = $null
if ($Prev) {
    $PrevOut = [ordered]@{ session = (Split-Path -Leaf $PrevDir); label = [string]$Prev.label; verdict = [string]$Prev.verdict
                           fps_avg = $Prev.frames.fps_avg; low1_fps = $Prev.frames.low1_fps; stutters_per_min = $Prev.frames.stutters_per_min
                           missed_pct = $Prev.frames.missed_pct; gpu_busy_p90 = $Prev.frames.gpu_busy_p90; cpu_busy_p90 = $Prev.frames.cpu_busy_p90 }
}
$Summary = [ordered]@{
    version = $GamePerfVersion
    analyzed = [DateTime]::Now.ToString('o', $GpInv)
    session = (Split-Path -Leaf $SessionDir)
    game = $GameName; game_exe = [string]$Meta.game_exe; game_version = [string]$Meta.game_version
    label = [string]$Meta.label; mode = [string]$Meta.mode; target_fps = $TargetFps; budget_ms = Round-Or $Budget
    started = [string]$Meta.started; duration_s = $Meta.duration_s
    verdict = $Verdict
    frames = $FramesOut
    gpu_throttle = [ordered]@{ samples = $ThrRows; power_cap = $ThrCount.power_cap; thermal = $ThrCount.sw_thermal + $ThrCount.hw_thermal; hw_slowdown = $ThrCount.hw_slowdown; power_brake = $ThrCount.power_brake }
    system = $SysOut
    logger = [ordered]@{ cpu_pct = $Meta.logger_cpu_pct; avg_loop_ms = $Meta.logger_avg_loop_ms; gaps = $Gaps.Count }
    findings = $FindingsSorted
    incidents = @($IncidentOut.ToArray())
    markers = @($MarkerOut.ToArray())
    configs = @($Manifest)
    config_changes = @($ConfigChanges.ToArray())
    previous = $PrevOut
    notes = @($Notes.ToArray())
    chart = $Chart
}

# ================================================================
#  REPORT.MD
# ================================================================
Say 'Writing report...'
$md = New-Object Text.StringBuilder
function L([string]$s = '') { [void]$md.AppendLine($s) }

L "# GamePerf report - $(Clean $GameName)"
L ''
$startLocal = ''
try { $startLocal = ([DateTime]::Parse([string]$Meta.started, $GpInv)).ToString('yyyy-MM-dd HH:mm', $GpInv) } catch { }
L "**$startLocal** - $(Format-GpDuration $Meta.duration_s) - $($Meta.mode) - target $TargetText$(if ($Meta.label) { ' - "' + (Clean $Meta.label) + '"' })"
L ''
L "> $Verdict"
L ''
L '## Frame pacing'
L ''
if ($HasFrames) {
    L '| Metric | Value |'
    L '|---|---|'
    L "| Average FPS | $(N $FA.FpsAvg 1) |"
    L "| 1% low / 0.1% low FPS | $(N $FA.Low1Fps 1) / $(N $FA.Low01Fps 1) |"
    L "| Frame time p50 / p95 / p99 / p99.9 | $(N $FA.P50 2) / $(N $FA.P95 2) / $(N $FA.P99 2) / $(N $FA.P999 2) ms |"
    L "| Worst frame | $(N $FA.Max 1) ms |"
    if ($Budget -gt 0) { L "| Frames over budget (>1.25x $(N $Budget 1) ms) | $($FA.Missed) ($(N $MissedPct 2)%) |" }
    L "| Stutters | $($FA.StutterCount) ($(N $StutterRate 2)/min, $($FA.MajorStutters) major) |"
    L "| Stutter type | GPU spike $($FA.StutterGpu) / game-thread $($FA.StutterCpu) / stall $($FA.StutterStall) |"
    if (-not $IsVr) { L "| Frames never displayed | $($FA.Dropped) |" }
    L "| Frames analysed | $($FA.Frames) over $(Format-GpDuration $FA.Seconds) ($($FA.ExcludedFrames) loading/paused frames excluded) |"
    L ''
    L '## What limited the frames'
    L ''
    L '| | Share of frames |'
    L '|---|---|'
    L "| GPU-bound (GPU busy >= 90% of the frame) | $(Pct $FA.GpuBound $FA.Classified 1) |"
    L "| CPU-side (game thread / driver / sync) | $(Pct $FA.CpuBound $FA.Classified 1) |"
    L "| Capped (met the target with time to spare) | $(Pct $FA.Capped $FA.Classified 1) |"
    L ''
    L "GPU busy per frame: $(N $FA.GpuBusyAvg 2) ms average, $(N $FA.GpuBusyP90 2) ms p90. CPU busy per frame: $(N $FA.CpuBusyAvg 2) ms average, $(N $FA.CpuBusyP90 2) ms p90."
    if (-not [double]::IsNaN($GpuHeadroom)) { L "Estimated headroom against the $(N $Budget 1) ms budget: GPU $(N $GpuHeadroom 0)%, CPU $(N $CpuHeadroom 0)%." }
    L ''
} elseif ($AbOnly) {
    L "Afterburner framerate (1 Hz): average $(N $AbOnly.avg 1), minimum $(N $AbOnly.min 1) fps. Per-frame data was not captured, so stutter cannot be measured."
    L ''
} else {
    L 'No frame data was captured.'
    L ''
}

L '## Findings'
L ''
if ($FindingsSorted.Count) {
    foreach ($f in $FindingsSorted) { L "- **[$($f.severity.ToUpper())] $(Clean $f.title)** - $(Clean $f.detail)" }
} else { L '- Nothing stood out.' }
L ''

if ($IncidentOut.Count) {
    L '## Worst stutters and what was happening'
    L ''
    L '| Time | Session s | Worst frame | Typical | GPU busy | CPU busy | Type | Around it |'
    L '|---|---|---|---|---|---|---|---|'
    foreach ($i in $IncidentOut) {
        $ctx = @($i.context)
        if ($i.background) { $ctx += "background CPU: $($i.background)" }
        $ctxText = $(if ($ctx.Count) { Clean ($ctx -join '; ') } else { 'nothing unusual in the 1 Hz log' })
        L "| $($i.clock) | $(N $i.t 1) | $(N $i.worst_ms 1) ms$(if ($i.frames -gt 1) { " (x$($i.frames))" }) | $(N $i.typical_ms 1) ms | $(N $i.gpu_busy_ms 1) | $(N $i.cpu_busy_ms 1) | $($KindText[$i.kind]) | $ctxText |"
    }
    L ''
}

if ($MarkerOut.Count) {
    L '## Your markers'
    L ''
    L '| # | Session s | Worst frame in the 4 s before | Stutters | Around it |'
    L '|---|---|---|---|---|'
    foreach ($mk in $MarkerOut) {
        $ctx = @($mk.context)
        if ($mk.background) { $ctx += "background CPU: $($mk.background)" }
        L "| $($mk.marker) | $(N $mk.t 1) | $(N $mk.worst_frame_ms 1) ms | $($mk.stutters_in_window) | $(Clean ($ctx -join '; ')) |"
    }
    L ''
}

L '## System during play'
L ''
L '| Sensor | Avg | p95 | Max | Min |'
L '|---|---|---|---|---|'
$Pretty = [ordered]@{
    cpu_total = 'CPU total %'; ccd0_cpu = 'CPU group 0 (CCD0) %'; ccd1_cpu = 'CPU group 1 (CCD1) %'; cpu_eff_mhz = 'CPU effective clock MHz'
    game_cpu = 'Game CPU % (whole machine)'; game_top_thread = "Game's busiest thread % of a core"; game_ws_mb = 'Game working set MB'; vr_cpu = 'VR runtime CPU %'
    tot_dpc = 'DPC % (all CPUs)'; cpu0_dpc = 'CPU 0 DPC %'; cpu0_int = 'CPU 0 interrupt %'; freqcore_int = 'Interrupt-target core interrupt %'
    gpu_util = 'GPU load %'; gpu_gclk = 'GPU clock MHz'; gpu_power_w = 'GPU power W'; gpu_temp = 'GPU temp C'; vram_used_mb = 'VRAM used MB'
    gpu_volt_mv = 'GPU voltage mV'; pcie_bus_pct = 'PCIe bus load %'
    free_ram_mb = 'Free RAM MB'; commit_pct = 'Commit charge %'; hardfaults_s = 'Hard faults/s (SYSTEM-WIDE)'; disk_read_mb_s = 'Disk read MB/s'; disk_busy_pct = 'Disk busy %'
    timer_res_ms = 'Timer resolution ms'; loop_ms = 'Logger loop ms'
}
foreach ($k in $Pretty.Keys) {
    $v = $Sum[$k]
    if (-not $v -or $v.n -le 0) { continue }
    L "| $($Pretty[$k]) | $(N $v.avg 1) | $(N $v.p95 1) | $(N $v.max 1) | $(N $v.min 1) |"
}
L ''
if ($ThrRows -gt 0) {
    L "NVIDIA clock-event reasons over $ThrRows samples: power cap $($ThrCount.power_cap), thermal $($ThrCount.sw_thermal + $ThrCount.hw_thermal), hardware slowdown $($ThrCount.hw_slowdown), power brake $($ThrCount.power_brake)."
    L ''
}
if (@($Meta.background_top).Count) {
    L ('**Top background CPU users over the session:** ' + ((@($Meta.background_top) | Select-Object -First 8 | ForEach-Object { "$($_.name) $(N $_.avg_pct 2)%" }) -join ', '))
    L ''
}

L '## Machine'
L ''
L "- CPU: $(Clean $m.cpu) ($($m.cpu_cores) cores / $($m.cpu_logical) threads)$(if ($m.x3d_profile) { " - $($m.x3d_profile), V-Cache cores $($m.vcache_cores)" })"
L "- RAM: $($m.ram_gb) GB$(if ($m.ram_mts) { " @ $($m.ram_mts) MT/s" })"
$gpuLine = ''
if ($m.nvidia) { $gpuLine = "$($m.nvidia.name), driver $($m.nvidia.driver), $($m.nvidia.vram_mb) MB, PCIe gen $($m.nvidia.pcie_gen_now) x$($m.nvidia.pcie_width_now) (max gen $($m.nvidia.pcie_gen_max) x$($m.nvidia.pcie_width_max)), power limit $($m.nvidia.power_limit_w) W" }
elseif ($m.gpus) { $gpuLine = (@($m.gpus) | ForEach-Object { "$($_.name) (driver $($_.driver))" }) -join '; ' }
L "- GPU: $(Clean $gpuLine)"
L "- Display: $($m.display_resolution) @ $($m.display_refresh_hz) Hz"
L "- Windows: $(Clean $m.os) - power plan '$(Clean $m.power_plan)' - HAGS $($m.hags) - Game Mode $($m.game_mode) - Game DVR $($m.game_dvr) - VBS $($m.vbs) / HVCI $($m.hvci) - timer $(N $m.timer_res_ms 2) ms"
if ($IsVr) {
    $rt = @($Meta.vr.runtimes_running) -join ', '
    L "- VR: runtime processes running at start: $(if ($rt) { $rt } else { 'none detected' }); OpenXR runtime: $(Clean $Meta.vr.openxr.ActiveRuntime)"
}
if ($FrameSource.present_mode) { L "- Present mode: $($FrameSource.present_mode), sync interval $($FrameSource.sync_interval)" }
L "- Logger cost: $(N $Meta.logger_cpu_pct 2)% CPU on average, $(N $Meta.logger_avg_loop_ms 1) ms per sample"
L ''

L '## Game configuration'
L ''
if ($Manifest.Count) {
    foreach ($c in $Manifest) { L "- ``$($c.file)`` - $(Clean $c.original) ($($c.source))" }
} else { L '- No config files were captured. Add them in the app (AI page) or paste them into your AI chat.' }
L ''
if ($ConfigChanges.Count) {
    L "### Changed since the previous session ($(Split-Path -Leaf $PrevDir))"
    L ''
    foreach ($cc in $ConfigChanges) {
        L "**$(Clean $cc.file)**"
        L ''
        L '```'
        foreach ($line in $cc.changes) { L $line }
        L '```'
        L ''
    }
}
if ($PrevOut) {
    L '## Compared with the previous session'
    L ''
    L '| | Previous | This session |'
    L '|---|---|---|'
    L "| Label | $(Clean $PrevOut.label) | $(Clean $Meta.label) |"
    L "| Average FPS | $(N $PrevOut.fps_avg 1) | $(N $FA.FpsAvg 1) |"
    L "| 1% low FPS | $(N $PrevOut.low1_fps 1) | $(N $FA.Low1Fps 1) |"
    L "| Stutters / min | $(N $PrevOut.stutters_per_min 2) | $(N $StutterRate 2) |"
    L "| Frames over budget % | $(N $PrevOut.missed_pct 2) | $(N $MissedPct 2) |"
    L "| GPU busy p90 ms | $(N $PrevOut.gpu_busy_p90 2) | $(N $FA.GpuBusyP90 2) |"
    L "| CPU busy p90 ms | $(N $PrevOut.cpu_busy_p90 2) | $(N $FA.CpuBusyP90 2) |"
    L ''
}
if ($Notes.Count) {
    L '## Data notes'
    L ''
    foreach ($n in $Notes) { L "- $(Clean $n)" }
    L ''
}
$ReportText = $md.ToString()

# ================================================================
#  AI-PROMPT.MD
# ================================================================
Say 'Building the AI brief...'
$ai = New-Object Text.StringBuilder
function A([string]$s = '') { [void]$ai.AppendLine($s) }

A '# Game performance analysis request'
A ''
A 'You are an expert PC gaming and VR performance engineer. Below is a performance capture made with GamePerf (a PresentMon + Windows performance-counter logger), the game''s configuration files, and my goals. Diagnose what limits my frame rate and causes frame drops or stutter, and tell me exactly what to change.'
A ''
A '## My goals'
A ''
A ([string]$Settings.Goals)
A ''
A "Display mode: **$($Meta.mode)**. Target: **$TargetText**."
A ''
A '## What I need from you'
A ''
A '1. **Diagnosis** - the main causes of missed frames and stutter, ranked by impact. Tie each one to evidence in the data (numbers, timestamps, stutter incidents, markers).'
A '2. **Game settings** - concrete edits to the config files below: file, setting, current value -> new value, and why. Order them by benefit per visual cost. Respect my goals: keep native resolution; no quad views, no foveated rendering, no upscaling. If there is headroom, say which settings I can raise.'
A '3. **Outside the game** - Windows, driver, VR runtime or hardware changes, only where the evidence points there.'
A '4. **Verify** - what to change for my next session (one or two things at a time) and which numbers in this report should move.'
A ''
A 'If a config file you need is missing, name it and where it usually lives. Do not invent setting names: only recommend keys that appear in the files below, or say clearly that a key is a suggestion to add.'
A ''
A '## How to read this data'
A ''
A '- **Frame time** = time between presents (PresentMon). 1% low FPS = 1000 / p99 frame time.'
A '- **GPU busy / CPU busy** = how long the GPU / the game''s CPU work was busy on each frame. GPU busy near the frame time means GPU-bound; GPU busy well below it means the GPU waited for the CPU side (game thread, driver, sync) or for the frame cap.'
A '- **Stutter** = a frame at least 2x the median of the ~60 frames around it and at least 6 ms slower. Types: *GPU spike* (GPU busy for the whole frame), *game-thread spike* (CPU busy), *stall* (neither busy: I/O, shader compilation, locks, the OS).'
A '- **Markers** = moments where I pressed a key because I felt a hitch.'
A '- **hardfaults_s is SYSTEM-WIDE**, not the game. On a traced iRacing session the sim caused 14 of 4,712 hard faults; Windows services caused the rest. Treat bursts as leads only.'
A '- **game_top_thread** = the game''s busiest thread as % of one core. Near 100% = main-thread bound regardless of total CPU %.'
A '- **ccd0_cpu / ccd1_cpu** = average load of the two CPU groups (on dual-CCD Ryzen X3D: V-Cache die / frequency die).'
if ($IsVr) { A '- **VR caveat**: PresentMon times the game''s own presents. In VR the runtime''s compositor and reprojection are separate; GPU busy still measures the game''s own GPU work per frame.' }
A ''
A '## Session report'
A ''
A ($ReportText -replace '^# .*\r?\n', '')

# ---- 10-second timeline -------------------------------------------
if ($TS.Length -gt 0) {
    $t0 = $TS[$GameRows[0]]; $t1 = $TS[$GameRows[$GameRows.Length - 1]]
    $bw = [math]::Max(10, [math]::Ceiling(($t1 - $t0) / 240 / 10) * 10)
    $stT = [double[]]@($FA.Stutters | ForEach-Object { $_.T } | Sort-Object)
    $ones = New-Object 'double[]' $stT.Length
    for ($i = 0; $i -lt $ones.Length; $i++) { $ones[$i] = 1 }
    $mkT = [double[]]@($Markers | Sort-Object)
    $mkOnes = New-Object 'double[]' $mkT.Length
    for ($i = 0; $i -lt $mkOnes.Length; $i++) { $mkOnes[$i] = 1 }
    A "## Timeline ($bw-second buckets, session seconds)"
    A ''
    A 'Columns: t, fps, worst frame ms, stutters, GPU busy ms, CPU busy ms, GPU load %, GPU MHz, GPU W, VRAM MB, CPU total %, game busiest thread %, CCD0 %, CCD1 %, DPC %, hard faults/s max, disk read MB/s max, markers'
    A ''
    A '```csv'
    A 't,fps,ft_max,stutters,gpu_busy,cpu_busy,gpu_load,gpu_mhz,gpu_w,vram_mb,cpu,game_thread,ccd0,ccd1,dpc,hardfaults_max,disk_read_max,markers'
    for ($b = [math]::Floor($t0); $b -le $t1; $b += $bw) {
        $e = $b + $bw - 0.001
        $fps = ''; $ftm = ''; $gb = ''; $cb = ''
        if ($HasFrames) {
            $wf = [GamePerf.Native.Stats]::Window($FA.T, $FA.Ft, $b, $e)
            if ($wf[0] -gt 0) { $fps = N (1000.0 / $wf[1]) 1; $ftm = N $wf[2] 1 }
            $wg = [GamePerf.Native.Stats]::Window($FA.T, $FA.Gpu, $b, $e); if ($wg[0] -gt 0) { $gb = N $wg[1] 2 }
            $wc = [GamePerf.Native.Stats]::Window($FA.T, $FA.Cpu, $b, $e); if ($wc[0] -gt 0) { $cb = N $wc[1] 2 }
        } else {
            $wa = [GamePerf.Native.Stats]::Window($TS, $SysCol['ab_fps'], $b, $e); if ($wa[0] -gt 0) { $fps = N $wa[1] 1 }
        }
        $st = 0
        if ($stT.Length) { $st = [int]([GamePerf.Native.Stats]::Window($stT, $ones, $b, $e)[0]) }
        $mk = 0
        if ($mkT.Length) { $mk = [int]([GamePerf.Native.Stats]::Window($mkT, $mkOnes, $b, $e)[0]) }
        $cells = @("$([int]$b)", $fps, $ftm, $st, $gb, $cb)
        foreach ($pair in @(@('gpu_util', 1, 0), @('gpu_gclk', 1, 0), @('gpu_power_w', 1, 0), @('vram_used_mb', 1, 0), @('cpu_total', 1, 0), @('game_top_thread', 1, 0),
                            @('ccd0_cpu', 1, 0), @('ccd1_cpu', 1, 0), @('tot_dpc', 1, 1), @('hardfaults_s', 2, 0), @('disk_read_mb_s', 2, 0))) {
            $wv = [GamePerf.Native.Stats]::Window($TS, $SysCol[$pair[0]], $b, $e)
            $cells += $(if ($wv[0] -gt 0) { N $wv[$pair[1]] $pair[2] } else { '' })
        }
        $cells += $mk
        A ((@($cells) | ForEach-Object { ("$_" -replace '^-$', '') }) -join ',')
    }
    A '```'
    A ''
}

# ---- config files -------------------------------------------------
A '## Game configuration files'
A ''
if ($Manifest.Count) {
    $total = 0
    foreach ($c in $Manifest) {
        $path = Join-Path $ConfigDir $c.file
        $text = Read-GpTextFile -Path $path
        if ($null -eq $text) { continue }
        $note = ''
        if ($text.Length -gt $MaxConfigChars) { $note = " - TRUNCATED: first $MaxConfigChars of $($text.Length) characters"; $text = $text.Substring(0, $MaxConfigChars) }
        if ($total + $text.Length -gt $MaxAllConfigChars) {
            A "### $(Split-Path -Leaf $c.original)"
            A ''
            A "(Not included - the brief would get too large. Full file: configs\$($c.file); paste it in if it matters.)"
            A ''
            continue
        }
        $total += $text.Length
        $ext = [IO.Path]::GetExtension($c.file).TrimStart('.').ToLowerInvariant()
        $fence = $(if ($ext -in @('json', 'xml', 'ini', 'lua', 'yaml', 'yml')) { $ext } else { '' })
        A "### $(Split-Path -Leaf $c.original)"
        A ''
        A "Location: ``$($c.original)`` ($($c.source)$note)"
        A ''
        A ('```' + $fence)
        A ($text.TrimEnd())
        A '```'
        A ''
    }
} else {
    A '(No config files captured. I will paste the relevant ones below, or ask me for them.)'
    A ''
}
$PromptText = $ai.ToString()
if ($Settings.Redact) {
    $PromptText = Protect-GpText $PromptText
    $ReportText = Protect-GpText $ReportText
}
$Summary.prompt_chars = $PromptText.Length
$Summary.prompt_tokens_est = [int]($PromptText.Length / 4)

Write-GpTextFile -Path (Join-Path $SessionDir 'report.md') -Text $ReportText
Write-GpTextFile -Path (Join-Path $SessionDir 'ai-prompt.md') -Text $PromptText
Write-GpJson -Path (Join-Path $SessionDir 'summary.json') -Object $Summary -Depth 8
# The app's session list reads only this, so opening it stays instant with hundreds of sessions.
$Card = [ordered]@{
    verdict = $Verdict; label = [string]$Meta.label
    frames = [ordered]@{ captured = $HasFrames; fps_avg = $FramesOut.fps_avg; low1_fps = $FramesOut.low1_fps; stutters = $FA.StutterCount; stutters_per_min = $FramesOut.stutters_per_min; missed_pct = $FramesOut.missed_pct }
}
Write-GpJson -Path (Join-Path $SessionDir 'card.json') -Object $Card -Depth 4

Say "Done: $Verdict"
if (-not $Quiet) { Write-Host "  Report: $(Join-Path $SessionDir 'report.md')" -ForegroundColor Green }
