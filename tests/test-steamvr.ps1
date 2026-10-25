<#
    test-steamvr.ps1
    ---------------------------------------------------------------
    Offline checks for the SteamVR timing reader. Nothing here talks
    to a headset or loads openvr_api.dll. The byte layout is the
    Windows x64 Compositor_FrameTiming (192 bytes with transfer
    latency, 184 without), which is what FullTrace decodes.
#>

$ErrorActionPreference = 'Stop'
$fails = 0
function Assert($cond, $msg) {
    if ($cond) { "    ok   $msg" }
    else       { "    FAIL $msg"; $script:fails++ }
}

$mod = Join-Path $PSScriptRoot '..\scripts\SteamVR-Timing.ps1'
$tracer = Join-Path $PSScriptRoot '..\scripts\FullTrace.ps1'
if (-not (Test-Path $mod)) { "FAIL: $mod missing"; exit 1 }
. $mod
"OK: SteamVR-Timing loaded"

# ---- column contract ------------------------------------------------
$names = Get-SteamVrColumnNames
Assert ($names -is [System.Array] -and $names[0] -is [string]) "column list is one string array"
Assert (@($names).Count -eq 33) "33 VR/timing columns ($((@($names)).Count))"
$uniq = @($names | Select-Object -Unique)
Assert ($uniq.Count -eq 33) "column names are unique"
Assert ((Get-SteamVrTextColumns) -contains 'vr_scene_app') "scene app is a text column"

$src = Get-Content $tracer -Raw
$hm = [regex]::Match($src, "(?m)^\`$CsvHeader = '(timestamp,power_plan,[^']+)'")
Assert $hm.Success "FullTrace header literal found"
$header = $hm.Groups[1].Value -split ','
Assert ($header[38] -eq 'fb_usage_pct') "original 39th column is still fb_usage_pct"
Assert (($header | Select-Object -Skip 39) -join ',' -eq ($names -join ',')) "header tail matches Get-SteamVrColumnNames in order"

# ---- byte layout ----------------------------------------------------
function Write-U32([byte[]]$buf, [int]$off, [uint32]$v) { [BitConverter]::GetBytes($v).CopyTo($buf, $off) }
function Write-F32([byte[]]$buf, [int]$off, [single]$v) { [BitConverter]::GetBytes($v).CopyTo($buf, $off) }
function Write-F64([byte[]]$buf, [int]$off, [double]$v) { [BitConverter]::GetBytes($v).CopyTo($buf, $off) }

function New-TimingBuffer {
    param([object[]]$Frames, [int]$Size = 192)
    $buf = New-Object byte[] ($Size * $Frames.Count)
    for ($i = 0; $i -lt $Frames.Count; $i++) {
        $f = $Frames[$i]
        $b = $i * $Size
        Write-U32 $buf ($b + 0)  ([uint32]$Size)
        Write-U32 $buf ($b + 4)  ([uint32]$f.Index)
        Write-U32 $buf ($b + 8)  ([uint32]$f.Presents)
        Write-U32 $buf ($b + 12) ([uint32]$f.Mis)
        Write-U32 $buf ($b + 16) ([uint32]$f.Dropped)
        Write-U32 $buf ($b + 20) ([uint32]$f.Flags)
        Write-F64 $buf ($b + 24) ([double]$f.Time)
        Write-F32 $buf ($b + 32) ([single]$f.AppGpu)
        Write-F32 $buf ($b + 36) ([single]0)
        Write-F32 $buf ($b + 40) ([single]$f.TotalGpu)
        Write-F32 $buf ($b + 44) ([single]$f.CompGpu)
        Write-F32 $buf ($b + 48) ([single]$f.CompCpu)
        Write-F32 $buf ($b + 52) ([single]0.5)
        Write-F32 $buf ($b + 56) ([single]$f.Interval)
        Write-F32 $buf ($b + 60) ([single]0)
        Write-F32 $buf ($b + 64) ([single]0)
        Write-F32 $buf ($b + 68) ([single]$f.Submit)
        if ($Size -ge 184) { Write-U32 $buf ($b + 180) ([uint32]$f.VSyncs) }
        if ($Size -ge 188) { Write-F32 $buf ($b + 184) ([single]$f.Transfer) }
    }
    return ,$buf
}

$spec = @(
    [pscustomobject]@{ Index = 1000; Presents = 1; Mis = 2; Dropped = 3; Flags = 0x20; Time = 1000.5; AppGpu = 8.25; TotalGpu = 9.5; CompGpu = 1.25; CompCpu = 0.5; Interval = 11.11; Submit = 0.2; VSyncs = 4; Transfer = 1.5 }
    [pscustomobject]@{ Index = 1001; Presents = 2; Mis = 0; Dropped = 1; Flags = 0x02; Time = 1000.511; AppGpu = 9.5; TotalGpu = 10; CompGpu = 1; CompCpu = 0.4; Interval = 11.11; Submit = 0.3; VSyncs = 7; Transfer = 0.25 }
)
$parsed = ConvertFrom-SteamVrTimingBuffer -Buffer (New-TimingBuffer $spec 192) -Size 192 -Count 2
Assert ($parsed -is [System.Array] -and $parsed.Count -eq 2) "two frames decoded from a 192-byte stride"
Assert ($parsed[0].Index -eq 1000 -and $parsed[1].Index -eq 1001) "frame index sits at offset 4, second frame at 192"
Assert ($parsed[0].Presents -eq 1 -and $parsed[0].Mis -eq 2 -and $parsed[0].Dropped -eq 3) "presents / mispresented / dropped offsets"
Assert ($parsed[0].Flags -eq 0x20 -and [math]::Abs($parsed[0].SystemTime - 1000.5) -lt 0.0001) "flags and system-time double"
Assert ([math]::Abs($parsed[0].AppGpuMs - 8.25) -lt 0.001) "app GPU float at offset 32"
Assert ($parsed[1].VSyncsToView -eq 7) "vsync count at offset 180"
Assert ([math]::Abs($parsed[1].TransferMs - 0.25) -lt 0.001) "transfer latency at offset 184"

$old = ConvertFrom-SteamVrTimingBuffer -Buffer (New-TimingBuffer @($spec[0]) 184) -Size 184 -Count 1
Assert ($old.Count -eq 1 -and $null -eq $old[0].TransferMs -and $old[0].VSyncsToView -eq 4) "184-byte struct has vsyncs and no transfer field"
$none = ConvertFrom-SteamVrTimingBuffer -Buffer (New-Object byte[] 0) -Size 192 -Count 0
Assert ($null -ne $none -and $none -is [System.Array] -and $none.Count -eq 0) "empty buffer stays an empty array"

$bad = $parsed[0].PSObject.Copy()
$bad.SystemTime = 0
Assert (-not (Test-SteamVrFramePlausible $bad)) "system time 0 is implausible"
Assert (Test-SteamVrFramePlausible $parsed[0]) "a normal frame is plausible"
$wild = $parsed[0].PSObject.Copy()
$wild.IntervalMs = 400
Assert (-not (Test-SteamVrFramePlausible $wild)) "a 400 ms interval is implausible"

# ---- aggregator -----------------------------------------------------
function New-Frames([int64]$Start, [int]$Count, [double]$Hz, [double]$Interval, [int]$Flags = 0, [int]$Presents = 1, [int]$Dropped = 0, [double]$AppGpu = 8, [double]$TotalGpu = 9) {
    $list = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Count; $i++) {
        $idx = $Start + $i
        $list.Add([pscustomobject]@{
            Index = $idx; Presents = $Presents; Mis = 0; Dropped = $Dropped; Flags = $Flags
            SystemTime = $idx / $Hz
            AppGpuMs = $AppGpu; PostGpuMs = 0; TotalGpuMs = $TotalGpu
            CompGpuMs = 1.0; CompCpuMs = 0.4; IdleCpuMs = 0.5
            IntervalMs = $Interval; PresentCpuMs = 0; WaitPresentMs = 0; SubmitMs = 0.1
            VSyncsToView = 1; TransferMs = 0.4
        })
    }
    return ,$list.ToArray()
}

$state = @{}
$ninety = Get-SteamVrFrameAggregates -Frames (New-Frames 1000 90 90 (1000.0/90)) -State $state -Hz 90 -VsyncToPhotonsMs 2 -SceneApp 'iRacingSim64DX11' -ScenePid 4242 -Renderer 'iRacingSim64DX11' -Hmd 'Pimax Crystal' -TargetW 2468 -TargetH 2716 -ResScale 1.4
$span = 89
$dt = (1089 / 90.0) - (1000 / 90.0)
Assert ($ninety.vr_fps -eq [math]::Round($span / $dt, 1)) "90 Hz series reports index-delta fps ($($ninety.vr_fps))"
Assert ($ninety.vr_fps -eq 90) "that fps rounds to 90"
Assert ($ninety.vr_frames -eq 90) "all 90 frames were new"
Assert ($ninety.vr_over_budget -eq 0) "on-budget 90 Hz frames are not late (limit is 1.02x refresh)"
Assert ($ninety.vr_hz -eq 90) "refresh stored in Hz"
Assert ($ninety.vr_target_w -eq 2468 -and $ninety.vr_target_h -eq 2716) "render target is pixels per eye"
Assert ($ninety.vr_res_scale -eq 1.4) "resolution scale kept"
Assert ($ninety.vr_predict_ms -eq 13.11) "prediction is one frame plus vsync-to-photons ($($ninety.vr_predict_ms))"
Assert ($ninety.vr_scene_app -eq 'iRacingSim64DX11' -and $ninety.vr_scene_pid -eq 4242) "scene app and pid"
Assert ($null -eq $ninety.gpu_timing_source) "aggregator leaves the source column for FullTrace"

$lateFrames = New-Frames 2000 10 90 (1000.0/90)
$lateFrames[3].IntervalMs = 20
$late = Get-SteamVrFrameAggregates -Frames $lateFrames -State @{} -Hz 90 -VsyncToPhotonsMs -1
Assert ($late.vr_over_budget -eq 1) "one 20 ms interval is over the 90 Hz budget"
Assert ($null -eq $late.vr_predict_ms) "prediction stays blank without vsync-to-photons"

$noHz = Get-SteamVrFrameAggregates -Frames (New-Frames 1 5 90 20) -State @{} -Hz 0 -VsyncToPhotonsMs 2
Assert ($null -eq $noHz.vr_over_budget) "unknown refresh leaves vr_over_budget blank, not zero"

# second poll overlaps the history; fps stays on the index delta
$overlap = @{}
$overlap.LastIndex = [int64]9
$overlap.LastTime = 0.9
$second = Get-SteamVrFrameAggregates -Frames (New-Frames 5 10 10 100) -State $overlap -Hz 10
Assert ($second.vr_fps -eq 10) "overlapping poll still reports 10 fps ($($second.vr_fps))"
Assert ($second.vr_frames -eq 5) "only frames newer than the previous index are averaged"

$missed = @{ LastIndex = [int64]1000; LastTime = 10.0 }
$missedRow = Get-SteamVrFrameAggregates -Frames (New-Frames 1100 128 100 10) -State $missed -Hz 100
$missDt = (1227 / 100.0) - 10.0
Assert ($missedRow.vr_fps -eq [math]::Round(227 / $missDt, 1)) "frames that fell out of the 128 buffer still count in fps ($($missedRow.vr_fps))"
Assert ($missedRow.vr_frames -eq 128) "vr_frames is only the sampled count"

$reset = @{ LastIndex = [int64]500; LastTime = 50.0 }
$resetRow = Get-SteamVrFrameAggregates -Frames (New-Frames 1 2 10 100) -State $reset -Hz 10
Assert ($resetRow.vr_fps -eq 10 -and $reset.LastIndex -eq 2) "an index restart does not subtract across the old baseline"

function Assert-Flags($flags, $presents, $reproj, $cpu, $gpu, $motion, $throttled, $extra, $label) {
    $row = Get-SteamVrFrameAggregates -Frames (New-Frames 10 2 90 (1000.0/90) $flags $presents) -State @{} -Hz 90 -VsyncToPhotonsMs 2
    Assert ($row.vr_reprojected -eq $reproj -and $row.vr_reproj_cpu -eq $cpu -and $row.vr_reproj_gpu -eq $gpu -and $row.vr_motion -eq $motion -and $row.vr_throttled -eq $throttled -and $row.vr_predict_extra -eq $extra) $label
}
Assert-Flags 0x04 1 0 0 0 0 0 0 "async-mode flag alone is not a reprojection"
Assert-Flags 0x08 1 2 0 0 2 0 0 "motion-smoothing flag counts as motion and reprojection"
Assert-Flags 0x02 1 2 0 2 0 0 0 "GPU reprojection flag"
Assert-Flags 0x01 1 2 2 0 0 0 0 "CPU reprojection flag"
Assert-Flags 0x00 2 2 0 0 0 0 0 "presented more than once is a reprojection"
Assert-Flags 0x100 1 0 0 0 0 2 0 "0x100 is the throttle field, not motion smoothing"
Assert-Flags 0x20 1 0 0 0 0 0 2 "prediction mask 0x20 is two extra frames"
$extraRow = Get-SteamVrFrameAggregates -Frames (New-Frames 10 2 90 (1000.0/90) 0x20) -State @{} -Hz 90 -VsyncToPhotonsMs 2
Assert ($extraRow.vr_predict_ms -eq 35.33) "two extra predicted frames at 90 Hz plus 2 ms ($($extraRow.vr_predict_ms))"

# cumulative stats: first sample only baselines; later deltas apply when
# the pid is the scene app and not this process.
function New-Cum([uint32]$procId, [uint32]$presents, [uint32]$dropped, [uint32]$reproj) {
    $b = New-Object byte[] 16
    Write-U32 $b 0 $procId
    Write-U32 $b 4 $presents
    Write-U32 $b 8 $dropped
    Write-U32 $b 12 $reproj
    return ConvertFrom-SteamVrCumulative $b
}
$cumState = @{}
$base = Get-SteamVrFrameAggregates -Frames (New-Frames 0 10 10 100) -State $cumState -Hz 10 -ScenePid 100 -Cumulative (New-Cum 100 5000 40 20) -OurPid 7
Assert ($base.vr_dropped -eq 0 -and $base.vr_reprojected -eq 0) "first cumulative sample is a baseline, not a delta"
Assert ($cumState.CumPid -eq 100 -and $cumState.CumDropped -eq 40) "baseline is stored"
$delta = Get-SteamVrFrameAggregates -Frames (New-Frames 10 10 10 100) -State $cumState -Hz 10 -ScenePid 100 -Cumulative (New-Cum 100 5090 41 25) -OurPid 7
Assert ($delta.vr_dropped -eq 1 -and $delta.vr_reprojected -eq 5) "later cumulative delta wins when it covers more than the buffer"
Assert ($delta.vr_fps_presented -eq 90) "presented fps uses the present delta (90 in one second)"

$ours = @{}
$ignored = Get-SteamVrFrameAggregates -Frames (New-Frames 0 4 10 100) -State $ours -Hz 10 -ScenePid 7 -Cumulative (New-Cum 7 100 9 9) -OurPid 7
Assert ($ignored.vr_dropped -eq 0 -and -not $ours.ContainsKey('CumPid')) "cumulative stats for our own pid are ignored"

$other = @{}
Get-SteamVrFrameAggregates -Frames (New-Frames 0 4 10 100) -State $other -Hz 10 -ScenePid 200 -Cumulative (New-Cum 100 10 3 3) -OurPid 7 | Out-Null
Assert (-not $other.ContainsKey('CumPid')) "a cumulative pid that is not the scene app is not baselined"

# a per-frame drop larger than the cumulative delta stays
$prefer = @{ CumPid = 100; CumPresents = 10; CumDropped = 0; CumReprojected = 0; LastIndex = [int64]0; LastTime = 0.0 }
$frameDrop = New-Frames 1 4 10 100 0 1 2
$kept = Get-SteamVrFrameAggregates -Frames $frameDrop -State $prefer -Hz 10 -ScenePid 100 -Cumulative (New-Cum 100 14 1 0) -OurPid 7
Assert ($kept.vr_dropped -eq 8) "per-frame dropped count is kept when it is larger than the cumulative delta ($($kept.vr_dropped))"

# ---- source and scale ----------------------------------------------
$ab = Resolve-GpuTimingSource 120 8.3 $null $null
Assert ($ab.Source -eq 'afterburner' -and $ab.Fps -eq 120 -and $ab.Frametime -eq 8.3) "Afterburner wins when it has both"
$vr = Resolve-GpuTimingSource '' '' 90 11.11
Assert ($vr.Source -eq 'steamvr' -and $vr.Fps -eq 90 -and $vr.Frametime -eq 11.11) "SteamVR fills both when Afterburner is blank"
$mix = Resolve-GpuTimingSource 144 '' '' 6.94
Assert ($mix.Source -eq 'afterburner+steamvr' -and $mix.Fps -eq 144 -and $mix.Frametime -eq 6.94) "mixed source keeps each side that was present"
$noneSrc = Resolve-GpuTimingSource $null $null $null $null
Assert ($noneSrc.Source -eq '' -and $null -eq $noneSrc.Fps) "neither source leaves the cells blank"

Assert ([math]::Abs((Resolve-SteamVrResScale 140 $true $null $false) - 1.4) -lt 0.0001) "140 percent becomes 1.4"
Assert ((Resolve-SteamVrResScale 1.5 $true $null $false) -eq 1.5) "1.5 stays a multiplier"
Assert ((Resolve-SteamVrResScale 100 $true 1.2 $true) -eq 1.0) "per-app 100 percent beats the global scale"
Assert ((Resolve-SteamVrResScale 0 $true 1.2 $true) -eq 1.2) "unset per-app value falls through to the global multiplier"
Assert ($null -eq (Resolve-SteamVrResScale 0 $false $null $false)) "both unset stays blank"
Assert ($null -eq (Resolve-SteamVrResScale 900 $true $null $false)) "a value above 500 is ignored"
Assert ($null -eq (Resolve-SteamVrResScale '1,5' $true $null $false)) "a comma decimal is not a scale"

# ---- process guard --------------------------------------------------
Assert (-not (Test-SteamVrShouldConnect @())) "no processes means do not connect"
Assert (-not (Test-SteamVrShouldConnect @('vrmonitor','steam'))) "vrmonitor alone is not enough"
Assert (Test-SteamVrShouldConnect @('vrserver')) "vrserver allows a connect"
Assert (Test-SteamVrShouldConnect @('VRCompositor')) "vrcompositor allows a connect, any case"
Assert (Test-SteamVrShouldConnect @('C:\Program Files (x86)\Steam\steamapps\common\SteamVR\bin\win64\vrserver.exe')) "a full vrserver path counts"

$running = @(Get-SteamVrRunningProcessNames)
Assert ($running.Count -eq 0) "this environment is not running SteamVR ($($running -join ','))"
$before = $script:SteamVrInitAttempts
Get-SteamVrSample | Out-Null
Assert ($script:SteamVrInitAttempts -eq $before) "Get-SteamVrSample does not init when SteamVR is absent"
Assert ($null -eq ('SteamVrClient' -as [type])) "openvr interop is not compiled until a connect is allowed"
Assert ($script:VrStatus -eq 'not-running') "status stays not-running"

# ---- incidents ------------------------------------------------------
function New-TraceRow($ts, $reproj, $drop, $over, $mis) {
    [pscustomobject]@{
        timestamp = $ts; vr_fps = '90'; vr_reprojected = "$reproj"; vr_dropped = "$drop"
        vr_over_budget = "$over"; vr_mispresented = "$mis"; vr_motion = '0'
        gpu_timing_source = 'steamvr'; vr_hmd = 'Pimax'; vr_hz = '90'
    }
}
$spike = Get-SteamVrTraceReport -Rows @(
    (New-TraceRow '00:00:01' 0 0 0 0)
    (New-TraceRow '00:00:02' 20 0 0 0)
    (New-TraceRow '00:00:03' 0 0 0 0)
)
Assert ($spike.HasColumns -and $spike.Incidents['00:00:02'] -contains 'REPROJ') "one reprojection spike is an incident"
$steady = Get-SteamVrTraceReport -Rows @(
    (New-TraceRow '00:00:01' 40 0 0 0)
    (New-TraceRow '00:00:02' 40 0 0 0)
    (New-TraceRow '00:00:03' 40 0 0 0)
)
Assert ($steady.Incidents.Count -eq 0) "steady reprojection is not a spike"
$bits = Get-SteamVrTraceReport -Rows @(
    (New-TraceRow '00:00:01' 0 1 4 0)
    (New-TraceRow '00:00:02' 0 0 5 5)
)
Assert ($bits.Incidents['00:00:01'] -contains 'DROPPED') "one dropped frame is DROPPED"
Assert ($bits.Incidents['00:00:01'] -notcontains 'LATE') "four over-budget frames are not LATE"
Assert ($bits.Incidents['00:00:02'] -contains 'LATE' -and $bits.Incidents['00:00:02'] -contains 'MISPRESENT') "five late and five mispresented"
$oldCsv = Get-SteamVrTraceReport -Rows @([pscustomobject]@{ timestamp = '00:00:01'; gpu_fps = '90' })
Assert (-not $oldCsv.HasColumns) "a pre-3.4.0 CSV has no VR columns"
Assert (($oldCsv.Lines -join ' ') -match 'before kit 3.4.0') "the report says so"

# ---- CSV round trip under a comma locale ---------------------------
$culture = [System.Threading.Thread]::CurrentThread.CurrentCulture
try {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new('nb-NO')
    $row = Get-SteamVrFrameAggregates -Frames (New-Frames 1000 90 90 (1000.0/90)) -State @{} -Hz 90 -VsyncToPhotonsMs 2 -SceneApp 'steamvr, test' -ScenePid 9 -Hmd 'Pimax, Crystal' -ResScale 1.25
    $row.gpu_timing_source = 'steamvr'
    $text = @('gpu_timing_source','vr_scene_app','vr_renderer','vr_hmd')
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $cells = foreach ($n in $names) {
        $v = $row[$n]
        if ($text -contains $n) {
            if ($null -eq $v -or "$v" -eq '') { '' }
            else { '"' + ("$v" -replace '"','""') + '"' }
        } elseif ($null -eq $v -or "$v" -eq '') { '' }
        else { ([double]$v).ToString('0.###', $inv) }
    }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) 'qw-steamvr.csv'
    Set-Content -LiteralPath $tmp -Value (($names -join ','), ($cells -join ',')) -Encoding utf8
    $back = @(Import-Csv -LiteralPath $tmp)[0]
    Assert ($back.vr_fps -eq '90') "csv vr_fps kept a period under nb-NO ('$($back.vr_fps)')"
    Assert ($back.vr_scene_app -eq 'steamvr, test') "csv scene app kept its comma"
    Assert ($back.vr_hmd -eq 'Pimax, Crystal') "csv headset name kept its comma"
    Assert ($back.gpu_timing_source -eq 'steamvr') "csv source column round-trips"
    Assert ($back.vr_res_scale -eq '1.25') "csv resolution scale kept its period"
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
} finally {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $culture
}

# ---- safety of the native path, as text ----------------------------
$modSrc = Get-Content $mod -Raw
Assert ($modSrc -match 'const int VRApplication_Background = 3') "init type is the Background constant"
Assert ($modSrc -match 'VR_InitInternal2\(ref err, VRApplication_Background') "VR_InitInternal2 uses Background"
Assert ($modSrc -match 'VR_InitInternal\(ref err, VRApplication_Background\)') "VR_InitInternal uses Background"
Assert ($modSrc -notmatch 'ref err, 1') "nothing inits as application type 1"
Assert ($modSrc -notmatch 'VR_IsHmdPresent') "VR_IsHmdPresent is not called"
Assert ($modSrc -match 'vrserver' -and $modSrc -match 'vrcompositor') "the guard names vrserver and vrcompositor"
Assert ($modSrc -match 'GetInt32, 7 is GetFloat' -and $modSrc -match 'Fn<GetIntSettingFn>\(p, 6\)' -and $modSrc -match 'Fn<GetFloatSettingFn>\(p, 7\)') "settings reads are GetInt32/GetFloat, not GetBool"

$fmt = [regex]::Match($src, "(?m)^\`$Fmt = '(\{0,8\}[^']+)'")
Assert $fmt.Success "console format string found"
$head = $fmt.Groups[1].Value -f 'TIME','G0%','G1%','BUSIEST','PF/s','C0int','C0dpc','CNint','CNdpc','tDPC','tINT','GPU%','GPU-W','GPUC','mV','FAN%','PCIE%','LIM','SIM%','vrCPU%','VRFPS','VRms'
Assert ($head.Length -eq 144) "console row is 144 columns wide ($($head.Length))"
# VRFPS is 5 letters in a 6-wide field, so the word starts one column
# after the field. The banner is the field, not the word.
Assert ($head.Substring(131, 13) -eq ' VRFPS   VRms') "VR fields occupy columns 131-143 ('$($head.Substring(131, 13))')"
Assert ($src -match "Start = 131;\s*Len = 13;\s*Label = ' VR '") "the VR banner covers VRFPS and VRms"

""
if ($fails) { "RESULT: $fails assertion(s) FAILED"; exit 1 }
"RESULT: all assertions passed"
