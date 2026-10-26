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

"--- scripts load on Windows PowerShell 5.1 ---"
$scripts = @(Get-ChildItem -LiteralPath $App -Filter *.ps1) + @(Get-ChildItem -LiteralPath $Lib -Filter *.ps1)
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
