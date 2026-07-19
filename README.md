# iRacing Tuning — Ryzen X3D + NVIDIA

Zero hiccups in iRacing on Ryzen X3D — dual-CCD (9950X3D / 7950X3D / 9900X3D / 7900X3D) **and** single-CCD (7800X3D / 9800X3D / 5800X3D). Six steps, measured on a real rig, all reversible. The guide and menus detect your chip and only ever show the fixes that are safe for it.

<h2 align="center">👉 <a href="https://no6969el.github.io/iracing-x3d-tuning/">OPEN THE GUIDE</a> 👈</h2>
<p align="center">Everything is there: the steps, the download, the explanations, and the troubleshooting.</p>

---

**In this repo** (the guide's [download](https://github.com/no6969el/iracing-x3d-tuning/archive/refs/heads/main.zip) gets you all of it): `Apply-Baseline.bat` — one-shot optimizer · `Start-Tuning-Menu.bat` — guided menu with undo for everything · `scripts/` — the individual tools ([inventory](scripts/README.txt)).

When you select Option ("Troubleshoot a stutter") in the `Start-Tuning-Menu.bat` and complete a race session, the script parses that exact file, isolates the timestamps matching your race, and filters out the exact names of the tasks running at that moment. 

> ⚠️ These scripts change Windows settings (power, registry, services, Defender). All reversible, nothing runs without your approval — review before running, at your own risk.

Adapted for dual-CCD from the single-CCD guide by [rcsracing93](https://rcsracing93.github.io/iracing-stutter-fix) · MIT licensed · share freely.

SCRIPTS — iRacing Tuning Guide (Ryzen X3D + NVIDIA)
============================================================
EASIEST: double-click "Start-Tuning-Menu.bat" (one folder up) for an
interactive menu that runs all of these for you and handles core numbers
automatically. In a hurry? "Apply-Baseline.bat" (also one folder up)
applies every fix below in one go with a single admin prompt.
Everything below is for running them by hand.

Run a script by hand with:
   powershell -ExecutionPolicy Bypass -File "<path to .ps1>"
Or run Create-Launchers.ps1 once to get a double-click .lnk next to each.

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
