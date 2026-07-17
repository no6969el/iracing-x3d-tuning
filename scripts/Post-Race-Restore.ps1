<#
    Post-Race-Restore.ps1
    ---------------------------------------------------------------
    Re-enables everything Pre-Race-Quiet.ps1 turned off, so Windows
    Update / Search work normally again. Run AFTER every session.
    RUN AS ADMINISTRATOR.
#>

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host "ERROR: Run as Administrator." -ForegroundColor Red; return }

Write-Host ""
Write-Host "Restoring background tasks and services..." -ForegroundColor Cyan

$tasks = @(
    @{ Path='\Microsoft\Windows\InstallService\';               Name='ScanForUpdates' },
    @{ Path='\Microsoft\Windows\InstallService\';               Name='ScanForUpdatesAsUser' },
    @{ Path='\Microsoft\Windows\UpdateOrchestrator\';           Name='Schedule Scan' },
    @{ Path='\Microsoft\Windows\UpdateOrchestrator\';           Name='Schedule Scan Static Task' },
    @{ Path='\Microsoft\Windows\PushToInstall\';                Name='LoginCheck' },
    @{ Path='\Microsoft\Windows\PushToInstall\';                Name='Registration' },
    @{ Path='\Microsoft\Windows\LanguageComponentsInstaller\';  Name='ReconcileLanguageResources' }
)
foreach ($t in $tasks) {
    try {
        Enable-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction Stop | Out-Null
        Write-Host ("  enabled task: {0}{1}" -f $t.Path, $t.Name) -ForegroundColor Green
    } catch {
        Write-Host ("  (skip {0}{1})" -f $t.Path, $t.Name) -ForegroundColor DarkGray
    }
}
Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'MicrosoftEdgeUpdateTaskMachine*' } | ForEach-Object {
    try { $_ | Enable-ScheduledTask -ErrorAction Stop | Out-Null; Write-Host ("  enabled task: {0}" -f $_.TaskName) -ForegroundColor Green } catch {}
}

foreach ($svc in 'wuauserv','UsoSvc','WSearch') {
    try {
        Start-Service -Name $svc -ErrorAction Stop
        Write-Host ("  started service: {0}" -f $svc) -ForegroundColor Green
    } catch {
        Write-Host ("  ({0} will restart on its own / on next boot)" -f $svc) -ForegroundColor DarkGray
    }
}

# --- Defender real-time protection back ON ---
Write-Host ""
Write-Host "Re-enabling Defender real-time protection..." -ForegroundColor Cyan
if (Get-Command Set-MpPreference -ErrorAction SilentlyContinue) {
    try {
        Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
        Start-Sleep -Milliseconds 500
        if ((Get-MpComputerStatus).RealTimeProtectionEnabled) {
            Write-Host "  Defender real-time protection: RE-ENABLED" -ForegroundColor Green
        } else {
            Write-Host "  ! Defender real-time still OFF - re-enable it in Windows Security to be safe." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  ! could not re-enable via script - turn it back on in Windows Security: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Done - Windows Update, Search, and Defender are back to normal." -ForegroundColor Green
