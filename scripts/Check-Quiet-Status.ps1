<#
    Check-Quiet-Status.ps1                                    v3.3.0
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

    v3.3.0 adds the five services and nineteen tasks that an xperf
    HARD_FAULTS trace showed firing during a real session - chiefly the
    Microsoft Store's app auto-update, which was the largest single
    non-kernel source of hard faults and which v3.2.5 did not cover.
    It also reports the Store auto-download policy.

    The verdict requires EVERY visible task to be off. Anything still
    live is listed by full path so you know exactly what to chase.
#>

function State($label,$good,$goodText,$badText){
    if($good){ Write-Host ("  [quiet]  {0}: {1}" -f $label,$goodText) -ForegroundColor Green }
    else     { Write-Host ("  [ on  ]  {0}: {1}" -f $label,$badText) -ForegroundColor Yellow }
}

$StateFile = Join-Path $env:ProgramData 'RaceQuiet\state.json'
$SvcRoot   = 'HKLM:\SYSTEM\CurrentControlSet\Services'
$StartName = @{ 0='Boot'; 1='System'; 2='Automatic'; 3='Manual'; 4='Disabled' }

# The service and task lists come from Kit-Common.ps1, the same file
# Pre-Race-Quiet reads. This screen can no longer disagree with what the
# quiet script actually does - which is exactly the v3.2.5 bug.
$common = Join-Path $PSScriptRoot 'Kit-Common.ps1'
if (-not (Test-Path $common)) {
    Write-Host ""
    Write-Host "  scripts\Kit-Common.ps1 is missing - re-unzip the kit." -ForegroundColor Red
    Write-Host ""
    return
}
. $common
# Provides: $KitVersion, $ServicesToQuiet, $TasksToDisable, $ServiceDefaults

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
foreach($s in $ServicesToQuiet){
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
$tasks = $TasksToDisable

# Not every task exists on every build. Windows 10 has no WindowsAI\Settings,
# some builds have no Flighting tasks. A task that isn't there can't fire, so
# it is counted separately and never held against the verdict.
$tasksDisabled = 0; $tasksSeen = 0; $tasksMissing = 0; $medicOn = $false
$stillOn = @()
foreach($t in $tasks){
    $obj = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue
    if(-not $obj){ $tasksMissing++; continue }
    $tasksSeen++
    $disabled = ($obj.State -eq 'Disabled')
    if($disabled){ $tasksDisabled++ }
    else {
        $stillOn += $t
        if($t.Name -eq 'PerformRemediation'){ $medicOn = $true }
    }
    State $t.Name $disabled "disabled" ("enabled (" + $obj.State + ")")
}

Write-Host ""
if ($tasksSeen -eq 0) {
    Write-Host "           none visible - run this from an ELEVATED prompt;" -ForegroundColor DarkGray
    Write-Host "           the WaaSMedic tasks are hidden from a normal user." -ForegroundColor DarkGray
} else {
    $col = if ($tasksDisabled -eq $tasksSeen) { 'Green' } else { 'Yellow' }
    Write-Host ("           {0} of {1} disabled" -f $tasksDisabled, $tasksSeen) -ForegroundColor $col
    if ($tasksMissing -gt 0) {
        Write-Host ("           {0} not present on this Windows build (nothing to do)" -f $tasksMissing) -ForegroundColor DarkGray
    }
}

# --- Microsoft Store auto-download policy ---
Write-Host ""
Write-Host "  Microsoft Store:" -ForegroundColor Gray
$storeVal = $null
try { $storeVal = [int](Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -Name 'AutoDownload' -ErrorAction Stop).AutoDownload } catch { }
$storeQuiet = ($storeVal -eq 2)
if ($storeQuiet) { Write-Host "  [quiet]  App auto-download: disabled by policy" -ForegroundColor Green }
elseif ($null -eq $storeVal) { Write-Host "  [ on  ]  App auto-download: no policy set (Store may update mid-race)" -ForegroundColor Yellow }
else { Write-Host ("  [ on  ]  App auto-download: policy value {0}" -f $storeVal) -ForegroundColor Yellow }

# --- noisy user apps seen faulting in the reference trace ---
$noisy = @('Telegram','MOZA Pit House','msedgewebview2')
$running = @()
foreach ($n in $noisy) { if (@(Get-Process -Name $n -ErrorAction SilentlyContinue).Count -gt 0) { $running += $n } }
if ($running.Count -gt 0) {
    Write-Host ""
    Write-Host "  Background apps:" -ForegroundColor Gray
    foreach ($r in $running) { Write-Host ("  [ on  ]  {0} is running" -f $r) -ForegroundColor Yellow }
    Write-Host "           Close them, or run Pre-Race-Quiet -CloseApps" -ForegroundColor DarkGray
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
$allTasksOff = ($tasksSeen -gt 0 -and $tasksDisabled -eq $tasksSeen)
if($svcQuiet -and $allTasksOff -and -not $storeQuiet){
    Write-Host "  QUIET, EXCEPT THE STORE." -ForegroundColor Yellow
    Write-Host "  Services and tasks are down, but Store app auto-download is not" -ForegroundColor Yellow
    Write-Host "  disabled. That was the single largest non-kernel source of hard" -ForegroundColor Yellow
    Write-Host "  faults in the reference trace - 829 of them. Re-run Pre-Race-Quiet." -ForegroundColor Yellow
} elseif($svcQuiet -and $allTasksOff){
    if ($anyManual) {
        Write-Host "  QUIET, BUT NOT LOCKED DOWN." -ForegroundColor Yellow
        Write-Host "  Some services are stopped yet still set to Manual/Automatic," -ForegroundColor Yellow
        Write-Host "  so Windows can restart them mid-race. Re-run Pre-Race-Quiet" -ForegroundColor Yellow
        Write-Host ("  (v{0} or later) to disable them properly." -f $KitVersion) -ForegroundColor Yellow
    } else {
        Write-Host "  RACE-QUIET is ACTIVE - the scans are paused. Good to race." -ForegroundColor Green
    }
    if ($medicOn) {
        Write-Host ""
        Write-Host "  ! WaaSMedic\PerformRemediation is still ENABLED. That is the" -ForegroundColor Yellow
        Write-Host "    task that re-enables Windows Update about 10 minutes after" -ForegroundColor Yellow
        Write-Host "    you quiet it. Re-run Pre-Race-Quiet as admin." -ForegroundColor Yellow
    }
} elseif ($svcQuiet -and $tasksSeen -gt 0) {
    Write-Host "  PARTLY QUIET - the services are down but tasks are still live." -ForegroundColor Yellow
    Write-Host ("  {0} of {1} scheduled task(s) can still fire mid-race:" -f ($tasksSeen - $tasksDisabled), $tasksSeen) -ForegroundColor Yellow
    foreach ($o in $stillOn) { Write-Host ("     {0}{1}" -f $o.Path, $o.Name) -ForegroundColor Yellow }
    Write-Host "  Re-run Pre-Race-Quiet AS ADMIN. If any of these survive that," -ForegroundColor Yellow
    Write-Host "  run Trace-QuietReverts.ps1 elevated to find out what is holding them." -ForegroundColor Yellow
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
