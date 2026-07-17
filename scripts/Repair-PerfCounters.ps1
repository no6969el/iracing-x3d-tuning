<#
    Repair-PerfCounters.ps1
    ---------------------------------------------------------------
    Your Windows performance counters are broken - every counter-based
    column in the trace came back empty (per-core load, interrupt/DPC
    time, pagefaults). That's also why Get-Counter failed earlier. This
    rebuilds them so we can actually measure the CCD split, confirm the
    GPU-interrupt move, and see which driver causes the periodic hitch.

    RUN AS ADMINISTRATOR, then REBOOT.
#>

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host "ERROR: Run as Administrator." -ForegroundColor Red; return }

Write-Host "Rebuilding performance counter registry (64-bit)..." -ForegroundColor Cyan
& "$env:windir\system32\lodctr.exe" /R

Write-Host "Rebuilding performance counter registry (32-bit)..." -ForegroundColor Cyan
& "$env:windir\syswow64\lodctr.exe" /R

Write-Host "Refreshing WMI performance classes (WMIADAP)..." -ForegroundColor Cyan
$wmiadap = "$env:windir\system32\wbem\wmiadap.exe"
if (Test-Path $wmiadap) {
    & $wmiadap /f
    Write-Host "  wmiadap /f done" -ForegroundColor Green
} else {
    Write-Host "  wmiadap.exe not found - skipping (the lodctr /R above is the main fix)" -ForegroundColor DarkGray
}
# best-effort WMI perf resync if the command is available on PATH
$wm = Get-Command winmgmt -ErrorAction SilentlyContinue
if ($wm) { try { & winmgmt /resyncperf } catch { } }

Write-Host ""
Write-Host "Done. REBOOT, then re-run Preflight-Check - the per-core columns should populate." -ForegroundColor Green
Write-Host "If they still don't, tell me and we'll try the deeper rebuild (sc / WMI repository)." -ForegroundColor DarkGray
