<#
    Apply-Baseline.ps1  -  one-shot baseline optimizer
    ---------------------------------------------------------------
    For people who just want the fixes, fast. Do the Process Lasso
    steps FIRST (they're on the Quick Baseline page), then run this:
    it applies every script fix in one go with a single admin prompt.

      https://no6969el.github.io/iracing-x3d-tuning/

    Run Apply-Baseline.bat, or right-click this > Run with PowerShell.
    Prefer step-by-step with explanations? Use Start-Tuning-Menu.bat.
#>

$ErrorActionPreference = 'SilentlyContinue'
$Root       = $PSScriptRoot
$ScriptsDir = Join-Path $Root 'scripts'
$ConfigFile = Join-Path $env:APPDATA 'iRacingX3DTuning\config.json'

$H='Cyan'; $T='White'; $Go='Green'; $Warn='Yellow'; $Bad='Red'; $Dim='DarkGray'
function Write-C { param([string]$Text,[string]$Color=$T) Write-Host $Text -ForegroundColor $Color }
function Bar  { Write-Host "  ============================================================" -ForegroundColor $H }
function Rule { Write-Host "  ------------------------------------------------------------" -ForegroundColor $Dim }

$fixes = @(
    @{ title='Defender exclusions - stop mid-race file scans';  script='Add-Defender-Exclusions.ps1' },
    @{ title='USB Selective Suspend + Game Bar off';            script='Apply-Guide-Extras.ps1' },
    @{ title='Diagnostic log on (for the stutter scanner)';     script='Enable-DiagnosticLogs.ps1' },
    @{ title='Timer fix - the VR focus stutter';                script='Enable-GlobalTimerResolution.ps1' },
    @{ title='GPU interrupts off the sim core';                 script='Set-GPU-IRQ-Affinity.ps1' }
)

if(-not (Test-Path $ScriptsDir)){
    Bar; Write-C "  Can't find the 'scripts' folder next to this file." $Bad
    Write-C "  Keep Apply-Baseline.ps1 in the kit folder as unzipped." $Dim
    [void](Read-Host "  Press Enter to close"); return
}

# ---- core profile: saved config if the menu has run, else ask once ----
$FreqFirst = 0
if(Test-Path $ConfigFile){ try { $FreqFirst = [int](Get-Content $ConfigFile -Raw | ConvertFrom-Json).FreqFirst } catch {} }
if($FreqFirst -lt 1){
    Clear-Host; Bar; Write-C "        iRacing X3D Tuning   -   BASELINE OPTIMIZER" $H; Bar
    Write-C "  Which dual-CCD X3D do you have?" $T
    Write-C "    [1] 16-core  (9950X3D / 7950X3D)" $T
    Write-C "    [2] 12-core  (9900X3D / 7900X3D)" $T
    do { $sel = Read-Host "  Choose 1 or 2" } while ($sel -notin '1','2')
    $FreqFirst = if($sel -eq '1'){ 16 } else { 12 }
}
$VCache = "0-$($FreqFirst - 1)"

# ---- advisory ----
Clear-Host; Bar; Write-C "        iRacing X3D Tuning   -   BASELINE OPTIMIZER" $H; Bar
Write-C "  Applies the full script baseline in ONE go:" $T
Write-Host ""
foreach($f in $fixes){ Write-C ("    * " + $f.title) $Dim }
Write-Host ""
Write-C "  Did you do the Process Lasso part first? (free, bitsum.com)" $Warn
Write-C "    * Power plan: activate  Bitsum Highest Performance" $T
Write-C ("    * Pin iRacing to V-Cache cores {0} (CPU Sets) + exclude" -f $VCache) $T
Write-C "      it from ProBalance. (Launch iRacing into a race once so" $T
Write-C "      iRacingSim64DX11.exe shows in Process Lasso's list.)" $T
Write-C "    Exact clicks: Step 2 on the web guide (repo front page)." $Dim
Write-Host ""
Write-C "  Good to know:" $H
Write-C "    * These change Windows settings (registry, power, Defender)." $T
Write-C "    * Every change has an Undo (see Start-Tuning-Menu > Advanced)." $T
Write-C "    * ONE blue admin prompt will appear - choose Yes." $T
Write-C "    * A window shows each fix as it runs, then closes itself." $T
Write-C "    * REBOOT afterward to make everything live." $T
Write-Host ""
Rule
if((Read-Host "  [Enter] apply the baseline    [Q] quit") -match '^[Qq]'){ return }

# ---- run every fix in one elevated window, no typing ----
$items = @()
foreach($f in $fixes){
    $p = Join-Path $ScriptsDir $f.script
    if(Test-Path $p){ $items += [pscustomobject]@{ Title=$f.title; Path=$p } }
    else { Write-C ("  ! missing: {0} (skipped)" -f $f.script) $Warn }
}
$sb = ("`$env:X3D_FREQ_FIRST_CORE='{0}'; `$Host.UI.RawUI.WindowTitle='iRacing X3D Tuning - applying baseline';" -f $FreqFirst)
$n = 0
foreach($it in $items){
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
if(-not $ok){
    Write-C "  Admin prompt was cancelled - no changes were made." $Warn
    Write-C "  Run this again any time." $Dim
    Bar; [void](Read-Host "  Press Enter to close"); return
}
Write-C "  BASELINE APPLIED." $Go
Write-Host ""
Write-C "  1) REBOOT now - the GPU-interrupt and timer fixes need it." $H
Write-C "  2) After the reboot, prove it worked (optional): run this" $T
Write-C "     again and press T, or use Start-Tuning-Menu > Troubleshoot." $T
Write-C "     FullTrace logs your race to a CSV - no skipped seconds in" $T
Write-C "     the timestamps = no stalls." $T
Write-C "  3) Once it's smooth, do the graphics pass last: Step 6 on" $T
Write-C "     the web guide (iRacing + NVIDIA settings, VR tips)." $T
Write-Host ""
Rule
$a = Read-Host "  [Enter] finish    [T] launch FullTrace now (race, then Ctrl+C)"
if($a -match '^[Tt]'){
    $ft = Join-Path $ScriptsDir 'FullTrace.ps1'
    if(Test-Path $ft){
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
