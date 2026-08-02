<#
    Pre-Race-Quiet.ps1  -  MEDIC-UNLOCK EDITION               v3.3.0
    ================================================================
    Same as the standard Pre-Race-Quiet, with ONE difference: it takes
    ownership of the WaaSMedicSvc registry key by default, instead of
    asking you to pass -UnlockMedic.

    WHY THIS EXISTS
    ---------------
    On some Windows builds WaaSMedicSvc's registry key is owned by
    TrustedInstaller and refuses to be disabled even when running as SYSTEM.
    Windows Update Medic then keeps switching the update services back on,
    roughly every ten minutes - mid-race, with a stutter each time.

    The standard edition stops at that point and tells you. This edition
    goes through: it takes ownership of that one key, disables the service,
    and hands ownership straight back in the same run.

    USE THIS ONLY IF you have confirmed Medic is the problem. Run
    Trace-QuietReverts.ps1 first - if it reports
        "WaaSMedicSvc: stopped, but could NOT disable (protected)"
    then this edition is what you want. Otherwise use the standard one.

    WHAT CHANGED IN v3.3.0
    ----------------------
    Everything added in this version came from an xperf HARD_FAULTS trace
    of one real 25-minute session - kernel-level, with filenames, not
    inference. It is a single reference machine (Win11, 64 GB, NVMe), so
    treat the numbers as an example of WHAT to look for rather than as
    universal truth; the processes involved are stock Windows components
    that exist on every install. 4,712 hard faults were captured:

        1,729  System (4)              $Mft, $UsnJrnl - NTFS metadata
          829  backgroundTaskHost.exe  WinStore.App.dll  (Microsoft Store)
          251  MicrosoftEdgeUpdate.exe
          245  SearchHost.exe          Start-menu web components
          222  MOZA Pit House.exe
          201  TabTip.exe              touch keyboard
          170  ctfmon.exe
          152  TextInputHost.exe
          130  MarvinsAIRARefactored.exe
          120  Trading Paints.exe
           14  iRacingSim64DX11.exe    <-- the sim

    The sim was responsible for 0.3% of them. Total iRacing content
    faulting for the whole session was 17 events on tracks.dat and
    porsche9922cup.dat, all during track load, which is exactly where
    you want them.

    So this kit is aimed correctly, but v3.2.5 was missing the biggest
    single offender: the Microsoft Store deciding to update apps mid-race.
    Added in v3.3.0: InstallService, edgeupdate/edgeupdatem, PcaSvc,
    TabletInputService, 19 more scheduled tasks, and the Store
    auto-download policy.

    WHAT IT TOUCHES
    ---------------
    HKLM\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc  -  owner and
    permissions, briefly. The original security descriptor is saved to the
    snapshot AND to a separate .sddl file before anything is changed, and
    permissions are handed back within the same run - the key is only in a
    modified state for a few seconds, not for the length of your session.

    Post-Race-Restore re-verifies the owner and permissions afterwards, and
    refuses to delete the snapshot while any key is still unrestored.

    >>> Post-Race-Restore.ps1 IS REQUIRED. <<<
    Services are disabled, not stopped - nothing self-heals on reboot.
    Until you restore, this PC has no Windows Update and, since Defender
    signature updates ride the same services, no fresh definitions.

    USAGE
      .\Pre-Race-Quiet.ps1              quiet + unlock Medic (the point of this edition)
      .\Pre-Race-Quiet.ps1 -Verify      wait 3 min afterwards, report anything that came back
      .\Pre-Race-Quiet.ps1 -NoUnlock    behave like the standard edition
      .\Pre-Race-Quiet.ps1 -KeepSearch  leave Windows Search alone
      .\Pre-Race-Quiet.ps1 -KeepTouchKeyboard  leave TabletInputService alone (VR keyboard)
      .\Pre-Race-Quiet.ps1 -KeepStore   leave the Store auto-download policy alone
      .\Pre-Race-Quiet.ps1 -CloseApps   also close Telegram / MOZA Pit House / webview hosts
      .\Pre-Race-Quiet.ps1 -SkipDefender  leave Defender real-time alone
      .\Pre-Race-Quiet.ps1 -Deadman     auto-restore at next boot if you forget
      .\Pre-Race-Quiet.ps1 -Force       discard the saved snapshot (rarely wanted)

    RUNNING IT TWICE
    ----------------
    Safe. An existing snapshot means you quieted and haven't restored, so it
    re-applies from that snapshot and keeps it. Your original startup types
    and permissions are preserved.

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
    [switch]$Deadman,
    [switch]$NoUnlock,
    [switch]$KeepTouchKeyboard,
    [switch]$KeepStore,
    [switch]$CloseApps
)

# This variant unlocks the Medic key by default. -NoUnlock turns it off.
$UnlockMedic = -not $NoUnlock

# ================================================================
#  WHAT GETS QUIETED
#  The lists live in Kit-Common.ps1 so that this script, the restore,
#  the status screen and the trace all read the same one. EDIT THEM
#  THERE - editing them here would only affect this script.
# ================================================================
$common = Join-Path $PSScriptRoot 'Kit-Common.ps1'
if (-not (Test-Path $common)) {
    Write-Host ""
    Write-Host "  scripts\Kit-Common.ps1 is missing - re-unzip the kit." -ForegroundColor Red
    Write-Host "  It holds the service and task lists this script needs." -ForegroundColor Red
    Write-Host ""
    return
}
. $common
# Provides: $KitVersion, $ServicesToQuiet, $TasksToDisable, $ServiceDefaults



# ================================================================
$StateDir  = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'RaceQuiet'
$StateFile = Join-Path $StateDir 'state.json'
$LogFile   = Join-Path $StateDir 'RaceQuiet.log'
$SvcRoot   = 'HKLM:\SYSTEM\CurrentControlSet\Services'

# ================================================================
#  Speed helpers
# ================================================================
#  Get-ScheduledTask is a CIM call into the Task Scheduler service.
#  Asking for 39 tasks one at a time meant 39 round trips, plus a
#  40th that enumerated every task on the box to find the Edge
#  updaters. One call returns the lot, so we fetch once and look up
#  in memory. On a laptop at low clocks this was most of the wait.
$script:TaskIndex = $null
function Get-TaskIndex {
    param([switch]$Refresh)
    if ($Refresh) { $script:TaskIndex = $null }
    if ($null -ne $script:TaskIndex) { return $script:TaskIndex }
    $idx = @{}
    foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        $idx[([string]$t.TaskPath + [string]$t.TaskName)] = $t
    }
    $script:TaskIndex = $idx
    return $idx
}
function Find-Task {
    param([string]$Path, [string]$Name)
    return (Get-TaskIndex)[($Path + $Name)]
}

#  Per-phase timings, so "it felt slow" can be answered from the log
#  instead of guessed at. Costs nothing; writes to RaceQuiet.log only.
$script:PhaseName = $null
$script:PhaseSw   = $null
$script:PhaseAll  = [System.Diagnostics.Stopwatch]::StartNew()
function Start-Phase {
    param([string]$Name)
    if ($script:PhaseSw) { Stop-Phase }
    $script:PhaseName = $Name
    $script:PhaseSw   = [System.Diagnostics.Stopwatch]::StartNew()
}
function Stop-Phase {
    if (-not $script:PhaseSw) { return }
    $script:PhaseSw.Stop()
    Write-Log ("timing  {0,-28} {1,7:N0} ms" -f $script:PhaseName, $script:PhaseSw.Elapsed.TotalMilliseconds) 'DarkGray' -NoHost
    $script:PhaseSw = $null
}

function Write-Log {
    param([string]$Msg, [string]$Color = 'Gray', [switch]$NoHost)
    $line = ("{0}  {1}" -f ([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)), $Msg)
    try {
        if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
        Add-Content -Path $LogFile -Value $line -Encoding utf8 -ErrorAction SilentlyContinue
    } catch { }
    if (-not $NoHost) { Write-Host ("  " + $Msg) -ForegroundColor $Color }
}


# ================================================================
#  Registry ownership helpers - only used by -UnlockMedic
# ================================================================
function Initialize-Privileges {
    # Taking ownership needs SeTakeOwnershipPrivilege, and handing it back to
    # TrustedInstaller needs SeRestorePrivilege. Admins hold both, but they
    # are disabled in the token until explicitly enabled.
    if ('RQPriv' -as [type]) { return $true }
    $code = @'
using System;
using System.Runtime.InteropServices;
public class RQPriv {
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool LookupPrivilegeValue(string host, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool AdjustTokenPrivileges(IntPtr tok, bool disall, ref TOKPRIV1LUID newst, int len, IntPtr prev, IntPtr rel);
    [StructLayout(LayoutKind.Sequential, Pack=1)]
    public struct TOKPRIV1LUID { public int Count; public long Luid; public int Attr; }
    public static bool Enable(string priv) {
        IntPtr tok = IntPtr.Zero;
        if (!OpenProcessToken(System.Diagnostics.Process.GetCurrentProcess().Handle, 0x28, out tok)) return false;
        TOKPRIV1LUID tp;
        tp.Count = 1;
        tp.Luid  = 0;
        tp.Attr  = 2;   // SE_PRIVILEGE_ENABLED
        if (!LookupPrivilegeValue(null, priv, out tp.Luid)) return false;
        return AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
    }
}
'@
    try { Add-Type -TypeDefinition $code -ErrorAction Stop } catch { return $false }
    return $true
}

function Unlock-ServiceKey {
    <#
        Take ownership of a service's registry key so its Start value can be
        written. Returns the ORIGINAL owner + SDDL so it can be handed back.
        Returns $null if anything failed - in which case nothing was changed.
    #>
    param([string]$ServiceName)

    $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    $sub  = "SYSTEM\CurrentControlSet\Services\$ServiceName"

    if (-not (Initialize-Privileges)) { Write-Log "could not compile the privilege helper" 'Yellow'; return $null }
    [void][RQPriv]::Enable('SeTakeOwnershipPrivilege')
    [void][RQPriv]::Enable('SeRestorePrivilege')
    [void][RQPriv]::Enable('SeBackupPrivilege')

    # capture BEFORE touching anything
    $origSddl = $null; $origOwner = $null
    try {
        $acl = Get-Acl -Path $path -ErrorAction Stop
        $origSddl  = $acl.Sddl
        $origOwner = [string]$acl.Owner
    } catch {
        Write-Log "could not read the security descriptor on $ServiceName - not touching it" 'Yellow'
        return $null
    }
    Write-Log ("original owner of {0}: {1}" -f $ServiceName, $origOwner) 'DarkGray'

    # belt and braces: a copy on disk as well as in the snapshot
    try { Set-Content -Path (Join-Path $StateDir "$ServiceName.sddl") -Value ("{0}`n{1}" -f $origOwner, $origSddl) -Encoding utf8 } catch { }

    try {
        $me  = New-Object System.Security.Principal.NTAccount('BUILTIN\Administrators')
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($sub, 'ReadWriteSubTree', 'TakeOwnership')
        $sec = $key.GetAccessControl([System.Security.AccessControl.AccessControlSections]::None)
        $sec.SetOwner($me)
        $key.SetAccessControl($sec)
        $key.Close()

        $key2 = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($sub, 'ReadWriteSubTree', 'ChangePermissions')
        $sec2 = $key2.GetAccessControl()
        $rule = New-Object System.Security.AccessControl.RegistryAccessRule($me,'FullControl','ContainerInherit','None','Allow')
        $sec2.SetAccessRule($rule)
        $key2.SetAccessControl($sec2)
        $key2.Close()
    } catch {
        Write-Log ("could not take ownership of {0}: {1}" -f $ServiceName, $_.Exception.Message) 'Yellow'
        return $null
    }

    return [pscustomobject]@{ Name = $ServiceName; Owner = $origOwner; Sddl = $origSddl }
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
    if ($NoUnlock)     { $argList += '-NoUnlock' }
    if ($KeepTouchKeyboard) { $argList += '-KeepTouchKeyboard' }
    if ($KeepStore)    { $argList += '-KeepStore' }
    if ($CloseApps)    { $argList += '-CloseApps' }
    try   { Start-Process powershell.exe -Verb RunAs -ArgumentList $argList }
    catch { Write-Host "Elevation cancelled - nothing was changed." -ForegroundColor Yellow }
    return
}

if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

Write-Host ""
Write-Host "========  PRE-RACE QUIET (MEDIC-UNLOCK EDITION)  ========" -ForegroundColor Cyan
if ($UnlockMedic) {
    Write-Host "  Medic unlock is ON. If WaaSMedicSvc refuses to disable, this" -ForegroundColor Yellow
    Write-Host "  will take ownership of its registry key, disable it, and hand" -ForegroundColor Yellow
    Write-Host "  ownership straight back. Original permissions are saved first." -ForegroundColor Yellow
    Write-Host "  Run with -NoUnlock to behave like the standard edition." -ForegroundColor DarkGray
}
Write-Log ("=== Pre-Race-Quiet v{0} starting ===" -f $KitVersion) 'Gray' -NoHost

# ---- an un-restored snapshot means we are already quiet ----------
# Don't refuse and don't re-snapshot: the machine is currently quieted, so
# capturing now would record the QUIETED state as "original" and a later
# restore would leave the services disabled forever. Instead, re-apply using
# the snapshot we already have. The original state is never lost.
$ReQuiet     = $false
$LoadedSnap  = $null
if (Test-Path $StateFile) {
    if ($Force) {
        Write-Host ""
        Write-Host "  -Force: discarding the previous snapshot." -ForegroundColor Yellow
        Write-Host "  Only do this if you have already restored by hand, otherwise the" -ForegroundColor Yellow
        Write-Host "  services' original startup types are lost and Post-Race-Restore" -ForegroundColor Yellow
        Write-Host "  will fall back to Windows defaults." -ForegroundColor Yellow
        Write-Log "-Force supplied: discarding existing snapshot" 'Yellow' -NoHost
    } else {
        try { $LoadedSnap = Get-Content $StateFile -Raw | ConvertFrom-Json } catch { $LoadedSnap = $null }
        if ($LoadedSnap) {
            $ReQuiet = $true
            Write-Host ""
            Write-Host "  Already quieted from an earlier session - re-applying." -ForegroundColor Cyan
            Write-Host ("  Original state was saved {0} UTC and is being kept." -f $LoadedSnap.CreatedUtc) -ForegroundColor DarkGray
            Write-Host "  Anything Windows switched back on will be shut down again." -ForegroundColor DarkGray
            Write-Log "re-quiet from existing snapshot" 'Gray' -NoHost
        } else {
            Write-Host ""
            Write-Host "  A state file exists but could not be read - starting fresh." -ForegroundColor Yellow
            Write-Log "unreadable state file, re-snapshotting" 'Yellow' -NoHost
        }
    }
}

if ($KeepSearch)        { $ServicesToQuiet = @($ServicesToQuiet | Where-Object { $_ -ne 'WSearch' }) }
if ($KeepTouchKeyboard) { $ServicesToQuiet = @($ServicesToQuiet | Where-Object { $_ -ne 'TabletInputService' }) }

# ================================================================
#  1. SNAPSHOT  -  capture real prior state BEFORE touching anything
# ================================================================
Write-Host ""
if ($ReQuiet) { Write-Host "1. Using the saved snapshot (not overwriting it)" -ForegroundColor White }
else          { Write-Host "1. Snapshotting current state" -ForegroundColor White }

$snapServices = @()
if ($ReQuiet) {
    $snapServices = @($LoadedSnap.Services)
    $snapTasks    = @($LoadedSnap.Tasks)
    $defenderWasOn = $LoadedSnap.DefenderWasOn
    Write-Host ("  {0} service(s), {1} task(s) from the saved snapshot" -f $snapServices.Count, $snapTasks.Count) -ForegroundColor Green

    # The curated list can grow between releases. A task in $TasksToDisable
    # that this snapshot has never heard of was never touched by the earlier
    # run, so whatever state it is in NOW is its original state. Capture it,
    # append it, and re-save. Without this a re-quiet silently skips every
    # task added since the snapshot was written, and Post-Race-Restore has no
    # record of them to put back.
    $knownTasks = @{}
    foreach ($k in $snapTasks) { $knownTasks[([string]$k.Path + [string]$k.Name)] = $true }
    $addedTasks = @()
    foreach ($t in $TasksToDisable) {
        if ($knownTasks.ContainsKey($t.Path + $t.Name)) { continue }
        $obj = Find-Task $t.Path $t.Name
        if (-not $obj) { continue }
        $addedTasks += [pscustomobject]@{ Path = $t.Path; Name = $t.Name; State = [string]$obj.State }
        Write-Log ("new since snapshot, captured as {0}: {1}{2}" -f $obj.State, $t.Path, $t.Name) 'DarkGray'
    }
    if ($addedTasks.Count -gt 0) {
        $snapTasks = @($snapTasks) + $addedTasks
        Write-Host ("  + {0} task(s) added to the list since that snapshot - captured now" -f $addedTasks.Count) -ForegroundColor Yellow
        try {
            $LoadedSnap.Tasks = $snapTasks
            $LoadedSnap | ConvertTo-Json -Depth 6 | Out-File -FilePath $StateFile -Encoding utf8 -ErrorAction Stop
            Write-Host "  snapshot updated so the restore knows about them" -ForegroundColor Green
            Write-Log ("snapshot extended with {0} newly-listed task(s)" -f $addedTasks.Count) 'Green' -NoHost
        } catch {
            Write-Host "  WARNING: could not update the snapshot file." -ForegroundColor Red
            Write-Host "  Those tasks will be disabled, but Post-Race-Restore will not know" -ForegroundColor Red
            Write-Host "  to re-enable them. Re-enable them by hand after your session." -ForegroundColor Red
            Write-Log "FAILED to re-save snapshot after extension" 'Red' -NoHost
        }
    }
}
else {
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

Start-Phase 'read scheduled tasks'
Write-Progress -Activity 'Pre-Race-Quiet' -Status 'Reading the scheduled task list' -PercentComplete 5
$taskIdx  = Get-TaskIndex          # one CIM call, not 40
$snapTasks = @()
$i = 0
foreach ($t in $TasksToDisable) {
    $i++
    Write-Progress -Activity 'Pre-Race-Quiet' -Status ("Checking scheduled tasks ({0} of {1})" -f $i, $TasksToDisable.Count) `
                   -CurrentOperation ($t.Path + $t.Name) -PercentComplete (5 + (15 * $i / $TasksToDisable.Count))
    $task = $taskIdx[($t.Path + $t.Name)]
    if (-not $task) { continue }
    $snapTasks += [pscustomobject]@{ Path = $t.Path; Name = $t.Name; State = [string]$task.State }
}
# Edge updaters (names carry a GUID, so match by pattern) - same index,
# no second enumeration of every task on the machine.
foreach ($e in $taskIdx.Values) {
    if ($e.TaskName -like 'MicrosoftEdgeUpdateTaskMachine*') {
        $snapTasks += [pscustomobject]@{ Path = $e.TaskPath; Name = $e.TaskName; State = [string]$e.State }
    }
}
Stop-Phase

$defenderWasOn = $null
if (-not $SkipDefender) {
    # First touch of a Defender cmdlet makes PowerShell import the Defender
    # module, which is the single slowest thing in a cold run. Timed so the
    # log says so plainly rather than leaving it to guesswork.
    Start-Phase 'load Defender module'
    Write-Progress -Activity 'Pre-Race-Quiet' -Status 'Querying Defender (slow on a cold start)' -PercentComplete 22
    if (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) {
        try { $defenderWasOn = [bool](Get-MpComputerStatus -ErrorAction Stop).RealTimeProtectionEnabled } catch { }
    }
    Stop-Phase
}

$snapshot = [pscustomobject]@{
    SchemaVersion = 1
    Tool          = ('Pre-Race-Quiet v{0}' -f $KitVersion)
    CreatedUtc    = (Get-Date).ToUniversalTime().ToString('s')
    Machine       = $env:COMPUTERNAME
    Services      = $snapServices
    Tasks         = $snapTasks
    DefenderWasOn = $defenderWasOn
    KeptSearch    = [bool]$KeepSearch
    SkippedDefender = [bool]$SkipDefender
    Deadman       = [bool]$Deadman
    UnlockedKeys  = @()
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
}   # end of fresh-snapshot branch

# ================================================================
#  2. SCHEDULED TASKS
# ================================================================
Write-Host ""
Write-Host "2. Disabling scheduled tasks" -ForegroundColor White
Start-Phase 'disable scheduled tasks'
$failedTasks = @()
$i = 0
foreach ($s in $snapTasks) {
    $i++
    Write-Progress -Activity 'Pre-Race-Quiet' -Status ("Disabling scheduled tasks ({0} of {1})" -f $i, $snapTasks.Count) `
                   -CurrentOperation ($s.Path + $s.Name) -PercentComplete (25 + (25 * $i / [Math]::Max(1,$snapTasks.Count)))
    if ($s.State -eq 'Disabled') { Write-Log ("already disabled: {0}{1}" -f $s.Path, $s.Name) 'DarkGray'; continue }
    try {
        Disable-ScheduledTask -TaskPath $s.Path -TaskName $s.Name -ErrorAction Stop | Out-Null
        Write-Log ("disabled task: {0}{1}" -f $s.Path, $s.Name) 'Green'
    } catch {
        $failedTasks += $s
        Write-Log ("could not disable (will retry as SYSTEM): {0}{1}" -f $s.Path, $s.Name) 'DarkGray'
    }
}
Stop-Phase

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

    # Poll every 100ms rather than every second. The helper usually reports
    # back in well under a second; the old loop slept a full second before
    # even looking, so a fast success still cost a second and a silent
    # failure cost the whole 30. Same 30s ceiling, far shorter typical wait.
    Start-Phase 'SYSTEM helper'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path $marker) -and $sw.Elapsed.TotalSeconds -lt 30) {
        Write-Progress -Activity 'Pre-Race-Quiet' `
                       -Status ("Retrying {0} protected task(s) as SYSTEM" -f $failedTasks.Count) `
                       -CurrentOperation ("waited {0:N1}s of 30" -f $sw.Elapsed.TotalSeconds) `
                       -PercentComplete 55
        Start-Sleep -Milliseconds 100
    }
    $sw.Stop()
    Stop-Phase
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
Start-Phase 'disable + stop services'
$script:UnlockedKeys = @()
$i = 0
foreach ($s in $snapServices) {
    $name = $s.Name
    $key  = Join-Path $SvcRoot $name
    $i++
    # Stop-Service blocks until the service actually stops. WSearch mid-index
    # is the usual culprit for a long pause here, so name what we are waiting on.
    Write-Progress -Activity 'Pre-Race-Quiet' -Status ("Stopping services ({0} of {1})" -f $i, $snapServices.Count) `
                   -CurrentOperation ("{0} - this one can take a few seconds" -f $name) `
                   -PercentComplete (60 + (25 * $i / [Math]::Max(1,$snapServices.Count)))

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

    # ---- last resort: the key is TrustedInstaller-owned -----------
    if (-not $disabled -and $UnlockMedic) {
        Write-Log ("{0}: protected - taking ownership of its registry key" -f $name) 'Yellow'
        $unlocked = Unlock-ServiceKey -ServiceName $name
        if ($unlocked) {
            try {
                Set-ItemProperty -Path $key -Name 'Start' -Value 4 -Type DWord -ErrorAction Stop
                $disabled = $true
                $script:UnlockedKeys += $unlocked
                Write-Log ("{0}: DISABLED after taking ownership" -f $name) 'Green'
            } catch {
                Write-Log ("{0}: still refused after taking ownership - {1}" -f $name, $_.Exception.Message) 'Yellow'
            }
            # hand ownership straight back - don't leave it changed a moment longer
            try {
                $a = Get-Acl -Path $key
                $a.SetSecurityDescriptorSddlForm($unlocked.Sddl)
                Set-Acl -Path $key -AclObject $a -ErrorAction Stop
                Write-Log ("{0}: original permissions restored immediately" -f $name) 'DarkGray'
            } catch {
                Write-Log ("{0}: could NOT hand permissions back yet - Post-Race-Restore will retry" -f $name) 'Yellow'
            }
        }
        if (-not $stopped) {
            try { Stop-Service -Name $name -Force -ErrorAction Stop; $stopped = $true } catch { }
        }
    }

    if ($disabled -and $stopped)      { Write-Log ("{0}: disabled + stopped" -f $name) 'Green' }
    elseif ($disabled)                { Write-Log ("{0}: disabled, still running - it will not come back after a reboot" -f $name) 'Yellow' }
    elseif ($stopped)                 { Write-Log ("{0}: stopped, but could NOT disable (protected) - may return" -f $name) 'Yellow'
                                        if (-not $UnlockMedic) { Write-Log ("   re-run with -UnlockMedic to force it (see the script header)" -f $name) 'Yellow' } }
    else                              { Write-Log ("{0}: could not disable or stop (protected)" -f $name) 'Yellow' }
}
Stop-Phase

# ---- record any keys we had to unlock, so the restore can verify ----
if ($script:UnlockedKeys.Count -gt 0) {
    try {
        $snapshot.UnlockedKeys = @($script:UnlockedKeys)
        $snapshot | ConvertTo-Json -Depth 6 | Out-File -FilePath $StateFile -Encoding utf8 -ErrorAction Stop
        Write-Log ("saved original permissions for {0} key(s) to the snapshot" -f $script:UnlockedKeys.Count) 'DarkGray'
    } catch {
        Write-Log "COULD NOT save the original permissions to the snapshot" 'Red'
        foreach ($u in $script:UnlockedKeys) {
            Write-Log ("  keep this: {0} owner={1}" -f $u.Name, $u.Owner) 'Red'
        }
    }
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
#  4b. MICROSOFT STORE AUTO-DOWNLOAD                        v3.3.0
# ================================================================
#  Disabling InstallService stops the engine, but the Store app can still
#  be woken by its background task. This policy value is what actually
#  stops it deciding to update apps while you are on track.
#
#  Original state goes to its own file rather than into the snapshot, so
#  the schema and the re-quiet path are untouched. Post-Race-Restore
#  looks for it the same way it looks for the .sddl files.
if (-not $KeepStore) {
    Write-Host ""
    Write-Host "4b. Microsoft Store auto-download" -ForegroundColor White
    $storeKey  = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
    $storeFile = Join-Path $StateDir 'storepolicy.json'
    try {
        if (-not (Test-Path $storeFile)) {
            $hadKey = Test-Path $storeKey
            $hadVal = $null
            if ($hadKey) {
                $pv = Get-ItemProperty -Path $storeKey -Name 'AutoDownload' -ErrorAction SilentlyContinue
                if ($null -ne $pv) { $hadVal = [int]$pv.AutoDownload }
            }
            [pscustomobject]@{ KeyExisted = $hadKey; Value = $hadVal } |
                ConvertTo-Json | Out-File -FilePath $storeFile -Encoding utf8 -ErrorAction Stop
            Write-Log ("captured original Store policy: keyExisted={0} value={1}" -f $hadKey, $hadVal) 'DarkGray'
        } else {
            Write-Log "Store policy already captured from an earlier run - keeping it" 'DarkGray'
        }
        if (-not (Test-Path $storeKey)) { New-Item -Path $storeKey -Force | Out-Null }
        Set-ItemProperty -Path $storeKey -Name 'AutoDownload' -Value 2 -Type DWord -ErrorAction Stop
        Write-Log "Store app auto-download: OFF for this session" 'Green'
    } catch {
        Write-Log ("could not set the Store policy: {0}" -f $_.Exception.Message) 'Yellow'
    }
}

# ================================================================
#  4c. NOISY USER APPS                                      v3.3.0
# ================================================================
#  These are not services and are not restored automatically - closing
#  an app you launched is your call, and there is no safe way to put a
#  user session back exactly as it was. By default this only REPORTS.
#  Pass -CloseApps to actually close them.
#
#  Two tiers. Safe=$true means -CloseApps may close it: chat clients and
#  shell components that respawn on demand. Safe=$false is REPORT ONLY and
#  is never closed even with -CloseApps - wheelbase and headset software
#  can own force-feedback profiles or a runtime the sim needs, and killing
#  it mid-setup breaks people's rigs. Those are listed so the user can
#  decide for themselves.
$NoisyApps = @(
    # --- chat / background clients: safe to close ---
    @{ Name='Telegram';       Safe=$true;  Why='chat client' },
    @{ Name='Discord';        Safe=$true;  Why='chat client (close only if not using voice)' },
    @{ Name='Slack';          Safe=$true;  Why='chat client' },
    @{ Name='WhatsApp';       Safe=$true;  Why='chat client' },
    @{ Name='Signal';         Safe=$true;  Why='chat client' },
    @{ Name='Spotify';        Safe=$true;  Why='streams and caches to disk' },
    @{ Name='msedgewebview2'; Safe=$true;  Why='webview host, wakes with Store/Edge activity' },
    # --- shell components: respawn on demand, safe to close ---
    @{ Name='TabTip';         Safe=$true;  Why='touch keyboard, respawns when needed' },
    @{ Name='TextInputHost';  Safe=$true;  Why='text input host, respawns when needed' },
    # --- report only: never auto-closed ---
    @{ Name='SearchHost';     Safe=$false; Why='shell component - respawns instantly, closing achieves nothing' },
    @{ Name='MOZA Pit House'; Safe=$false; Why='wheelbase software - may hold your FFB profile' },
    @{ Name='FanaLab';        Safe=$false; Why='wheelbase software - may hold your FFB profile' },
    @{ Name='TrueDrive';      Safe=$false; Why='wheelbase software - may hold your FFB profile' },
    @{ Name='SimPro Manager'; Safe=$false; Why='wheelbase software - may hold your FFB profile' },
    @{ Name='lghub';          Safe=$false; Why='wheelbase software - may hold your FFB profile' },
    @{ Name='lghub_agent';    Safe=$false; Why='wheelbase software - may hold your FFB profile' },
    @{ Name='RaceHub';        Safe=$false; Why='wheelbase software - may hold your FFB profile' },
    @{ Name='MSIAfterburner'; Safe=$false; Why='monitoring - you may want its overlay' },
    @{ Name='RTSS';           Safe=$false; Why='frame limiter - closing it can change your frame pacing' },
    @{ Name='HWiNFO64';       Safe=$false; Why='monitoring - you may be logging with it' }
)
# One process enumeration instead of 21 separate Get-Process calls.
Start-Phase 'scan background apps'
$running = @{}
foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
    if ($running.ContainsKey($p.ProcessName)) { $running[$p.ProcessName]++ } else { $running[$p.ProcessName] = 1 }
}
$found = @()
foreach ($a in $NoisyApps) {
    if ($running.ContainsKey($a.Name)) {
        $found += [pscustomobject]@{ Name=$a.Name; Why=$a.Why; Count=$running[$a.Name]; Safe=$a.Safe }
    }
}
Stop-Phase
if ($found.Count -gt 0) {
    Write-Host ""
    Write-Host "4c. Background apps worth closing before you drive" -ForegroundColor White
    foreach ($f in $found) {
        $tag = if ($f.Safe) { ' ' } else { '*' }
        Write-Host ("   {0} {1,-18} running ({2})  - {3}" -f $tag, $f.Name, $f.Count, $f.Why) -ForegroundColor Yellow
    }
    if (@($found | Where-Object { -not $_.Safe }).Count -gt 0) {
        Write-Host "     * report only - never closed automatically, your call" -ForegroundColor DarkGray
    }
    if ($CloseApps) {
        foreach ($f in $found) {
            if (-not $f.Safe) { Write-Log ("left running (report only): {0}" -f $f.Name) 'DarkGray'; continue }
            try {
                Stop-Process -Name $f.Name -Force -ErrorAction Stop
                Write-Log ("closed: {0}" -f $f.Name) 'Green'
            } catch {
                Write-Log ("could not close {0}: {1}" -f $f.Name, $_.Exception.Message) 'Yellow'
            }
        }
        Write-Host "     Closed apps are NOT reopened by Post-Race-Restore - relaunch what you want." -ForegroundColor DarkGray
    } else {
        Write-Host "     Reporting only. Pass -CloseApps to close the unmarked ones." -ForegroundColor DarkGray
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
    # -Refresh is essential here: the whole point of verify is to see what
    # changed since, so the cached index from earlier must be thrown away.
    # Still one CIM call rather than one per task.
    $freshIdx = Get-TaskIndex -Refresh
    foreach ($t in $snapTasks) {
        $now = $freshIdx[($t.Path + $t.Name)]
        if ($now -and $now.State -ne 'Disabled') { Write-Log ("REVERTED: task {0}{1} is enabled again" -f $t.Path, $t.Name) 'Yellow'; $bad++ }
    }
    if ($bad -eq 0) { Write-Log "nothing came back - the machine is holding quiet" 'Green' }
    else            { Write-Log ("{0} item(s) reverted - see above" -f $bad) 'Yellow' }
}

Stop-Phase
Write-Progress -Activity 'Pre-Race-Quiet' -Completed
$script:PhaseAll.Stop()
Write-Log ("timing  {0,-28} {1,7:N0} ms  TOTAL" -f 'whole run', $script:PhaseAll.Elapsed.TotalMilliseconds) 'DarkGray' -NoHost

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ("  Quiet. Go race.   ({0:N1}s)" -f $script:PhaseAll.Elapsed.TotalSeconds) -ForegroundColor Green
Write-Host ""
Write-Host "  >>> RUN Post-Race-Restore.ps1 AFTERWARDS <<<" -ForegroundColor Yellow
Write-Host "  This survives a reboot. Until you restore, this PC has no" -ForegroundColor Yellow
Write-Host "  Windows Update and no fresh Defender definitions." -ForegroundColor Yellow
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""
Write-Log "=== Pre-Race-Quiet finished ===" 'Gray' -NoHost
