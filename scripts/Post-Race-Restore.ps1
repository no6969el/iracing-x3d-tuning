<#
    Post-Race-Restore.ps1                                          v3
    ---------------------------------------------------------------
    Re-enables everything Pre-Race-Quiet.ps1 turned off, so Windows Update,
    Search, and Defender work normally again. Run AFTER every session.
    RUN AS ADMINISTRATOR (self-elevates).

    Restores from the snapshot Pre-Race-Quiet saved, so every service, task,
    and Defender setting goes back to its EXACT prior state (correct startup
    type, delayed-start flag, whether Defender was already off, etc.), then
    deletes the snapshot. If no snapshot is found it falls back to sane
    Windows defaults and says so.

    -NoSystem   do NOT hop to SYSTEM context. By DEFAULT this script re-runs
                itself as SYSTEM (temporary scheduled task, deleted after) so
                the tasks that only SYSTEM could disable get re-enabled. This
                mirrors Pre-Race-Quiet.ps1, which also defaults to SYSTEM.
                Needs nothing from you beyond the admin prompt.

    State + log live in C:\ProgramData\RaceQuiet\ so the Admin run and the
    SYSTEM run always agree on the path.
#>

param(
    [switch] $NoSystem,
    [string] $StatePath,
    [string] $LogPath
)

# ---- config (keep in sync with Pre-Race-Quiet.ps1) ------------------------
$StateName = 'RaceQuiet-State.json'
$Services  = @('wuauserv','UsoSvc','WSearch','bits','DoSvc')
$Tasks = @(
    @{ Path='\Microsoft\Windows\InstallService\';               Name='ScanForUpdates' }
    @{ Path='\Microsoft\Windows\InstallService\';               Name='ScanForUpdatesAsUser' }
    @{ Path='\Microsoft\Windows\UpdateOrchestrator\';           Name='Schedule Scan' }
    @{ Path='\Microsoft\Windows\UpdateOrchestrator\';           Name='Schedule Scan Static Task' }
    @{ Path='\Microsoft\Windows\PushToInstall\';                Name='LoginCheck' }
    @{ Path='\Microsoft\Windows\PushToInstall\';                Name='Registration' }
    @{ Path='\Microsoft\Windows\LanguageComponentsInstaller\';  Name='ReconcileLanguageResources' }
    @{ Path='\Microsoft\Windows\WaaSMedic\';                    Name='PerformRemediation' }
)
$TaskNamePatterns = @('MicrosoftEdgeUpdateTaskMachine*')
# used ONLY when no snapshot exists (best-effort defaults)
$Defaults = @{
    wuauserv = @{ Start=3; Delayed=$null }   # Manual (trigger)
    UsoSvc   = @{ Start=3; Delayed=$null }   # Manual (trigger)
    WSearch  = @{ Start=2; Delayed=1 }        # Automatic (Delayed)
    bits     = @{ Start=3; Delayed=$null }   # Manual (trigger)
    DoSvc    = @{ Start=2; Delayed=1 }        # Automatic (Delayed)
}

$ErrorActionPreference = 'SilentlyContinue'

# Must match Pre-Race-Quiet.ps1: ProgramData is writable by Admin AND SYSTEM.
$stateDir = Join-Path $env:ProgramData 'RaceQuiet'
if (-not (Test-Path $stateDir)) { New-Item -Path $stateDir -ItemType Directory -Force | Out-Null }
if (-not $StatePath) { $StatePath = Join-Path $stateDir $StateName }
if (-not $LogPath)   { $LogPath   = Join-Path $stateDir 'RaceQuiet.log' }

function Log { param($m,$c='Gray')
    $ts = (Get-Date).ToString('HH:mm:ss')
    Write-Host "  $m" -ForegroundColor $c
    Add-Content -Path $LogPath -Value "[$ts] POST $m" -ErrorAction SilentlyContinue
}
function Test-IsSystem { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18' }
function Set-RegValue {
    param([string]$Path,[string]$Name,$Value,[string]$Kind)
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Kind -Force | Out-Null
}
function Get-ForwardArgs {
    $a = @()
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) { if ($kv.Value.IsPresent) { $a += "-$($kv.Key)" } }
        else { $a += "-$($kv.Key)"; $a += ('"{0}"' -f $kv.Value) }
    }
    $a
}
function Invoke-AsSystem {
    $exe     = (Get-Process -Id $PID).Path
    $wrapper = Join-Path $env:windir ("Temp\RaceQuiet-sysR-{0}.cmd" -f $PID)
    $cmd     = '@echo off' + "`r`n" + ('"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" {2}' -f $exe, $PSCommandPath, ((Get-ForwardArgs) -join ' '))
    Set-Content -Path $wrapper -Value $cmd -Encoding ASCII
    $tn = 'RaceQuiet-Restore'
    schtasks.exe /Create /TN $tn /TR ('"{0}"' -f $wrapper) /SC ONCE /ST 23:59 /RU SYSTEM /RL HIGHEST /F > $null 2>&1
    Log "Relaunching restore under SYSTEM..." Cyan
    schtasks.exe /Run /TN $tn > $null 2>&1
    $deadline = (Get-Date).AddSeconds(180)
    do { Start-Sleep -Seconds 3; $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue; $st = if ($t) { $t.State.ToString() } else { 'Gone' } }
    while ($st -eq 'Running' -and (Get-Date) -lt $deadline)
    schtasks.exe /Delete /TN $tn /F > $null 2>&1
    Remove-Item $wrapper -ErrorAction SilentlyContinue
    if (Test-Path $LogPath) {
        Write-Host "  --- SYSTEM restore log (a SYSTEM task has no visible console) ---" -ForegroundColor DarkGray
        Get-Content $LogPath -Tail 60 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    }
}

# ---- elevate to admin -----------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Elevation required - relaunching as administrator..." -ForegroundColor Yellow
    $exe  = (Get-Process -Id $PID).Path
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"{0}"' -f $PSCommandPath)) + (Get-ForwardArgs)
    try { Start-Process -FilePath $exe -Verb RunAs -ArgumentList $args } catch { Write-Host "Could not elevate: $($_.Exception.Message)" -ForegroundColor Red }
    exit
}

# ---- SYSTEM hop -----------------------------------------------------------
if (-not $NoSystem -and -not (Test-IsSystem)) {
    Write-Host ""
    Write-Host "  =========================  POST-RACE-RESTORE  ======================" -ForegroundColor Cyan
    Invoke-AsSystem
    Write-Host "  ====================================================================" -ForegroundColor Cyan
    exit 0
}

Write-Host ""
Write-Host "  =========================  POST-RACE-RESTORE  ======================" -ForegroundColor Cyan
Log ("run start (ctx=" + $(if (Test-IsSystem){'SYSTEM'}else{'Admin'}) + ")")

# ==========================================================================
#  Path A: snapshot exists -> faithful restore
# ==========================================================================
if (Test-Path $StatePath) {
    try { $state = Get-Content $StatePath -Raw | ConvertFrom-Json } catch { $state = $null }
    if (-not $state) {
        Log "State file is unreadable: $StatePath" Red
        Log "Delete it and re-run for a best-effort default restore." Red
        Write-Host "  ====================================================================" -ForegroundColor Cyan
        exit 1
    }
    Log "Restoring from snapshot saved $($state.SavedAt)" Cyan

    # 1. re-enable tasks we disabled
    Log "Re-enabling scheduled tasks..." Cyan
    $en = 0; $stuck = 0
    foreach ($t in @($state.Tasks)) {
        if (-not $t.Disabled) { continue }
        $ok = $false
        try { Enable-ScheduledTask -TaskName $t.Name -TaskPath $t.Path -ErrorAction Stop | Out-Null; $ok=$true }
        catch { schtasks.exe /Change /TN ($t.Path + $t.Name) /ENABLE > $null 2>&1; if ($LASTEXITCODE -eq 0) { $ok=$true } }
        if ($ok) { $en++; Log ("  enabled: {0}{1}" -f $t.Path,$t.Name) Green } else { $stuck++; Log ("  could not re-enable: {0}{1}" -f $t.Path,$t.Name) Yellow }
    }
    Log "  re-enabled $en task(s)$(if($stuck){"; $stuck stuck - re-run WITHOUT -NoSystem"})" DarkGray

    # 2. restore services
    Log "Restoring services..." Cyan
    foreach ($e in @($state.Services)) {
        if (-not $e.Present) { continue }
        $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$($e.Name)"
        if ($e.Start.Existed)   { Set-RegValue -Path $path -Name 'Start' -Value ([int]$e.Start.Value) -Kind $e.Start.Kind }
        if ($e.Delayed.Existed) { Set-RegValue -Path $path -Name 'DelayedAutostart' -Value ([int]$e.Delayed.Value) -Kind $e.Delayed.Kind }
        else                    { Remove-ItemProperty -Path $path -Name 'DelayedAutostart' -ErrorAction SilentlyContinue }
        if ($e.Status -eq 'Running') {
            try { Start-Service -Name $e.Name -ErrorAction Stop; Log "  $($e.Name) : restored + started" Green }
            catch { Log "  $($e.Name) : type restored (will trigger-start on demand)" DarkGray }
        } else { Log "  $($e.Name) : type restored (was $($e.Status))" DarkGray }
    }

    # 3. restore registry (clear pause/policy)
    Log "Clearing the Windows Update pause..." Cyan
    foreach ($r in @($state.Registry)) {
        if ($r.Existed) { Set-RegValue -Path $r.Path -Name $r.Name -Value $r.Value -Kind $r.Kind }
        else            { Remove-ItemProperty -Path $r.Path -Name $r.Name -ErrorAction SilentlyContinue }
    }

    # 4. restore Defender
    if ($state.Defender -and $state.Defender.Present) {
        Log "Restoring Defender real-time protection..." Cyan
        $was = $state.Defender.RealTimeWasEnabled
        if ($was -eq $true) {
            try {
                Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
                Start-Sleep -Milliseconds 500
                if ((Get-MpComputerStatus).RealTimeProtectionEnabled) { Log "  Defender real-time protection: RE-ENABLED" Green }
                else { Log "  ! still OFF - re-enable it in Windows Security to be safe." Yellow }
            } catch { Log "  ! could not re-enable via script - turn it on in Windows Security: $($_.Exception.Message)" Yellow }
        } elseif ($was -eq $false) {
            Log "  Defender real-time was OFF before the session; leaving it OFF." Yellow
            Log "    (If that's not what you want, turn it on in Windows Security.)" Yellow
        }
    }

    Remove-Item -Path $StatePath -ErrorAction SilentlyContinue
    Log "Snapshot consumed. Windows Update, Search, and Defender are back to normal." Green
    Write-Host "  ====================================================================" -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

# ==========================================================================
#  Path B: no snapshot -> best-effort defaults
# ==========================================================================
Log "No snapshot at $StatePath" Yellow
Log "Doing a best-effort restore to Windows defaults..." Yellow

# re-enable the known tasks + Edge pattern
$targets = New-Object System.Collections.Generic.List[object]
foreach ($t in $Tasks) { $o = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue; if ($o) { $targets.Add($o) } }
foreach ($pat in $TaskNamePatterns) { Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like $pat } | ForEach-Object { $targets.Add($_) } }
$en = 0
foreach ($t in $targets) {
    if ($t.State -ne 'Disabled') { continue }
    try { Enable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop | Out-Null; $en++ }
    catch { schtasks.exe /Change /TN ($t.TaskPath + $t.TaskName) /ENABLE > $null 2>&1; if ($LASTEXITCODE -eq 0) { $en++ } }
}
Log "  re-enabled $en task(s)" DarkGray

foreach ($s in $Services) {
    if (-not (Get-Service -Name $s -ErrorAction SilentlyContinue)) { continue }
    $d = $Defaults[$s]; $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$s"
    Set-RegValue -Path $path -Name 'Start' -Value ([int]$d.Start) -Kind 'DWord'
    if ($null -ne $d.Delayed) { Set-RegValue -Path $path -Name 'DelayedAutostart' -Value ([int]$d.Delayed) -Kind 'DWord' }
    else { Remove-ItemProperty -Path $path -Name 'DelayedAutostart' -ErrorAction SilentlyContinue }
    Log "  $s : reset to default (Start=$($d.Start))" DarkGray
}

$ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
foreach ($n in 'PauseUpdatesExpiryTime','PauseFeatureUpdatesStartTime','PauseFeatureUpdatesEndTime','PauseQualityUpdatesStartTime','PauseQualityUpdatesEndTime') {
    Remove-ItemProperty -Path $ux -Name $n -ErrorAction SilentlyContinue
}
Remove-ItemProperty -Path $au -Name 'NoAutoUpdate' -ErrorAction SilentlyContinue
Log "  cleared Windows Update pause" DarkGray

if (Get-Command Set-MpPreference -ErrorAction SilentlyContinue) {
    try { Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop; Log "Defender real-time protection: RE-ENABLED (default)" Green }
    catch { Log "! could not re-enable Defender - turn it on in Windows Security." Yellow }
}

Log "Best-effort restore complete (verify Windows Update opens and scans)." Yellow
Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host ""
