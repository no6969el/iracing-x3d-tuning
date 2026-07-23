$env:APPDATA = '/tmp/appdata'
. "$PSScriptRoot/../scripts/X3D-Profiles.ps1"

$fail = 0
function Assert($cond, $msg) {
    if ($cond) { "    ok   $msg" }
    else       { "    FAIL $msg"; $script:fail++ }
}

$chips = @('5500X3D','5600X3D','5700X3D','5800X3D','7500X3D','7600X3D','7700X3D','7800X3D',
           '7900X3D','7950X3D','7945HX3D','9800X3D','9850X3D','9900X3D','9950X3D','9950X3D2','9955HX3D')

foreach ($chip in $chips) {
    $env:X3D_FORCE_PROFILE = $chip
    Remove-Item Env:X3D_FREQ_FIRST_CORE -ErrorAction SilentlyContinue
    Clear-X3DConfig
    $P = Get-X3DProfile -NoCache
    $lim = $P.LogicalCores

    "$chip  ($($P.Model))"

    # --- Set-GPU-IRQ-Affinity would use this ---
    Assert ($P.FreqFirst -ge 1 -and $P.FreqFirst -lt $lim) `
        "GPU IRQ target CPU $($P.FreqFirst) is inside 0..$($lim-1)"

    # mask must be representable in the 8-byte KAFFINITY the script writes
    $mask = ([uint64]1) -shl $P.FreqFirst
    Assert ($mask -ne 0 -and $P.FreqFirst -lt 64) "affinity mask 0x$('{0:X}' -f $mask) is valid"

    # --- Set-NIC-USB-IRQ-Affinity would use these ---
    $bad = @($P.IrqTargets | Where-Object { $_ -lt 1 -or $_ -ge $lim })
    Assert ($P.IrqTargets.Count -ge 1 -and $bad.Count -eq 0) `
        "NIC/USB targets [$($P.IrqTargets -join ',')] all inside 1..$($lim-1)"
    Assert ($P.IrqTargets -notcontains $P.FreqFirst) "NIC/USB targets avoid the GPU core"
    Assert ($P.IrqTargets -notcontains 0) "NIC/USB targets avoid CPU 0"

    # --- FullTrace split ---
    Assert ($P.FreqFirst -lt $lim) "FullTrace low/high split at $($P.FreqFirst) leaves both groups non-empty"

    # --- topology sanity ---
    if ($P.Topology -eq 'dual') {
        Assert ($P.FreqFirst -eq ($lim / 2)) "dual-CCD split is exactly half ($($P.FreqFirst) of $lim)"
        Assert ($P.VCacheRange -eq "0-$($P.FreqFirst - 1)") "V-Cache range $($P.VCacheRange) covers CCD0 only"
    } else {
        Assert ($P.VCacheRange -eq "0-$($lim - 1)") "single-CCD V-Cache range $($P.VCacheRange) covers every CPU"
    }
    Assert ($P.IsX3D) "recognised as an X3D part"
    Assert ($P.TopologyKnown) "topology is trusted"
    Assert ($P.Simulated) "simulated profile does not write to the registry"
    ""
}

"--- 9950X3D2 must NOT be mistaken for a 9950X3D ---"
$env:X3D_FORCE_PROFILE = '9950X3D2'; Clear-X3DConfig
$a = Get-X3DProfile -NoCache
$env:X3D_FORCE_PROFILE = '9950X3D'; Clear-X3DConfig
$b = Get-X3DProfile -NoCache
Assert ($a.VCacheScope -eq 'both')  "9950X3D2 -> VCacheScope 'both'"
Assert ($b.VCacheScope -eq 'ccd0')  "9950X3D  -> VCacheScope 'ccd0'"
Assert ($a.Model -ne $b.Model)      "models are distinct"
Assert ($a.FreqFirst -eq $b.FreqFirst) "both still pin the sim to one CCD (same split)"
""

"--- SMT-off style edge case: half the logical CPUs ---"
Remove-Item Env:X3D_FORCE_PROFILE -ErrorAction SilentlyContinue
Clear-X3DConfig
$cls = Get-X3DClasses | Where-Object { $_.Key -eq '1' }
$P = Get-X3DProfile -NoCache -Assume $cls
Assert ($P.FreqFirst -ge 0 -and $P.FreqFirst -lt [Math]::Max(2,$P.ActualLogical)) `
    "6-core class on a $($P.ActualLogical)-CPU host clamps to CPU $($P.FreqFirst) instead of 6"
Assert (-not $P.Simulated) "manual class pick is NOT treated as a simulation (writes stay enabled)"
""

"--- config round-trip ---"
Remove-Item Env:X3D_FORCE_PROFILE -ErrorAction SilentlyContinue
Clear-X3DConfig
$w = Get-X3DProfile -NoCache
Export-X3DConfig $w
$r = Import-X3DConfig
Assert ($r -ne $null) "saved profile reloads"
if ($r) { Assert ([int]$r.SchemaVersion -eq [int]$w.SchemaVersion) "schema version preserved ($($r.SchemaVersion))" }
# a config from a machine with a different CPU count must be rejected
$w.ActualLogical = 999; Export-X3DConfig $w
Assert ((Import-X3DConfig) -eq $null) "profile from a different CPU is rejected, not trusted"
Clear-X3DConfig
""

if ($fail) { "RESULT: $fail assertion(s) FAILED"; exit 1 } else { "RESULT: all assertions passed"; exit 0 }
