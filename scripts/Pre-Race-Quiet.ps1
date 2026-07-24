<#
    Pre-Race-Quiet.ps1                                        v3.0.0
    ================================================================
    Silences the background work behind the classic periodic micro-stalls
    (Windows Update scans, Update Orchestrator, Edge updates, PushToInstall,
    Windows Search) and optionally turns off Defender real-time protection
    for the session.

    WHY THIS VERSION EXISTS
    -----------------------
    Earlier versions only STOPPED the services. A stopped service keeps its
    startup type, so the first API call restarts it - and Windows Update
    Medic (WaaSMedicSvc) exists specifically to detect a tampered-with update
    stack and repair it, on roughly a 10-minute cadence. Users reported the
    services coming back mid-race and stuttering when they did.

    This version:
      * DISABLES the services (Start=4) instead of stopping them
      * clears each service's failure/recovery actions, so a force-stop
        can't trigger an auto-restart
      * disables WaaSMedic\PerformRemediation, the task that drives the
        ~10-minute revert
      * snapshots the ACTUAL prior state first, so the restore puts things
        back exactly as they were rather than guessing at defaults

    >>> BECAUSE THIS SURVIVES A REBOOT, Post-Race-Restore.ps1 IS REQUIRED. <<<
    Leaving it un-restored means no Windows Update and - since Defender
    signature updates ride on wuauserv/BITS - stale virus definitions.

    USAGE
      .\Pre-Race-Quiet.ps1                 normal run
      .\Pre-Race-Quiet.ps1 -Verify         re-check after 3 min that nothing came back
      .\Pre-Race-Quiet.ps1 -KeepSearch     leave Windows Search alone
      .\Pre-Race-Quiet.ps1 -SkipDefender   leave Defender real-time alone
      .\Pre-Race-Quiet.ps1 -Deadman        auto-restore at next boot if you forget
      .\Pre-Race-Quiet.ps1 -Force          re-snapshot over a stale state file
      .\Pre-Race-Quiet.ps1 -NoSystem       don't use the SYSTEM helper

    Self-elevates. Requires Tamper Protection OFF for the Defender part.
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$SkipDefender,
    [switch]$KeepSearch,
    [switch]$NoSystem,
    [switch]$Verify,
    [int]   $VerifyDelay = 180,
    [switch]$Deadman
)

# ================================================================
#  EDIT HERE if you want to trim what gets quieted.
#  Order matters: Medic first so it can't react to the rest.
# ================================================================
$ServicesToQuiet = @(
    'WaaSMedicSvc',   # Update Medic - the thing that undoes all of this
    'UsoSvc',         # Update Orchestrator
    'wuauserv',       # Windows Update
    'bits',           # Background Intelligent Transfer (update downloads)
    'DoSvc',          # Delivery Optimization
    'WSearch'         # Windows Search  (skipped with -KeepSearch)
)

$TasksToDisable = @(
    @{ Path='\Microsoft\Windows\WaaSMedic\';                    Name='PerformRemediation' },
    @{ Path='\Microsoft\Windows\UpdateOrchestrator\';           Name='Schedule Scan' },
    @{ Path='\Microsoft\Windows\UpdateOrchestrator\';           Name='Schedule Scan Static Task' },
    @{ Path='\Microsoft\Windows\UpdateOrchestrator\';           Name='Universal Orchestrator Start' },
    @{ Path='\Microsoft\Windows\UpdateOrchestrator\';           Name='Report policies' },
    @{ Path='\Microsoft\Windows\UpdateOrchestrator\';           Name='UUS Failover Task' },
    @{ Path='\Microsoft\Windows\InstallService\';               Name='ScanForUpdates' },
    @{ Path='\Microsoft\Windows\InstallService\';               Name='ScanForUpdatesAsUser' },
    @{ Path='\Microsoft\Windows\PushToInstall\';                Name='LoginCheck' },
    @{ Path='\Microsoft\Windows\PushToInstall\';                Name='Registration' },
    @{ Path='\Microsoft\Windows\LanguageComponentsInstaller\';  Name='ReconcileLanguageResources' }
)

# ================================================================
$StateDir  = Join-Path $env:ProgramData 'RaceQuiet'
$StateFile = Join-Path $StateDir 'state.json'
$LogFile   = Join-Path $StateDir 'RaceQuiet.log'
$SvcRoot   = 'HKLM:\SYSTEM\CurrentControlSet\Services'

function Write-Log {
    param([string]$Msg, [string]$Color = 'Gray', [switch]$NoHost)
    $line = ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg)
    try {
        if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
        Add-Content -Path $LogFile -Value $line -Encoding utf8 -ErrorAction SilentlyContinue
    } catch { }
    if (-not $NoHost) { Write-Host ("  " + $Msg) -ForegroundColor $Color }
}

# ---- self-elevate -------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Elevating..." -ForegroundColor Cyan
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"{0}"' -f $PSCommandPath))
    if ($Force)        { $argList += '-Force' }
    if ($SkipDefender) { $argList += '-SkipDefender' }
    if ($KeepSearch)   { $argList += '-KeepSearch' }
    if ($NoSystem)     { $argList += '-NoSystem' }
    if ($Verify)       { $argList += @('-Verify','-VerifyDelay',$VerifyDelay) }
    if ($Deadman)      { $argList += '-Deadman' }
    try   { Start-Process powershell.exe -Verb RunAs -ArgumentList $argList }
    catch { Write-Host "Elevation cancelled - nothing was changed." -ForegroundColor Yellow }
    return
}

if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

Write-Host ""
Write-Host "================  PRE-RACE QUIET  ================" -ForegroundColor Cyan
Write-Log "=== Pre-Race-Quiet v3.0.0 starting ===" 'Gray' -NoHost

# ---- refuse to overwrite an un-restored snapshot ------------------
if ((Test-Path $StateFile) -and -not $Force) {
    Write-Host ""
    Write-Host "  A previous session was never restored." -ForegroundColor Yellow
    Write-Host "  $StateFile already exists." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Run Post-Race-Restore.ps1 first, or re-run this with -Force" -ForegroundColor Yellow
    Write-Host "  to snapshot over it (you would lose the original state)." -ForegroundColor Yellow
    Write-Host ""
    Write-Log "ABORT: stale state file present, -Force not supplied" 'Yellow' -NoHost
    return
}

if ($KeepSearch) { $ServicesToQuiet = @($ServicesToQuiet | Where-Object { $_ -ne 'WSearch' }) }

# ================================================================
#  1. SNAPSHOT  -  capture real prior state BEFORE touching anything
# ================================================================
Write-Host ""
Write-Host "1. Snapshotting current state" -ForegroundColor White

$snapServices = @()
foreach ($name in $ServicesToQuiet) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Log "service not present, skipping: $name" 'DarkGray'; continue }

    $key   = Join-Path $SvcRoot $name
    $start = $null; $delayed = $null; $faB64 = $null; $faNonCrash = $null
    try {
        $p = Get-ItemProperty -Path $key -ErrorAction Stop
        if ($null -ne $p.Start)            { $start   = [int]$p.Start }
        if ($null -ne $p.DelayedAutostart) { $delayed = [int]$p.DelayedAutostart }
        if ($null -ne $p.FailureActions)   { $faB64   = [Convert]::ToBase64String([byte[]]$p.FailureActions) }
        if ($null -ne $p.FailureActionsOnNonCrashFailures) { $faNonCrash = [int]$p.FailureActionsOnNonCrashFailures }
    } catch { }

    $snapServices += [pscustomobject]@{
        Name              = $name
        Start             = $start
        DelayedAutostart  = $delayed
        FailureActionsB64 = $faB64
        FailureNonCrash   = $faNonCrash
        WasRunning        = ($svc.Status -eq 'Running')
    }
    Write-Log ("captured {0}: Start={1} running={2} recovery={3}" -f $name, $start, ($svc.Status -eq 'Running'), [bool]$faB64) 'DarkGray'
}

$snapTasks = @()
foreach ($t in $TasksToDisable) {
    $task = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue
    if (-not $task) { continue }
    $snapTasks += [pscustomobject]@{ Path = $t.Path; Name = $t.Name; State = [string]$task.State }
}
# Edge updaters (names carry a GUID, so match by pattern)
$edge = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'MicrosoftEdgeUpdateTaskMachine*' })
foreach ($e in $edge) {
    $snapTasks += [pscustomobject]@{ Path = $e.TaskPath; Name = $e.TaskName; State = [string]$e.State }
}

$defenderWasOn = $null
if (-not $SkipDefender -and (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue)) {
    try { $defenderWasOn = [bool](Get-MpComputerStatus -ErrorAction Stop).RealTimeProtectionEnabled } catch { }
}

$snapshot = [pscustomobject]@{
    SchemaVersion = 1
    Tool          = 'Pre-Race-Quiet v3.0.0'
    CreatedUtc    = (Get-Date).ToUniversalTime().ToString('s')
    Machine       = $env:COMPUTERNAME
    Services      = $snapServices
    Tasks         = $snapTasks
    DefenderWasOn = $defenderWasOn
    KeptSearch    = [bool]$KeepSearch
    SkippedDefender = [bool]$SkipDefender
    Deadman       = [bool]$Deadman
}
try {
    $snapshot | ConvertTo-Json -Depth 6 | Out-File -FilePath $StateFile -Encoding utf8 -ErrorAction Stop
    Write-Host ("  saved: {0}" -f $StateFile) -ForegroundColor Green
    Write-Log "snapshot written" 'Gray' -NoHost
} catch {
    Write-Host "  ABORT: could not write the snapshot - $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Nothing was changed. Without a snapshot there would be no safe way back." -ForegroundColor Red
    Write-Log "ABORT: snapshot write failed" 'Red' -NoHost
    return
}

# ================================================================
#  2. SCHEDULED TASKS
# ================================================================
Write-Host ""
Write-Host "2. Disabling scheduled tasks" -ForegroundColor White
$failedTasks = @()
foreach ($s in $snapTasks) {
    if ($s.State -eq 'Disabled') { Write-Log ("already disabled: {0}{1}" -f $s.Path, $s.Name) 'DarkGray'; continue }
    try {
        Disable-ScheduledTask -TaskPath $s.Path -TaskName $s.Name -ErrorAction Stop | Out-Null
        Write-Log ("disabled task: {0}{1}" -f $s.Path, $s.Name) 'Green'
    } catch {
        $failedTasks += $s
        Write-Log ("could not disable (will retry as SYSTEM): {0}{1}" -f $s.Path, $s.Name) 'DarkGray'
    }
}

# ---- SYSTEM helper for TrustedInstaller-owned tasks ---------------
if ($failedTasks.Count -gt 0 -and -not $NoSystem) {
    Write-Host ""
    Write-Host ("  {0} task(s) refused - retrying as SYSTEM" -f $failedTasks.Count) -ForegroundColor Yellow
    $helper = Join-Path $StateDir 'system-hop.ps1'
    $marker = Join-Path $StateDir 'system-hop.done'
    if (Test-Path $marker) { Remove-Item $marker -Force -ErrorAction SilentlyContinue }

    $lines = @('$done = @()')
    foreach ($f in $failedTasks) {
        $pp = $f.Path -replace "'","''"
        $nn = $f.Name -replace "'","''"
        # NB: built by concatenation, not -f. The format operator treats the
        # literal braces in try{}/catch{} as malformed placeholders and throws.
        $lines += "try { Disable-ScheduledTask -TaskPath '$pp' -TaskName '$nn' -ErrorAction Stop | Out-Null; `$done += 'OK   $pp$nn' } catch { `$done += 'FAIL $pp$nn' }"
    }
    $lines += ("`$done | Out-File -FilePath '{0}' -Encoding utf8" -f ($marker -replace "'","''"))
    Set-Content -Path $helper -Value $lines -Encoding utf8

    $taskName = 'RaceQuiet-SystemHop'
    $cmd = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $helper)
    & schtasks.exe /Create /TN $taskName /TR $cmd /SC ONCE /ST 00:00 /RU SYSTEM /RL HIGHEST /F 2>&1 | Out-Null
    & schtasks.exe /Run /TN $taskName 2>&1 | Out-Null

    $waited = 0
    while (-not (Test-Path $marker) -and $waited -lt 30) { Start-Sleep -Seconds 1; $waited++ }
    & schtasks.exe /Delete /TN $taskName /F 2>&1 | Out-Null

    if (Test-Path $marker) {
        foreach ($l in (Get-Content $marker)) {
            if ($l -like 'OK*')   { Write-Log ("SYSTEM " + $l) 'Green' }
            else                  { Write-Log ("SYSTEM " + $l) 'Yellow' }
        }
        Remove-Item $marker -Force -ErrorAction SilentlyContinue
    } else {
        Write-Log "SYSTEM helper did not report back within 30s - those tasks stay enabled" 'Yellow'
    }
    Remove-Item $helper -Force -ErrorAction SilentlyContinue
}
elseif ($failedTasks.Count -gt 0) {
    Write-Log ("{0} task(s) refused and -NoSystem was set - left enabled" -f $failedTasks.Count) 'Yellow'
}

# ================================================================
#  3. SERVICES  -  disable, clear recovery actions, then stop
# ================================================================
Write-Host ""
Write-Host "3. Disabling services" -ForegroundColor White
foreach ($s in $snapServices) {
    $name = $s.Name
    $key  = Join-Path $SvcRoot $name

    # (a) clear failure/recovery actions so a force-stop can't auto-restart it
    try {
        if ($s.FailureActionsB64) {
            Remove-ItemProperty -Path $key -Name 'FailureActions' -Force -ErrorAction Stop
            Write-Log "cleared recovery actions: $name" 'DarkGray'
        }
    } catch { Write-Log "could not clear recovery actions on $name (protected)" 'DarkGray' }

    # (b) set startup type to Disabled  (Set-Service first, registry as fallback)
    $disabled = $false
    try { Set-Service -Name $name -StartupType Disabled -ErrorAction Stop; $disabled = $true } catch { }
    if (-not $disabled) {
        try { Set-ItemProperty -Path $key -Name 'Start' -Value 4 -Type DWord -ErrorAction Stop; $disabled = $true } catch { }
    }

    # (c) stop it
    $stopped = $false
    try { Stop-Service -Name $name -Force -ErrorAction Stop; $stopped = $true }
    catch { if ((Get-Service -Name $name -ErrorAction SilentlyContinue).Status -eq 'Stopped') { $stopped = $true } }

    if ($disabled -and $stopped)      { Write-Log ("{0}: disabled + stopped" -f $name) 'Green' }
    elseif ($disabled)                { Write-Log ("{0}: disabled, still running - it will not come back after a reboot" -f $name) 'Yellow' }
    elseif ($stopped)                 { Write-Log ("{0}: stopped, but could NOT disable (protected) - may return" -f $name) 'Yellow' }
    else                              { Write-Log ("{0}: could not disable or stop (protected)" -f $name) 'Yellow' }
}

# ================================================================
#  4. DEFENDER
# ================================================================
if (-not $SkipDefender) {
    Write-Host ""
    Write-Host "4. Defender real-time protection" -ForegroundColor White
    if ($defenderWasOn -eq $false) {
        Write-Log "already off before this run - leaving it alone" 'DarkGray'
    } elseif (Get-Command Set-MpPreference -ErrorAction SilentlyContinue) {
        try {
            Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
            Start-Sleep -Milliseconds 600
            if ((Get-MpComputerStatus).RealTimeProtectionEnabled) {
                Write-Log "still ON - Tamper Protection is probably enabled" 'Yellow'
                Write-Host "     Windows Security > Virus and threat protection > Manage settings > Tamper Protection = Off" -ForegroundColor Yellow
            } else {
                Write-Log "real-time protection: OFF for this session" 'Green'
            }
        } catch { Write-Log "could not disable (Tamper Protection on?)" 'Yellow' }
    } else {
        Write-Log "Defender cmdlets unavailable - skipped" 'DarkGray'
    }
}

# ================================================================
#  5. DEADMAN  -  auto-restore at next boot if the user forgets
# ================================================================
if ($Deadman) {
    Write-Host ""
    Write-Host "5. Deadman restore" -ForegroundColor White
    $restore = Join-Path $PSScriptRoot 'Post-Race-Restore.ps1'
    if (Test-Path $restore) {
        $cmd = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $restore)
        & schtasks.exe /Create /TN 'RaceQuiet-Deadman' /TR $cmd /SC ONSTART /RU SYSTEM /RL HIGHEST /F 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Log "registered: everything restores automatically at next boot unless you restore first" 'Green' }
        else                     { Write-Log "could not register the deadman task" 'Yellow' }
    } else {
        Write-Log "Post-Race-Restore.ps1 not found next to this script - deadman skipped" 'Yellow'
    }
}

# ================================================================
#  6. VERIFY
# ================================================================
if ($Verify) {
    Write-Host ""
    Write-Host ("6. Verifying (waiting {0}s for anything to creep back)" -f $VerifyDelay) -ForegroundColor White
    Start-Sleep -Seconds $VerifyDelay
    $bad = 0
    foreach ($s in $snapServices) {
        $now = Get-Service -Name $s.Name -ErrorAction SilentlyContinue
        $st  = $null
        try { $st = [int](Get-ItemProperty -Path (Join-Path $SvcRoot $s.Name) -Name 'Start' -ErrorAction Stop).Start } catch { }
        if ($now -and $now.Status -eq 'Running') { Write-Log ("REVERTED: {0} is running again" -f $s.Name) 'Yellow'; $bad++ }
        elseif ($st -ne 4)                       { Write-Log ("REVERTED: {0} startup type is back to {1}" -f $s.Name, $st) 'Yellow'; $bad++ }
    }
    foreach ($t in $snapTasks) {
        $now = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue
        if ($now -and $now.State -ne 'Disabled') { Write-Log ("REVERTED: task {0}{1} is enabled again" -f $t.Path, $t.Name) 'Yellow'; $bad++ }
    }
    if ($bad -eq 0) { Write-Log "nothing came back - the machine is holding quiet" 'Green' }
    else            { Write-Log ("{0} item(s) reverted - see above" -f $bad) 'Yellow' }
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  Quiet. Go race." -ForegroundColor Green
Write-Host ""
Write-Host "  >>> RUN Post-Race-Restore.ps1 AFTERWARDS <<<" -ForegroundColor Yellow
Write-Host "  This survives a reboot. Until you restore, this PC has no" -ForegroundColor Yellow
Write-Host "  Windows Update and no fresh Defender definitions." -ForegroundColor Yellow
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""
Write-Log "=== Pre-Race-Quiet finished ===" 'Gray' -NoHost
