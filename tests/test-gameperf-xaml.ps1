# GamePerf's window: the markup must be well-formed, every element the
# code reaches for must exist, and every style it names must be defined.
# A typo in any of these is invisible until the app is opened on Windows.

$src = Get-Content "$PSScriptRoot/../GamePerf/GamePerf.ps1" -Raw

$start = $src.IndexOf("`$Xaml = @'")
$end = $src.IndexOf("'@", $start)
if ($start -lt 0 -or $end -lt 0) { "FAIL: could not locate the XAML block"; exit 1 }
$xamlText = $src.Substring($start + "`$Xaml = @'".Length, $end - $start - "`$Xaml = @'".Length)

try { [xml]$x = $xamlText } catch { "FAIL: XAML is not well-formed XML -> $_"; exit 1 }
"OK: XAML is well-formed XML"

$names = @{}
$dupes = @()
# Names inside a ControlTemplate live in the template's own namescope, so
# the same part name (PART_ContentHost, B) in several templates is correct.
foreach ($n in $x.SelectNodes('//*[not(ancestor::*[local-name()="ControlTemplate"])]')) {
    foreach ($a in $n.Attributes) {
        if ($a.LocalName -eq 'Name') {
            if ($names.ContainsKey($a.Value)) { $dupes += $a.Value }
            $names[$a.Value] = $n.LocalName
        }
    }
}
if ($dupes.Count) { "FAIL: duplicate x:Name values -> $($dupes -join ', ')"; exit 1 }
"OK: $($names.Count) named elements, no duplicates"

$missing = @()
foreach ($m in [regex]::Matches($src, '\$ui\.(\w+)')) {
    if (-not $names.ContainsKey($m.Groups[1].Value)) { $missing += $m.Groups[1].Value }
}
if ($missing.Count) { "FAIL: `$ui references with no matching x:Name -> " + (($missing | Sort-Object -Unique) -join ', '); exit 1 }
"OK: every `$ui.<name> the code uses exists in the XAML"

$keys = @{}
foreach ($n in $x.SelectNodes('//*')) { foreach ($a in $n.Attributes) { if ($a.LocalName -eq 'Key') { $keys[$a.Value] = $true } } }
$used = @([regex]::Matches($xamlText, '\{StaticResource (\w+)\}') | ForEach-Object { $_.Groups[1].Value }) +
        @([regex]::Matches($src, "FindResource\('(\w+)'\)") | ForEach-Object { $_.Groups[1].Value })
$undef = @($used | Where-Object { -not $keys.ContainsKey($_) } | Sort-Object -Unique)
if ($undef.Count) { "FAIL: StaticResource keys that are not defined -> $($undef -join ', ')"; exit 1 }
"OK: every StaticResource / FindResource key is defined"

foreach ($p in 'PageRecord', 'PageResults', 'PageAi', 'PageSettings', 'NavRecord', 'NavResults', 'NavAi', 'NavSettings', 'BtnStart', 'ChartCanvas', 'RtbAnswer') {
    if (-not $names.ContainsKey($p)) { "FAIL: $p missing"; exit 1 }
}
"OK: all pages, nav items and core controls present"

# The window must not run an always-on animation: WPF would redraw at 60 Hz
# for as long as the app is open, which is exactly what a perf tool must not do.
if ($xamlText -match 'RepeatBehavior="Forever"') { "FAIL: a forever-running animation is declared in the XAML"; exit 1 }
"OK: no always-on animation"

if ($src -notmatch 'RenderMode\]::SoftwareOnly') { "FAIL: the window should render in software so it never competes for the GPU"; exit 1 }
"OK: software rendering"
