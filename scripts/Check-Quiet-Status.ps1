<#
    Check-Quiet-Status.ps1                                    v3.0.0
    ---------------------------------------------------------------
    READ-ONLY. Shows whether "race quiet" is active right now.
    No admin needed. Changes nothing.

    Since v3.0.0 Pre-Race-Quiet DISABLES the services rather than just
    stopping them, so this now reports the startup type as well as the
    running state - a stopped-but-Manual service is the exact condition
    that let Windows restart it mid-race.

    It also tells you whether an un-restored snapshot is sitting in
    C:\ProgramData\RaceQuiet, which is the definitive answer to
    "am I still quieted?"
#>

function State($label,$good,$goodText,$badText){
    if($good){ Write-Host ("  [quiet]  {0}: {1}" -f $label,$goodText) -ForegroundColor Green }
    else     { Write-Host ("  [ on  ]  {0}: {1}" -f $label,$badText) -ForegroundColor Yellow }
}

$StateFile = Join-Path $env:ProgramData 'RaceQuiet\state.json'
$SvcRoot   = 'HKLM:\SYSTEM\CurrentControlSet\Services'
$StartName = @{ 0='Boot'; 1='System'; 2='Automatic'; 3='Manual'; 4='Disabled' }

Write-Host ""
Write-Host "  ================  RACE-QUIET STATUS  ================" -ForegroundColor Cyan
Write-Host ""

# --- is there an un-restored session? ---
$snap = $null
if (Test-Path $StateFile) {
    try { $snap = Get-Content $StateFile -Raw | ConvertFrom-Json } catch { }
}
if ($snap) {
    Write-Host ("  Snapshot present - quieted at {0} UTC and NOT yet restored." -f $snap.CreatedUtc) -ForegroundColor Green
} else {
    Write-Host "  No snapshot - this PC is not currently quieted by the kit." -ForegroundColor DarkGray
}
Write-Host ""

# --- services: running state AND startup type ---
Write-Host "  Services:" -ForegroundColor Gray
$svcQuiet = $true
$anyManual = $false
foreach($s in 'WaaSMedicSvc','UsoSvc','wuauserv','bits','DoSvc','WSearch'){
    $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
    if(-not $svc){ Write-Host "           $s not present on this build" -ForegroundColor DarkGray; continue }

    $start = $null
    try { $start = [int](Get-ItemProperty -Path (Join-Path $SvcRoot $s) -Name 'Start' -ErrorAction Stop).Start } catch { }
    $startTxt = '?'
    if ($null -ne $start -and $StartName.ContainsKey($start)) { $startTxt = $StartName[$start] }

    $stopped  = ($svc.Status -eq 'Stopped')
    $disabled = ($start -eq 4)
    if(-not $stopped){ $svcQuiet = $false }
    if($stopped -and -not $disabled){ $anyManual = $true }

    if ($stopped -and $disabled) {
        State $s $true "stopped + Disabled (cannot come back)" ""
    } elseif ($stopped) {
        Write-Host ("  [ ~~  ]  {0}: stopped, but startup type is {1} - Windows can restart it" -f $s,$startTxt) -ForegroundColor Yellow
    } else {
        State $s $false "" ("running (startup type " + $startTxt + ")")
    }
}

# --- scheduled tasks ---
Write-Host ""
Write-Host "  Scheduled tasks:" -ForegroundColor Gray
$tasks = @(
    @{ Path='\Microsoft\Windows\WaaSMedic\';                   Name='PerformRemediation' },
    @{ Path='\Microsoft\Windows\UpdateOrchestrator\';          Name='Schedule Scan' },
    @{ Path='\Microsoft\Windows\UpdateOrchestrator\';          Name='Schedule Scan Static Task' },
    @{ Path='\Microsoft\Windows\UpdateOrchestrator\';          Name='Universal Orchestrator Start' },
    @{ Path='\Microsoft\Windows\UpdateOrchestrator\';          Name='Report policies' },
    @{ Path='\Microsoft\Windows\InstallService\';              Name='ScanForUpdates' },
    @{ Path='\Microsoft\Windows\PushToInstall\';               Name='LoginCheck' },
    @{ Path='\Microsoft\Windows\LanguageComponentsInstaller\'; Name='ReconcileLanguageResources' }
)
$tasksDisabled = 0; $tasksSeen = 0; $medicOn = $false
foreach($t in $tasks){
    $obj = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue
    if(-not $obj){ continue }
    $tasksSeen++
    $disabled = ($obj.State -eq 'Disabled')
    if($disabled){ $tasksDisabled++ }
    elseif($t.Name -eq 'PerformRemediation'){ $medicOn = $true }
    State $t.Name $disabled "disabled" ("enabled (" + $obj.State + ")")
}
if ($tasksSeen -eq 0) {
    Write-Host "           none visible - run this from an ELEVATED prompt;" -ForegroundColor DarkGray
    Write-Host "           the WaaSMedic tasks are hidden from a normal user." -ForegroundColor DarkGray
}

# --- Defender ---
Write-Host ""
Write-Host "  Defender:" -ForegroundColor Gray
$rt = $null
try { $rt = (Get-MpComputerStatus -ErrorAction Stop).RealTimeProtectionEnabled } catch {}
if($rt -eq $false){ Write-Host "  [quiet]  Real-time protection: OFF" -ForegroundColor Green }
elseif($rt -eq $true){ Write-Host "  [ on  ]  Real-time protection: ON" -ForegroundColor Yellow }
else { Write-Host "           Real-time protection: unknown" -ForegroundColor DarkGray }

# --- verdict ---
Write-Host ""
Write-Host "  ====================================================" -ForegroundColor Cyan
if($svcQuiet -and $tasksSeen -gt 0 -and $tasksDisabled -ge 1){
    if ($anyManual) {
        Write-Host "  QUIET, BUT NOT LOCKED DOWN." -ForegroundColor Yellow
        Write-Host "  Some services are stopped yet still set to Manual/Automatic," -ForegroundColor Yellow
        Write-Host "  so Windows can restart them mid-race. Re-run Pre-Race-Quiet" -ForegroundColor Yellow
        Write-Host "  (v3.0.0 or later) to disable them properly." -ForegroundColor Yellow
    } else {
        Write-Host "  RACE-QUIET is ACTIVE - the scans are paused. Good to race." -ForegroundColor Green
    }
    if ($medicOn) {
        Write-Host ""
        Write-Host "  ! WaaSMedic\PerformRemediation is still ENABLED. That is the" -ForegroundColor Yellow
        Write-Host "    task that re-enables Windows Update about 10 minutes after" -ForegroundColor Yellow
        Write-Host "    you quiet it. Re-run Pre-Race-Quiet as admin." -ForegroundColor Yellow
    }
} else {
    Write-Host "  NOT quieted - background scans can fire during a race." -ForegroundColor Yellow
    Write-Host "  Run Pre-Race-Quiet before you drive (then Post-Race-Restore after)." -ForegroundColor Yellow
}
if ($snap) {
    Write-Host ""
    Write-Host "  Remember: Post-Race-Restore is required. Until it runs, this PC" -ForegroundColor Yellow
    Write-Host "  has no Windows Update and no fresh Defender definitions." -ForegroundColor Yellow
}
Write-Host "  ====================================================" -ForegroundColor Cyan
Write-Host ""
Read-Host "  Press Enter to close" | Out-Null
