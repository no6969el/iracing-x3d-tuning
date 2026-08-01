<#
    Kit-Common.ps1  -  shared constants for the race-quiet scripts    v3.3.0
    ================================================================
    SINGLE SOURCE OF TRUTH for the kit version and for everything
    Pre-Race-Quiet turns off. Dot-source it:

        . (Join-Path $PSScriptRoot 'Kit-Common.ps1')

    WHY THIS EXISTS
    ---------------
    The service list used to live in four places and the task list in
    four more, each with a hand-written "must mirror Pre-Race-Quiet"
    comment above it. Those comments were an admission that the lists
    drift - and they did. v3.2.5's own changelog entry reads "the quiet
    list was incomplete, and the status screen agreed with it": the
    quiet script gained services, the status screen did not, and it
    reported "race ready" while they were still running.

    Editing this file now updates every script at once. There is
    nothing left to keep in step by hand.

    WHAT READS WHAT
      $KitVersion         every script's banner
      $ServicesToQuiet    Pre-Race-Quiet   disables them
                          Post-Race-Restore restores them
                          Check-Quiet-Status reports on them
                          Trace-QuietReverts watches them for reverts
      $TasksToDisable     the same four scripts
      $ServiceDefaults    Post-Race-Restore only, and only when there is
                          no snapshot to replay

    This file only declares data. It runs nothing, changes nothing, and
    needs no elevation, so it is safe for a read-only script to load.
#>

# ================================================================
#  KIT VERSION
#  Bump here and every script's banner follows.
# ================================================================
$KitVersion = '3.3.0'

# ================================================================
#  SERVICES
#  EDIT HERE if you want to trim what gets quieted.
#  Order matters: Medic first so it can't react to the rest.
# ================================================================
$ServicesToQuiet = @(
    'WaaSMedicSvc',   # Update Medic - the thing that undoes all of this
    'UsoSvc',         # Update Orchestrator
    'wuauserv',       # Windows Update
    'bits',           # Background Intelligent Transfer (update downloads)
    'DoSvc',          # Delivery Optimization
    'WSearch',        # Windows Search  (skipped with -KeepSearch)

    # ---- Added v3.3.0 from an xperf HARD_FAULTS trace ----------------
    # 25-minute Nordschleife session, 4,712 hard faults captured WITH
    # filenames (kernel HARD_FAULTS+FILENAME providers, not inference).
    # iRacingSim64DX11.exe accounted for 14 of them. The five services
    # below accounted for 1,547 between them - two orders of magnitude
    # more than the sim itself.
    'InstallService',      # Store install/update engine.  Drove backgroundTaskHost.exe
                           # faulting 829 times on WinStore.App.dll (15.9 MB) mid-race.
    'edgeupdate',          # MicrosoftEdgeUpdate.exe, 251 faults. The scheduled tasks
    'edgeupdatem',         # were already handled; the SERVICES were not.
    'PcaSvc',              # Program Compatibility Assistant -> Amcache.hve, 101 faults
    'TabletInputService'   # touch keyboard: TabTip 201 + TextInputHost 152 + ctfmon 170.
                           # Skipped with -KeepTouchKeyboard if you use it in VR.
                           # NOTE: absent on Windows 11 24H2 and later - the service was
                           # retired and TabTip is shell-launched instead. The script
                           # skips it harmlessly there; TabTip is handled in 4c instead.
)

# ================================================================
#  SCHEDULED TASKS
# ================================================================
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
    @{ Path='\Microsoft\Windows\LanguageComponentsInstaller\';  Name='ReconcileLanguageResources' },

    # ---- Added after a field trace showed these firing mid-session ----
    # 14 launches in a 17-minute window on an 8-core X3D rig, none of
    # them covered above. The two UpdateOrchestrator entries both run
    # usoclient.exe; the rest are telemetry/flighting and cost nothing
    # to hold off for the length of a race.
    @{ Path='\Microsoft\Windows\UpdateOrchestrator\';           Name='Schedule Work' },
    @{ Path='\Microsoft\Windows\UpdateOrchestrator\';           Name='Start Oobe Expedite Work' },
    @{ Path='\Microsoft\Windows\Flighting\FeatureConfig\';      Name='ReconcileFeatures' },
    @{ Path='\Microsoft\Windows\Flighting\FeatureConfig\';      Name='UsageDataReceiver' },
    @{ Path='\Microsoft\Windows\Flighting\FeatureConfig\';      Name='UsageDataFlushing' },
    @{ Path='\Microsoft\Windows\Flighting\OneSettings\';        Name='RefreshCache' },
    @{ Path='\Microsoft\Windows\Windows Error Reporting\';      Name='QueueReporting' },
    @{ Path='\Microsoft\Windows\DeviceDirectoryClient\';        Name='RegisterUserDevice' },
    @{ Path='\Microsoft\Windows\WindowsAI\Settings\';           Name='InitialConfiguration' },

    # ---- Added v3.3.0 from the same HARD_FAULTS trace ----------------
    # Store app auto-update was the single largest non-kernel faulter.
    @{ Path='\Microsoft\Windows\WindowsUpdate\';                Name='Automatic App Update' },
    @{ Path='\Microsoft\Windows\WindowsUpdate\';                Name='Scheduled Start' },
    # Application Experience wrote Amcache.hve during the session.
    @{ Path='\Microsoft\Windows\Application Experience\';       Name='Microsoft Compatibility Appraiser' },
    @{ Path='\Microsoft\Windows\Application Experience\';       Name='ProgramDataUpdater' },
    @{ Path='\Microsoft\Windows\Application Experience\';       Name='StartupAppTask' },
    @{ Path='\Microsoft\Windows\Application Experience\';       Name='PcaPatchDbTask' },
    @{ Path='\Microsoft\Windows\Application Experience\';       Name='MareBackup' },
    @{ Path='\Microsoft\Windows\Customer Experience Improvement Program\'; Name='Consolidator' },
    @{ Path='\Microsoft\Windows\Customer Experience Improvement Program\'; Name='UsbCeip' },
    @{ Path='\Microsoft\Windows\Feedback\Siuf\';                Name='DmClient' },
    @{ Path='\Microsoft\Windows\Feedback\Siuf\';                Name='DmClientOnScenarioDownload' },
    # Heavy maintenance. Any of these landing mid-race is a guaranteed
    # hitch, and none of them need to run in the next 45 minutes.
    @{ Path='\Microsoft\Windows\Defrag\';                       Name='ScheduledDefrag' },
    @{ Path='\Microsoft\Windows\DiskCleanup\';                  Name='SilentCleanup' },
    @{ Path='\Microsoft\Windows\DiskFootprint\';                Name='Diagnostics' },
    @{ Path='\Microsoft\Windows\Chkdsk\';                       Name='ProactiveScan' },
    @{ Path='\Microsoft\Windows\Maintenance\';                  Name='WinSAT' },
    @{ Path='\Microsoft\Windows\Servicing\';                    Name='StartComponentCleanup' },
    @{ Path='\Microsoft\Windows\Registry\';                     Name='RegIdleBackup' },
    @{ Path='\Microsoft\Windows\StateRepository\';              Name='MaintenanceTasks' }

    # Security maintenance (Secure Boot DBX + TPM). Fires rarely and is
    # short. Uncomment only if you have traced it hitting a session.
    #
    # Note: before v3.3.0 this line was commented out here but PRESENT in
    # Post-Race-Restore's no-snapshot fallback, so a restore could enable
    # a task the quiet had never disabled. Sharing one list removes that.
    # ,@{ Path='\Microsoft\Windows\PI\'; Name='Secure-Boot-Update' }
)

# ================================================================
#  RESTORE DEFAULTS
#  Used by Post-Race-Restore ONLY when there is no snapshot to replay.
#  Every service in $ServicesToQuiet needs an entry here.
#  2 = Automatic, 3 = Manual, 4 = Disabled
# ================================================================
$ServiceDefaults = @{
    'WaaSMedicSvc'       = 3
    'UsoSvc'             = 2
    'wuauserv'           = 3
    'bits'               = 3
    'DoSvc'              = 2
    'WSearch'            = 2
    'InstallService'     = 3
    'edgeupdate'         = 2
    'edgeupdatem'        = 3
    'PcaSvc'             = 2
    'TabletInputService' = 3
}

# ================================================================
#  HARD-FAULT TRACING
#  Shared by FullTrace (which captures) and Scan-Stutter-Events
#  (which reads what it produced). Preflight-Check reports on it.
# ================================================================
# The whole point of this file is that a fact stated in two places
# drifts. The xperf lookup and the output filenames are exactly that
# kind of fact, so they live here rather than in each script.

# ETW session name. xperf's kernel logger is a single global session,
# so a run left behind by a force-closed window blocks the next one -
# and keeps writing to disk. Preflight-Check looks for this.
$HardFaultSessionName = 'NT Kernel Logger'

# PROC_THREAD + LOADER give process names; HARD_FAULTS is the payload;
# FILENAME is what resolves kernel file objects to real paths. Without
# FILENAME you get faults with no names, which is useless.
$HardFaultProviders = 'PROC_THREAD+LOADER+HARD_FAULTS+FILENAME'

# Filename patterns, so the producer and the consumer cannot disagree.
$FullTraceCsvPattern  = 'iRacing-FullTrace-*.csv'
$HardFaultCsvPattern  = 'iRacing-HardFaults-*.csv'

# Columns FullTrace appends when the hard-fault trace ran. Their
# absence is how every reader detects a plain (non-elevated) trace.
$HardFaultColumns = @('sim_hardfaults_s','top_fault_proc','top_fault_file')

function Find-Xperf {
    <#
        .SYNOPSIS
        Locate xperf.exe from the Windows Performance Toolkit, or $null.

        .DESCRIPTION
        Ships with the Windows ADK and is not on PATH by default, so the
        install locations are checked first and PATH second. Returns
        $null rather than throwing - every caller treats a missing
        toolkit as "degrade quietly", never as an error.
    #>
    foreach ($cand in @(
        'C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\xperf.exe'
        'C:\Program Files\Windows Kits\10\Windows Performance Toolkit\xperf.exe'
    )) { if (Test-Path -LiteralPath $cand) { return $cand } }

    $cmd = Get-Command xperf.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Test-HardFaultTraceRunning {
    <#
        .SYNOPSIS
        Is a kernel trace session currently active? $true / $false / $null
        when it cannot be determined.

        .DESCRIPTION
        Uses logman rather than xperf so this works even without the
        toolkit installed - a session can be left running by a kit that
        has since been partially removed.
    #>
    try {
        $out = & logman.exe query -ets 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -and -not $out) { return $null }
        return [bool]($out -match [regex]::Escape($HardFaultSessionName))
    } catch { return $null }
}

# ================================================================
#  CONSOLE QUICKEDIT
# ================================================================
# Windows consoles ship with QuickEdit on. Click anywhere in the window
# and the console enters selection mode, which BLOCKS the process on its
# next write to stdout until Enter or Esc is pressed.
#
# For a sampling loop that is not cosmetic. The loop stalls, so no CSV
# row is written either - and the result is a gap in the timestamps that
# looks exactly like a system stall. A stray click can therefore
# manufacture the very stutter the tool exists to find.
#
# Noticed on the elevated ("Hard faults") run in particular: an elevated
# console is a different window and reads its own defaults, so QuickEdit
# can be on there while off in a normal window.
#
# Callers disable it for the life of the script and restore the original
# mode on exit. Restoring matters - leaving a user's console permanently
# unable to select text would be its own bug.

if (-not ([System.Management.Automation.PSTypeName]'KitConsole').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class KitConsole {
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

    const int  STD_INPUT_HANDLE      = -10;
    const uint ENABLE_QUICK_EDIT     = 0x0040;
    // Without EXTENDED_FLAGS the QuickEdit bit is ignored on write.
    const uint ENABLE_EXTENDED_FLAGS = 0x0080;

    public static uint GetMode() {
        uint m;
        if (!GetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), out m)) return 0;
        return m;
    }
    public static bool SetMode(uint m) {
        return SetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), m);
    }
    public static bool DisableQuickEdit() {
        uint m = GetMode();
        if (m == 0) return false;
        return SetMode((m & ~ENABLE_QUICK_EDIT) | ENABLE_EXTENDED_FLAGS);
    }
}
'@ -ErrorAction SilentlyContinue
}

function Disable-ConsoleQuickEdit {
    <#
        .SYNOPSIS
        Turn off click-to-select. Returns the previous console mode so the
        caller can restore it, or $null if it could not be changed.

        .DESCRIPTION
        Returns $null rather than throwing when there is no real console -
        Windows Terminal, a redirected host or the ISE. A logger must never
        fail to start because it could not adjust a console setting.
    #>
    try {
        if (-not ('KitConsole' -as [type])) { return $null }
        $prev = [KitConsole]::GetMode()
        if ($prev -eq 0) { return $null }
        if ([KitConsole]::DisableQuickEdit()) { return $prev }
        return $null
    } catch { return $null }
}

function Restore-ConsoleQuickEdit {
    <# Put the console mode back exactly as it was. #>
    param($PreviousMode)
    try {
        if ($null -eq $PreviousMode) { return }
        if (-not ('KitConsole' -as [type])) { return }
        [void][KitConsole]::SetMode([uint32]$PreviousMode)
    } catch { }
}

function Invoke-HardFaultAnalysis {
    <#
        .SYNOPSIS
        Turn a captured .etl into a HardFaults CSV and merge the fault
        columns into its matching FullTrace CSV. Returns $true on success.

        .DESCRIPTION
        This lives here, apart from the capture, for one reason: the
        analysis must be runnable LATER.

        Exit-time cleanup cannot be relied on. PowerShell's finally does
        not reliably run on Ctrl+C, and nothing at all runs when a user
        closes the window with the X - the process is killed outright.
        Both are normal ways to stop a logger, so a design that only
        analyses on a clean exit will silently lose data, and did:
        five consecutive runs left 50-100 MB .etl files in %TEMP% and
        produced no attribution whatsoever.

        So capture and analysis are decoupled. The capture writes
        iRacing-hf-<stamp>.etl; the FullTrace CSV is
        iRacing-FullTrace-<stamp>.csv. The shared stamp is the join key,
        so any later run can find an orphan and finish the job.
    #>
    param(
        [Parameter(Mandatory)][string] $EtlPath,
        [Parameter(Mandatory)][string] $Stamp,
        [string] $Desktop = [Environment]::GetFolderPath('Desktop'),
        [switch] $Quiet
    )

    function Say { param($m,$c='Gray') if (-not $Quiet) { Write-Host $m -ForegroundColor $c } }

    $xperf = Find-Xperf
    if (-not $xperf)                        { Say "  xperf not available - cannot analyse $Stamp" 'Yellow'; return $false }
    if (-not (Test-Path -LiteralPath $EtlPath)) { return $false }

    $merged = Join-Path $env:TEMP "iRacing-hf-$Stamp-merged.etl"
    $dump   = Join-Path $env:TEMP "iRacing-hf-$Stamp-dump.csv"
    $hfCsv  = Join-Path $Desktop  "iRacing-HardFaults-$Stamp.csv"

    try {
        # A live session still holding the file has to be stopped first.
        # -d merges it; if the session is already gone that fails, so fall
        # back to merging the raw file we already have.
        & $xperf -stop -d "`"$merged`"" 2>&1 | Out-Null
        if (-not (Test-Path -LiteralPath $merged)) {
            & $xperf -merge "`"$EtlPath`"" "`"$merged`"" 2>&1 | Out-Null
        }
        if (-not (Test-Path -LiteralPath $merged)) { $merged = $EtlPath }

        & $xperf -i "`"$merged`"" -o "`"$dump`"" -a dumper 2>&1 | Out-Null
        if (-not (Test-Path -LiteralPath $dump)) { throw 'xperf produced no dump' }

        # The dumper indents every line, so a naive StartsWith finds nothing.
        $events = [System.Collections.Generic.List[object]]::new()
        foreach ($line in [System.IO.File]::ReadLines($dump)) {
            $t = $line.TrimStart()
            if (-not $t.StartsWith('HardFault,')) { continue }
            if ($t -match 'TimeStamp') { continue }
            $f = $t.Split(',')
            if ($f.Count -lt 10) { continue }
            $us = 0L; if (-not [int64]::TryParse($f[1].Trim(), [ref]$us)) { continue }
            $sz = 0L; [void][int64]::TryParse($f[6].Trim(), [ref]$sz)
            $events.Add([pscustomobject]@{ Us=$us; Process=$f[2].Trim(); IOSize=$sz; FileName=$f[9].Trim().Trim('"') })
        }
        Remove-Item -LiteralPath $dump -Force -EA SilentlyContinue

        if ($events.Count -eq 0) {
            # Nothing to attribute, but the capture must still be cleared or
            # it is rediscovered as an "orphan" on every subsequent launch
            # and analysed again forever.
            Say "  $Stamp - no hard faults captured" 'DarkGray'
            if ($merged -ne $EtlPath) { Remove-Item -LiteralPath $merged -Force -EA SilentlyContinue }
            Remove-Item -LiteralPath $EtlPath -Force -EA SilentlyContinue
            return $true
        }

        # Wall-clock origin. On a recovered trace we no longer know when
        # xperf started, so derive it from the CSV's own first timestamp -
        # both were started within the same second.
        $csvPath = Join-Path $Desktop "iRacing-FullTrace-$Stamp.csv"
        $origin  = $null
        if ($Stamp -match '^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})$') {
            $origin = Get-Date -Year $Matches[1] -Month $Matches[2] -Day $Matches[3] `
                               -Hour $Matches[4] -Minute $Matches[5] -Second $Matches[6] -Millisecond 0
        }
        if (-not $origin) { $origin = (Get-Item -LiteralPath $EtlPath).CreationTime }

        $events | Select-Object `
            @{n='timestamp';e={ $origin.AddMilliseconds($_.Us/1000.0).ToString('HH:mm:ss') }},
            @{n='process'; e={$_.Process}}, @{n='io_size';e={$_.IOSize}}, @{n='file';e={$_.FileName}} |
            Export-Csv -LiteralPath $hfCsv -NoTypeInformation -Encoding UTF8

        # ---- per-second buckets, then merge into the FullTrace CSV ----
        $simSec = @{}; $allSec = @{}
        foreach ($e in $events) {
            $k = $origin.AddMilliseconds($e.Us/1000.0).ToString('HH:mm:ss')
            if ($e.Process -match '^iRacingSim64') { if (-not $simSec.ContainsKey($k)) { $simSec[$k]=0 }; $simSec[$k]++ }
            if (-not $allSec.ContainsKey($k)) { $allSec[$k] = @{ P=@{}; F=@{} } }
            if ($e.Process)  { if (-not $allSec[$k].P.ContainsKey($e.Process))  { $allSec[$k].P[$e.Process]=0  }; $allSec[$k].P[$e.Process]++  }
            if ($e.FileName) { if (-not $allSec[$k].F.ContainsKey($e.FileName)) { $allSec[$k].F[$e.FileName]=0 }; $allSec[$k].F[$e.FileName]++ }
        }

        if (Test-Path -LiteralPath $csvPath) {
            $lines = Get-Content -LiteralPath $csvPath
            if ($lines.Count -gt 1 -and $lines[0] -notmatch 'sim_hardfaults_s') {
                $out = [System.Collections.Generic.List[string]]::new()
                $out.Add($lines[0] + ',sim_hardfaults_s,top_fault_proc,top_fault_file')
                for ($i = 1; $i -lt $lines.Count; $i++) {
                    $row = $lines[$i]; if (-not $row.Trim()) { continue }
                    $ts  = $row.Split(',')[0]
                    $sim = if ($simSec.ContainsKey($ts)) { $simSec[$ts] } else { 0 }
                    $tp = ''; $tf = ''
                    if ($allSec.ContainsKey($ts)) {
                        $tp = ($allSec[$ts].P.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
                        $tf = ($allSec[$ts].F.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
                    }
                    $out.Add(('{0},{1},"{2}","{3}"' -f $row, $sim, $tp, $tf))
                }
                $out | Set-Content -LiteralPath $csvPath -Encoding utf8
                Say "  merged fault columns into $(Split-Path $csvPath -Leaf)" 'Green'
            }
        } else {
            Say "  no matching FullTrace CSV for $Stamp - wrote the fault log only" 'DarkGray'
        }

        if (-not $Quiet) {
            $simN = @($events | Where-Object { $_.Process -match '^iRacingSim64' }).Count
            $pct  = if ($events.Count) { 100*$simN/$events.Count } else { 0 }
            Write-Host ""
            Write-Host "  HARD FAULTS BY PROCESS  ($($events.Count) events)" -ForegroundColor Cyan
            $events | Group-Object Process | Sort-Object Count -Descending | Select-Object -First 12 | ForEach-Object {
                $mb  = (($_.Group | Measure-Object IOSize -Sum).Sum)/1MB
                $col = if ($_.Name -match '^iRacingSim64') { 'Green' } else { 'Gray' }
                Write-Host ('   {0,6:N0}  {1,7:N1} MB   {2}' -f $_.Count, $mb, $_.Name) -ForegroundColor $col
            }
            Write-Host ""
            Write-Host ('   iRacing accounted for {0:N0} of {1:N0} faults ({2:N1}%).' -f $simN, $events.Count, $pct) -ForegroundColor Yellow
            if ($pct -lt 10) { Write-Host '   The sim is NOT your bottleneck. The processes above are.' -ForegroundColor Yellow }
            # A capture that was never closed cleanly loses its byte counts in
            # the merge. Counts, processes and filenames survive; sizes do not.
            # Say so rather than letting a column of zeroes look like a finding.
            if (@($events | Where-Object { $_.IOSize -gt 0 }).Count -eq 0) {
                Write-Host ''
                Write-Host '   NOTE: byte counts are 0 - this capture was recovered from a run that' -ForegroundColor DarkGray
                Write-Host '   was killed rather than stopped, and an unclosed .etl loses io_size in' -ForegroundColor DarkGray
                Write-Host '   the merge. Fault counts, processes and filenames are unaffected.' -ForegroundColor DarkGray
            }
            Write-Host ""
            Write-Host "  Fault log: $hfCsv" -ForegroundColor Green
        }

        if ($merged -ne $EtlPath) { Remove-Item -LiteralPath $merged -Force -EA SilentlyContinue }
        Remove-Item -LiteralPath $EtlPath -Force -EA SilentlyContinue
        return $true
    }
    catch {
        Say "  analysis of $Stamp failed: $($_.Exception.Message)" 'Yellow'
        Say "  the .etl is kept at $EtlPath - it will be retried next run" 'DarkGray'
        return $false
    }
}

function Invoke-HardFaultRecovery {
    <#
        .SYNOPSIS
        Find .etl files left by runs that were killed, and finish them.
        Returns the number recovered.

        .DESCRIPTION
        Called at startup. This is what makes the feature survive an X-out:
        the run that died leaves its capture behind, and the next run picks
        it up. Nothing is lost by closing the window the "wrong" way.
    #>
    param([switch]$Quiet)

    $orphans = @(Get-ChildItem $env:TEMP -Filter 'iRacing-hf-*.etl' -EA SilentlyContinue |
                 Where-Object { $_.Name -notmatch '-merged\.etl$' })
    if ($orphans.Count -eq 0) { return 0 }

    if (-not $Quiet) {
        Write-Host ""
        Write-Host ("  Found {0} unfinished hard-fault capture(s) from a previous run." -f $orphans.Count) -ForegroundColor Cyan
        Write-Host "  Analysing them now - nothing was lost." -ForegroundColor Cyan
    }

    $done = 0
    foreach ($o in $orphans) {
        if ($o.Name -match '^iRacing-hf-(\d{8}-\d{6})\.etl$') {
            $stamp = $Matches[1]
            if (-not $Quiet) { Write-Host ("   {0}  ({1:N0} MB)" -f $stamp, ($o.Length/1MB)) -ForegroundColor DarkGray }
            if (Invoke-HardFaultAnalysis -EtlPath $o.FullName -Stamp $stamp -Quiet:$Quiet) { $done++ }
        }
    }
    return $done
}

function Get-QuietTaskPathPattern {
    <#
        .SYNOPSIS
        Regex matching the task-folder names in $TasksToDisable.

        .DESCRIPTION
        Trace-QuietReverts filters the TaskScheduler event log down to
        tasks the kit cares about. That filter used to be a hand-typed
        regex listing six folders, so every task added to $TasksToDisable
        was invisible to the trace. Deriving it from the list instead
        means the filter can never fall behind again.
    #>
    $folders = $TasksToDisable |
        ForEach-Object { ($_.Path -split '\\' | Where-Object { $_ }) | Select-Object -Last 1 } |
        Sort-Object -Unique |
        ForEach-Object { [regex]::Escape($_) }
    return ($folders -join '|')
}
