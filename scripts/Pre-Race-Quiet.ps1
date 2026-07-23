<#
    Pre-Race-Quiet.ps1                                             v3
    ---------------------------------------------------------------
    Silences the background tasks/services behind the periodic (~5-10 min)
    micro-stalls -- Windows Update scans, the Update Medic, Edge update,
    PushToInstall, Windows Search -- AND disables Defender real-time
    protection for the session (stops it scanning iRacing's file reads).
    Run BEFORE a session.  RUN AS ADMINISTRATOR (self-elevates).

    >>> Run Post-Race-Restore.ps1 afterward to turn everything back on <<<

    WHAT CHANGED FROM v2 (why your services came back after ~10 min):
      * v2 only STOPPED wuauserv/UsoSvc, so the Update Medic + Orchestrator
        restarted them within minutes. This version DISABLES them (Start=4)
        AND disables the WaaSMedic PerformRemediation task that does the
        reverting, so they stay down for the whole session.
      * Because they are DISABLED (not just stopped), they stay off across a
        reboot too -- until you run Post-Race-Restore.ps1. That is the point.
      * Everything is snapshotted to a JSON file first, so Post-Race-Restore
        puts each service / task / Defender back to its EXACT prior state
        (not a guessed default).

    Requires Tamper Protection = OFF for the Defender toggle to take.

    Options:
      -Verify        after the work, wait then re-check nothing reverted.
      -VerifyDelay   seconds to wait before that check (default 180).
      -AsSystem      run in SYSTEM context so the TrustedInstaller-locked
                     WaaSMedic/Orchestrator tasks can be disabled too.
                     If you use it here, use it on Post-Race-Restore too.
      -SkipDefender  leave Defender real-time protection alone.
      -PauseDays     WU pause backstop length (default 2; restore clears it).
      -Force         re-snapshot even if a state file already exists.
#>

param(
    [switch] $Verify,
    [int]    $VerifyDelay = 180,
    [switch] $AsSystem,
    [switch] $SkipDefender,
    [int]    $PauseDays   = 2,
    [switch] $Force,
    [string] $StatePath,
    [string] $LogPath
)

# ---- config ---------------------------------------------------------------
$StateName = 'RaceQuiet-State.json'
# services that are DISABLED (Start=4) + stopped for the session
$Services  = @('wuauserv','UsoSvc','WSearch','bits','DoSvc')
$MedicSvc  = 'WaaSMedicSvc'                              # protected; best-effort stop only
# curated task list (the originals' set + the medic remediation task)
$Tasks = @(
    @{ Path='\Microsoft\Windows\InstallService\';               Name='ScanForUpdates' }
    @{ Path='\Microsoft\Windows\InstallService\';               Name='ScanForUpdatesAsUser' }
    @{ Path='\Microsoft\Windows\UpdateOrchestrator\';           Name='Schedule Scan' }
    @{ Path='\Microsoft\Windows\UpdateOrchestrator\';           Name='Schedule Scan Static Task' }
    @{ Path='\Microsoft\Windows\PushToInstall\';                Name='LoginCheck' }
    @{ Path='\Microsoft\Windows\PushToInstall\';                Name='Registration' }
    @{ Path='\Microsoft\Windows\LanguageComponentsInstaller\';  Name='ReconcileLanguageResources' }
    @{ Path='\Microsoft\Windows\WaaSMedic\';                    Name='PerformRemediation' }   # the ~10-min reverter
)
$TaskNamePatterns = @('MicrosoftEdgeUpdateTaskMachine*')  # Edge auto-update (GUID-suffixed)

$ErrorActionPreference = 'SilentlyContinue'

$root = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
if (-not $StatePath) { $StatePath = Join-Path $root $StateName }
if (-not $LogPath)   { $LogPath   = Join-Path $root 'RaceQuiet.log' }

function Log { param($m,$c='Gray')
    $ts = (Get-Date).ToString('HH:mm:ss')
    Write-Host "  $m" -ForegroundColor $c
    Add-Content -Path $LogPath -Value "[$ts] PRE  $m" -ErrorAction SilentlyContinue
}
function Test-IsSystem { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18' }
function Get-RegSnapshot {
    param([string]$Path,[string]$Name)
    $snap = [ordered]@{ Path=$Path; Name=$Name; Existed=$false; Value=$null; Kind=$null }
    if (Test-Path $Path) {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        if ($item -and ($item.PSObject.Properties.Name -contains $Name)) {
            $snap.Existed = $true
            $snap.Value   = $item.$Name
            try { $snap.Kind = (Get-Item -LiteralPath $Path).GetValueKind($Name).ToString() } catch { $snap.Kind = 'String' }
        }
    }
    [pscustomobject]$snap
}
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
    $wrapper = Join-Path $env:windir ("Temp\RaceQuiet-sys-{0}.cmd" -f $PID)
    $cmd     = '@echo off' + "`r`n" + ('"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" {2}' -f $exe, $PSCommandPath, ((Get-ForwardArgs) -join ' '))
    Set-Content -Path $wrapper -Value $cmd -Encoding ASCII
    $tn = 'RaceQuiet-Elevate'
    schtasks.exe /Create /TN $tn /TR ('"{0}"' -f $wrapper) /SC ONCE /ST 23:59 /RU SYSTEM /RL HIGHEST /F > $null 2>&1
    Log "Relaunching under SYSTEM..." Cyan
    schtasks.exe /Run /TN $tn > $null 2>&1
    $maxWait  = if ($Verify) { $VerifyDelay + 180 } else { 180 }
    $deadline = (Get-Date).AddSeconds($maxWait)
    do { Start-Sleep -Seconds 3; $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue; $st = if ($t) { $t.State.ToString() } else { 'Gone' } }
    while ($st -eq 'Running' -and (Get-Date) -lt $deadline)
    schtasks.exe /Delete /TN $tn /F > $null 2>&1
    Remove-Item $wrapper -ErrorAction SilentlyContinue
    if (Test-Path $LogPath) {
        Write-Host "  --- SYSTEM run log (tail) ---" -ForegroundColor DarkGray
        Get-Content $LogPath -Tail 32 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
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
if ($AsSystem -and -not (Test-IsSystem)) {
    Write-Host ""
    Write-Host "  ==========================  PRE-RACE-QUIET  ========================" -ForegroundColor Cyan
    Invoke-AsSystem
    Write-Host "  ====================================================================" -ForegroundColor Cyan
    exit 0
}

# ---- banner + guard -------------------------------------------------------
Write-Host ""
Write-Host "  ==========================  PRE-RACE-QUIET  ========================" -ForegroundColor Cyan
Log ("run start (PauseDays=$PauseDays; ctx=" + $(if (Test-IsSystem){'SYSTEM'}else{'Admin'}) + ")")

if ((Test-Path $StatePath) -and -not $Force) {
    Log "A saved-state file already exists:" Yellow
    Log "    $StatePath" Yellow
    Log "A previous Pre-Race-Quiet run was never restored. Run Post-Race-Restore.ps1" Yellow
    Log "first, or pass -Force to snapshot the CURRENT state anyway." Yellow
    Write-Host "  ====================================================================" -ForegroundColor Cyan
    exit 1
}

# ---- 1. snapshot + disable services --------------------------------------
Log "Disabling update / search services for the session..." Cyan
$svcState = foreach ($s in $Services) {
    $svc  = Get-Service -Name $s -ErrorAction SilentlyContinue
    $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$s"
    $rec  = [pscustomobject]@{
        Name    = $s
        Present = [bool]$svc
        Status  = if ($svc) { $svc.Status.ToString() } else { 'Absent' }
        Start   = Get-RegSnapshot -Path $path -Name 'Start'
        Delayed = Get-RegSnapshot -Path $path -Name 'DelayedAutostart'
    }
    if ($svc) {
        try { Stop-Service -Name $s -Force -ErrorAction Stop } catch {}
        Set-RegValue -Path $path -Name 'Start' -Value 4 -Kind 'DWord'
        Log "  $s : was $($rec.Status) -> stopped + disabled" Green
    } else { Log "  $s : not present (skipped)" DarkGray }
    $rec
}
try { Stop-Service -Name $MedicSvc -Force -ErrorAction Stop; Log "  $MedicSvc : stopped" DarkGray }
catch { Log "  $MedicSvc : not stopped (normal - handled via its task below)" DarkGray }

# ---- 2. snapshot + disable scheduled tasks --------------------------------
Log "Disabling background scan / update tasks..." Cyan
$targets = New-Object System.Collections.Generic.List[object]
foreach ($t in $Tasks) {
    $o = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue
    if ($o) { $targets.Add($o) }
}
foreach ($pat in $TaskNamePatterns) {
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like $pat } | ForEach-Object { $targets.Add($_) }
}
$seen = @{}; $uniq = New-Object System.Collections.Generic.List[object]
foreach ($o in $targets) { $k = $o.TaskPath + $o.TaskName; if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $uniq.Add($o) } }

$taskState = New-Object System.Collections.Generic.List[object]
$refused   = New-Object System.Collections.Generic.List[string]
$medicRefused = $false
foreach ($t in $uniq) {
    if ($t.State -eq 'Disabled') {
        $taskState.Add([pscustomobject]@{ Path=$t.TaskPath; Name=$t.TaskName; PrevState='Disabled'; Disabled=$false; Method='already' })
        continue
    }
    $ok = $false; $method = ''
    try { Disable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop | Out-Null; $ok=$true; $method='cmdlet' }
    catch { schtasks.exe /Change /TN ($t.TaskPath + $t.TaskName) /DISABLE > $null 2>&1; if ($LASTEXITCODE -eq 0) { $ok=$true; $method='schtasks' } }
    if ($ok) { Log ("  disabled: {0}{1}" -f $t.TaskPath,$t.TaskName) Green }
    else {
        $refused.Add(($t.TaskPath + $t.TaskName))
        if ($t.TaskName -eq 'PerformRemediation') { $medicRefused = $true }
        Log ("  refused : {0}{1} (protected)" -f $t.TaskPath,$t.TaskName) DarkGray
    }
    $taskState.Add([pscustomobject]@{ Path=$t.TaskPath; Name=$t.TaskName; PrevState=$t.State.ToString(); Disabled=$ok; Method=$method })
}
if ($medicRefused -and -not (Test-IsSystem)) {
    Log "  ** WaaSMedic\PerformRemediation refused - that's the ~10-min reverter." Yellow
    Log "     Re-run with -AsSystem to disable it (and use -AsSystem on restore too)." Yellow
}

# ---- 3. snapshot + pause updates (backstop) -------------------------------
Log "Pausing Windows Update for $PauseDays day(s) (backstop)..." Cyan
$ux  = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$au  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$now = (Get-Date).ToUniversalTime(); $fmt = 'yyyy-MM-ddTHH:mm:ssZ'
$exp = $now.AddDays($PauseDays)
$pause = @(
    @{ Path=$ux; Name='PauseUpdatesExpiryTime';       Kind='String'; Value=$exp.ToString($fmt) }
    @{ Path=$ux; Name='PauseFeatureUpdatesStartTime'; Kind='String'; Value=$now.ToString($fmt) }
    @{ Path=$ux; Name='PauseFeatureUpdatesEndTime';   Kind='String'; Value=$exp.ToString($fmt) }
    @{ Path=$ux; Name='PauseQualityUpdatesStartTime'; Kind='String'; Value=$now.ToString($fmt) }
    @{ Path=$ux; Name='PauseQualityUpdatesEndTime';   Kind='String'; Value=$exp.ToString($fmt) }
    @{ Path=$au; Name='NoAutoUpdate';                 Kind='DWord';  Value=1 }
)
$regState = foreach ($r in $pause) { $snap = Get-RegSnapshot -Path $r.Path -Name $r.Name; Set-RegValue -Path $r.Path -Name $r.Name -Value $r.Value -Kind $r.Kind; $snap }
Log "  paused until $($exp.ToLocalTime().ToString('yyyy-MM-dd HH:mm')) local" DarkGray

# ---- 4. snapshot + disable Defender real-time -----------------------------
$defState = [pscustomobject]@{ Present=$false; RealTimeWasEnabled=$null; Changed=$false }
if (-not $SkipDefender) {
    Write-Host ""
    Log "Disabling Defender real-time protection for the session..." Cyan
    if (Get-Command Set-MpPreference -ErrorAction SilentlyContinue) {
        try { $defState.RealTimeWasEnabled = (Get-MpComputerStatus -ErrorAction Stop).RealTimeProtectionEnabled; $defState.Present = $true } catch {}
        try {
            Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
            Start-Sleep -Milliseconds 500
            if ((Get-MpComputerStatus).RealTimeProtectionEnabled) {
                Log "  ! still ON - Tamper Protection is likely enabled. Turn it off:" Yellow
                Log "    Windows Security > Virus & threat protection > Manage settings > Tamper Protection = Off" Yellow
            } else { $defState.Changed = $true; Log "  Defender real-time protection: DISABLED for this session" Green }
        } catch { Log "  ! could not disable (Tamper Protection on?): $($_.Exception.Message)" Yellow }
    } else { Log "  (Defender cmdlets not available - skipping)" DarkGray }
} else { Log "Defender: left as-is (-SkipDefender)" DarkGray }

# ---- save snapshot --------------------------------------------------------
$state = [pscustomobject]@{
    SavedAt   = (Get-Date).ToString('o')
    PauseDays = $PauseDays
    Services  = @($svcState)
    Tasks     = @($taskState)
    Registry  = @($regState)
    Defender  = $defState
}
try { $state | ConvertTo-Json -Depth 8 | Set-Content -Path $StatePath -Encoding UTF8; Log "State saved -> $StatePath" Green }
catch { Log "FAILED to save state file: $($_.Exception.Message)" Red }

# ---- 5. verify (optional) -------------------------------------------------
if ($Verify) {
    Log "Verify: waiting $VerifyDelay s, then re-checking it held..." Cyan
    Start-Sleep -Seconds $VerifyDelay
    $bad = New-Object System.Collections.Generic.List[string]
    foreach ($e in @($svcState)) {
        if (-not $e.Present) { continue }
        $p   = "HKLM:\SYSTEM\CurrentControlSet\Services\$($e.Name)"
        $cur = (Get-ItemProperty -Path $p -Name 'Start' -ErrorAction SilentlyContinue).Start
        if ($cur -ne 4) { $bad.Add("$($e.Name): Start reverted to $cur (expected 4)") }
        $svc = Get-Service -Name $e.Name -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { $bad.Add("$($e.Name): running again") }
    }
    foreach ($t in @($taskState | Where-Object Disabled)) {
        $st = (Get-ScheduledTask -TaskName $t.Name -TaskPath $t.Path -ErrorAction SilentlyContinue).State
        if ($st -and $st -ne 'Disabled') { $bad.Add("task $($t.Name): re-enabled ($st)") }
    }
    if ($defState.Changed) {
        try { if ((Get-MpComputerStatus).RealTimeProtectionEnabled) { $bad.Add("Defender: real-time back ON") } } catch {}
    }
    if ($bad.Count -eq 0) { Log "Verify: OK - services, tasks, Defender all held for $VerifyDelay s." Green }
    else {
        Log "Verify: SOMETHING REVERTED --" Red
        foreach ($b in $bad) { Log "     $b" Red }
        if (-not (Test-IsSystem)) { Log "Try re-running with -AsSystem. If it still reverts, it's an ownership-locked task or an Intune/GPO policy." Yellow }
        else { Log "Already ran as SYSTEM and it still reverted -> ownership-locked task or management policy." Yellow }
    }
}

Write-Host "  ====================================================================" -ForegroundColor Cyan
Write-Host "  Quiet. Go race. Services stay OFF (even across reboot) until restore." -ForegroundColor Green
Write-Host "  >>> RUN Post-Race-Restore.ps1$(if($AsSystem){' -AsSystem'}) AFTER the session <<<" -ForegroundColor Yellow
Write-Host ""
