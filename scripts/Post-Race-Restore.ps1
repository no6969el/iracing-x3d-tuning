<#
    Post-Race-Restore.ps1                                     v3.0.0
    ================================================================
    Puts everything Pre-Race-Quiet touched back exactly as it was.

    This is NOT optional. Pre-Race-Quiet disables services rather than
    stopping them, so nothing self-heals on reboot. Until this runs, the
    machine has no Windows Update - and because Defender signature updates
    ride on wuauserv/BITS, no fresh virus definitions either.

    It replays the snapshot written by Pre-Race-Quiet, so anything you had
    already turned off yourself STAYS off. If Defender real-time was already
    disabled before you raced, it is left disabled.

    If no snapshot exists (someone deleted it, or quieting was done by hand)
    it falls back to Windows defaults and says so loudly.

    USAGE
      .\Post-Race-Restore.ps1              normal run
      .\Post-Race-Restore.ps1 -Verify      re-check after 30s that it held

    Self-elevates.
#>

[CmdletBinding()]
param(
    [switch]$Verify,
    [int]   $VerifyDelay = 30
)

$StateDir  = Join-Path $env:ProgramData 'RaceQuiet'
$StateFile = Join-Path $StateDir 'state.json'
$LogFile   = Join-Path $StateDir 'RaceQuiet.log'
$SvcRoot   = 'HKLM:\SYSTEM\CurrentControlSet\Services'

# Windows defaults, used only when there is no snapshot to replay.
# 2 = Automatic, 3 = Manual, 4 = Disabled
$Defaults = @{
    'wuauserv'     = 3
    'UsoSvc'       = 2
    'WaaSMedicSvc' = 3
    'bits'         = 3
    'DoSvc'        = 2
    'WSearch'      = 2
}

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
    if ($Verify) { $argList += @('-Verify','-VerifyDelay',$VerifyDelay) }
    try   { Start-Process powershell.exe -Verb RunAs -ArgumentList $argList }
    catch { Write-Host "Elevation cancelled - nothing was restored." -ForegroundColor Yellow }
    return
}

Write-Host ""
Write-Host "===============  POST-RACE RESTORE  ===============" -ForegroundColor Cyan
Write-Log "=== Post-Race-Restore v3.0.0 starting ===" 'Gray' -NoHost

# ---- load the snapshot -------------------------------------------
$snap = $null
if (Test-Path $StateFile) {
    try { $snap = Get-Content $StateFile -Raw | ConvertFrom-Json } catch { $snap = $null }
}

if ($snap) {
    Write-Host ""
    Write-Host ("  Replaying snapshot from {0} UTC" -f $snap.CreatedUtc) -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "  !! NO SNAPSHOT FOUND !!" -ForegroundColor Yellow
    Write-Host "  Falling back to Windows defaults. If you had deliberately" -ForegroundColor Yellow
    Write-Host "  disabled any of these services yourself, they are about to" -ForegroundColor Yellow
    Write-Host "  be switched back on." -ForegroundColor Yellow
    Write-Log "no snapshot - using defaults" 'Yellow' -NoHost
}

# ================================================================
#  1. SERVICES
# ================================================================
Write-Host ""
Write-Host "1. Services" -ForegroundColor White

$svcList = @()
if ($snap) { $svcList = @($snap.Services) }
else {
    foreach ($k in $Defaults.Keys) {
        $svcList += [pscustomobject]@{
            Name=$k; Start=$Defaults[$k]; DelayedAutostart=$null
            FailureActionsB64=$null; FailureNonCrash=$null; WasRunning=$false
        }
    }
}

foreach ($s in $svcList) {
    $name = $s.Name
    if (-not (Get-Service -Name $name -ErrorAction SilentlyContinue)) { continue }
    $key = Join-Path $SvcRoot $name

    # (a) startup type back to exactly what it was
    $target = $s.Start
    if ($null -eq $target) { if ($Defaults.ContainsKey($name)) { $target = $Defaults[$name] } else { $target = 3 } }
    $ok = $false
    $mapped = @{ 2='Automatic'; 3='Manual'; 4='Disabled' }
    if ($mapped.ContainsKey([int]$target)) {
        try { Set-Service -Name $name -StartupType $mapped[[int]$target] -ErrorAction Stop; $ok = $true } catch { }
    }
    if (-not $ok) {
        try { Set-ItemProperty -Path $key -Name 'Start' -Value ([int]$target) -Type DWord -ErrorAction Stop; $ok = $true } catch { }
    }

    # (b) delayed-autostart flag
    if ($null -ne $s.DelayedAutostart) {
        try { Set-ItemProperty -Path $key -Name 'DelayedAutostart' -Value ([int]$s.DelayedAutostart) -Type DWord -ErrorAction SilentlyContinue } catch { }
    }

    # (c) recovery actions, byte-for-byte
    if ($s.FailureActionsB64) {
        try {
            $bytes = [Convert]::FromBase64String($s.FailureActionsB64)
            Set-ItemProperty -Path $key -Name 'FailureActions' -Value $bytes -Type Binary -ErrorAction Stop
            Write-Log "restored recovery actions: $name" 'DarkGray'
        } catch { Write-Log "could not restore recovery actions on $name" 'Yellow' }
    }
    if ($null -ne $s.FailureNonCrash) {
        try { Set-ItemProperty -Path $key -Name 'FailureActionsOnNonCrashFailures' -Value ([int]$s.FailureNonCrash) -Type DWord -ErrorAction SilentlyContinue } catch { }
    }

    # (d) start it again only if it was running before, and only if not Disabled
    $started = ''
    if ($s.WasRunning -and [int]$target -ne 4) {
        try { Start-Service -Name $name -ErrorAction Stop; $started = ' + started' } catch { $started = ' (could not start - it will start on demand)' }
    }

    if ($ok) { Write-Log ("{0}: startup type {1}{2}" -f $name, $mapped[[int]$target], $started) 'Green' }
    else     { Write-Log ("{0}: could NOT restore startup type (protected)" -f $name) 'Yellow' }
}

# ================================================================
#  2. SCHEDULED TASKS
# ================================================================
Write-Host ""
Write-Host "2. Scheduled tasks" -ForegroundColor White

$taskList = @()
if ($snap) { $taskList = @($snap.Tasks) }

if ($taskList.Count -eq 0) {
    # no snapshot: re-enable the standard set by name
    $fallback = @(
        @{ Path='\Microsoft\Windows\WaaSMedic\';                   Name='PerformRemediation' },
        @{ Path='\Microsoft\Windows\UpdateOrchestrator\';          Name='Schedule Scan' },
        @{ Path='\Microsoft\Windows\UpdateOrchestrator\';          Name='Schedule Scan Static Task' },
        @{ Path='\Microsoft\Windows\UpdateOrchestrator\';          Name='Universal Orchestrator Start' },
        @{ Path='\Microsoft\Windows\UpdateOrchestrator\';          Name='Report policies' },
        @{ Path='\Microsoft\Windows\UpdateOrchestrator\';          Name='UUS Failover Task' },
        @{ Path='\Microsoft\Windows\InstallService\';              Name='ScanForUpdates' },
        @{ Path='\Microsoft\Windows\InstallService\';              Name='ScanForUpdatesAsUser' },
        @{ Path='\Microsoft\Windows\PushToInstall\';               Name='LoginCheck' },
        @{ Path='\Microsoft\Windows\PushToInstall\';               Name='Registration' },
        @{ Path='\Microsoft\Windows\LanguageComponentsInstaller\'; Name='ReconcileLanguageResources' }
    )
    foreach ($f in $fallback) { $taskList += [pscustomobject]@{ Path=$f.Path; Name=$f.Name; State='Ready' } }
    foreach ($e in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'MicrosoftEdgeUpdateTaskMachine*' })) {
        $taskList += [pscustomobject]@{ Path=$e.TaskPath; Name=$e.TaskName; State='Ready' }
    }
}

$failedTasks = @()
foreach ($t in $taskList) {
    if ($t.State -eq 'Disabled') {
        Write-Log ("leaving disabled (it was already off before): {0}{1}" -f $t.Path, $t.Name) 'DarkGray'
        continue
    }
    if (-not (Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue)) { continue }
    try {
        Enable-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction Stop | Out-Null
        Write-Log ("enabled task: {0}{1}" -f $t.Path, $t.Name) 'Green'
    } catch {
        $failedTasks += $t
    }
}

# SYSTEM helper for anything TrustedInstaller-owned
if ($failedTasks.Count -gt 0) {
    Write-Host ""
    Write-Host ("  {0} task(s) refused - retrying as SYSTEM" -f $failedTasks.Count) -ForegroundColor Yellow
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
    $helper = Join-Path $StateDir 'system-hop-restore.ps1'
    $marker = Join-Path $StateDir 'system-hop-restore.done'
    if (Test-Path $marker) { Remove-Item $marker -Force -ErrorAction SilentlyContinue }

    $lines = @('$done = @()')
    foreach ($f in $failedTasks) {
        $pp = $f.Path -replace "'","''"
        $nn = $f.Name -replace "'","''"
        # NB: concatenation, not -f - see Pre-Race-Quiet for why.
        $lines += "try { Enable-ScheduledTask -TaskPath '$pp' -TaskName '$nn' -ErrorAction Stop | Out-Null; `$done += 'OK   $pp$nn' } catch { `$done += 'FAIL $pp$nn' }"
    }
    $lines += ("`$done | Out-File -FilePath '{0}' -Encoding utf8" -f ($marker -replace "'","''"))
    Set-Content -Path $helper -Value $lines -Encoding utf8

    $cmd = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $helper)
    & schtasks.exe /Create /TN 'RaceQuiet-SystemHopRestore' /TR $cmd /SC ONCE /ST 00:00 /RU SYSTEM /RL HIGHEST /F 2>&1 | Out-Null
    & schtasks.exe /Run /TN 'RaceQuiet-SystemHopRestore' 2>&1 | Out-Null
    $waited = 0
    while (-not (Test-Path $marker) -and $waited -lt 30) { Start-Sleep -Seconds 1; $waited++ }
    & schtasks.exe /Delete /TN 'RaceQuiet-SystemHopRestore' /F 2>&1 | Out-Null

    if (Test-Path $marker) {
        foreach ($l in (Get-Content $marker)) {
            if ($l -like 'OK*') { Write-Log ("SYSTEM " + $l) 'Green' } else { Write-Log ("SYSTEM " + $l) 'Yellow' }
        }
        Remove-Item $marker -Force -ErrorAction SilentlyContinue
    } else {
        Write-Log "SYSTEM helper did not report back - re-run this script from an elevated prompt" 'Yellow'
    }
    Remove-Item $helper -Force -ErrorAction SilentlyContinue
}

# ================================================================
#  3. DEFENDER
# ================================================================
Write-Host ""
Write-Host "3. Defender real-time protection" -ForegroundColor White
$shouldReenable = $true
if ($snap -and $snap.PSObject.Properties['DefenderWasOn']) {
    if ($snap.DefenderWasOn -eq $false) { $shouldReenable = $false }
}
if (-not $shouldReenable) {
    Write-Log "was already OFF before the session - leaving it off, as you had it" 'DarkGray'
} elseif (Get-Command Set-MpPreference -ErrorAction SilentlyContinue) {
    try {
        Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
        Start-Sleep -Milliseconds 600
        if ((Get-MpComputerStatus).RealTimeProtectionEnabled) { Write-Log "real-time protection: back ON" 'Green' }
        else { Write-Log "still reporting OFF - check Windows Security manually" 'Yellow' }
    } catch { Write-Log "could not re-enable - check Windows Security manually" 'Yellow' }
} else {
    Write-Log "Defender cmdlets unavailable - skipped" 'DarkGray'
}

# ================================================================
#  4. TIDY UP
# ================================================================
& schtasks.exe /Delete /TN 'RaceQuiet-Deadman' /F 2>&1 | Out-Null

if (Test-Path $StateFile) {
    try { Remove-Item $StateFile -Force -ErrorAction Stop; Write-Log "snapshot consumed" 'DarkGray' }
    catch { Write-Log "could not delete the snapshot - delete $StateFile by hand" 'Yellow' }
}

# ================================================================
#  5. VERIFY
# ================================================================
if ($Verify) {
    Write-Host ""
    Write-Host ("5. Verifying after {0}s" -f $VerifyDelay) -ForegroundColor White
    Start-Sleep -Seconds $VerifyDelay
    $bad = 0
    foreach ($s in $svcList) {
        if (-not (Get-Service -Name $s.Name -ErrorAction SilentlyContinue)) { continue }
        $st = $null
        try { $st = [int](Get-ItemProperty -Path (Join-Path $SvcRoot $s.Name) -Name 'Start' -ErrorAction Stop).Start } catch { }
        if ($st -eq 4 -and [int]$s.Start -ne 4) { Write-Log ("STILL DISABLED: {0}" -f $s.Name) 'Yellow'; $bad++ }
    }
    if ($bad -eq 0) { Write-Log "everything is back the way it was" 'Green' }
    else            { Write-Log ("{0} service(s) did not restore - re-run elevated" -f $bad) 'Yellow' }
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  Restored. Windows Update and Defender are back." -ForegroundColor Green
Write-Host "  Run Check-Quiet-Status.ps1 any time to confirm." -ForegroundColor DarkGray
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""
Write-Log "=== Post-Race-Restore finished ===" 'Gray' -NoHost
