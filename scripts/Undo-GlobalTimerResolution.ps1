<#
    Undo-GlobalTimerResolution.ps1
    ---------------------------------------------------------------
    Reverts Enable-GlobalTimerResolution.ps1: removes the
    GlobalTimerResolutionRequests value so Windows 11 goes back to its
    default focus-dependent timer behavior.
    RUN AS ADMINISTRATOR. REBOOT for it to take effect.
#>

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host "ERROR: Run as Administrator." -ForegroundColor Red; return }

$key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'

if (Get-ItemProperty -Path $key -Name 'GlobalTimerResolutionRequests' -ErrorAction SilentlyContinue) {
    Remove-ItemProperty -Path $key -Name 'GlobalTimerResolutionRequests' -Force
    Write-Host "Removed GlobalTimerResolutionRequests - default behavior restored." -ForegroundColor Green
} else {
    Write-Host "GlobalTimerResolutionRequests not set - nothing to undo." -ForegroundColor DarkGray
}

Write-Host "Done. Reboot for it to take effect." -ForegroundColor Yellow
