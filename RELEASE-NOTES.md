# Release Notes — v3.0.0

## Read this first — two breaking changes

**1. `Post-Race-Restore.ps1` is now required.** Quieting disables services rather
than stopping them, so nothing self-heals on reboot. Skip the restore and the PC
has no Windows Update and no fresh Defender definitions until you run it.

**2. Do not mix files across versions.** Six scripts share
`scripts\X3D-Profiles.ps1`. Replace the whole folder — a partial upgrade produces
wrong core numbers silently.

Everything else in this release is a straight improvement.

---

## Race-Quiet now actually holds

A user reported `wuauserv` and `UsoSvc` switching themselves back on about ten
minutes into a session, stuttering the moment they did.

**Cause.** The script only *stopped* those services. A stopped service keeps its
startup type, so the first API call restarts it — and Windows Update Medic
(`WaaSMedicSvc`) exists specifically to detect a tampered-with update stack and
repair it, on roughly that cadence.

**Fix.** `Pre-Race-Quiet` now:

- sets the services to **Disabled** (`Start=4`) rather than stopping them
- disables `WaaSMedic\PerformRemediation`, the task driving the ~10-minute revert
- clears each service's **recovery actions**, so a force-stop can't trigger an
  auto-restart, and restores them byte-for-byte afterwards
- adds `WaaSMedicSvc`, `bits` and `DoSvc`, plus three more `UpdateOrchestrator`
  tasks
- retries anything TrustedInstaller-owned through a temporary **SYSTEM** task
- **snapshots your real prior state** to `C:\ProgramData\RaceQuiet\state.json`
  so the restore replays exactly that — anything you had already turned off
  stays off

New switches: `-Verify` (wait, then report anything that crept back),
`-KeepSearch` (leave Start Menu search working), `-SkipDefender`, `-Deadman`
(auto-restore at next boot if you forget), `-Force`.

`Check-Quiet-Status` now reports **startup type**, not just running state — a
service that is stopped but still Manual is precisely the condition that let it
return, and the old checker called that "quiet".

> ⚠️ **Because this survives a reboot, `Post-Race-Restore.ps1` is now required.**
> Until it runs, the PC has no Windows Update and no fresh Defender definitions.

---

## Also fixed

**Every dashboard page now opens at the right size.** Some pages needed scrolling
to see all the buttons. The window now measures each page and resizes to fit,
scrolling only if a page genuinely exceeds your screen — and it refits when you
expand a section.

**The Process Lasso step was missing "Always".** Both the guide and the dashboard
said CPU Sets → tick your cores, leaving out the `Always` submenu that makes it
persist. Without it the pin was silently lost when the sim closed. If you set
this up before, it is worth redoing — you may have been racing without it.

**Single-CCD owners were told to change power plan.** The dashboard said to set
Bitsum Highest Performance; everything else correctly says keep Balanced. Fixed.

**The web guide** now offers all five chip classes (including 9950X3D2 and the
6-core parts), and a stale instruction about editing a file that no longer exists
has been removed.

## Faster startup

Cache validation was making a WMI call on every launch — a regression in v2.2.0,
where the previous code just read a JSON file. That is gone, three duplicate CPU
queries are now one, and the XAML is parsed once instead of twice. The app should
open noticeably quicker than v2.2.0.

---

## If you are coming from v2.1.0 or earlier — full AMD X3D lineup support
*(this shipped in v2.2.0)*


**Full AMD X3D lineup support**

This release rewrites how the kit identifies your processor. Previously it
recognised three chip layouts and guessed at anything else. It now knows every
X3D processor AMD has shipped, detects real CCD boundaries from your CPU's cache
topology, and validates every core number against the processors Windows actually
reports.

If you have a 12- or 16-core X3D, nothing about your setup changes — the core
numbers you were given before were correct, and they're the same now. If you have
anything else, this release is the one that makes the kit work properly for you.

---

## Newly supported processors

**6-core X3D — previously unsupported entirely**

| Chip | Cores / Threads | Layout |
|---|---|---|
| Ryzen 5 5500X3D | 6C / 12T | single CCD |
| Ryzen 5 5600X3D | 6C / 12T | single CCD |
| Ryzen 5 7500X3D | 6C / 12T | single CCD |
| Ryzen 5 7600X3D | 6C / 12T | single CCD |

There was no 6-core option in the chip picker, so owners of these chips had to
pick the 8-core profile — which produced the wrong core numbers.

**Also newly recognised**

| Chip | Cores / Threads | Layout |
|---|---|---|
| Ryzen 7 7700X3D | 8C / 16T | single CCD |
| Ryzen 7 9850X3D | 8C / 16T | single CCD |
| Ryzen 9 9950X3D2 Dual Edition | 16C / 32T | dual CCD, **V-Cache on both** |
| Ryzen 9 7945HX3D (mobile) | 16C / 32T | dual CCD |
| Ryzen 9 9955HX3D (mobile) | 16C / 32T | dual CCD |

**Complete supported list (17 chips)**

- 6-core single-CCD — 5500X3D, 5600X3D, 7500X3D, 7600X3D
- 8-core single-CCD — 5700X3D, 5800X3D, 7700X3D, 7800X3D, 9800X3D, 9850X3D
- 12-core dual-CCD — 7900X3D, 9900X3D
- 16-core dual-CCD — 7950X3D, 9950X3D
- 16-core dual-CCD, both cached — 9950X3D2 Dual Edition
- Mobile — 7945HX3D, 9955HX3D

**Non-X3D processors are now supported too.** The general fixes (Defender
exclusions, timer resolution, Game Bar / USB suspend, pre-race quieting, tracing,
stutter scanning) all run. Core pinning and interrupt steering are skipped
automatically rather than guessed at.

---

## The 9950X3D2 needs different advice

This chip has V-Cache on **both** CCDs, so the usual "pin the sim to the good CCD"
framing doesn't apply — there is no good and bad CCD, and no preferred die for the
Windows scheduler to target.

Pinning still helps, but for a different reason: keeping the sim on **one** CCD
avoids the latency cost of reaching across to the other die's cache. The kit now
gives you the same CPU-Set (0–15) but explains it correctly instead of telling you
to avoid a "slow" CCD that doesn't exist.

Note that a 9950X3D2 reports 16 cores exactly like a 9950X3D, so core-count
detection alone cannot tell them apart. The new detection identifies it by name and
by cache size.

---

## Bug fixes

**Invalid interrupt targets on 6-core chips.** The old code assumed any chip that
wasn't 12 or 16 cores had 8 cores, and steered GPU interrupts to CPU 8 with NIC and
USB interrupts to CPUs 9, 10 and 11. On a 6-core chip with SMT enabled those
processors happen to exist, so it appeared to work while pointing at arbitrary
cores. With SMT disabled, or with cores limited in msconfig, those processors do
not exist — and the kit wrote interrupt affinity masks targeting nothing. Core
targets are now derived from your actual topology and validated before anything is
written; if a target isn't a real processor the script refuses and explains why
instead of writing a bad mask.

**Two components disagreed about your CPU.** `Preflight-Check` and the Tuning Menu
used different fallback calculations. On a 6-core chip the menu chose CPU 8 while
Preflight expected CPU 6, so Preflight reported a GPU-IRQ mismatch that wasn't
real. All components now read from one shared source.

**Wrong V-Cache range reported on single-CCD chips.** Preflight described an 8-core
single-CCD chip's V-Cache cores as `0-7` when all 16 logical processors share it.

**SMT-disabled systems mis-numbered.** The dashboard calculated your highest core
number as `cores × 2 - 1`, which is wrong whenever SMT is off.

**Core count could be under-reported.** Detection used `[Environment]::ProcessorCount`,
which can be skewed by process affinity. It now reads the true count from WMI.

**FullTrace could stop logging.** If a CPU was missing from Windows' performance
counter set, the per-core lookup threw and the row was lost. Missing counters are
now skipped rather than fatal.

**Contradictory advice on non-X3D chips.** The Optimize page said to skip the
Process Lasso step, then a dialog asked whether you'd completed it. On a non-X3D
chip that dialog no longer appears, and the "steps by hand" heading is hidden.
Single-CCD chips now correctly say *one* step (the power plan) rather than two.

---

## Changes you'll notice

**New "CPU profile" page** in the dashboard, replacing the old *Reset system*
button. It shows the chip that was detected, how it was identified, and the core
numbers in use. If detection gets it wrong you can pick your chip class by hand —
six options covering every supported layout, plus a re-detect.

**Saved profiles are re-detected automatically.** The stored format changed, so your
first launch after upgrading re-identifies your CPU. Profiles are also discarded if
your logical processor count no longer matches, so swapping CPUs can't leave stale
core numbers behind. Nothing to clear by hand.

**Interrupt steering is hidden when it doesn't apply.** On a non-X3D CPU, or when
topology can't be determined confidently, the GPU-IRQ fix is dropped from the
automatic run and its Advanced button is disabled with an explanation.

**Mobile chips warn about OEM power management.** Laptop firmware can override power
plans and interrupt settings, and vendor control apps may revert them. The kit says
so up front and points at the Undo scripts.

---

## Under the hood

All CPU logic now lives in `scripts\X3D-Profiles.ps1`. Six scripts previously
carried their own copy of the detection fallback, and those copies had drifted
apart.

Detection resolves in four layers, most reliable first:

1. **CPU name** matched against the catalog of all 17 chips
2. **L3 cache topology** via `GetLogicalProcessorInformationEx` — finds real CCD
   boundaries and identifies which CCDs carry V-Cache by cache size, so chips that
   don't exist yet still resolve correctly
3. **Total L3 size** — a cheap X3D / non-X3D discriminator
4. **Core count** — last-resort estimate, which marks topology as untrusted and
   disables the topology-specific fixes

The cache probe is defensive: if it returns anything failing its sanity checks
(overlapping cache pools, asymmetric CCDs, coverage that doesn't match the reported
CPU count) it reports "unknown" and the name catalog takes over rather than acting
on bad data. `Preflight-Check` prints which layer answered.

Requires Windows PowerShell 5.1, built into Windows 10 and 11. PowerShell 7 is not
needed for any part of the kit.

---

## Upgrading

**Replace the whole folder. Don't copy individual files across.**

1. Rename your existing kit folder (keep it until the new one is confirmed working)
2. Extract this release in its place
3. Run `Start-Tuning-Menu.bat`

Six scripts now share `scripts\X3D-Profiles.ps1`. Mixing an old copy of one script
with new ones produces inconsistent core numbers, which is exactly the failure this
release exists to eliminate.

Your first launch re-detects your CPU. Check the header shows the right chip; if
not, use **CPU profile** to set it by hand.

---

## For testers

You can make the entire kit behave as any supported chip without owning one:

```powershell
$env:X3D_FORCE_PROFILE = '5600X3D'
.\Start-Tuning-Menu.bat
```

Everything that writes to the registry switches to dry-run and changes nothing.
Close the window to return to normal detection.

`tests\test-integration.ps1` sweeps all 17 chips and asserts that every interrupt
target, CPU-Set range and trace split is valid and in range:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\test-integration.ps1
```

The `tests\` folder is development-only and safe to delete.

---

## Unchanged

FullTrace CSV column names are the same (`ccd0_cpu`, `ccd1_cpu`, `freqcore_int`,
`freqcore_dpc`) so existing traces and any spreadsheets you've built still work. On
a single-CCD chip those two columns represent the low and high halves of your cores
rather than separate dies; the console output labels this correctly while logging.
