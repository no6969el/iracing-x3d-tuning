<#
    Check-Quiet-Status.ps1
    ---------------------------------------------------------------
    READ-ONLY. Shows whether "race quiet" is currently active - i.e.
    whether Pre-Race-Quiet's changes are in effect right now, or the
    background scans (Windows Update / Search) are running normally.
    No admin needed. Changes nothing.
#>

function State($label,$good,$goodText,$badText){
    if($good){ Write-Host ("  [{0}]  {1}: {2}" -f 'quiet',$label,$goodText) -ForegroundColor Green }
    else     { Write-Host ("  [ on ]  {0}: {1}" -f $label,$badText) -ForegroundColor Yellow }
}

Write-Host ""
Write-Host "  ================  RACE-QUIET STATUS  ================" -ForegroundColor Cyan
Write-Host ""

# --- services (the per-session lever; restart on reboot) ---
Write-Host "  Services:" -ForegroundColor Gray
$svcQuiet = $true
foreach($s in 'wuauserv','UsoSvc','WSearch'){
    $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
    if($svc){
        $stopped = ($svc.Status -eq 'Stopped')
        if(-not $stopped){ $svcQuiet = $false }
        State $s $stopped "stopped" ("running (" + $svc.Status + ")")
    } else { Write-Host "         $s not found" -ForegroundColor DarkGray }
}

# --- the update/scan scheduled tasks ---
Write-Host ""
Write-Host "  Scheduled tasks:" -ForegroundColor Gray
$tasks = @(
    @{ Path='\Microsoft\Windows\InstallService\';              Name='ScanForUpdates' },
    @{ Path='\Microsoft\Windows\UpdateOrchestrator\';          Name='Schedule Scan' },
    @{ Path='\Microsoft\Windows\UpdateOrchestrator\';          Name='Schedule Scan Static Task' },
    @{ Path='\Microsoft\Windows\PushToInstall\';               Name='LoginCheck' },
    @{ Path='\Microsoft\Windows\LanguageComponentsInstaller\'; Name='ReconcileLanguageResources' }
)
$tasksDisabled = 0; $tasksSeen = 0
foreach($t in $tasks){
    $obj = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue
    if($obj){
        $tasksSeen++
        $disabled = ($obj.State -eq 'Disabled')
        if($disabled){ $tasksDisabled++ }
        State $t.Name $disabled "disabled" ("enabled (" + $obj.State + ")")
    }
}

# --- Defender real-time ---
Write-Host ""
Write-Host "  Defender:" -ForegroundColor Gray
$rt = $null
try { $rt = (Get-MpComputerStatus -ErrorAction Stop).RealTimeProtectionEnabled } catch {}
if($rt -eq $false){ Write-Host "  [quiet]  Real-time protection: OFF" -ForegroundColor Green }
elseif($rt -eq $true){ Write-Host "  [ on ]  Real-time protection: ON" -ForegroundColor Yellow }
else { Write-Host "         Real-time protection: unknown" -ForegroundColor DarkGray }

# --- verdict ---
Write-Host ""
Write-Host "  ====================================================" -ForegroundColor Cyan
if($svcQuiet -and $tasksSeen -gt 0 -and $tasksDisabled -ge 1){
    Write-Host "  RACE-QUIET is ACTIVE - the scans are paused. Good to race." -ForegroundColor Green
} else {
    Write-Host "  NOT quieted - background scans can fire during a race." -ForegroundColor Yellow
    Write-Host "  Run Pre-Race-Quiet before you drive (then Post-Race-Restore after)." -ForegroundColor Yellow
}
Write-Host "  ====================================================" -ForegroundColor Cyan
Write-Host ""
Read-Host "  Press Enter to close" | Out-Null
