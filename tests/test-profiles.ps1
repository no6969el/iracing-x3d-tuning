$env:APPDATA = '/tmp/appdata'
. "$PSScriptRoot/../scripts/X3D-Profiles.ps1"

$names = @(
  '5500X3D','5600X3D','5700X3D','5800X3D',
  '7500X3D','7600X3D','7700X3D','7800X3D','7900X3D','7950X3D','7945HX3D',
  '9800X3D','9850X3D','9900X3D','9950X3D','9950X3D2','9955HX3D'
)

"{0,-10} {1,-34} {2,-7} {3,-6} {4,-5} {5,-9} {6,-11} {7}" -f 'FORCE','Model','Topo','VCche','Freq','VCacheRng','BgRange','IRQ'
"-" * 118
foreach ($n in $names) {
    $env:X3D_FORCE_PROFILE = $n
    Clear-X3DConfig
    $p = Get-X3DProfile -NoCache
    "{0,-10} {1,-34} {2,-7} {3,-6} {4,-5} {5,-9} {6,-11} {7}" -f `
        $n, $p.Model, $p.Topology, $p.VCacheScope, $p.FreqFirst, $p.VCacheRange, $p.BackgroundRange, ($p.IrqTargets -join ',')
}

""
"=== 9950X3D2 advice ==="
$env:X3D_FORCE_PROFILE = '9950X3D2'; Clear-X3DConfig
$p = Get-X3DProfile -NoCache
Get-X3DTopologySummary $p
Get-X3DPinningAdvice  $p

""
"=== 5600X3D advice + warnings ==="
$env:X3D_FORCE_PROFILE = '5600X3D'; Clear-X3DConfig
$p = Get-X3DProfile -NoCache
Get-X3DTopologySummary $p
Get-X3DPinningAdvice  $p
Write-X3DWarnings $p

""
"=== mobile warning (9955HX3D) ==="
$env:X3D_FORCE_PROFILE = '9955HX3D'; Clear-X3DConfig
$p = Get-X3DProfile -NoCache
Write-X3DWarnings $p

""
"=== unknown / non-X3D fallback (no force) ==="
Remove-Item Env:X3D_FORCE_PROFILE -ErrorAction SilentlyContinue
Clear-X3DConfig
$p = Get-X3DProfile -NoCache
"Model=$($p.Model)  IsX3D=$($p.IsX3D)  TopologyKnown=$($p.TopologyKnown)  Source=$($p.DetectSource)  Freq=$($p.FreqFirst)  Logical=$($p.LogicalCores)"
Write-X3DWarnings $p
Get-X3DPinningAdvice $p

""
"=== bad force value is ignored ==="
$env:X3D_FORCE_PROFILE = 'NotARealChip'
Clear-X3DConfig
$p = Get-X3DProfile -NoCache
"Simulated=$($p.Simulated)"
Write-X3DWarnings $p

""
"=== Resolve-X3DTarget rejects an impossible env override ==="
Remove-Item Env:X3D_FORCE_PROFILE -ErrorAction SilentlyContinue
$env:X3D_FREQ_FIRST_CORE = '999'
Clear-X3DConfig
$r = Resolve-X3DTarget
"resolved FreqFirst=$($r.FreqFirst)  Limit=$($r.Limit)  Valid=$($r.Valid)"
Remove-Item Env:X3D_FREQ_FIRST_CORE -ErrorAction SilentlyContinue
