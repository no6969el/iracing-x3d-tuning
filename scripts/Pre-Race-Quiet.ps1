<#
    Pre-Race-Quiet.ps1
    ---------------------------------------------------------------
    Silences the background tasks/services behind the classic periodic
    (~5-7 min cadence) micro-stalls (Windows Update scans, Edge update,
    PushToInstall, Windows Search) AND disables Defender real-time protection for the
    session (stops it scanning iRacing's file reads). Run BEFORE a session.

    Requires Tamper Protection = OFF for the Defender toggle to take.
    RUN AS ADMINISTRATOR.
    >>> Run Post-Race-Restore.ps1 afterward to turn everything back on <<<
    (leaving these off means Windows won't update or scan for threats).
#>

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host "ERROR: Run as Administrator." -ForegroundColor Red; return }

Write-Host ""
Write-Host "Quieting background tasks for a clean session..." -ForegroundColor Cyan

# --- scheduled tasks on the periodic-scan cadence ---
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
        Disable-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction Stop | Out-Null
        Write-Host ("  disabled task: {0}{1}" -f $t.Path, $t.Name) -ForegroundColor Green
    } catch {
        Write-Host ("  (skip {0}{1} - protected or not present)" -f $t.Path, $t.Name) -ForegroundColor DarkGray
    }
}
# Edge auto-update tasks (name varies by GUID)
Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'MicrosoftEdgeUpdateTaskMachine*' } | ForEach-Object {
    try { $_ | Disable-ScheduledTask -ErrorAction Stop | Out-Null; Write-Host ("  disabled task: {0}" -f $_.TaskName) -ForegroundColor Green } catch {}
}

# --- stop (not permanently disable) the update/search services ---
foreach ($svc in 'wuauserv','UsoSvc','WSearch') {
    try {
        Stop-Service -Name $svc -Force -ErrorAction Stop
        Write-Host ("  stopped service: {0}" -f $svc) -ForegroundColor Green
    } catch {
        Write-Host ("  (could not stop {0}: {1})" -f $svc, $_.Exception.Message) -ForegroundColor DarkGray
    }
}

# --- Defender real-time protection OFF for the session (needs Tamper Protection OFF) ---
Write-Host ""
Write-Host "Disabling Defender real-time protection for the session..." -ForegroundColor Cyan
if (Get-Command Set-MpPreference -ErrorAction SilentlyContinue) {
    try {
        Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
        Start-Sleep -Milliseconds 500
        if ((Get-MpComputerStatus).RealTimeProtectionEnabled) {
            Write-Host "  ! still ON - Tamper Protection is likely still enabled. Turn it off:" -ForegroundColor Yellow
            Write-Host "    Windows Security > Virus & threat protection > Manage settings > Tamper Protection = Off" -ForegroundColor Yellow
        } else {
            Write-Host "  Defender real-time protection: DISABLED for this session" -ForegroundColor Green
        }
    } catch {
        Write-Host "  ! could not disable (Tamper Protection on?): $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  (Defender cmdlets not available - skipping)" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Done - go race.  >>> RUN Post-Race-Restore.ps1 AFTER to turn Defender + services back on <<<" -ForegroundColor Yellow
