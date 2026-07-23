<#
    Enable-GlobalTimerResolution.ps1
    ---------------------------------------------------------------
    Fixes the "it stutters until I click the iRacing window" problem.

    Windows 11 only honors a game's high-resolution timer request while
    that game owns FOREGROUND focus. In VR, the compositor constantly
    steals focus from the sim window, so Windows drops the system timer
    from ~1 ms to its 15.625 ms default mid-race -> periodic frame-pacing
    hitches that stop the moment you click the sim window (focus returns,
    the timer snaps back). That click-to-fix pattern is the signature.
    (Confirm it first with Watch-TimerResolution.ps1 if you like.)

    This restores the pre-Windows-11 behavior: high-resolution timer
    requests are honored globally, whether or not the requester has focus.

    RUN AS ADMINISTRATOR. REBOOT for it to take effect.
    Reversible with Undo-GlobalTimerResolution.ps1.
#>

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host "ERROR: right-click PowerShell -> Run as Administrator, then re-run." -ForegroundColor Red; return }

$key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'

Write-Host ""
Write-Host "Enabling global high-resolution timer requests..." -ForegroundColor Cyan
try {
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -Path $key -Name 'GlobalTimerResolutionRequests' -PropertyType DWord -Value 1 -Force | Out-Null
    $v = (Get-ItemProperty -Path $key -Name 'GlobalTimerResolutionRequests').GlobalTimerResolutionRequests
    if ($v -eq 1) {
        Write-Host "  GlobalTimerResolutionRequests = 1  (set)" -ForegroundColor Green
    } else {
        Write-Host "  ! value reads back as $v - expected 1" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  ERROR writing registry: $($_.Exception.Message)" -ForegroundColor Red
    return
}

Write-Host ""
Write-Host "Done. REBOOT for it to take effect." -ForegroundColor Yellow
Write-Host "After the reboot, Watch-TimerResolution.ps1 should show ~1 ms or better" -ForegroundColor DarkGray
Write-Host "while the sim runs, even when the sim window doesn't have focus." -ForegroundColor DarkGray
