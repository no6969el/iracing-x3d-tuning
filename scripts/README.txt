SCRIPTS — iRacing Tuning Guide (Dual-CCD Ryzen X3D + NVIDIA)
============================================================
EASIEST: double-click "Start-Tuning-Menu.bat" (one folder up) for an
interactive menu that runs all of these for you and handles core numbers
automatically. In a hurry? "Apply-Baseline.bat" (also one folder up)
applies every fix below in one go with a single admin prompt.
Everything below is for running them by hand.

Run a script by hand with:
   powershell -ExecutionPolicy Bypass -File "<path to .ps1>"
Or run Create-Launchers.ps1 once to get a double-click .lnk next to each.

>>> CHIP TYPE + CORE COUNT (handled for you by the menu) <<<
Supported: dual-CCD (9950X3D/7950X3D = 16-core, 9900X3D/7900X3D = 12-core)
AND single-CCD (7800X3D/9800X3D/5800X3D = 8-core). The Tuning-Menu and
Apply-Baseline detect your chip and set the right IRQ target core for you.

Run BY HAND with no saved config? The IRQ scripts fall back to HALF your
logical processor count - a valid, safe target for every X3D:
   16-core dual  (32 threads)  -> IRQ core 16
   12-core dual  (24 threads)  -> IRQ core 12
   8-core single (16 threads)  -> IRQ core 8
So you normally don't need to edit anything. (To override, set the env var
X3D_FREQ_FIRST_CORE, or edit the "...else { ... }" line near the top.)

DUAL-CCD only: also pin the sim in Process Lasso (CPU Set) to your V-Cache
cores - 0-15 on 16-core, 0-11 on 12-core. SINGLE-CCD chips have nothing to
pin (all cores are V-Cache) and should stay on the Balanced power plan.

ADMIN? Scripts that change system settings must be run from an
elevated PowerShell (right-click > Run as administrator). Marked below.

--- DIAGNOSTICS (read-only) ---
FullTrace.ps1            MAIN logger. Run, race, read the CSV on your Desktop.
                         Time-gaps in it = system-wide stalls.            (no admin)
Preflight-Check.ps1      Pre-session sanity check. NOTE: this one is a TEMPLATE
                         tuned to the example rig (checks Bitsum plan, CPU-16
                         IRQ, a Process Lasso config path). Adapt the expected
                         values to your setup.                            (no admin*)
Scan-Stutter-Events.ps1  Auto-reads your latest FullTrace CSV from the Desktop,
                         finds the stutters, and lists tasks/events around each.
                         No editing needed. (Enable-DiagnosticLogs first.) (no admin)

--- FIXES (change settings) ---
Repair-PerfCounters.ps1        Rebuild broken perf counters. Reboot after.   (ADMIN)
Enable-DiagnosticLogs.ps1      Turn on TaskScheduler log for Scan-Stutter.   (ADMIN)
Set-GPU-IRQ-Affinity.ps1       Steer GPU interrupts to frequency CCD. Reboot.(ADMIN)
Undo-GPU-IRQ-Affinity.ps1      Revert the above. Reboot.                     (ADMIN)
Set-NIC-USB-IRQ-Affinity.ps1   Steer NIC + USB interrupts off CPU 0. Reboot. (ADMIN)
Undo-NIC-USB-IRQ-Affinity.ps1  Revert the above. Reboot.                     (ADMIN)
Pre-Race-Quiet.ps1             Before racing: quiets Windows Update/Search +
                               (optional) Defender real-time. DISABLES those
                               services (v2.1.0) so they can't be restarted by
                               the Update Medic mid-session - which means it
                               HOLDS ACROSS A REBOOT until you restore.
                               Runs itself as SYSTEM automatically; add -Verify
                               to re-check a few minutes later that nothing
                               reverted. Needs Tamper Protection OFF for the
                               Defender part.                                (ADMIN)
Post-Race-Restore.ps1          After racing: REQUIRED, not optional. Restores
                               every service, task, and Defender setting to its
                               exact prior state from the snapshot that
                               Pre-Race-Quiet saved.                         (ADMIN)
Add-Defender-Exclusions.ps1    Exclude iRacing folders from Defender (once).  (ADMIN)
Apply-Guide-Extras.ps1         USB Selective Suspend off + Game Mode/Bar off. (ADMIN)
Undo-Guide-Extras.ps1          Revert the above.                             (ADMIN)

--- UTILITY ---
Create-Launchers.ps1     Make a .lnk next to every .ps1 (admin ones auto-elevate). (no admin)

SUGGESTED FIRST-TIME ORDER
1) Repair-PerfCounters (if FullTrace per-core columns are empty) -> reboot
2) Set your power plan to all-cores-unparked (see guide)
3) Process Lasso: CPU Set sim -> V-Cache cores; background -> frequency cores
4) Set-GPU-IRQ-Affinity -> Set-NIC-USB-IRQ-Affinity -> reboot
5) Add-Defender-Exclusions, Apply-Guide-Extras (once)
6) iRacing in-game settings (see guide) with the sim CLOSED
7) Preflight-Check, then FullTrace a race to verify zero time-gaps

PER-SESSION
Before: Pre-Race-Quiet     After: Post-Race-Restore

>>> CHANGED IN v2.1.0 - READ THIS <<<
Quieting now SURVIVES A REBOOT. Earlier versions only stopped the services, so
Windows quietly restarted them (that was the bug: update scans came back ~10
minutes into a session). They are now disabled outright, so nothing brings them
back on its own - not even a reboot.

That makes Post-Race-Restore mandatory. Until you run it:
  - Windows Update stays off (no patches), and
  - Defender definition updates ride on those same services, so signatures
    go stale. Don't leave a rig quieted for days.

Snapshot + log live in C:\ProgramData\RaceQuiet\ (not the script folder, so the
SYSTEM run can always write them). The restore consumes the snapshot.
Not sure what state a PC is in? Run Check-Quiet-Status.ps1 - read-only, no admin.

These scripts change Windows/registry/power settings. Every one has an
Undo or is reversible, but review before running on someone else's PC.
