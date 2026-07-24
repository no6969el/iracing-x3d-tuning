$src = Get-Content "$PSScriptRoot/../Tuning-Menu.ps1" -Raw

# pull the here-string that holds the XAML
$start = $src.IndexOf('$XAML = @"')
$end   = $src.IndexOf('"@', $start)
if ($start -lt 0 -or $end -lt 0) { "FAIL: could not locate XAML block"; exit 1 }
$xamlText = $src.Substring($start + '$XAML = @"'.Length, $end - $start - '$XAML = @"'.Length)

try { [xml]$x = $xamlText } catch { "FAIL: XAML is not well-formed XML -> $_"; exit 1 }
"OK: XAML is well-formed XML"

# collect every x:Name defined in the markup
$names = @{}
$nsMgr = New-Object System.Xml.XmlNamespaceManager($x.NameTable)
foreach ($n in $x.SelectNodes("//*")) {
    foreach ($a in $n.Attributes) {
        if ($a.LocalName -eq 'Name') { $names[$a.Value] = $n.LocalName }
    }
}
"OK: $($names.Count) named elements in XAML"

# every FindName("X") in the script must resolve
$missing = @()
foreach ($m in [regex]::Matches($src, 'FindName\("([^"]+)"\)')) {
    $n = $m.Groups[1].Value
    if (-not $names.ContainsKey($n)) { $missing += $n }
}
if ($missing.Count) {
    "FAIL: FindName targets with no matching x:Name -> " + (($missing | Sort-Object -Unique) -join ', ')
    exit 1
}
"OK: every FindName target exists in the XAML"

# every page referenced by Show-Page must exist
foreach ($p in 'PageMain','PageOptimize','PageTroubleshoot','PageEachRace','PageAdvanced','PageHelp','PageChip') {
    if (-not $names.ContainsKey($p)) { "FAIL: page $p missing"; exit 1 }
}
"OK: all 7 pages present"

# no orphaned handlers left over from the old Reset button
if ($src -match 'BtnReset') { "FAIL: stale BtnReset reference still in script"; exit 1 }
if ($src -match 'Detect-System|Load-Config|Save-Config') { "FAIL: stale detection function reference"; exit 1 }
"OK: no stale references to the old detection code"
