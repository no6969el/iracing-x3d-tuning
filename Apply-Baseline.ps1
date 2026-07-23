<#
    Apply-Baseline.ps1  -  one-shot baseline optimizer
    ---------------------------------------------------------------
    For people who just want the fixes, fast. Do the Process Lasso
    steps FIRST (they're shown below, tailored to your chip), then
    let this apply every script fix in one go with one admin prompt.

      https://no6969el.github.io/iracing-x3d-tuning/

    Run Apply-Baseline.bat, or right-click this > Run with PowerShell.
    Prefer step-by-step with explanations? Use Start-Tuning-Menu.bat.

    Supports every X3D AMD has shipped (6/8-core single-CCD, 12/16-core
    dual-CCD, the dual-cached 9950X3D2, and the mobile HX3D parts).
    On a non-X3D CPU it applies the general fixes and skips the
    topology-specific ones.
#>

$ErrorActionPreference = 'SilentlyContinue'
$Root       = $PSScriptRoot
$ScriptsDir = Join-Path $Root 'scripts'

$H='Cyan'; $T='White'; $Go='Green'; $Warn='Yellow'; $Bad='Red'; $Dim='DarkGray'; $Sim='Magenta'
function Write-C { param([string]$Text,[string]$Color=$T) Write-Host $Text -ForegroundColor $Color }
function Bar  { Write-Host "  ============================================================" -ForegroundColor $H }
function Rule { Write-Host "  ------------------------------------------------------------" -ForegroundColor $Dim }

if (-not (Test-Path $ScriptsDir)) {
    Bar; Write-C "  Can't find the 'scripts' folder next to this file." $Bad
    Write-C "  Keep Apply-Baseline.ps1 in the kit folder as unzipped." $Dim
    [void](Read-Host "  Press Enter to close"); return
}

$mod = Join-Path $ScriptsDir 'X3D-Profiles.ps1'
if (-not (Test-Path $mod)) {
    Bar; Write-C "  scripts\X3D-Profiles.ps1 is missing - re-unzip the kit." $Bad
    [void](Read-Host "  Press Enter to close"); return
}
. $mod

# ---- identify the chip ------------------------------------------
$P = Get-X3DProfile

function Show-ChipPicker {
    Clear-Host; Bar; Write-C "        iRacing X3D Tuning   -   BASELINE OPTIMIZER" $H; Bar
    Write-C "  Which chip do you have?" $T
    Write-Host ""
    foreach ($c in Get-X3DClasses) {
        Write-C ("    [{0}] {1}" -f $c.Key, $c.Label) $T
        Write-C ("        {0}" -f $c.Examples) $Dim
    }
    Write-Host ""
    Write-C "    [A] Let it detect my CPU automatically" $Dim
    Write-Host ""
    $keys = @(@(Get-X3DClasses | ForEach-Object { $_.Key }) + 'A' + 'a')
    do { $sel = Read-Host "  Choose" } while ($sel -notin $keys)
    if ($sel -match '^[Aa]$') { return (Get-X3DProfile -NoCache) }
    $cls = Get-X3DClasses | Where-Object { $_.Key -eq $sel } | Select-Object -First 1
    if ($cls.Cores -lt 1) { return (Get-X3DProfile -NoCache) }   # "something else" = plain detection
    return (Get-X3DProfile -NoCache -Assume $cls)
}

# Ask only when detection is not confident; otherwise show and let them change it.
if (-not $P.Known -or -not $P.TopologyKnown) {
    $P = Show-ChipPicker
}

# ---- what can we actually apply on this chip? -------------------
$CanSteer = ($P.TopologyKnown -and $P.IsX3D -and $P.FreqFirst -ge 1 -and $P.FreqFirst -lt $P.ActualLogical)

$fixes = @(
    @{ title='Defender exclusions - stop mid-race file scans';  script='Add-Defender-Exclusions.ps1' },
    @{ title='USB Selective Suspend + Game Bar off';            script='Apply-Guide-Extras.ps1' },
    @{ title='Diagnostic log on (for the stutter scanner)';     script='Enable-DiagnosticLogs.ps1' },
    @{ title='Timer fix - the VR focus stutter';                script='Enable-GlobalTimerResolution.ps1' }
)
if ($CanSteer) {
    $fixes += @{ title="GPU interrupts off the sim core (-> CPU $($P.FreqFirst))"; script='Set-GPU-IRQ-Affinity.ps1' }
}

# ---- advisory ----------------------------------------------------
Clear-Host; Bar; Write-C "        iRacing X3D Tuning   -   BASELINE OPTIMIZER" $H; Bar
Write-C ("  Detected: {0}" -f $P.Model) $Go
Write-C ("            {0}" -f $P.Profile) $Dim
Write-C ("            {0}" -f (Get-X3DTopologySummary $P)) $Dim
if ($P.Simulated) { Write-Host ""; Write-C "  SIMULATED PROFILE ACTIVE (X3D_FORCE_PROFILE) - fixes will DRY-RUN only." $Sim }
Write-Host ""
Write-C "  Applies in ONE go:" $T
Write-Host ""
foreach ($f in $fixes) { Write-C ("    * " + $f.title) $Dim }
if (-not $CanSteer) {
    Write-C "    (GPU interrupt steering skipped - not applicable on this CPU)" $Dim
}
Write-Host ""

if ($P.IsX3D -and $P.Topology -ne 'single') {
    Write-C "  Did you do the Process Lasso part first? (free, bitsum.com)" $Warn
    foreach ($line in ((Get-X3DPinningAdvice $P) -split "`n")) { Write-C ("    " + $line.TrimEnd()) $T }
    Write-C "    Exact clicks: Step 2 on the web guide (repo front page)." $Dim
} elseif ($P.IsX3D) {
    Write-C "  Single-CCD chip: nothing to set up first." $Go
    Write-C "    (No core pinning - every core already has the V-Cache.)" $Dim
    Write-C "    * No core pinning - all your cores have the V-Cache." $T
    Write-C "    * Keep your normal Balanced power plan (do NOT force" $T
    Write-C "      all-cores-unparked - that's a dual-CCD-only fix)." $T
} else {
    Write-C "  No 3D V-Cache detected on this CPU." $Warn
    Write-C "    * The general fixes below still apply and still help." $T
    Write-C "    * Core pinning and interrupt steering are skipped." $T
}

if ($P.Warnings -and $P.Warnings.Count) {
    Write-Host ""
    Write-X3DWarnings $P '  '
}

Write-Host ""
Write-C "  Good to know:" $H
Write-C "    * These change Windows settings (registry, power, Defender)." $T
Write-C "    * Every change has an Undo (see Start-Tuning-Menu > Advanced)." $T
Write-C "    * ONE blue admin prompt will appear - choose Yes." $T
Write-C "    * A window shows each fix as it runs, then closes itself." $T
Write-C "    * REBOOT afterward to make everything live." $T
Write-Host ""
Rule
$go = Read-Host "  [Enter] apply the baseline    [C] change chip    [Q] quit"
if ($go -match '^[Qq]') { return }
if ($go -match '^[Cc]') {
    $P = Show-ChipPicker
    Export-X3DConfig $P
    Write-C "  Chip profile updated - re-run Apply-Baseline to continue." $Go
    Start-Sleep -Seconds 2
    return
}

# ---- run every fix in one elevated window, no typing -------------
$items = @()
foreach ($f in $fixes) {
    $p = Join-Path $ScriptsDir $f.script
    if (Test-Path $p) { $items += [pscustomobject]@{ Title=$f.title; Path=$p } }
    else { Write-C ("  ! missing: {0} (skipped)" -f $f.script) $Warn }
}
$sb = ("`$env:X3D_FREQ_FIRST_CORE='{0}'; `$env:X3D_SIMULATED='{1}'; `$Host.UI.RawUI.WindowTitle='iRacing X3D Tuning - applying baseline';" -f $P.FreqFirst, $(if ($P.Simulated) { '1' } else { '0' }))
if ($P.Simulated) { $sb += (" `$env:X3D_FORCE_PROFILE='{0}';" -f $env:X3D_FORCE_PROFILE) }
$n = 0
foreach ($it in $items) {
    $n++
    $ttl = $it.Title -replace "'","''"    # NB: not $t - would clobber the $T color var (PS vars are case-insensitive)
    $pth = $it.Path  -replace "'","''"
    $sb += (" Write-Host ''; Write-Host ('=' * 60) -ForegroundColor DarkCyan; Write-Host '[{0}/{1}]  {2}' -ForegroundColor Cyan; & '{3}';" -f $n,$items.Count,$ttl,$pth)
}
$sb += " Write-Host ''; Write-Host 'BASELINE APPLIED - this window closes in 5 seconds...' -ForegroundColor Green; Start-Sleep 5"
$ok = $true
try {
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($sb))
    Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc"
} catch { $ok = $false }

Clear-Host; Bar
if (-not $ok) {
    Write-C "  Admin prompt was cancelled - no changes were made." $Warn
    Write-C "  Run this again any time." $Dim
    Bar; [void](Read-Host "  Press Enter to close"); return
}
Write-C "  BASELINE APPLIED." $Go
Write-Host ""
if ($CanSteer) {
    Write-C "  1) REBOOT now - the GPU-interrupt and timer fixes need it." $H
} else {
    Write-C "  1) REBOOT now - the timer fix needs it." $H
}
Write-C "  2) After the reboot, prove it worked (optional): run this" $T
Write-C "     again and press T, or use Start-Tuning-Menu > Troubleshoot." $T
Write-C "     FullTrace logs your race to a CSV - no skipped seconds in" $T
Write-C "     the timestamps = no stalls." $T
Write-C "  3) Once it's smooth, do the graphics pass last: Step 6 on" $T
Write-C "     the web guide (iRacing + NVIDIA settings, VR tips)." $T
Write-Host ""
Rule
$a = Read-Host "  [Enter] finish    [T] launch FullTrace now (race, then Ctrl+C)"
if ($a -match '^[Tt]') {
    $ft = Join-Path $ScriptsDir 'FullTrace.ps1'
    if (Test-Path $ft) {
        Start-Process powershell.exe -ArgumentList "-NoExit -ExecutionPolicy Bypass -File `"$ft`""
        Write-C "  FullTrace launched in its own window. Go race, then Ctrl+C." $Go
        Write-C "  (Best AFTER the reboot - fixes aren't fully live until then.)" $Warn
        Start-Sleep -Seconds 3
    } else {
        Write-C "  Couldn't find scripts\FullTrace.ps1" $Bad; Start-Sleep -Seconds 2
    }
}
Write-C "  Smooth laps." $Go
Start-Sleep -Seconds 1
