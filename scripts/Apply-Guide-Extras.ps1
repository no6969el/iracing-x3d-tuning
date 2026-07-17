<#
    Apply-Guide-Extras.ps1
    ---------------------------------------------------------------
    Remaining low-risk guide items (#11):
      * USB Selective Suspend = OFF on the active power plan
        (stops your wheel/VR USB devices power-cycling mid-race -
         a real DPC-hitch source on this rig)
      * Windows Game Mode / Game Bar / Game DVR = OFF
    Safe and reversible (Undo-Guide-Extras.ps1). No reboot needed.
    HAGS is handled separately - see the note Claude gave you.
    RUN AS ADMINISTRATOR.
#>

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host "ERROR: Run as Administrator." -ForegroundColor Red; return }

Write-Host ""
Write-Host "1) USB Selective Suspend -> OFF (active power plan)" -ForegroundColor Cyan
$usbSub     = '2a737441-1930-4402-8d77-b2bebba308a3'
$usbSetting = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
try {
    powercfg /setacvalueindex SCHEME_CURRENT $usbSub $usbSetting 0 | Out-Null
    powercfg /setdcvalueindex SCHEME_CURRENT $usbSub $usbSetting 0 | Out-Null
    powercfg /setactive SCHEME_CURRENT | Out-Null
    Write-Host "   done - USB devices will no longer selectively suspend" -ForegroundColor Green
} catch { Write-Host "   ! failed: $($_.Exception.Message)" -ForegroundColor Yellow }

Write-Host ""
Write-Host "2) Game Mode / Game Bar / Game DVR -> OFF" -ForegroundColor Cyan
function Set-Reg($path, $name, $value) {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    New-ItemProperty -Path $path -Name $name -PropertyType DWord -Value $value -Force | Out-Null
}
try {
    Set-Reg 'HKCU:\System\GameConfigStore'            'GameDVR_Enabled'      0
    Set-Reg 'HKCU:\Software\Microsoft\GameBar'        'AutoGameModeEnabled'  0
    Set-Reg 'HKCU:\Software\Microsoft\GameBar'        'AllowAutoGameMode'    0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
    Write-Host "   done - Game Mode/Bar/DVR disabled" -ForegroundColor Green
} catch { Write-Host "   ! failed: $($_.Exception.Message)" -ForegroundColor Yellow }

Write-Host ""
Write-Host "Done. No reboot needed. (Undo with Undo-Guide-Extras.ps1)" -ForegroundColor Yellow
