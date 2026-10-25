<#
    SteamVR-Timing.ps1
    ---------------------------------------------------------------
    Read-only SteamVR compositor timing for FullTrace.

    iRacing's OpenVR mode and its OpenXR mode both submit to the
    SteamVR compositor on this rig (Pimax via the sBOYS driver, SteamVR
    as the active OpenXR runtime). IVRCompositor::GetFrameTimings is
    therefore the same data in both modes. No RTSS / Afterburner
    required for FPS or frame time.

    SAFETY
    ------
    * The process guard runs first. Unless vrserver.exe or
      vrcompositor.exe is already running, this file never loads
      openvr_api.dll and never calls VR_Init.
    * When it does init, the application type is Background (3).
      That type does not start SteamVR, does not keep it running,
      and does not submit frames. Scene (1) is not used.
    * The only compositor calls are reads: frame timing, cumulative
      stats, scene-focus pid, last-frame renderer. No Submit, no
      overlay, no launch, no quit.
    * System / settings / applications calls are reads too (render
      target, refresh, vsync-to-photons, model, resolution scale,
      app key). Nothing is written.
    * If SteamVR is absent, or init fails, every VR column stays
      blank and the rest of the logger is unchanged.
    * -NoSteamVr on FullTrace skips this path entirely.

    The history buffer holds 128 frames. At 72 / 90 / 120 Hz that is
    a full second. Above that, vr_fps still counts every frame index
    the compositor advanced, while the averages cover the newest 128.

    Column units are documented in README.md and the kit changelog.
#>

$script:SteamVrColumnNames = @(
    'gpu_timing_source',
    'vr_fps',
    'vr_fps_presented',
    'vr_frametime_ms',
    'vr_frametime_max_ms',
    'vr_app_gpu_ms',
    'vr_app_gpu_max_ms',
    'vr_comp_gpu_ms',
    'vr_comp_cpu_ms',
    'vr_gpu_ms',
    'vr_idle_cpu_ms',
    'vr_submit_ms',
    'vr_over_budget',
    'vr_reprojected',
    'vr_reproj_cpu',
    'vr_reproj_gpu',
    'vr_motion',
    'vr_dropped',
    'vr_mispresented',
    'vr_throttled',
    'vr_frames',
    'vr_hz',
    'vr_target_w',
    'vr_target_h',
    'vr_res_scale',
    'vr_predict_ms',
    'vr_predict_extra',
    'vr_vsync_to_photons_ms',
    'vr_transfer_ms',
    'vr_scene_app',
    'vr_scene_pid',
    'vr_renderer',
    'vr_hmd'
)

$script:SteamVrTextColumnNames = @(
    'gpu_timing_source',
    'vr_scene_app',
    'vr_renderer',
    'vr_hmd'
)

# Reprojection flags from openvr.h (app-facing Compositor_FrameTiming).
# 0x04 means async reprojection is enabled, not that it happened.
# 0x100 is the throttle-count field on this struct, not "motion enabled"
# (that name belongs to the driver-direct timing struct and overlaps).
$script:SteamVrFlagCpu        = 0x01
$script:SteamVrFlagGpu        = 0x02
$script:SteamVrFlagMotion     = 0x08
$script:SteamVrFlagPredict    = 0xF0
$script:SteamVrFlagThrottle   = 0xF00

$script:SteamVrInitAttempts = 0
$script:VrConnected         = $false
$script:VrStatus            = 'not-running'
$script:VrDetail            = ''
$script:VrLastError         = ''
$script:VrBackoff           = 0
$script:VrTicks             = 0
$script:SteamVrDisabled     = $false
$script:VrState             = @{ StructSize = 0 }
$script:VrStatic            = @{ Hz = 0; PhotonsMs = -1; Hmd = ''; TargetW = $null; TargetH = $null; ResScale = $null }
$script:VrProcNames         = @{}

function Get-SteamVrColumnNames { return ,$script:SteamVrColumnNames }
function Get-SteamVrTextColumns { return ,$script:SteamVrTextColumnNames }

function Test-SteamVrShouldConnect {
    <#
        True only when the SteamVR server or compositor process is
        already running. vrmonitor alone is not enough: init is what
        would talk to the runtime, and this guard is what keeps a
        logger started too early from calling it.
    #>
    param([string[]]$ProcessNames)
    if (-not $ProcessNames) { return $false }
    foreach ($n in $ProcessNames) {
        if (-not $n) { continue }
        # Get-Process returns a bare name. A full path has to work on
        # Windows and in the Linux test host, so both separators count.
        $sep = [System.IO.Path]::DirectorySeparatorChar
        $norm = ("$n").Replace('\', $sep).Replace('/', $sep)
        $leaf = [System.IO.Path]::GetFileNameWithoutExtension($norm)
        if (-not $leaf) { continue }
        $leaf = $leaf.ToLowerInvariant()
        if ($leaf -eq 'vrserver' -or $leaf -eq 'vrcompositor') { return $true }
    }
    return $false
}

function Get-SteamVrRunningProcessNames {
    try {
        $procs = @(Get-Process -Name 'vrserver','vrcompositor' -ErrorAction SilentlyContinue)
        return @($procs | ForEach-Object { $_.ProcessName })
    } catch {
        return @()
    }
}

function Resolve-GpuTimingSource {
    <#
        gpu_fps / gpu_frametime_ms stay on Afterburner when it has
        them. SteamVR fills whichever of the two Afterburner left
        blank. The source string says which.
    #>
    param($AbFps, $AbFt, $VrFps, $VrFt)
    $hasAbF = ($null -ne $AbFps -and "$AbFps" -ne '')
    $hasAbT = ($null -ne $AbFt  -and "$AbFt"  -ne '')
    $hasVrF = ($null -ne $VrFps -and "$VrFps" -ne '')
    $hasVrT = ($null -ne $VrFt  -and "$VrFt"  -ne '')
    $fps = $AbFps
    $ft  = $AbFt
    $usedVr = $false
    $usedAb = $hasAbF -or $hasAbT
    if (-not $hasAbF -and $hasVrF) { $fps = $VrFps; $usedVr = $true }
    if (-not $hasAbT -and $hasVrT) { $ft  = $VrFt;  $usedVr = $true }
    $src = ''
    if     ($usedAb -and $usedVr) { $src = 'afterburner+steamvr' }
    elseif ($usedAb)              { $src = 'afterburner' }
    elseif ($usedVr)              { $src = 'steamvr' }
    return @{ Fps = $fps; Frametime = $ft; Source = $src }
}

function Resolve-SteamVrResScale {
    <#
        Per-app resolutionScale wins. SteamVR stores that as a percent
        (100 = 1.0) and the legacy supersampleScale as a multiplier.
        A value >= 10 is a percent; anything smaller and positive is
        already a multiplier. 0 / unset falls through.
    #>
    param($AppValue, [bool]$AppOk, $GlobalValue, [bool]$GlobalOk)
    function AsScale($v, [bool]$ok) {
        if (-not $ok -or $null -eq $v) { return $null }
        $n = 0.0
        if (-not [double]::TryParse("$v", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
            return $null
        }
        if ($n -le 0 -or $n -gt 500) { return $null }
        if ($n -ge 10) { return $n / 100.0 }
        return $n
    }
    $app = AsScale $AppValue $AppOk
    if ($null -ne $app) { return $app }
    return (AsScale $GlobalValue $GlobalOk)
}

function ConvertTo-SteamVrRound($Value, [int]$Digits) {
    if ($null -eq $Value) { return $null }
    return [math]::Round([double]$Value, $Digits)
}

function ConvertFrom-SteamVrTimingBuffer {
    <#
        Decode a GetFrameTimings buffer. Stride is the struct size the
        runtime accepted (192 with m_flTransferLatencyMs, 184 without).
        Field offsets are the Windows x64 layout of Compositor_FrameTiming
        and have been stable since the vsync fields were added: six
        uint32s, a double at offset 24, sixteen floats, then the pose.

        The unary comma on the return is load-bearing. It keeps a 0- or
        1-frame result an array. Callers must assign the call directly.
        Wrapping it in @() nests that array, so Count is 1, every frame
        fails the plausibility check, and the timing columns stay blank.
    #>
    param(
        [byte[]]$Buffer,
        [int]$Size,
        [int]$Count
    )
    $empty = @()
    if (-not $Buffer -or $Size -lt 96 -or $Count -le 0) { return ,$empty }
    $max = [int][math]::Floor($Buffer.Length / $Size)
    if ($Count -gt $max) { $Count = $max }
    if ($Count -le 0) { return ,$empty }

    $list = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Count; $i++) {
        $b = $i * $Size
        $transfer = $null
        if (($b + 188) -le ($b + $Size) -and $Size -ge 188) {
            $transfer = [double][BitConverter]::ToSingle($Buffer, $b + 184)
        }
        $vsyncs = 0
        if ($Size -ge 184) { $vsyncs = [int][BitConverter]::ToUInt32($Buffer, $b + 180) }
        $list.Add([pscustomobject]@{
            Index         = [int64][BitConverter]::ToUInt32($Buffer, $b + 4)
            Presents      = [int][BitConverter]::ToUInt32($Buffer, $b + 8)
            Mis           = [int][BitConverter]::ToUInt32($Buffer, $b + 12)
            Dropped       = [int][BitConverter]::ToUInt32($Buffer, $b + 16)
            Flags         = [int][BitConverter]::ToUInt32($Buffer, $b + 20)
            SystemTime    = [double][BitConverter]::ToDouble($Buffer, $b + 24)
            AppGpuMs      = [double][BitConverter]::ToSingle($Buffer, $b + 32)
            PostGpuMs     = [double][BitConverter]::ToSingle($Buffer, $b + 36)
            TotalGpuMs    = [double][BitConverter]::ToSingle($Buffer, $b + 40)
            CompGpuMs     = [double][BitConverter]::ToSingle($Buffer, $b + 44)
            CompCpuMs     = [double][BitConverter]::ToSingle($Buffer, $b + 48)
            IdleCpuMs     = [double][BitConverter]::ToSingle($Buffer, $b + 52)
            IntervalMs    = [double][BitConverter]::ToSingle($Buffer, $b + 56)
            PresentCpuMs  = [double][BitConverter]::ToSingle($Buffer, $b + 60)
            WaitPresentMs = [double][BitConverter]::ToSingle($Buffer, $b + 64)
            SubmitMs      = [double][BitConverter]::ToSingle($Buffer, $b + 68)
            VSyncsToView  = $vsyncs
            TransferMs    = $transfer
        })
    }
    return ,$list.ToArray()
}

function ConvertFrom-SteamVrCumulative([byte[]]$Buffer) {
    if (-not $Buffer -or $Buffer.Length -lt 16) { return $null }
    return [pscustomobject]@{
        Pid         = [int64][BitConverter]::ToUInt32($Buffer, 0)
        Presents    = [int64][BitConverter]::ToUInt32($Buffer, 4)
        Dropped     = [int64][BitConverter]::ToUInt32($Buffer, 8)
        Reprojected = [int64][BitConverter]::ToUInt32($Buffer, 12)
    }
}

function Test-SteamVrFramePlausible($Frame) {
    if ($null -eq $Frame) { return $false }
    $t = 0.0
    try { $t = [double]$Frame.SystemTime } catch { return $false }
    if ($t -le 0 -or $t -gt 1e12) { return $false }
    foreach ($name in @('IntervalMs','AppGpuMs','TotalGpuMs','CompGpuMs','CompCpuMs','SubmitMs')) {
        $v = 0.0
        try { $v = [double]$Frame.$name } catch { return $false }
        if ($v -lt 0 -or $v -gt 250) { return $false }
    }
    return $true
}

function Get-SteamVrFrameAggregates {
    <#
        Turn one second of compositor frames into a CSV row hashtable.
        Keys match Get-SteamVrColumnNames except gpu_timing_source,
        which FullTrace fills after comparing with Afterburner.

        FPS uses the frame-index delta over the system-time delta, so
        frames that rotated out of the 128-deep history still count.
        Averages use only the frames actually returned.
    #>
    param(
        [object[]]$Frames,
        [hashtable]$State,
        [double]$Hz = 0,
        [double]$VsyncToPhotonsMs = -1,
        [string]$SceneApp = '',
        $ScenePid = 0,
        [string]$Renderer = '',
        [string]$Hmd = '',
        $TargetW = $null,
        $TargetH = $null,
        $ResScale = $null,
        $Cumulative = $null,
        $OurPid = 0
    )
    if (-not $State) { $State = @{} }
    $row = @{}
    foreach ($c in $script:SteamVrColumnNames) { $row[$c] = $null }

    if ($Hz -gt 1) { $row.vr_hz = (ConvertTo-SteamVrRound $Hz 2) }
    if ($null -ne $TargetW -and "$TargetW" -ne '' -and [int]$TargetW -gt 0) { $row.vr_target_w = [int]$TargetW }
    if ($null -ne $TargetH -and "$TargetH" -ne '' -and [int]$TargetH -gt 0) { $row.vr_target_h = [int]$TargetH }
    if ($null -ne $ResScale -and "$ResScale" -ne '') { $row.vr_res_scale = (ConvertTo-SteamVrRound $ResScale 3) }
    if ($VsyncToPhotonsMs -ge 0) { $row.vr_vsync_to_photons_ms = (ConvertTo-SteamVrRound $VsyncToPhotonsMs 2) }
    if ($SceneApp) { $row.vr_scene_app = $SceneApp }
    if ([int64]$ScenePid -gt 0) { $row.vr_scene_pid = [int64]$ScenePid }
    if ($Renderer) { $row.vr_renderer = $Renderer }
    if ($Hmd) { $row.vr_hmd = $Hmd }

    $frames = @($Frames | Where-Object { $null -ne $_ })
    if ($frames.Count -eq 0) { return $row }

    $ordered = @($frames | Sort-Object { [int64]$_.Index })
    $newest = $ordered[-1]
    $oldest = $ordered[0]
    $havePrev = $State.ContainsKey('LastIndex') -and $null -ne $State.LastIndex
    if ($havePrev -and [int64]$newest.Index -lt [int64]$State.LastIndex) {
        # Compositor index restarted. Don't subtract across the reset.
        $havePrev = $false
        $State.Remove('LastIndex')
        $State.Remove('LastTime')
    }

    $new = $ordered
    $indexSpan = [int64]$newest.Index - [int64]$oldest.Index
    $dt = [double]$newest.SystemTime - [double]$oldest.SystemTime
    if ($havePrev) {
        $prev = [int64]$State.LastIndex
        $new = @($ordered | Where-Object { [int64]$_.Index -gt $prev })
        $indexSpan = [int64]$newest.Index - $prev
        $dt = [double]$newest.SystemTime - [double]$State.LastTime
    }

    $State.LastIndex = [int64]$newest.Index
    $State.LastTime  = [double]$newest.SystemTime

    $fps = $null
    if ($dt -gt 0.001 -and $indexSpan -ge 0) { $fps = $indexSpan / $dt }

    $cumDelta = $null
    if ($Cumulative -and [int64]$Cumulative.Pid -gt 0 -and [int64]$Cumulative.Pid -ne [int64]$OurPid) {
        $sceneOk = ([int64]$ScenePid -le 0) -or ([int64]$Cumulative.Pid -eq [int64]$ScenePid)
        # Scene focus is the app we want. A zero focus (compositor showing
        # the dashboard) must not inherit the previous app's totals.
        if ([int64]$ScenePid -gt 0 -and $sceneOk) {
            if ($State.CumPid -and [int64]$State.CumPid -eq [int64]$Cumulative.Pid) {
                $dP = [int64]$Cumulative.Presents - [int64]$State.CumPresents
                $dD = [int64]$Cumulative.Dropped - [int64]$State.CumDropped
                $dR = [int64]$Cumulative.Reprojected - [int64]$State.CumReprojected
                if ($dP -ge 0 -and $dP -lt 100000 -and $dD -ge 0 -and $dR -ge 0) {
                    $cumDelta = @{ Presents = $dP; Dropped = $dD; Reprojected = $dR }
                }
            }
            $State.CumPid = [int64]$Cumulative.Pid
            $State.CumPresents = [int64]$Cumulative.Presents
            $State.CumDropped = [int64]$Cumulative.Dropped
            $State.CumReprojected = [int64]$Cumulative.Reprojected
        }
    }

    if ($new.Count -eq 0) {
        if ($null -ne $fps) { $row.vr_fps = (ConvertTo-SteamVrRound $fps 1) }
        $row.vr_frames = 0
        return $row
    }

    $sumInterval = 0.0; $intervalN = 0
    $sumApp = 0.0; $sumCompG = 0.0; $sumCompC = 0.0
    $sumTotal = 0.0; $sumIdle = 0.0; $sumSubmit = 0.0; $sumExtra = 0.0
    $sumTransfer = 0.0; $nTransfer = 0
    $maxInterval = $null; $maxApp = $null
    $reproj = 0; $cpuN = 0; $gpuN = 0; $motionN = 0; $throttleN = 0; $over = 0
    $misSum = 0; $dropSum = 0; $presentSum = 0
    $limit = 0.0
    if ($Hz -gt 1) { $limit = (1000.0 / $Hz) * 1.02 }

    foreach ($f in $new) {
        $flags = [int]$f.Flags
        $cpuR = ($flags -band $script:SteamVrFlagCpu) -ne 0
        $gpuR = ($flags -band $script:SteamVrFlagGpu) -ne 0
        $mot  = ($flags -band $script:SteamVrFlagMotion) -ne 0
        $extra = [int](($flags -band $script:SteamVrFlagPredict) / 16)
        $thr   = [int](($flags -band $script:SteamVrFlagThrottle) / 256)
        if ($cpuR) { $cpuN++ }
        if ($gpuR) { $gpuN++ }
        if ($mot)  { $motionN++ }
        if ($thr -gt 0) { $throttleN++ }
        if ([int]$f.Presents -gt 1 -or $cpuR -or $gpuR -or $mot) { $reproj++ }
        $misSum += [int]$f.Mis
        $dropSum += [int]$f.Dropped
        $presentSum += [int]$f.Presents
        $sumExtra += $extra
        # IntervalMs is 0 when the compositor is presenting but no scene
        # app is calling WaitGetPoses. That is "not measured", not a
        # 0 ms frame. Leave it out of the mean and the max.
        $iv = [double]$f.IntervalMs
        if ($iv -gt 0) {
            $sumInterval += $iv
            $intervalN++
            if ($null -eq $maxInterval -or $iv -gt $maxInterval) { $maxInterval = $iv }
        }
        $sumApp += [double]$f.AppGpuMs
        $sumCompG += [double]$f.CompGpuMs
        $sumCompC += [double]$f.CompCpuMs
        $sumTotal += [double]$f.TotalGpuMs
        $sumIdle += [double]$f.IdleCpuMs
        $sumSubmit += [double]$f.SubmitMs
        if ($null -ne $f.TransferMs) { $sumTransfer += [double]$f.TransferMs; $nTransfer++ }
        if ($null -eq $maxApp -or [double]$f.AppGpuMs -gt $maxApp) { $maxApp = [double]$f.AppGpuMs }
        if ($limit -gt 0) {
            if ([double]$f.IntervalMs -gt $limit -or [double]$f.AppGpuMs -gt $limit -or [double]$f.TotalGpuMs -gt $limit) {
                $over++
            }
        }
    }

    $n = [double]$new.Count
    $presented = $null
    if ($cumDelta -and $dt -gt 0.001) {
        $presented = $cumDelta.Presents / $dt
    } elseif ($null -ne $fps -and $n -gt 0) {
        $presented = ($presentSum / $n) * $fps
    }

    $dropped = $dropSum
    $reprojOut = $reproj
    if ($cumDelta) {
        if ($cumDelta.Dropped -ge $dropSum) { $dropped = [int]$cumDelta.Dropped }
        if ($cumDelta.Reprojected -ge $reproj) { $reprojOut = [int]$cumDelta.Reprojected }
    }

    if ($null -ne $fps) { $row.vr_fps = (ConvertTo-SteamVrRound $fps 1) }
    if ($null -ne $presented) { $row.vr_fps_presented = (ConvertTo-SteamVrRound $presented 1) }
    if ($intervalN -gt 0) {
        $row.vr_frametime_ms     = (ConvertTo-SteamVrRound ($sumInterval / $intervalN) 2)
        $row.vr_frametime_max_ms = (ConvertTo-SteamVrRound $maxInterval 2)
    }
    $row.vr_app_gpu_ms       = (ConvertTo-SteamVrRound ($sumApp / $n) 2)
    $row.vr_app_gpu_max_ms   = (ConvertTo-SteamVrRound $maxApp 2)
    $row.vr_comp_gpu_ms      = (ConvertTo-SteamVrRound ($sumCompG / $n) 2)
    $row.vr_comp_cpu_ms      = (ConvertTo-SteamVrRound ($sumCompC / $n) 2)
    $row.vr_gpu_ms           = (ConvertTo-SteamVrRound ($sumTotal / $n) 2)
    $row.vr_idle_cpu_ms      = (ConvertTo-SteamVrRound ($sumIdle / $n) 2)
    $row.vr_submit_ms        = (ConvertTo-SteamVrRound ($sumSubmit / $n) 2)
    if ($limit -gt 0) { $row.vr_over_budget = $over }
    $row.vr_reprojected   = $reprojOut
    $row.vr_reproj_cpu    = $cpuN
    $row.vr_reproj_gpu    = $gpuN
    $row.vr_motion        = $motionN
    $row.vr_dropped       = $dropped
    $row.vr_mispresented  = $misSum
    $row.vr_throttled     = $throttleN
    $row.vr_frames        = [int]$n
    $row.vr_predict_extra = (ConvertTo-SteamVrRound ($sumExtra / $n) 2)
    if ($nTransfer -gt 0) { $row.vr_transfer_ms = (ConvertTo-SteamVrRound ($sumTransfer / $nTransfer) 2) }
    if ($Hz -gt 1 -and $VsyncToPhotonsMs -ge 0) {
        $predict = (1.0 + ($sumExtra / $n)) * (1000.0 / $Hz) + $VsyncToPhotonsMs
        $row.vr_predict_ms = (ConvertTo-SteamVrRound $predict 2)
    }
    return $row
}

function Get-SteamVrNumber($Value) {
    if ($null -eq $Value) { return $null }
    $s = "$Value".Trim()
    if ($s -eq '') { return $null }
    $n = 0.0
    $styles = [Globalization.NumberStyles]::Float
    $culture = [Globalization.CultureInfo]::InvariantCulture
    if ([double]::TryParse($s, $styles, $culture, [ref]$n)) { return $n }
    return $null
}

function Get-SteamVrMedian([double[]]$Values) {
    $s = @($Values | Where-Object { $null -ne $_ } | Sort-Object)
    if ($s.Count -eq 0) { return $null }
    $mid = [int][math]::Floor($s.Count / 2)
    if ($s.Count % 2 -eq 1) { return [double]$s[$mid] }
    return ([double]$s[$mid - 1] + [double]$s[$mid]) / 2.0
}

function Get-SteamVrTraceReport {
    <#
        What Scan-Stutter-Events adds on top of a gap/fault scan.
        Reprojection is only an incident when it spikes against a
        quiet session. A race that motion-smooths every frame would
        otherwise flag every second.
    #>
    param($Rows)
    $rows = @($Rows)
    $lines = New-Object System.Collections.Generic.List[string]
    $inc = @{}
    $result = @{ HasColumns = $false; HadSamples = $false; Lines = @(); Incidents = $inc }
    if ($rows.Count -eq 0) { $result.Lines = @($lines); return $result }
    $names = @($rows[0].PSObject.Properties.Name)
    if ($names -notcontains 'vr_fps') {
        $lines.Add('=== STEAMVR FRAME TIMING ===')
        $lines.Add('This trace has no vr_* columns. It was recorded before kit 3.4.0.')
        $result.Lines = $lines.ToArray()
        return $result
    }
    $result.HasColumns = $true

    $fps = @(); $pres = @(); $ft = @(); $ftMax = @(); $gpu = @(); $gpuMax = @()
    $comp = @(); $total = @(); $reprojVals = @()
    $dropSum = 0.0; $misSum = 0.0; $overSum = 0.0; $motSum = 0.0; $reprojSum = 0.0
    $srcTally = @{}; $samples = 0
    $hmd = ''; $hz = ''; $tw = ''; $th = ''; $scale = ''; $scene = ''; $rend = ''
    foreach ($r in $rows) {
        $f = Get-SteamVrNumber $r.vr_fps
        if ($null -ne $f) { $fps += $f; $samples++ }
        $p = Get-SteamVrNumber $r.vr_fps_presented; if ($null -ne $p) { $pres += $p }
        $a = Get-SteamVrNumber $r.vr_frametime_ms; if ($null -ne $a) { $ft += $a }
        $b = Get-SteamVrNumber $r.vr_frametime_max_ms; if ($null -ne $b) { $ftMax += $b }
        $g = Get-SteamVrNumber $r.vr_app_gpu_ms; if ($null -ne $g) { $gpu += $g }
        $gx = Get-SteamVrNumber $r.vr_app_gpu_max_ms; if ($null -ne $gx) { $gpuMax += $gx }
        $c = Get-SteamVrNumber $r.vr_comp_gpu_ms; if ($null -ne $c) { $comp += $c }
        $t = Get-SteamVrNumber $r.vr_gpu_ms; if ($null -ne $t) { $total += $t }
        $rv = Get-SteamVrNumber $r.vr_reprojected; if ($null -ne $rv) { $reprojVals += $rv; $reprojSum += $rv }
        $d = Get-SteamVrNumber $r.vr_dropped; if ($null -ne $d) { $dropSum += $d }
        $m = Get-SteamVrNumber $r.vr_mispresented; if ($null -ne $m) { $misSum += $m }
        $o = Get-SteamVrNumber $r.vr_over_budget; if ($null -ne $o) { $overSum += $o }
        $mo = Get-SteamVrNumber $r.vr_motion; if ($null -ne $mo) { $motSum += $mo }
        $src = ("$($r.gpu_timing_source)").Trim()
        if ($src) {
            if (-not $srcTally.ContainsKey($src)) { $srcTally[$src] = 0 }
            $srcTally[$src]++
        }
        if (-not $hmd -and "$($r.vr_hmd)") { $hmd = "$($r.vr_hmd)".Trim() }
        if (-not $hz -and "$($r.vr_hz)") { $hz = "$($r.vr_hz)".Trim() }
        if (-not $tw -and "$($r.vr_target_w)") { $tw = "$($r.vr_target_w)".Trim() }
        if (-not $th -and "$($r.vr_target_h)") { $th = "$($r.vr_target_h)".Trim() }
        if (-not $scale -and "$($r.vr_res_scale)") { $scale = "$($r.vr_res_scale)".Trim() }
        if (-not $scene -and "$($r.vr_scene_app)") { $scene = "$($r.vr_scene_app)".Trim() }
        if (-not $rend -and "$($r.vr_renderer)") { $rend = "$($r.vr_renderer)".Trim() }
    }

    $lines.Add('=== STEAMVR FRAME TIMING ===')
    if ($samples -eq 0) {
        $lines.Add('Columns are present but every vr_fps cell is blank. SteamVR was not running, or the compositor had no frames yet. The logger does not start SteamVR.')
        $result.Lines = $lines.ToArray()
        return $result
    }
    $result.HadSamples = $true

    function Mean([double[]]$v) {
        $a = @($v)
        if ($a.Count -eq 0) { return $null }
        return ($a | Measure-Object -Average).Average
    }
    function Fmt($v, $digits) {
        if ($null -eq $v) { return '-' }
        return ([double]$v).ToString(('0.' + ('0' * $digits)).TrimEnd('.'), [Globalization.CultureInfo]::InvariantCulture)
    }

    $head = @()
    if ($hmd) { $head += $hmd }
    if ($hz) { $head += ($hz + ' Hz') }
    if ($tw -and $th) { $head += ("render target {0}x{1} per eye" -f $tw, $th) }
    if ($scale) { $head += ("scale {0}" -f $scale) }
    if ($head.Count) { $lines.Add('Headset : ' + ($head -join '   ')) }
    if ($scene -or $rend) {
        $lines.Add(('Scene   : {0}    renderer {1}' -f $(if ($scene) { $scene } else { '-' }), $(if ($rend) { $rend } else { '-' })))
    }
    if ($srcTally.Count) {
        $bits = @($srcTally.GetEnumerator() | Sort-Object Name | ForEach-Object { '{0} {1}' -f $_.Key, $_.Value })
        $lines.Add('gpu_fps source : ' + ($bits -join ', ') + ' row(s)')
    }
    $fpsM = Mean $fps; $presM = Mean $pres; $ftM = Mean $ft
    $ftPeak = $null; if ($ftMax.Count) { $ftPeak = ($ftMax | Measure-Object -Maximum).Maximum }
    $gpuM = Mean $gpu
    $gpuPeak = $null; if ($gpuMax.Count) { $gpuPeak = ($gpuMax | Measure-Object -Maximum).Maximum }
    $compM = Mean $comp; $totM = Mean $total
    $lines.Add(('App FPS mean {0} (presented {1})   frame interval mean {2} ms (worst second max {3})' -f `
        (Fmt $fpsM 1), (Fmt $presM 1), (Fmt $ftM 2), (Fmt $ftPeak 2)))
    $lines.Add(('App GPU mean {0} ms (worst second max {1})   compositor GPU mean {2} ms   total GPU mean {3} ms' -f `
        (Fmt $gpuM 2), (Fmt $gpuPeak 2), (Fmt $compM 2), (Fmt $totM 2)))
    $lines.Add(('Totals : over-budget {0}   dropped {1}   mispresented {2}   reprojected {3}   motion-smoothed {4}' -f `
        [int]$overSum, [int]$dropSum, [int]$misSum, [int]$reprojSum, [int]$motSum))
    $lines.Add('DROPPED = a second with a dropped frame. LATE = 5 or more frames over the refresh budget. REPROJ = a reprojection spike, and only when the session is not already reprojecting every frame. MISPRESENT = 5 or more mispresented frames.')

    $median = Get-SteamVrMedian $reprojVals
    $steady = ($null -ne $median -and $median -gt 1)
    foreach ($r in $rows) {
        $why = @()
        $d = Get-SteamVrNumber $r.vr_dropped
        if ($null -ne $d -and $d -ge 1) { $why += 'DROPPED' }
        $o = Get-SteamVrNumber $r.vr_over_budget
        if ($null -ne $o -and $o -ge 5) { $why += 'LATE' }
        $m = Get-SteamVrNumber $r.vr_mispresented
        if ($null -ne $m -and $m -ge 5) { $why += 'MISPRESENT' }
        $rp = Get-SteamVrNumber $r.vr_reprojected
        if (-not $steady -and $null -ne $rp -and $rp -ge 8) { $why += 'REPROJ' }
        if ($why.Count -and $r.timestamp) { $inc[$r.timestamp] = $why }
    }
    $result.Lines = $lines.ToArray()
    $result.Incidents = $inc
    return $result
}

function New-SteamVrBlankRow {
    $row = @{}
    foreach ($c in $script:SteamVrColumnNames) { $row[$c] = $null }
    return $row
}

function Get-SteamVrProcessName([int]$ProcId) {
    if ($ProcId -le 0) { return 'compositor' }
    $key = "$ProcId"
    if ($script:VrProcNames.ContainsKey($key)) { return $script:VrProcNames[$key] }
    $name = "$ProcId"
    try {
        $p = Get-Process -Id $ProcId -ErrorAction Stop
        if ($p.ProcessName) { $name = [string]$p.ProcessName }
    } catch { }
    $script:VrProcNames[$key] = $name
    return $name
}

function Find-SteamVrApiDll {
    $bit = if ([Environment]::Is64BitProcess) { 'win64' } else { 'win32' }
    $candidates = New-Object System.Collections.Generic.List[string]
    $vrpath = Join-Path $env:LOCALAPPDATA 'openvr\openvrpaths.vrpath'
    if ($vrpath -and (Test-Path -LiteralPath $vrpath)) {
        try {
            $raw = [System.IO.File]::ReadAllText($vrpath)
            if ($raw.Length -gt 0 -and [int][char]$raw[0] -eq 0xFEFF) { $raw = $raw.Substring(1) }
            $j = $raw | ConvertFrom-Json
            foreach ($r in @($j.runtime)) {
                if ($r) { $candidates.Add((Join-Path "$r" "bin\$bit\openvr_api.dll")) }
            }
        } catch { }
    }
    $steam = $null
    try {
        $steam = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction SilentlyContinue).InstallPath
    } catch { }
    if (-not $steam) {
        try { $steam = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath } catch { }
    }
    if ($steam) {
        $candidates.Add((Join-Path $steam "steamapps\common\SteamVR\bin\$bit\openvr_api.dll"))
    }
    $candidates.Add("C:\Program Files (x86)\Steam\steamapps\common\SteamVR\bin\$bit\openvr_api.dll")
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Initialize-SteamVrClient {
    if ('SteamVrClient' -as [type]) { return $true }
    $code = @'
using System;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;

public class SteamVrClient {
    // Background. Does not start SteamVR and does not submit frames.
    // Application type 1 is the scene app; it is intentionally not used.
    const int VRApplication_Background = 3;

    static bool _loaded;
    static bool _inited;
    static IntPtr _comp;
    public static string LastError = "";
    public static string CompositorVersion = "";

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr LoadLibrary(string path);

    [DllImport("openvr_api.dll", EntryPoint = "VR_InitInternal2", CallingConvention = CallingConvention.Cdecl)]
    static extern uint VR_InitInternal2(ref int peError, int appType, string startupInfo);

    [DllImport("openvr_api.dll", EntryPoint = "VR_InitInternal", CallingConvention = CallingConvention.Cdecl)]
    static extern uint VR_InitInternal(ref int peError, int appType);

    [DllImport("openvr_api.dll", EntryPoint = "VR_ShutdownInternal", CallingConvention = CallingConvention.Cdecl)]
    static extern void VR_ShutdownInternal();

    [DllImport("openvr_api.dll", EntryPoint = "VR_GetGenericInterface", CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr VR_GetGenericInterface(string version, ref int peError);

    [DllImport("openvr_api.dll", EntryPoint = "VR_GetVRInitErrorAsEnglishDescription", CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr VR_GetVRInitErrorAsEnglishDescription(int error);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate byte GetFrameTimingFn(IntPtr timing, uint framesAgo);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate uint GetFrameTimingsFn(IntPtr timing, uint frames);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate void GetCumFn(IntPtr stats, uint bytes);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate uint GetUintFn();
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate void GetSizeFn(ref uint width, ref uint height);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate float GetFloatPropFn(uint device, int prop, ref int error);
    [UnmanagedFunctionPointer(CallingConvention.StdCall, CharSet = CharSet.Ansi)]
    delegate uint GetStringPropFn(uint device, int prop, StringBuilder value, uint size, ref int error);
    [UnmanagedFunctionPointer(CallingConvention.StdCall, CharSet = CharSet.Ansi)]
    delegate int GetIntSettingFn(string section, string key, ref int error);
    [UnmanagedFunctionPointer(CallingConvention.StdCall, CharSet = CharSet.Ansi)]
    delegate float GetFloatSettingFn(string section, string key, ref int error);
    [UnmanagedFunctionPointer(CallingConvention.StdCall, CharSet = CharSet.Ansi)]
    delegate int GetAppKeyFn(uint pid, StringBuilder buf, uint len);

    static GetFrameTimingFn _frameTiming;
    static GetFrameTimingsFn _frameTimings;
    static GetCumFn _cum;
    static GetUintFn _scene;
    static GetUintFn _renderer;
    static GetSizeFn _size;
    static GetFloatPropFn _floatProp;
    static GetStringPropFn _stringProp;
    static GetIntSettingFn _getInt;
    static GetFloatSettingFn _getFloat;
    static GetAppKeyFn _appKey;
    static byte[] _cumBuf = new byte[128];

    static T Fn<T>(IntPtr table, int index) where T : class {
        IntPtr fp = Marshal.ReadIntPtr(table, index * IntPtr.Size);
        if (fp == IntPtr.Zero) return null;
        return (T)(object)Marshal.GetDelegateForFunctionPointer(fp, typeof(T));
    }

    static string Describe(int err) {
        try {
            IntPtr p = VR_GetVRInitErrorAsEnglishDescription(err);
            if (p == IntPtr.Zero) return "error " + err.ToString(CultureInfo.InvariantCulture);
            string s = Marshal.PtrToStringAnsi(p);
            if (string.IsNullOrEmpty(s)) return "error " + err.ToString(CultureInfo.InvariantCulture);
            return s + " (" + err.ToString(CultureInfo.InvariantCulture) + ")";
        } catch {
            return "error " + err.ToString(CultureInfo.InvariantCulture);
        }
    }

    static void ClearDelegates() {
        _frameTiming = null;
        _frameTimings = null;
        _cum = null;
        _scene = null;
        _renderer = null;
        _size = null;
        _floatProp = null;
        _stringProp = null;
        _getInt = null;
        _getFloat = null;
        _appKey = null;
        _comp = IntPtr.Zero;
        CompositorVersion = "";
    }

    public static void Disconnect() {
        ClearDelegates();
        if (_inited) {
            _inited = false;
            try { VR_ShutdownInternal(); } catch { }
        }
    }

    public static bool Connect(string dllPath) {
        LastError = "";
        if (_inited && _frameTimings != null) return true;
        if (!_loaded) {
            if (string.IsNullOrEmpty(dllPath) || !System.IO.File.Exists(dllPath)) {
                LastError = "openvr_api.dll not found";
                return false;
            }
            if (LoadLibrary(dllPath) == IntPtr.Zero) {
                LastError = "LoadLibrary failed (" + Marshal.GetLastWin32Error().ToString(CultureInfo.InvariantCulture) + ")";
                return false;
            }
            _loaded = true;
        }
        int err = 0;
        try {
            try {
                VR_InitInternal2(ref err, VRApplication_Background, "");
            } catch (EntryPointNotFoundException) {
                err = 0;
                VR_InitInternal(ref err, VRApplication_Background);
            }
        } catch (Exception ex) {
            LastError = ex.GetType().Name;
            return false;
        }
        if (err != 0) {
            LastError = Describe(err);
            try { VR_ShutdownInternal(); } catch { }
            return false;
        }
        _inited = true;
        if (!BindCompositor()) {
            if (string.IsNullOrEmpty(LastError)) LastError = "compositor interface not available";
            Disconnect();
            return false;
        }
        BindSystem();
        BindSettings();
        BindApps();
        return true;
    }

    // Indices verified against openvr.h for each interface version.
    // Unknown versions are not guessed: a wrong index would call the
    // wrong function.
    static bool BindCompositor() {
        string[] vers = new string[] { "IVRCompositor_029", "IVRCompositor_028", "IVRCompositor_027", "IVRCompositor_026" };
        int[] timing = new int[] { 10, 9, 8, 8 };
        int[] timings = new int[] { 11, 10, 9, 9 };
        int[] cum = new int[] { 13, 12, 11, 11 };
        int[] scene = new int[] { 24, 23, 22, 22 };
        int[] rend = new int[] { 25, 24, 23, 23 };
        for (int i = 0; i < vers.Length; i++) {
            int err = 0;
            IntPtr p = VR_GetGenericInterface("FnTable:" + vers[i], ref err);
            if (p == IntPtr.Zero || err != 0) continue;
            GetFrameTimingFn a = Fn<GetFrameTimingFn>(p, timing[i]);
            GetFrameTimingsFn b = Fn<GetFrameTimingsFn>(p, timings[i]);
            GetCumFn c = Fn<GetCumFn>(p, cum[i]);
            GetUintFn s = Fn<GetUintFn>(p, scene[i]);
            GetUintFn r = Fn<GetUintFn>(p, rend[i]);
            if (a == null || b == null || c == null || s == null || r == null) continue;
            _comp = p;
            _frameTiming = a;
            _frameTimings = b;
            _cum = c;
            _scene = s;
            _renderer = r;
            CompositorVersion = vers[i];
            return true;
        }
        LastError = "no supported IVRCompositor (tried 029..026)";
        return false;
    }

    static void BindSystem() {
        string[] vers = new string[] { "IVRSystem_026", "IVRSystem_023", "IVRSystem_022" };
        int[] floats = new int[] { 23, 22, 22 };
        int[] strs = new int[] { 28, 27, 27 };
        for (int i = 0; i < vers.Length; i++) {
            int err = 0;
            IntPtr p = VR_GetGenericInterface("FnTable:" + vers[i], ref err);
            if (p == IntPtr.Zero || err != 0) continue;
            _size = Fn<GetSizeFn>(p, 0);
            _floatProp = Fn<GetFloatPropFn>(p, floats[i]);
            _stringProp = Fn<GetStringPropFn>(p, strs[i]);
            return;
        }
    }

    static void BindSettings() {
        int err = 0;
        IntPtr p = VR_GetGenericInterface("FnTable:IVRSettings_003", ref err);
        if (p == IntPtr.Zero || err != 0) return;
        // IVRSettings_003: 5 is GetBool, 6 is GetInt32, 7 is GetFloat.
        _getInt = Fn<GetIntSettingFn>(p, 6);
        _getFloat = Fn<GetFloatSettingFn>(p, 7);
    }

    static void BindApps() {
        string[] vers = new string[] { "IVRApplications_008", "IVRApplications_007" };
        for (int i = 0; i < vers.Length; i++) {
            int err = 0;
            IntPtr p = VR_GetGenericInterface("FnTable:" + vers[i], ref err);
            if (p == IntPtr.Zero || err != 0) continue;
            _appKey = Fn<GetAppKeyFn>(p, 5);
            return;
        }
    }

    public static bool TryFrameTiming(byte[] buffer, int size) {
        if (_frameTiming == null || buffer == null || size < 4 || buffer.Length < size) return false;
        Array.Clear(buffer, 0, size);
        byte[] sz = BitConverter.GetBytes((uint)size);
        Buffer.BlockCopy(sz, 0, buffer, 0, 4);
        GCHandle h = GCHandle.Alloc(buffer, GCHandleType.Pinned);
        try {
            return _frameTiming(h.AddrOfPinnedObject(), 0) != 0;
        } finally { h.Free(); }
    }

    public static int ReadFrameTimings(byte[] buffer, int size, int maxFrames) {
        if (_frameTimings == null || buffer == null || size < 4 || maxFrames < 1) return -1;
        if (buffer.Length < size * maxFrames) return -1;
        Array.Clear(buffer, 0, size * maxFrames);
        byte[] sz = BitConverter.GetBytes((uint)size);
        Buffer.BlockCopy(sz, 0, buffer, 0, 4);
        GCHandle h = GCHandle.Alloc(buffer, GCHandleType.Pinned);
        try {
            uint n = _frameTimings(h.AddrOfPinnedObject(), (uint)maxFrames);
            if (n > (uint)maxFrames) n = (uint)maxFrames;
            return (int)n;
        } finally { h.Free(); }
    }

    public static byte[] ReadCumulative() {
        if (_cum == null) return null;
        Array.Clear(_cumBuf, 0, _cumBuf.Length);
        GCHandle h = GCHandle.Alloc(_cumBuf, GCHandleType.Pinned);
        try { _cum(h.AddrOfPinnedObject(), 112); }
        finally { h.Free(); }
        return _cumBuf;
    }

    public static int ScenePid() {
        if (_scene == null) return 0;
        uint v = _scene();
        if (v > int.MaxValue) return 0;
        return (int)v;
    }

    public static int RendererPid() {
        if (_renderer == null) return 0;
        uint v = _renderer();
        if (v > int.MaxValue) return 0;
        return (int)v;
    }

    public static string RenderSize() {
        if (_size == null) return "";
        uint w = 0, h = 0;
        _size(ref w, ref h);
        if (w == 0 || h == 0) return "";
        return w.ToString(CultureInfo.InvariantCulture) + "x" + h.ToString(CultureInfo.InvariantCulture);
    }

    public static string HmdFloat(int prop) {
        if (_floatProp == null) return "";
        int err = 0;
        float v = _floatProp(0, prop, ref err);
        if (err != 0 || float.IsNaN(v) || float.IsInfinity(v)) return "";
        return v.ToString("R", CultureInfo.InvariantCulture);
    }

    public static string HmdString(int prop) {
        if (_stringProp == null) return "";
        StringBuilder sb = new StringBuilder(256);
        int err = 0;
        _stringProp(0, prop, sb, (uint)sb.Capacity, ref err);
        if (err != 0) return "";
        return sb.ToString();
    }

    public static string AppKey(int pid) {
        if (_appKey == null || pid <= 0) return "";
        StringBuilder sb = new StringBuilder(256);
        int err = _appKey((uint)pid, sb, (uint)sb.Capacity);
        if (err != 0) return "";
        return sb.ToString();
    }

    public static string ReadSettingNumber(string section, string key) {
        if (string.IsNullOrEmpty(section) || string.IsNullOrEmpty(key)) return "";
        int err = 0;
        if (_getInt != null) {
            int iv = _getInt(section, key, ref err);
            if (err == 0) return iv.ToString(CultureInfo.InvariantCulture);
        }
        if (_getFloat == null) return "";
        err = 0;
        float fv = _getFloat(section, key, ref err);
        if (err != 0 || float.IsNaN(fv) || float.IsInfinity(fv)) return "";
        return fv.ToString("R", CultureInfo.InvariantCulture);
    }
}
'@
    try {
        Add-Type -TypeDefinition $code -Language CSharp -ErrorAction Stop
        return $true
    } catch {
        $script:VrLastError = "OpenVR interop did not compile: $($_.Exception.Message)"
        $script:VrStatus = 'init-failed'
        return $false
    }
}

function Update-SteamVrStatic {
    if (-not $script:VrConnected) { return }
    if (-not ('SteamVrClient' -as [type])) { return }
    $hz = 0.0
    $photons = -1.0
    try {
        $hzText = [SteamVrClient]::HmdFloat(2002) # Prop_DisplayFrequency_Float
        if ($hzText) {
            $parsed = 0.0
            if ([double]::TryParse($hzText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and $parsed -gt 1 -and $parsed -lt 1000) {
                $hz = $parsed
            }
        }
        $phText = [SteamVrClient]::HmdFloat(2001) # Prop_SecondsFromVsyncToPhotons_Float
        if ($phText) {
            $parsedP = 0.0
            if ([double]::TryParse($phText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsedP) -and $parsedP -ge 0 -and $parsedP -lt 0.1) {
                $photons = $parsedP * 1000.0
            }
        }
        $model = [SteamVrClient]::HmdString(1001) # Prop_ModelNumber_String
        if ($model) { $script:VrStatic.Hmd = $model }
        $size = [SteamVrClient]::RenderSize()
        if ($size -match '^(\d+)x(\d+)$') {
            $script:VrStatic.TargetW = [int]$Matches[1]
            $script:VrStatic.TargetH = [int]$Matches[2]
        }
    } catch { }
    if ($hz -gt 1) { $script:VrStatic.Hz = $hz }
    if ($photons -ge 0) { $script:VrStatic.PhotonsMs = $photons }

    $scenePid = 0
    try { $scenePid = [int][SteamVrClient]::ScenePid() } catch { $scenePid = 0 }
    $appOk = $false; $appVal = $null; $globOk = $false; $globVal = $null
    try {
        if ($scenePid -gt 0) {
            $key = [SteamVrClient]::AppKey($scenePid)
            if ($key) {
                $txt = [SteamVrClient]::ReadSettingNumber($key, 'resolutionScale')
                if ($txt) { $appOk = $true; $appVal = $txt }
            }
        }
        $g = [SteamVrClient]::ReadSettingNumber('steamvr', 'supersampleScale')
        if ($g) { $globOk = $true; $globVal = $g }
    } catch { }
    $scale = Resolve-SteamVrResScale -AppValue $appVal -AppOk $appOk -GlobalValue $globVal -GlobalOk $globOk
    if ($null -ne $scale) { $script:VrStatic.ResScale = $scale }

    $bits = @()
    try {
        if ([SteamVrClient]::CompositorVersion) { $bits += [SteamVrClient]::CompositorVersion }
    } catch { }
    if ($script:VrStatic.Hz -gt 1) {
        $bits += ($script:VrStatic.Hz.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture) + ' Hz')
    }
    if ($script:VrStatic.Hmd) { $bits += $script:VrStatic.Hmd }
    if ($bits.Count) { $script:VrDetail = $bits -join ', ' }
}

function Update-SteamVrConnection {
    if ($script:SteamVrDisabled) {
        $script:VrStatus = 'disabled'
        $script:VrConnected = $false
        return $false
    }
    if ($script:VrConnected) { return $true }

    $names = @(Get-SteamVrRunningProcessNames)
    if (-not (Test-SteamVrShouldConnect -ProcessNames $names)) {
        $script:VrStatus = 'not-running'
        $script:VrDetail = ''
        return $false
    }

    # Past here we are allowed to touch OpenVR. The process check above
    # is the guarantee that we do not start SteamVR ourselves.
    $script:SteamVrInitAttempts++
    $dll = Find-SteamVrApiDll
    if (-not $dll) {
        $script:VrStatus = 'no-dll'
        $script:VrLastError = 'SteamVR is running but openvr_api.dll was not found'
        return $false
    }
    if (-not (Initialize-SteamVrClient)) { return $false }
    $ok = $false
    try { $ok = [SteamVrClient]::Connect($dll) } catch {
        $script:VrLastError = $_.Exception.Message
        $script:VrStatus = 'init-failed'
        return $false
    }
    if (-not $ok) {
        $script:VrStatus = 'init-failed'
        try { $script:VrLastError = [string][SteamVrClient]::LastError } catch { }
        return $false
    }
    $script:VrConnected = $true
    $script:VrStatus = 'connected'
    try { $script:VrDetail = [string][SteamVrClient]::CompositorVersion } catch { }
    return $true
}

function Find-SteamVrStructSize {
    foreach ($sz in @(192, 184)) {
        $buf = New-Object byte[] $sz
        $ok = $false
        try { $ok = [SteamVrClient]::TryFrameTiming($buf, $sz) } catch { $ok = $false }
        if (-not $ok) { continue }
        # Direct assignment. @() nests the unary-comma return, so Count
        # is 1 and [0] is the frame array rather than the frame.
        $parsed = ConvertFrom-SteamVrTimingBuffer -Buffer $buf -Size $sz -Count 1
        if ($parsed.Count -eq 1 -and (Test-SteamVrFramePlausible $parsed[0])) { return $sz }
    }
    return 0
}

function Disconnect-SteamVrTiming {
    if ('SteamVrClient' -as [type]) {
        try { [SteamVrClient]::Disconnect() } catch { }
    }
    $script:VrConnected = $false
    $script:VrState = @{ StructSize = 0 }
    $script:VrStatic = @{ Hz = 0; PhotonsMs = -1; Hmd = ''; TargetW = $null; TargetH = $null; ResScale = $null }
    $script:VrProcNames = @{}
}

function Get-SteamVrSample {
    <#
        One logger tick. Returns a hashtable keyed by column name.
        Never throws. Never calls into OpenVR unless SteamVR is already running.
    #>
    if ($script:SteamVrDisabled) { return (New-SteamVrBlankRow) }
    if (-not $script:VrConnected) {
        if ($script:VrBackoff -gt 0) {
            $script:VrBackoff--
            return (New-SteamVrBlankRow)
        }
        if (-not (Update-SteamVrConnection)) {
            $script:VrBackoff = 4
            return (New-SteamVrBlankRow)
        }
        try { Update-SteamVrStatic } catch { }
    }

    $frames = @()
    $cum = $null
    $size = 0
    if ($script:VrState.StructSize) { $size = [int]$script:VrState.StructSize }
    if (-not $size) {
        try { $size = [int](Find-SteamVrStructSize) } catch { $size = 0 }
        if ($size) { $script:VrState.StructSize = $size }
    }
    if ($size) {
        $buf = New-Object byte[] ($size * 128)
        $n = -1
        try { $n = [int][SteamVrClient]::ReadFrameTimings($buf, $size, 128) } catch { $n = -1 }
        if ($n -lt 0) {
            Disconnect-SteamVrTiming
            $script:VrStatus = 'read-failed'
            $script:VrLastError = 'GetFrameTimings failed; VR columns cleared until SteamVR answers again'
            $script:VrBackoff = 4
            return (New-SteamVrBlankRow)
        }
        if ($n -gt 0) {
            # Same rule as Find-SteamVrStructSize: do not wrap this call
            # in @(). A live 128-frame read came back as Count 1 and the
            # timing columns stayed blank on every tick.
            $parsed = ConvertFrom-SteamVrTimingBuffer -Buffer $buf -Size $size -Count $n
            $good = @($parsed | Where-Object { Test-SteamVrFramePlausible $_ })
            $need = [int][math]::Ceiling($n / 2.0)
            if ($good.Count -lt $need) {
                $script:VrState.StructSize = 0
            } else {
                $frames = $good
            }
        }
        try {
            $cumBuf = [SteamVrClient]::ReadCumulative()
            $cum = ConvertFrom-SteamVrCumulative $cumBuf
        } catch { $cum = $null }
    }

    $script:VrTicks++
    if (($script:VrTicks % 10) -eq 1) {
        try { Update-SteamVrStatic } catch { }
    }

    $scenePid = 0
    $rendPid = 0
    try {
        $scenePid = [int][SteamVrClient]::ScenePid()
        $rendPid = [int][SteamVrClient]::RendererPid()
    } catch { }
    $sceneApp = ''
    if ($scenePid -gt 0) { $sceneApp = Get-SteamVrProcessName $scenePid }
    $renderer = Get-SteamVrProcessName $rendPid

    $our = 0
    try { $our = [int][System.Diagnostics.Process]::GetCurrentProcess().Id } catch { $our = 0 }

    return Get-SteamVrFrameAggregates -Frames $frames -State $script:VrState `
        -Hz ([double]$script:VrStatic.Hz) -VsyncToPhotonsMs ([double]$script:VrStatic.PhotonsMs) `
        -SceneApp $sceneApp -ScenePid $scenePid -Renderer $renderer -Hmd $script:VrStatic.Hmd `
        -TargetW $script:VrStatic.TargetW -TargetH $script:VrStatic.TargetH -ResScale $script:VrStatic.ResScale `
        -Cumulative $cum -OurPid $our
}
