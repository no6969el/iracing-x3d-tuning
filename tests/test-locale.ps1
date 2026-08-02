<#
    test-locale.ps1
    ---------------------------------------------------------------
    Regression test for a bug that shipped and cost somebody a whole
    session's CPU data.

    PowerShell formats numbers with the machine's regional settings.
    On a Norwegian, German, French, Spanish, Brazilian, Italian or
    Polish install the decimal separator is a COMMA - so 12.5 is
    written "12,5", which in a comma-separated file is two fields, not
    one.

    A real trace from a Norwegian PC came back with rows 41 to 46
    fields wide against a 39-field header, every row shifted by a
    different amount. Nothing errored. The file opened fine. The
    numbers were simply in the wrong columns, and every CPU column was
    unrecoverable.

    The invariant this test defends is simple and total:

        a row must have exactly as many fields as the header,
        in every culture, for every value we can produce.

    Run it directly. No admin, changes nothing.
#>

$ErrorActionPreference = 'Stop'
$fails = 0
function Assert($cond, $msg) {
    if ($cond) { "    ok   $msg" }
    else       { "    FAIL $msg"; $script:fails++ }
}

$tracer = Join-Path $PSScriptRoot '..\scripts\Record-Session.ps1'
if (-not (Test-Path $tracer)) { $tracer = Join-Path $PSScriptRoot '..\scripts\FullTrace.ps1' }
if (-not (Test-Path $tracer)) { "FAIL: cannot find the recorder script"; exit 1 }
$src = Get-Content $tracer -Raw

# ---- pull the real header out of the script ----------------------
$m = [regex]::Match($src, "(?m)^'(timestamp,power_plan,[^']+)'")
if (-not $m.Success) { "FAIL: could not find the CSV header literal"; exit 1 }
$headerNames = $m.Groups[1].Value -split ','
"OK: header found, $($headerNames.Count) columns"

# ---- pull the real Inv/Txt helpers out of the script -------------
$h = [regex]::Match($src, '(?s)\$InvCulture = \[System\.Globalization\.CultureInfo\]::InvariantCulture.*?\n\}\r?\n(?=\r?\n# Afterburner)')
if (-not $h.Success) { "FAIL: Inv/Txt helpers not found - has the CSV SAFETY block been removed?"; exit 1 }
Invoke-Expression $h.Value
"OK: Inv/Txt helpers loaded from the real script"

# ---- values chosen to be as awkward as the real ones -------------
# A double that rounds to one decimal place is the exact shape that
# broke it: [math]::Round(x,1) on a comma locale.
function Build-Row {
    $now = Get-Date
    @(
        $now.ToString('HH:mm:ss', $InvCulture)
        (Txt 'Balansert, h y ytelse')      # a plan name WITH a comma in it
        (Inv ([math]::Round(37.5, 0)))
        (Inv ([math]::Round(12.55, 1)))
        (Inv 3)
        (Inv ([math]::Round(99.94, 1)))
        (Inv ([math]::Round(0.1234, 1)))
        (Inv ([math]::Round(1.05, 1)))
        (Inv ([math]::Round(2.25, 1)))
        (Inv ([math]::Round(3.35, 1)))
        (Inv ([math]::Round(4.45, 1)))
        (Inv ([math]::Round(5.55, 1)))
        (Inv '97')                          # nvidia-smi: already a string
        (Inv '443.21')
        (Inv '2850')
        (Inv '10501')
        (Inv '67')
        (Inv '0x0000000000000004')           # throttle mask, hex
        (Inv 1)
        (Inv ([math]::Round(23.75, 1)))
        (Inv '0xFFFF')                       # affinity mask
        (Inv ([math]::Round(8.15, 1)))
        (Inv 812)
        (Inv 51234)
        (Inv ([math]::Round(1050.0, 0)))
        (Inv ([math]::Round(62.5, 0)))
        (Inv '41')
        (Inv '18342')
        (Inv ([math]::Round(78.0, 0)))
        (Inv ([math]::Round(142.55, 1)))     # fps
        (Inv ([math]::Round(6.9825, 2)))     # frametime
        (Inv 'P0')
        (Inv 0), (Inv 1), (Inv 0), (Inv 0)
        (Inv ([math]::Round(1820.0, 0)))
        (Inv ([math]::Round(12.5, 0)))
        (Inv ([math]::Round(44.5, 0)))
    ) -join ','
}

$cultures = 'nb-NO', 'de-DE', 'fr-FR', 'pt-BR', 'pl-PL', 'en-US', 'en-GB'
$original = [System.Threading.Thread]::CurrentThread.CurrentCulture

try {
    foreach ($c in $cultures) {
        ""
        "--- $c ---"
        [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new($c)

        # prove the culture is really active, or the test proves nothing
        $native = (12.5).ToString()
        $comma  = $native.Contains(',')
        "    (native decimal formatting here: '$native')"

        $row = Build-Row

        # the invariant
        $tmp = Join-Path $env:TEMP ("qw-locale-{0}.csv" -f $c)
        Set-Content -LiteralPath $tmp -Value (($headerNames -join ','), $row) -Encoding UTF8
        $parsed = @(Import-Csv -LiteralPath $tmp)
        $cols   = $parsed[0].PSObject.Properties.Name

        Assert ($parsed.Count -eq 1) "row parses as exactly one record"
        Assert ($cols.Count -eq $headerNames.Count) `
               "row is $($cols.Count) fields against a $($headerNames.Count)-field header"

        # no field may contain a decimal comma
        $bad = @($cols | Where-Object { "$($parsed[0].$_)" -match '^\-?\d+,\d+$' })
        Assert ($bad.Count -eq 0) "no field came out with a comma decimal"

        # spot-check values that would have been mangled
        Assert ($parsed[0].gpu_fps -eq '142.6' -or $parsed[0].gpu_fps -eq '142.5') `
               "gpu_fps kept its period ('$($parsed[0].gpu_fps)')"
        Assert ($parsed[0].gpu_frametime_ms -match '^\d+\.\d+$') `
               "gpu_frametime_ms kept its period ('$($parsed[0].gpu_frametime_ms)')"
        Assert ($parsed[0].power_plan -eq 'Balansert, h y ytelse') `
               "a power plan name containing a comma survived intact"
        Assert ($parsed[0].timestamp -match '^\d{2}:\d{2}:\d{2}$') `
               "timestamp used colons ('$($parsed[0].timestamp)')"

        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
} finally {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $original
}

""
"--- casing: the Turkish dotless i ---"
# In tr-TR, 'I'.ToLower() is 'i' WITHOUT a dot. Any code that lowercases an
# ASCII identifier to compare it - process names, registry GUIDs, file paths -
# gets a different string there than it does anywhere else. ToLowerInvariant
# is immune. This asserts the scripts use the invariant form.
try {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new('tr-TR')
    # The probe needs a CAPITAL I in it. Turkish maps capital I to a
    # DOTLESS lowercase i; a lowercase i is left alone. An earlier version
    # of this test probed 'iRacingSim64DX11.EXE', which has no capital I at
    # all, so it proved nothing and then failed for the wrong reason.
    $probe = 'iRacingUI.EXE'
    Assert ($probe.ToLower() -ne $probe.ToLowerInvariant()) `
           "tr-TR changes ASCII casing ('$($probe.ToLower())' vs '$($probe.ToLowerInvariant())')"
    Assert ($probe.ToLowerInvariant() -eq 'iracingui.exe') "ToLowerInvariant stays ASCII"
} finally {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $original
}

$scriptDir = Join-Path $PSScriptRoot '..\scripts'
$offenders = @()
foreach ($f in (Get-ChildItem $scriptDir -Filter *.ps1 -ErrorAction SilentlyContinue)) {
    foreach ($line in (Get-Content $f.FullName)) {
        if ($line.TrimStart().StartsWith('#')) { continue }
        if ($line -match '\.ToLower\(\)|\.ToUpper\(\)') { $offenders += ("{0}: {1}" -f $f.Name, $line.Trim()) }
    }
}
Assert ($offenders.Count -eq 0) ("no culture-sensitive ToLower/ToUpper left in scripts" +
    $(if ($offenders.Count) { " -> " + ($offenders -join ' | ') } else { '' }))

""
"--- timestamps: the two CSVs must join ---"
# The trace CSV and the hard-fault CSV are joined on a HH:mm:ss string.
# If one is written with the culture's time separator and the other is
# invariant, the join silently matches nothing and every fault column
# reads zero. Both must be invariant.
$tracer2 = Get-Content $tracer -Raw
$kit     = Join-Path $scriptDir 'Kit-Common.ps1'
$bad = @()
foreach ($f in @($tracer, $kit)) {
    if (-not (Test-Path $f)) { continue }
    foreach ($line in (Get-Content $f)) {
        if ($line.TrimStart().StartsWith('#')) { continue }
        if ($line -match "ToString\('HH:mm:ss'\)") { $bad += ("{0}: {1}" -f (Split-Path $f -Leaf), $line.Trim()) }
    }
}
Assert ($bad.Count -eq 0) ("every HH:mm:ss is written invariantly" +
    $(if ($bad.Count) { " -> " + ($bad -join ' | ') } else { '' }))

""
"--- no machine-specific paths ---"
$root = Join-Path $PSScriptRoot '..'
$hard = @()
foreach ($f in (Get-ChildItem $root -Recurse -Include *.ps1,*.bat -ErrorAction SilentlyContinue)) {
    if ($f.Name -eq 'test-locale.ps1') { continue }
    foreach ($line in (Get-Content $f.FullName)) {
        if ($line -match '[A-Za-z]:\\Users\\[A-Za-z0-9_.-]+\\') { $hard += ("{0}: {1}" -f $f.Name, $line.Trim()) }
    }
}
Assert ($hard.Count -eq 0) ("no absolute user-profile paths" +
    $(if ($hard.Count) { " -> " + (($hard | Select-Object -First 3) -join ' | ') } else { '' }))

""
if ($fails) { "RESULT: $fails assertion(s) FAILED"; exit 1 }
"RESULT: all assertions passed"
