<#
    Enable-DiagnosticLogs.ps1
    ---------------------------------------------------------------
    Turns on the logs needed to catch periodic stutters:
      * TaskScheduler/Operational  - so we can see which task fired
      * Kernel-Processor-Power/... - power/parking state changes
    Read-mostly: only enables event logs, changes nothing else.
    RUN AS ADMINISTRATOR. No reboot needed.
#>

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host "ERROR: Run as Administrator." -ForegroundColor Red; return }

$logs = @(
    'Microsoft-Windows-TaskScheduler/Operational',
    'Microsoft-Windows-Kernel-Processor-Power/Diagnostic'
)

foreach ($log in $logs) {
    try {
        & wevtutil sl "$log" /enabled:true
        Write-Host "Enabled: $log" -ForegroundColor Green
    } catch {
        Write-Host "Could not enable $log : $_" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Done. These now record - re-run your test session, then Scan-Stutter-Events.ps1." -ForegroundColor Cyan
