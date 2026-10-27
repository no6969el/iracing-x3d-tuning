# GamePerf: the analyzer against sessions with known, planted problems;
# both PresentMon CSV layouts; the A/B config diff; locale safety; every
# AI provider's wire format; redaction; config discovery; and the rules
# that keep the scripts loadable on Windows PowerShell 5.1.
#
# Runs on Windows PowerShell 5.1, PowerShell 7, and pwsh on Linux (the
# Windows-only sensors are not exercised - see the fixtures).

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$App = Join-Path $Root 'GamePerf'
$Lib = Join-Path $App 'lib'

$fail = 0
function Check($ok, $msg) {
    if ($ok) { "    ok   $msg" }
    else     { "    FAIL $msg"; $script:fail++ }
}

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ('gameperf-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
# Keep the user's real settings and DLL cache out of it.
$env:APPDATA = Join-Path $Tmp 'appdata'
$env:LOCALAPPDATA = Join-Path $Tmp 'localappdata'

. (Join-Path $Lib 'GamePerf-Common.ps1')
. (Join-Path $Lib 'GamePerf-Games.ps1')
. (Join-Path $Lib 'GamePerf-AI.ps1')
. (Join-Path $PSScriptRoot 'gameperf-fixtures.ps1')
$Analyze = Join-Path $Lib 'GamePerf-Analyze.ps1'

"--- native helpers ---"
$cs = Join-Path $Lib 'GamePerf.Native.cs'
$csc = $null
$fw = Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if ($fw -and (Test-Path -LiteralPath $fw)) { $csc = $fw }
$mcs = Get-Command mcs -ErrorAction SilentlyContinue
if ($csc -or $mcs) {
    # Windows PowerShell 5.1's Add-Type is the .NET Framework compiler: C# 5.
    $out = Join-Path $Tmp 'native-check.dll'
    if ($csc) { $o = & $csc /nologo /langversion:5 /target:library "/out:$out" $cs 2>&1 }
    else      { $o = & $mcs.Source -langversion:5 -target:library "-out:$out" -r:System.dll $cs 2>&1 }
    Check ($LASTEXITCODE -eq 0) ("GamePerf.Native.cs compiles as C# 5" + $(if ($LASTEXITCODE) { ": $($o | Select-Object -First 3)" }))
} else { "    skip no C# 5 compiler on this machine" }
Check (Initialize-GpNative) 'Initialize-GpNative compiles and loads the helpers'
Check ([bool]('GamePerf.Native.FrameAnalyzer' -as [type])) 'FrameAnalyzer type is available'
$dlls = @(Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'GamePerf\bin') -Filter 'GamePerf.Native.*.dll' -ErrorAction SilentlyContinue)
Check ($dlls.Count -ge 1) 'compiled helpers are cached as a DLL for the next run'

"--- analyzer: PresentMon 2.x session with planted problems ---"
$SessRoot = Join-Path $Tmp 'Sessions'
$prev = New-GpFixtureSession -Root $SessRoot -Name '20261026-190000-prev' -ShadowValue 2
$cur  = New-GpFixtureSession -Root $SessRoot -Name '20261026-200000-cur'  -ShadowValue 4
& $Analyze -SessionDir $prev -Quiet
& $Analyze -SessionDir $cur -Quiet
$sum = Read-GpJson (Join-Path $cur 'summary.json')
Check ($null -ne $sum) 'summary.json written'
$f = $sum.frames
Check ($f.captured) 'frames captured'
Check ((ConvertTo-GpDouble $f.fps_avg) -gt 80 -and (ConvertTo-GpDouble $f.fps_avg) -lt 91) "average fps is plausible ($($f.fps_avg))"
Check ($f.stutters -eq 3) "finds exactly the three planted stutters (found $($f.stutters))"
Check ($f.stutter_gpu -eq 1 -and $f.stutter_cpu -eq 1 -and $f.stutter_stall -eq 1) 'classifies them as one GPU spike, one game-thread spike, one stall'
Check ((ConvertTo-GpDouble $f.ft_max) -eq 45) "a 500 ms overlay swap chain is ignored and loading frames excluded (worst frame $($f.ft_max) ms)"
Check ($f.excluded_frames -gt 0) 'the loading screen is excluded from the stats'
Check ((ConvertTo-GpDouble $f.missed_pct) -gt 10 -and (ConvertTo-GpDouble $f.missed_pct) -lt 20) "the GPU-heavy stretch shows as missed frames ($($f.missed_pct)%)"
Check ($f.missed_gpu_bound -gt 0.9 * $f.missed) 'missed frames are attributed to the GPU'
Check ($sum.verdict -match 'GPU-bound') "verdict names the limiter ($($sum.verdict))"
$stall = @($sum.incidents | Where-Object { $_.kind -eq 'stall' }) | Select-Object -First 1
Check ($stall -and [math]::Abs((ConvertTo-GpDouble $stall.t) - 60.3) -lt 0.2) 'the stall is located at 60.3 s'
Check ($stall -and (@($stall.context) -join ';') -match 'disk reads burst') 'the stall carries the disk-read burst as context'
Check ($stall -and (@($stall.context) -join ';') -notmatch 'power limit') 'a power limit active half the session is not reported as stutter context'
$mk = @($sum.markers) | Select-Object -First 1
Check ($mk -and (ConvertTo-GpDouble $mk.worst_frame_ms) -eq 45) 'the marker is tied to the 45 ms frame before it'
$titles = @($sum.findings | ForEach-Object { $_.title }) -join ' | '
Check ($titles -match 'quad-views') 'an enabled quad-views OpenXR layer is flagged (goals forbid it)'
Check ($titles -match 'Missed frames are GPU-bound') 'missed-frame bottleneck finding present'
Check ($titles -match 'Background apps') 'background CPU (Discord) is flagged and the VR runtime is not'
Check ($titles -notmatch 'pi_server') 'the VR runtime is not called a background app'
Check (@($sum.chart.t).Count -gt 50 -and @($sum.chart.t).Count -le 900) "chart data is bucketed for the app ($(@($sum.chart.t).Count) points)"
$ls = Get-GpDefaultSettings; $ls.DataRoot = $Tmp
$listed = @(Get-GpSessions $ls)
Check ($listed.Count -eq 2 -and $listed[0].Name -eq '20261026-200000-cur') 'session list is newest first'
Check ((Test-Path -LiteralPath (Join-Path $cur 'card.json')) -and (ConvertTo-GpDouble $listed[0].Summary.frames.fps_avg) -gt 80) 'the list reads the small card.json, with the headline numbers'

"--- reports ---"
$report = Get-Content -LiteralPath (Join-Path $cur 'report.md') -Raw
$prompt = Get-Content -LiteralPath (Join-Path $cur 'ai-prompt.md') -Raw
Check ($report -match '## Worst stutters') 'report.md has the stutter table'
Check ($report -match '\| Average FPS \|') 'report.md has the frame pacing table'
Check ($prompt -match '## My goals' -and $prompt -match 'no quad views') 'ai-prompt.md carries the goals'
Check ($prompt -match '## Timeline') 'ai-prompt.md carries the timeline'
Check ($prompt -match 'ShadowMapSize=4') 'ai-prompt.md carries the config file contents'
Check ($prompt -match 'SYSTEM-WIDE') 'ai-prompt.md warns that hardfaults_s is system-wide'

"--- A/B: previous session and config diff ---"
Check ($null -ne $sum.previous -and $sum.previous.session -eq '20261026-190000-prev') 'the previous session of the same game is found'
$changes = @($sum.config_changes | ForEach-Object { $_.changes }) -join ' | '
Check ($changes -match 'ShadowMapSize : 2 -> 4') "the changed setting is reported ($changes)"

"--- legacy PresentMon 1.x CSV ---"
$v1 = New-GpFixtureSession -Root (Join-Path $Tmp 'v1') -Name '20261026-210000-v1' -Format v1
& $Analyze -SessionDir $v1 -Quiet -NoPrevious
$s1 = Read-GpJson (Join-Path $v1 'summary.json')
Check ($s1.frames.captured) 'v1 frames are read'
Check ($s1.frames.stutters -eq 3) "v1 stutters found ($($s1.frames.stutters))"
Check ($s1.frames.source.time_base -eq 'relative') 'v1 frames are placed on the session clock via the PresentMon start event'
Check ($null -eq $s1.frames.gpu_busy_avg) 'no GPU-busy column means no bottleneck claims'

"--- SteamVR: the frame writer ---"
# Raw Compositor_FrameTiming records, as GetFrameTimings returns them.
$q0s = 100.0
$mk = { param($i, $iv, $flags = 0x04) [pscustomobject]@{ Index = $i; Time = $q0s + 10 + ($i - 1000) / 90.0; Interval = $iv; Pre = 7.5; Post = 0.5; Total = 9.2; CompGpu = 1.2; CompCpu = 0.4
                                                         Idle = 2; Submit = 0.2; PosesReady = 1; FrameReady = 7; Presents = 1; Mis = 0; Dropped = 0; Flags = $flags } }
$wp = Join-Path $Tmp 'vr-writer.csv'
$vw = [GamePerf.Native.VrFrameWriter]::new($wp, $q0s)
$a1 = @(1000..1009 | ForEach-Object { & $mk $_ 11.11 }); [array]::Reverse($a1)
$n1 = $vw.Add((New-GpVrTimingBuffer $a1), 192, $a1.Count, 10.2, $q0s + 10.2, 4242)
$a2 = @(1005..1019 | ForEach-Object { & $mk $_ 11.11 })
$n2 = $vw.Add((New-GpVrTimingBuffer $a2), 192, $a2.Count, 10.3, $q0s + 10.3, 4242)
$a3 = @((& $mk 1025 11.11), (& $mk 1026 0), (& $mk 1027 9999))
$n3 = $vw.Add((New-GpVrTimingBuffer $a3), 192, $a3.Count, 10.4, $q0s + 10.4, 4242)
$n4 = $vw.Add((New-GpVrTimingBuffer $a3), 192, $a3.Count, 15.0, $q0s + 15.0, 4242)
$vw.Dispose()
$vt = [GamePerf.Native.CsvTable]::Load($wp)
Check ($n1 -eq 10 -and $n2 -eq 10 -and $n3 -eq 1 -and $n4 -eq 0) "overlapping reads write each frame once, newest-first buffers included ($n1/$n2/$n3/$n4)"
Check ($vw.Missing -eq 5) "frames that rotated out between reads are counted as missing ($($vw.Missing))"
Check ($vw.Rejected -eq 1) 'an implausible record (9999 ms) is rejected, not logged'
Check ($vt.Count -eq 21 -and -not (@($vt.Num('interval_ms')) -contains 0)) 'an idle compositor interval (0) is not a frame'
Check ($vw.TimeBase -eq 'qpc' -and [math]::Abs($vt.Num('t_s')[0] - 10.0) -lt 0.001) "compositor time lands on the session clock ($($vw.TimeBase), t=$($vt.Num('t_s')[0]))"
Check ([math]::Abs($vt.Num('app_gpu_ms')[0] - 8.0) -lt 0.01 -and [math]::Abs($vt.Num('app_cpu_ms')[0] - 6.0) -lt 0.01) 'game GPU = pre + post Submit, game CPU = poses ready -> last Submit'
Check (([GamePerf.Native.FrameAnalyzer]::Reference(22.2, 11.1, $true)) -eq 11.1 -and ([GamePerf.Native.FrameAnalyzer]::Reference(22.2, 11.1, $false)) -eq 22.2) 'a vsynced late frame is judged against the refresh budget'

"--- SteamVR: a VR session analysed from compositor frames ---"
$vrs = New-GpFixtureSession -Root (Join-Path $Tmp 'vr') -Name '20261026-230000-vr' -SteamVr
& $Analyze -SessionDir $vrs -Quiet -NoPrevious
$sv = Read-GpJson (Join-Path $vrs 'summary.json')
$fv = $sv.frames
Check ($fv.captured -and $fv.source.kind -eq 'steamvr') "frames come from the SteamVR compositor ($($fv.source.kind))"
Check ((ConvertTo-GpDouble $fv.fps_avg) -gt 80 -and (ConvertTo-GpDouble $fv.fps_avg) -le 90.5) "average fps is plausible ($($fv.fps_avg))"
Check ((@($sv.notes) -join ' ') -match 'other scene apps') 'SteamVR Home frames before the game are left out'
$v = $sv.vr
Check ($null -ne $v -and $v.reprojected -eq ($v.reproj_gpu + $v.reproj_cpu + $v.motion_smoothed)) "reprojections are SteamVR's own flags ($($v.reprojected) = $($v.reproj_gpu) GPU + $($v.reproj_cpu) CPU + $($v.motion_smoothed) motion)"
Check ($v.reproj_gpu -gt 150 -and $v.reproj_cpu -eq 1 -and $v.motion_smoothed -eq 5 -and $v.dropped_frames -eq 1) 'GPU-late stretch, the CPU-late frame, motion smoothing and the compositor drop are all seen'
Check ((ConvertTo-GpDouble $v.reprojected_pct) -lt 5) "the 'async reprojection enabled' flag on every frame is not counted ($($v.reprojected_pct)%)"
Check ($fv.missed_gpu_bound -gt 0.9 * $fv.missed -and $fv.missed_cpu_side -ge 1) "late VR frames are judged against the refresh: GPU-late ones are GPU-bound ($($fv.missed_gpu_bound) of $($fv.missed))"
$tv = @($sv.findings | ForEach-Object { $_.title }) -join ' | '
Check ($tv -match 'SteamVR reprojected' -and $tv -match 'Motion smoothing' -and $tv -match 'compositor itself dropped') 'reprojection, motion smoothing and compositor drops are findings'
Check ($tv -match 'Missed frames are GPU-bound') 'the missed-frame bottleneck is the GPU'
Check ($tv -match 'render target 4312x5100') 'the SteamVR render target is reported'
Check ($sv.verdict -match 'SteamVR reprojected') "verdict carries SteamVR's reprojection ($($sv.verdict))"
Check ($sv.chart.source -eq 'steamvr' -and @($sv.chart.t).Count -gt 50) 'the chart is drawn from compositor frames'
$pv = Get-Content -LiteralPath (Join-Path $vrs 'ai-prompt.md') -Raw
$rv = Get-Content -LiteralPath (Join-Path $vrs 'report.md') -Raw
Check ($rv -match '## SteamVR compositor' -and $pv -match 'SteamVR compositor') 'report and AI brief explain the SteamVR numbers'
Check ($pv -match 'vr_reproj_s') 'the AI timeline carries reprojection per second'

$nvr = New-GpFixtureSession -Root (Join-Path $Tmp 'vr') -Name '20261026-231000-novr' -VrState 'not-running'
& $Analyze -SessionDir $nvr -Quiet -NoPrevious
$sn = Read-GpJson (Join-Path $nvr 'summary.json')
$nf = @($sn.findings | Where-Object { $_.title -eq 'No frame data in this session' }) | Select-Object -First 1
Check ($nf -and $nf.detail -match 'SteamVR was not running' -and $nf.detail -match 'never starts SteamVR') 'a VR session without SteamVR says exactly why there is no frame timing'

"--- locale: comma-decimal Windows cannot corrupt the output ---"
$saved = [Threading.Thread]::CurrentThread.CurrentCulture
try {
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('de-DE')
    Check ((Inv 12.5) -eq '12.5') 'Inv writes a period under de-DE'
    Check ((Format-GpNum 86.04 1) -eq '86.0') 'Format-GpNum is invariant under de-DE'
    $de = New-GpFixtureSession -Root (Join-Path $Tmp 'de') -Name '20261026-220000-de'
    & $Analyze -SessionDir $de -Quiet -NoPrevious
    $sde = Read-GpJson (Join-Path $de 'summary.json')
    Check ($sde.frames.stutters -eq 3) 'the analysis is identical under de-DE'
    $rde = Get-Content -LiteralPath (Join-Path $de 'report.md') -Raw
    Check ($rde -notmatch '\| Average FPS \| \d+,\d') 'report numbers keep a period under de-DE'
} finally { [Threading.Thread]::CurrentThread.CurrentCulture = $saved }

"--- JSON safety ---"
$jp = Join-Path $Tmp 'nan.json'
Write-GpJson -Path $jp -Object ([ordered]@{ a = [double]::NaN; b = @(1.5, [double]::PositiveInfinity); c = 'NaN is fine in text' })
$jt = Get-Content -LiteralPath $jp -Raw
$jo = Read-GpJson $jp
Check ($null -ne $jo -and $null -eq $jo.a -and $jo.c -eq 'NaN is fine in text') "NaN / Infinity are written as null and the file reads back ($($jt -replace '\s+', ' '))"

"--- AI wire formats ---"
$s = Get-GpDefaultSettings
$s.AiProvider = 'xai'
$x = Get-GpAiConfig $s; $x.ApiKey = 'k'
$r = New-GpAiRequest -Config $x -Messages @(@{ role = 'user'; content = 'hi' })
$b = $r.Body | ConvertFrom-Json
Check ($r.Uri -eq 'https://api.x.ai/v1/chat/completions') 'xAI uses its OpenAI-compatible endpoint'
Check ($r.Headers['Authorization'] -eq 'Bearer k') 'xAI key sent as a bearer token'
Check ($b.messages[0].role -eq 'system' -and $b.messages[1].content -eq 'hi') 'system + user messages'
Check ($r.Body -notmatch 'temperature|top_p|top_k') 'no sampling parameters are sent'
$s.AiProvider = 'anthropic'
$a = Get-GpAiConfig $s; $a.ApiKey = 'ak'
$r = New-GpAiRequest -Config $a -Messages @(@{ role = 'user'; content = 'hi' })
$b = $r.Body | ConvertFrom-Json
Check ($r.Uri -eq 'https://api.anthropic.com/v1/messages') 'Claude uses the Messages API'
Check ($r.Headers['anthropic-version'] -eq '2026-10-21' -and $r.Headers['x-api-key'] -eq 'ak') 'Claude version and key headers'
Check ($b.model -eq 'claude-opus-5-5' -and $b.max_tokens -gt 0 -and $b.system) 'Claude body: model, max_tokens, system'
Check ($b.fallbacks -eq 'default' -and $r.Headers['anthropic-beta'] -eq 'server-side-fallback-2026-07-01') 'Claude opts into server-side refusal fallbacks'
Check ($b.output_config.effort -eq 'high') 'Claude effort is set explicitly'
Check ($r.Body -notmatch 'temperature|top_p|top_k|budget_tokens') 'Claude body has no removed parameters'
$a.Model = 'claude-haiku-4-5'
$r = New-GpAiRequest -Config $a -Messages @(@{ role = 'user'; content = 'hi' })
Check ($r.Body -notmatch 'fallbacks|output_config' -and -not $r.Headers.Contains('anthropic-beta')) 'older Claude models get a plain request'
$ok = Read-GpAiResponse -Config $x -Json '{"model":"m","choices":[{"message":{"content":"answer"},"finish_reason":"stop"}]}'
Check ($ok.ok -and $ok.text -eq 'answer') 'OpenAI-style response parsed'
$ok = Read-GpAiResponse -Config $a -Json '{"model":"m","stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},{"type":"text","text":"answer"}]}'
Check ($ok.ok -and $ok.text -eq 'answer') 'Claude response parsed (thinking blocks skipped)'
$no = Read-GpAiResponse -Config $a -Json '{"model":"m","stop_reason":"refusal","stop_details":{"category":"cyber"},"content":[]}'
Check (-not $no.ok -and $no.error -match 'declined') 'a Claude refusal is reported, not shown as an empty answer'
$s.AiProvider = 'none'
Check ((Test-GpAiReady (Get-GpAiConfig $s)) -ne '') 'no provider = not ready (the app falls back to copy/paste)'
$s.AiProvider = 'ollama'
$o = Get-GpAiConfig $s; $o.Model = 'llama'
Check ((Test-GpAiReady $o) -eq '') 'a local model needs no key'

"--- redaction ---"
$env:USERNAME = 'TestPilot'; $env:USERPROFILE = 'C:\Users\TestPilot'
$red = Protect-GpText "path=$($env:USERPROFILE)\Documents\iRacing`napi_key = sk-live-123`nPassword: hunter2`nShadowMapSize=4"
Check ($red -notmatch 'TestPilot') 'the Windows user name is removed'
Check ($red -notmatch 'sk-live-123|hunter2') 'credential-looking values are removed'
Check ($red -match 'ShadowMapSize=4') 'ordinary settings are kept'

"--- config discovery ---"
$docs = Join-Path $Tmp 'Documents'
New-Item -ItemType Directory -Force -Path (Join-Path $docs 'iRacing') | Out-Null
Set-Content -LiteralPath (Join-Path $docs 'iRacing/rendererDX11OpenXR.ini') -Value '[Graphics]'
Set-Content -LiteralPath (Join-Path $docs 'iRacing/app.ini') -Value '[Graphics]'
$la = Join-Path $Tmp 'LocalAppData'
New-Item -ItemType Directory -Force -Path (Join-Path $la 'MyUEGame/Saved/Config/Windows') | Out-Null
Set-Content -LiteralPath (Join-Path $la 'MyUEGame/Saved/Config/Windows/GameUserSettings.ini') -Value '[ScalabilityGroups]'
$folders = @{ Documents = $docs; SavedGames = $null; LocalAppData = $la; AppData = $null; Steam = $null }
$ir = @(Find-GpGameConfigFiles -Exe 'iRacingSim64DX11.exe' -Folders $folders -SteamLibraries @())
Check ($ir.Count -eq 2 -and @($ir | Where-Object { $_.Source -eq 'catalog' }).Count -eq 2) 'iRacing renderer + app ini found from the catalog'
$ue = @(Find-GpGameConfigFiles -Exe 'MyUEGame-Win64-Shipping.exe' -Folders $folders -SteamLibraries @())
Check ($ue.Count -eq 1 -and $ue[0].Source -eq 'search' -and $ue[0].Path -like '*GameUserSettings.ini') 'an unknown Unreal Engine game is found by search'
$vdf = "`"libraryfolders`"`n{`n `"0`" { `"path`" `"C:\\Program Files (x86)\\Steam`" }`n `"1`" { `"path`" `"D:\\SteamLibrary`" }`n}"
$libs = @(Get-GpSteamLibraries -SteamRoot '' -VdfText $vdf)
Check ($libs -contains 'D:\SteamLibrary' -and $libs -contains 'C:\Program Files (x86)\Steam') 'Steam library folders parsed from libraryfolders.vdf'
$rf = @(Expand-GpPattern -Pattern '{SteamApps:rFactor 2}\UserData\player\player.JSON' -Folders $folders -SteamLibraries $libs)
Check ($rf -contains 'D:\SteamLibrary\steamapps\common\rFactor 2\UserData\player\player.JSON') 'Steam app paths expand per library'
$gx = Join-Path (Join-Path $Tmp 'Games') 'X'
$exe = Join-Path (Join-Path (Join-Path $gx 'Binaries') 'Win64') 'X-Win64-Shipping.exe'
Check ((Get-GpInstallRoot $exe) -eq $gx) 'install root climbs out of Binaries\Win64'

"--- logger / analyzer column contract ---"
# One list, read by both sides: a column the analyzer reads but the logger
# no longer writes would silently turn into blanks.
$loggerText = Get-Content -LiteralPath (Join-Path $Lib 'GamePerf-Logger.ps1') -Raw
$m = [regex]::Match($loggerText, '\$Columns = @\(([\s\S]*?)\)\s*\r?\n\$SysWriter')
$logCols = @([regex]::Matches($m.Groups[1].Value, "'([a-z0-9_]+)'") | ForEach-Object { $_.Groups[1].Value })
Check ($logCols.Count -gt 50) "logger declares $($logCols.Count) columns"
$anText = Get-Content -LiteralPath $Analyze -Raw
$m2 = [regex]::Match($anText, '\$NumCols = @\(([\s\S]*?)\)\s*\r?\n')
$anCols = @([regex]::Matches($m2.Groups[1].Value, "'([a-z0-9_]+)'") | ForEach-Object { $_.Groups[1].Value })
$missing = @($anCols | Where-Object { $logCols -notcontains $_ })
Check ($anCols.Count -gt 30 -and $missing.Count -eq 0) ("every column the analyzer reads is written by the logger" + $(if ($missing.Count) { " (missing: $($missing -join ', '))" }))
$fixCols = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'gameperf-fixtures.ps1') -Raw)
$m3 = [regex]::Match($fixCols, "\`$cols = '([^']+)'")
Check (($m3.Groups[1].Value -split ',') -join ',' -eq ($logCols -join ',')) 'the test fixture writes the logger''s exact header'

"--- SteamVR: the kit's reader is the one GamePerf uses ---"
$kitVr = Join-Path (Join-Path $Root 'scripts') 'SteamVR-Timing.ps1'
Check (Test-Path -LiteralPath $kitVr) 'scripts\SteamVR-Timing.ps1 is in the kit'
Check ($loggerText -match "Join-Path \`$GpKitScripts 'SteamVR-Timing.ps1'") 'the recorder dot-sources the kit''s SteamVR reader (no copy of it)'
. $kitVr
$kitAll = Get-SteamVrColumnNames   # unary-comma return: assign it, never pipe the call
$kitCols = @($kitAll | Where-Object { $_ -ne 'gpu_timing_source' })
$gpVrCols = @($logCols | Where-Object { $_ -like 'vr_*' -and $_ -ne 'vr_cpu' })
Check (($gpVrCols -join ',') -eq ($kitCols -join ',')) "system.csv carries the kit's vr_* columns in the kit's order ($($gpVrCols.Count))"

"--- SteamVR: the recorder's glue, against a fake compositor ---"
# The real openvr_api.dll is Windows-only and needs a headset. This stands
# in for the kit's SteamVrClient (same static API, so the kit's
# Initialize-SteamVrClient leaves it alone) and serves a 90 Hz ring buffer.
Add-Type -TypeDefinition @'
using System;
public class SteamVrClient {
    public static string LastError = "";
    public static string CompositorVersion = "IVRCompositor_029";
    public static long Index = 5000;
    public static bool Fail;
    static void Frame(byte[] b, int o, long index, double time) {
        BitConverter.GetBytes((uint)192).CopyTo(b, o);
        BitConverter.GetBytes((uint)index).CopyTo(b, o + 4);
        BitConverter.GetBytes((uint)1).CopyTo(b, o + 8);
        BitConverter.GetBytes((uint)4).CopyTo(b, o + 20);
        BitConverter.GetBytes(time).CopyTo(b, o + 24);
        float[] v = { 7.5f, 0.5f, 9.2f, 1.2f, 0.4f, 2f, 11.111f, 0f, 0f, 0.2f, 0f, 1f, 7f };
        for (int i = 0; i < v.Length; i++) BitConverter.GetBytes(v[i]).CopyTo(b, o + 32 + 4 * i);
    }
    static double Now() { return System.Diagnostics.Stopwatch.GetTimestamp() / (double)System.Diagnostics.Stopwatch.Frequency; }
    public static bool Connect(string dll) { return true; }
    public static void Disconnect() { }
    public static bool TryFrameTiming(byte[] b, int size) { if (size != 192) return false; Frame(b, 0, Index, Now()); return true; }
    public static int ReadFrameTimings(byte[] b, int size, int max) {
        if (Fail) return -1;
        double now = Now();
        int n = Math.Min(max, 128);
        for (int i = 0; i < n; i++) Frame(b, i * size, Index - i, now - i / 90.0);
        return n;
    }
    public static byte[] ReadCumulative() { return new byte[128]; }
    public static int ScenePid() { return 4242; }
    public static int RendererPid() { return 4242; }
    public static string RenderSize() { return "4312x5100"; }
    public static string HmdFloat(int prop) { return prop == 2002 ? "90" : prop == 2001 ? "0.002" : ""; }
    public static string HmdString(int prop) { return "Crystal"; }
    public static string AppKey(int pid) { return "steam.app.266410"; }
    public static string ReadSettingNumber(string section, string key) { return key == "resolutionScale" ? "100" : ""; }
}
'@
function Get-SteamVrRunningProcessNames { @('vrserver') }
function Find-SteamVrApiDll { 'openvr_api.dll' }
$GlueLog = New-Object System.Collections.ArrayList
function Write-GpLog([string]$Message, [string]$Color = '') { [void]$GlueLog.Add($Message) }
function Add-GpWarning([string]$Text) { [void]$GlueLog.Add("WARNING: $Text") }
function Add-GpEvent([string]$Kind, [string]$Detail) { [void]$GlueLog.Add("event $Kind") }
$lAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Lib 'GamePerf-Logger.ps1'), [ref]$null, [ref]$null)
foreach ($fnName in 'Read-GpVrFrames', 'Update-GpVrState') {
    $fn = $lAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }, $true)
    Invoke-Expression $fn.Extent.Text
}
$SvrOn = $true; $SvrWriter = $null; $SvrBuf = $null; $SvrSeen = ''; $SvrWaitSince = $null; $SvrLastStatic = $null
$IsVr = $true; $GameTracker = $true
$VrCsv = Join-Path $Tmp 'glue-vr-frames.csv'
$QpcFreq = [GamePerf.Native.Win]::QpcFrequency(); $QpcStart = [GamePerf.Native.Win]::Qpc()
$rows = @()
for ($tick = 0; $tick -lt 6; $tick++) {
    $rows += ,(Get-SteamVrSample)
    Read-GpVrFrames
    Update-GpVrState
    Start-Sleep -Milliseconds 300
    [SteamVrClient]::Index += 27
}
$last = $rows[$rows.Count - 1]
Check ($script:VrStatus -eq 'connected' -and ($GlueLog -join ' ') -match 'SteamVR frame timing connected') "the kit's reader connects as a Background client and the recorder logs it ($($script:VrStatus))"
Check ([int]$script:VrState.StructSize -eq 192) 'the 192-byte frame record is detected'
Check ($null -ne $SvrWriter -and $SvrWriter.Written -eq (128 + 5 * 27) -and $SvrWriter.Missing -eq 0) "every frame reaches vr-frames.csv exactly once ($(if ($SvrWriter) { $SvrWriter.Written }))"
Check ($SvrWriter.TimeBase -eq 'qpc') 'compositor time is recognised as the QPC clock'
$lf = ConvertTo-GpDouble $last.vr_fps
Check ($lf -gt 30 -and $lf -lt 150 -and $last.vr_hz -eq 90 -and $last.vr_hmd -eq 'Crystal' -and $last.vr_target_w -eq 4312 -and $last.vr_res_scale -eq 1) "the kit's 1 Hz row is filled (vr_fps $lf, $($last.vr_hz) Hz, $($last.vr_hmd), $($last.vr_target_w) px, scale $($last.vr_res_scale))"
Check ($null -ne $SvrLastStatic -and [double]$SvrLastStatic.Hz -eq 90) 'the headset details are kept for the report'
[SteamVrClient]::Fail = $true
[void](Get-SteamVrSample); Read-GpVrFrames; Update-GpVrState
Check ($script:VrStatus -eq 'read-failed' -and ($GlueLog -join ' ') -match 'SteamVR stopped answering' -and [double]$SvrLastStatic.Hz -eq 90) 'SteamVR going away is logged, and what was known about the headset survives'
$SvrWriter.Dispose()

$appText = Get-Content -LiteralPath (Join-Path $App 'GamePerf.ps1') -Raw
Check ($appText -match "\`$elevate = .*\`$Settings.Mode -ne 'VR'") 'the recorder is never elevated in VR (SteamVR runs as the user)'

"--- GamePerf.exe: the icon you double-click ---"
$launcherDir = Join-Path $App 'launcher'
$lsrc = Join-Path $launcherDir 'GamePerfLauncher.cs'
$exe = Join-Path $App 'GamePerf.exe'
if ($csc -or $mcs) {
    $out = Join-Path $Tmp 'launcher-check.exe'
    if ($csc) { $o = & $csc /nologo /langversion:5 /target:winexe "/out:$out" $lsrc 2>&1 }
    else      { $o = & $mcs.Source -langversion:5 -target:winexe "-out:$out" -r:System.dll $lsrc 2>&1 }
    Check ($LASTEXITCODE -eq 0) ("the launcher compiles as C# 5" + $(if ($LASTEXITCODE) { ": $($o | Select-Object -First 3)" }))
}
Check (Test-Path -LiteralPath $exe) 'GamePerf.exe is shipped next to the app'
$vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
Check ($vi.ProductName -eq 'GamePerf' -and $vi.FileDescription -eq 'GamePerf') "it is called GamePerf in Task Manager ($($vi.FileDescription))"
$expect = Get-GpLauncherInformationalVersion ([IO.File]::ReadAllText($lsrc))
Check ($vi.ProductVersion -eq $expect) "the committed exe was built from the committed source ($($vi.ProductVersion) vs $expect) - rebuild with launcher\Build-Launcher.ps1"
Check ($vi.FileVersion -eq "$GamePerfVersion.0") "exe version matches GamePerf $GamePerfVersion"
$hdr = [IO.File]::ReadAllBytes($exe)
$peOff = [BitConverter]::ToInt32($hdr, 0x3C)
Check ([BitConverter]::ToUInt16($hdr, $peOff + 24 + 68) -eq 2) 'GamePerf.exe is a Windows GUI program - it never opens a console window'
[xml]$mani = Get-Content -LiteralPath (Join-Path $launcherDir 'GamePerf.exe.manifest') -Raw
$lvl = $mani.SelectSingleNode("//*[local-name()='requestedExecutionLevel']").level
Check ($lvl -eq 'asInvoker') 'opening the app never asks for admin (asInvoker)'
Check ($null -ne $mani.SelectSingleNode("//*[local-name()='assemblyIdentity' and @name='Microsoft.Windows.Common-Controls']")) 'modern themed dialogs (Common Controls 6)'
$ico = [IO.File]::ReadAllBytes((Join-Path $launcherDir 'GamePerf.ico'))
$sizes = @(); for ($i = 0; $i -lt [BitConverter]::ToUInt16($ico, 4); $i++) { $w = $ico[6 + 16 * $i]; if ($w -eq 0) { $w = 256 }; $sizes += $w }
Check (($sizes -contains 16) -and ($sizes -contains 32) -and ($sizes -contains 48) -and ($sizes -contains 256)) "the icon carries every size Windows asks for ($($sizes -join ', '))"

"--- the launcher hosts PowerShell in-process ---"
$refs = @()
if ($PSVersionTable.PSEdition -eq 'Core') { $refs = @('System.Text.RegularExpressions', 'System.Collections', 'System.Collections.NonGeneric', 'System.Runtime.InteropServices', 'System.Threading', 'System.Threading.Thread', 'System.Console') }
$hostOk = $false
try {
    if (-not ('GamePerf.Launcher.ScriptHost' -as [type])) {
        $p = @{ TypeDefinition = [IO.File]::ReadAllText($lsrc); ErrorAction = 'Stop' }
        if ($refs.Count) { $p.ReferencedAssemblies = $refs }
        Add-Type @p
    }
    $hostOk = $true
} catch { "    note: $($_.Exception.Message)" }
Check $hostOk 'launcher source loads'
if ($hostOk) {
    $hd = Join-Path $Tmp "it's a dir"
    New-Item -ItemType Directory -Force -Path $hd | Out-Null
    Set-Content -LiteralPath (Join-Path $hd 'probe.ps1') -Value "param([string]`$SessionDir, [switch]`$Quiet)`n`"quiet=`$Quiet root=`$PSScriptRoot`"`nSet-Content -LiteralPath (Join-Path `$SessionDir 'ran.txt') -Value ok`nWrite-Error 'soft error'"
    $err = New-Object Text.StringBuilder
    $res = [GamePerf.Launcher.ScriptHost]::Run('& ' + [GamePerf.Launcher.ScriptHost]::Quote((Join-Path $hd 'probe.ps1')) + ' -SessionDir ' + [GamePerf.Launcher.ScriptHost]::Quote($hd) + ' -Quiet', $err)
    Check (Test-Path -LiteralPath (Join-Path $hd 'ran.txt')) 'a script runs in-process, with a quote in its path'
    Check ((@($res) -join '') -match 'quiet=True' -and (@($res) -join '') -match [regex]::Escape($hd)) 'parameters and $PSScriptRoot arrive intact'
    Check ($err.ToString() -match 'soft error') 'script errors are captured for the launcher log'
    $threw = $false
    try { [void][GamePerf.Launcher.ScriptHost]::Run("throw 'boom'", $err) } catch { $threw = $true }
    Check $threw 'a terminating error reaches the launcher'
}

"--- silent: nothing the recorder does can open a window ---"
$lt = Get-Content -LiteralPath (Join-Path $Lib 'GamePerf-Logger.ps1') -Raw
$noisy = @([regex]::Matches($lt, '(?m)^(?!\s*#).*(Start-Process|powercfg|&\s*\$SmiExe|&\s*\$PmExe).*$') | ForEach-Object { $_.Value.Trim() })
Check ($noisy.Count -eq 0) ("the recorder starts helpers only through the windowless launcher" + $(if ($noisy.Count) { ": $($noisy -join ' | ')" }))
Check ($lt -match '\[switch\]\$Beep' -and $lt -notmatch 'NoBeep') 'the marker sound is opt-in'
Check (-not (Get-GpDefaultSettings).MarkerBeep) 'the app ships with the marker sound off'
$gt = Get-Content -LiteralPath (Join-Path $App 'GamePerf.ps1') -Raw
Check (@([regex]::Matches($gt, 'Start-Process powershell')).Count -eq 1) 'the app starts the recorder without a PowerShell window (only the STA fallback relaunch remains)'
Check ($gt -match "Start-GpHidden -Mode '--logger'") 'the recorder is started through Start-GpHidden'
$ct = Get-Content -LiteralPath (Join-Path $Lib 'GamePerf-Common.ps1') -Raw
Check ($ct -match 'CreateNoWindow = \$true') 'Start-GpHidden uses CreateNoWindow'
Check ($gt -notmatch '\.Activate\(\)') 'finishing a session never pulls the window in front of the game'

"--- status file is replaced atomically ---"
$sp = Join-Path $Tmp 'status.json'
Write-GpJson -Path $sp -Object @{ n = 1 }
Write-GpJson -Path $sp -Object @{ n = 2 }
Check ((Read-GpJson $sp).n -eq 2 -and -not (Test-Path -LiteralPath "$sp.tmp")) 'a rewrite replaces the file and leaves no temp file'

"--- scripts load on Windows PowerShell 5.1 ---"
$scripts = @(Get-ChildItem -LiteralPath $App -Filter *.ps1) + @(Get-ChildItem -LiteralPath $Lib -Filter *.ps1) + @(Get-ChildItem -LiteralPath (Join-Path $App 'launcher') -Filter *.ps1)
foreach ($sc in $scripts) {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($sc.FullName, [ref]$null, [ref]$errs)
    Check ($errs.Count -eq 0) "$($sc.Name) parses"
    # 5.1 reads a BOM-less script in the ANSI code page: non-ASCII would be mangled.
    $bytes = [IO.File]::ReadAllBytes($sc.FullName)
    Check (-not ($bytes | Where-Object { $_ -gt 127 } | Select-Object -First 1)) "$($sc.Name) is pure ASCII"
}
if (Get-Module -ListAvailable PSScriptAnalyzer) {
    $set = @{ IncludeRules = @('PSUseCompatibleSyntax'); Rules = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') } } }
    $hits = @($scripts | ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Settings $set })
    Check ($hits.Count -eq 0) ("no syntax newer than PowerShell 5.1" + $(if ($hits.Count) { ': ' + (($hits | Select-Object -First 3 | ForEach-Object { "$($_.ScriptName):$($_.Line) $($_.Message)" }) -join '; ') }))
} else { "    skip PSScriptAnalyzer not installed (5.1 syntax check)" }

Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
""
if ($fail) { "RESULT: $fail assertion(s) failed"; exit 1 } else { "RESULT: all assertions passed" }
