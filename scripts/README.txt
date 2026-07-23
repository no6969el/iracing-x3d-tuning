SCRIPTS — iRacing Tuning Guide (AMD X3D + NVIDIA)
============================================================
EASIEST: double-click "Start-Tuning-Menu.bat" (one folder up) for an
interactive menu that runs all of these for you and handles core numbers
automatically. In a hurry? "Apply-Baseline.bat" (also one folder up)
applies every fix below in one go with a single admin prompt.
Everything below is for running them by hand.

Run a script by hand with:
   powershell -ExecutionPolicy Bypass -File "<path to .ps1>"
Or run Create-Launchers.ps1 once to get a double-click .lnk next to each.

>>> CHIP DETECTION (handled for you) <<<
scripts\X3D-Profiles.ps1 is the single source of truth for CPU topology.
Every other script reads from it, so there are no core numbers to edit.
It identifies your chip four ways, most reliable first:
   1. CPU name  -> catalog of every X3D SKU (below)
   2. L3 cache topology -> real CCD boundaries + which CCDs have V-Cache
      (so chips that don't exist yet still resolve correctly)
   3. Total L3 size -> X3D / non-X3D
   4. Core count -> last-resort estimate
The answer is then validated against the CPUs Windows actually reports,
so a target core can never point at a processor that doesn't exist.

SUPPORTED CHIPS
---------------
  6-core single-CCD   5500X3D  5600X3D  7500X3D  7600X3D
  8-core single-CCD   5700X3D  5800X3D  7700X3D  7800X3D  9800X3D  9850X3D
  12-core dual-CCD    7900X3D  9900X3D                    (6+6, V-Cache CCD0)
  16-core dual-CCD    7950X3D  9950X3D                    (8+8, V-Cache CCD0)
  16-core dual-CCD    9950X3D2 Dual Edition               (8+8, V-Cache BOTH)
  mobile (16-core)    7945HX3D  9955HX3D

  NOT an X3D? The kit still runs. The general fixes (Defender exclusions,
  timer resolution, Game Bar / USB suspend, pre-race quieting, tracing,
  stutter scanning) all apply. Core pinning and interrupt steering are
  skipped automatically rather than guessed at.

WHAT EACH TOPOLOGY MEANS FOR YOU
--------------------------------
  SINGLE-CCD: every core has the V-Cache, so there is nothing to pin.
  Stay on the Balanced power plan. Interrupts are steered to a core well
  away from CPU 0 (CPU 6 on a 6-core, CPU 8 on an 8-core).

  DUAL-CCD (V-Cache on CCD0): pin the sim in Process Lasso (CPU Sets) to
  the V-Cache cores — 0-11 on a 12-core, 0-15 on a 16-core — and let
  background work use the other die. Use an all-cores-unparked plan.

  9950X3D2 (V-Cache on BOTH CCDs): there is no "good" and "bad" CCD here;
  the cores are equivalent and there is no preferred die for the scheduler
  to target. Pinning the sim to cores 0-15 still helps, but for a different
  reason — it keeps the sim on ONE die and avoids the latency cost of
  reaching across to the other CCD's cache.

  MOBILE (HX3D): supported, but your laptop OEM's power management can
  override the power plan and interrupt changes, and the vendor control
  app may revert them. The scripts warn you when they detect a mobile
  chip. Every fix has an Undo if things get worse.

ADMIN? Scripts that change system settings must be run from an
elevated PowerShell (right-click > Run as administrator). Marked below.

--- DIAGNOSTICS (read-only) ---
FullTrace.ps1            MAIN logger. Run, race, read the CSV on your Desktop.
                         Time-gaps in it = system-wide stalls.            (no admin)
Preflight-Check.ps1      Pre-session sanity check. Adapts to your chip: on a
                         single-CCD or non-X3D CPU the pinning and interrupt
                         checks are skipped rather than failed.            (no admin*)
Scan-Stutter-Events.ps1  Auto-reads your latest FullTrace CSV from the Desktop,
                         finds the stutters, and lists tasks/events around each.
                         No editing needed. (Enable-DiagnosticLogs first.) (no admin)

--- FIXES (change settings) ---
Repair-PerfCounters.ps1        Rebuild broken perf counters. Reboot after.   (ADMIN)
Enable-DiagnosticLogs.ps1      Turn on TaskScheduler log for Scan-Stutter.   (ADMIN)
Set-GPU-IRQ-Affinity.ps1       Steer GPU interrupts off the sim core. Reboot.(ADMIN)
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
X3D-Profiles.ps1         Shared CPU detection. Not run directly - every other
                         script loads it. Don't delete it.                (n/a)
Create-Launchers.ps1     Make a .lnk next to every .ps1 (admin ones auto-elevate). (no admin)

SUGGESTED FIRST-TIME ORDER
1) Repair-PerfCounters (if FullTrace per-core columns are empty) -> reboot
2) Power plan: all-cores-unparked on dual-CCD; Balanced is fine on single-CCD
3) Dual-CCD only — Process Lasso: CPU Set sim -> V-Cache cores;
   background -> the other CCD
4) Set-GPU-IRQ-Affinity -> Set-NIC-USB-IRQ-Affinity -> reboot
5) Add-Defender-Exclusions, Apply-Guide-Extras (once)
6) iRacing in-game settings (see guide) with the sim CLOSED
7) Preflight-Check, then FullTrace a race to verify zero time-gaps

PER-SESSION
Before: Pre-Race-Quiet     After: Post-Race-Restore

TESTING ON HARDWARE YOU DON'T OWN
---------------------------------
Set X3D_FORCE_PROFILE to any supported model and the whole kit behaves as
if it were running on that chip:

   $env:X3D_FORCE_PROFILE = '5600X3D'
   .\Start-Tuning-Menu.bat

Scripts that write to the registry detect the simulated profile and run in
DRY-RUN mode instead — they print what they would do and change nothing.
Close the window (or Remove-Item Env:X3D_FORCE_PROFILE) to go back to real
detection. Useful for checking every code path before a release.

SAVED PROFILE
-------------
Detection results are cached at:
   %APPDATA%\iRacingX3DTuning\config.json
It is re-detected automatically if the schema changes or if the logical
processor count no longer matches (so swapping CPUs can't leave a stale
profile behind). To force it: Tuning-Menu > CPU profile > Detect again.

These scripts change Windows/registry/power settings. Every one has an
Undo or is reversible, but review before running on someone else's PC.
