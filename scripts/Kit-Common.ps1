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
