SCRIPTS — iRacing Tuning Guide (Dual-CCD Ryzen X3D + NVIDIA)
============================================================
All PowerShell. Read the main guide first. Run a script with:
   powershell -ExecutionPolicy Bypass -File "<path to .ps1>"
Or run Create-Launchers.ps1 once to get a double-click .lnk next to each.

>>> IMPORTANT: ADJUST FOR YOUR CPU'S CORE COUNT <<<
These scripts assume a 16-core X3D (9950X3D / 7950X3D), where the
frequency CCD starts at logical core 16. If you have a 12-core X3D
(9900X3D / 7900X3D), the frequency CCD starts at core 12 - so edit the
number at the top of these two scripts before running:
   Set-GPU-IRQ-Affinity.ps1      ->  $TargetCore  = 12   (was 16)
   Set-NIC-USB-IRQ-Affinity.ps1  ->  $TargetCores = @(13,14,15)  (was 17,18,19)
And in your Process Lasso CPU Set, pin the sim to 0-11 (not 0-15).

ADMIN? Scripts that change system settings must be run from an
elevated PowerShell (right-click > Run as administrator). Marked below.

--- DIAGNOSTICS (read-only) ---
FullTrace.ps1            MAIN logger. Run, race, read the CSV on your Desktop.
                         Time-gaps in it = system-wide stalls.            (no admin)
Preflight-Check.ps1      Pre-session sanity check. NOTE: this one is a TEMPLATE
                         tuned to the example rig (checks Bitsum plan, CPU-16
                         IRQ, a Process Lasso config path). Adapt the expected
                         values to your setup.                            (no admin*)
Scan-Stutter-Events.ps1  Lists scheduled tasks + system events around a stutter.
                         EDIT the window/timestamps at the top first.     (no admin)

--- FIXES (change settings) ---
Repair-PerfCounters.ps1        Rebuild broken perf counters. Reboot after.   (ADMIN)
Enable-DiagnosticLogs.ps1      Turn on TaskScheduler log for Scan-Stutter.   (ADMIN)
Set-GPU-IRQ-Affinity.ps1       Steer GPU interrupts to frequency CCD. Reboot.(ADMIN)
Undo-GPU-IRQ-Affinity.ps1      Revert the above. Reboot.                     (ADMIN)
Set-NIC-USB-IRQ-Affinity.ps1   Steer NIC + USB interrupts off CPU 0. Reboot. (ADMIN)
Undo-NIC-USB-IRQ-Affinity.ps1  Revert the above. Reboot.                     (ADMIN)
Pre-Race-Quiet.ps1             Before racing: quiet Windows Update/Search +
                               (optional) Defender real-time. Needs Tamper
                               Protection OFF for the Defender part.         (ADMIN)
Post-Race-Restore.ps1          After racing: turn all of the above back on.  (ADMIN)
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

These scripts change Windows/registry/power settings. Every one has an
Undo or is reversible, but review before running on someone else's PC.
