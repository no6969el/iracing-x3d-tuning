$env:APPDATA = '/tmp/appdata'
. "$PSScriptRoot/../scripts/X3D-Profiles.ps1"

function Time($label, $iterations, $block) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $iterations; $i++) { & $block | Out-Null }
    $sw.Stop()
    "{0,-46} {1,8:N2} ms/call" -f $label, ($sw.Elapsed.TotalMilliseconds / $iterations)
}

# build a realistic config once
Remove-Item Env:X3D_FORCE_PROFILE -ErrorAction SilentlyContinue
Clear-X3DConfig
$p = Get-X3DProfile -NoCache
Export-X3DConfig $p
$cfgPath = Get-X3DConfigPath

"=== measurable startup work (pure PowerShell, no WMI/WPF) ==="
Time "read + parse config.json"            200 { Get-Content $cfgPath -Raw | ConvertFrom-Json }
Time "  ...just the file read"             200 { Get-Content $cfgPath -Raw }
Time "[Environment]::ProcessorCount"      2000 { [Environment]::ProcessorCount }
Time "catalog regex match (worst case)"   2000 {
    $n = 'AMD Ryzen 5 5500X3D 6-Core Processor'
    foreach ($e in (Get-X3DCatalog)) { if ($n -match $e.Match) { break } }
}
Time "full Import-X3DConfig (as shipped)"  200 { Import-X3DConfig }

""
"=== how many times is the SAME data fetched? ==="
$s = Get-Content "$PSScriptRoot/../scripts/X3D-Profiles.ps1" -Raw
"  Win32_Processor queries in the module : " + ([regex]::Matches($s,'Get-CimInstance Win32_Processor')).Count
"  Win32_VideoController queries         : " + ([regex]::Matches($s,'Get-CimInstance Win32_VideoController')).Count

""
"=== which run on the CACHED path (every launch after the first)? ==="
"  Import-X3DConfig -> Get-X3DLogicalCount -> Get-CimInstance Win32_Processor"
"  i.e. one WMI round trip on EVERY launch just to validate the cache."
"  The pre-v3.0.0 code read the JSON and did no WMI at all."
