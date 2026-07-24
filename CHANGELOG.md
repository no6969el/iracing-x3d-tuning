# Changelog — iRacing X3D Tuner / Optimizer


The project ships as a script kit plus a web guide at
`https://no6969el.github.io/iracing-x3d-tuning/`.

---

## v3.0.0 — Race-Quiet that actually holds (current)

**Major release.** Two breaking changes, both worth reading before you upgrade:
`Post-Race-Restore` is now mandatory rather than tidy-up, and scripts can no
longer be mixed across versions. Details under **Breaking** below.

*(v2.2.1 was never published — its contents ship here.)*

Field report from a user: `wuauserv` and `UsoSvc` came back on their own roughly
10 minutes after `Pre-Race-Quiet` ran, stuttering the moment they did — mid-race.

**Root cause.** The shipped script only *stopped* those services. A stopped
service keeps its startup type, so the first API call restarts it, and Windows
Update Medic (`WaaSMedicSvc`) exists specifically to detect a tampered-with update
stack and repair it. Stopping was never going to hold. This is the fix v2.1.0
described but which never reached the repo.

### Breaking
- **Quieting now survives a reboot.** Services are set to `Start=4` (Disabled),
  not merely stopped. **`Post-Race-Restore.ps1` is now mandatory, not tidy-up** —
  a forgotten restore leaves the machine with no Windows Update and, since
  Defender signature updates ride `wuauserv`/BITS, stale definitions.

### Added
- **Snapshot / faithful restore.** `Pre-Race-Quiet` writes the *actual* prior
  state — each service's `Start`, `DelayedAutostart` and recovery actions, each
  task's prior state, whether Defender was already off — to
  `C:\ProgramData\RaceQuiet\state.json`. `Post-Race-Restore` replays exactly
  that rather than re-enabling blindly, so anything you had already turned off
  stays off. Snapshot is consumed on a successful restore.
- **Service recovery actions are cleared and restored byte-for-byte.** A service
  with restart-on-failure configured can come back after a force-stop. The
  `FailureActions` binary value is captured to base64, deleted, and written back
  verbatim on restore. *(Not in the v2.1.0 design — new here.)*
- **`WaaSMedic\PerformRemediation`** added to the disabled-task list — the task
  that drives the ~10-minute revert.
- **`WaaSMedicSvc`, `bits` and `DoSvc`** added to the quieted services, plus the
  `UpdateOrchestrator` tasks `Universal Orchestrator Start`, `Report policies`
  and `UUS Failover Task`.
- **SYSTEM helper** for TrustedInstaller-owned tasks: anything that refuses to
  disable as admin is retried through a temporary SYSTEM scheduled task (created,
  run, deleted). `-NoSystem` opts out. Both scripts do this.
- **`-Verify` / `-VerifyDelay`** (default 180s) — waits, then re-reads each
  service's `Start` value and re-checks the tasks, reporting anything that
  reverted. The definitive per-machine test.
- **`-KeepSearch`** leaves Windows Search alone. Disabling `WSearch` degrades
  Start Menu search visibly, and it is the least likely of the services to cause
  a mid-race stall — so it is now easy to opt out of.
- **`-Deadman`** registers a one-shot boot task that auto-restores if you forget.
  Deleted on a normal restore.
- **`-SkipDefender`**, **`-Force`** (re-snapshot over a stale state file), and
  self-elevation in both scripts.
- **Shared log** at `C:\ProgramData\RaceQuiet\RaceQuiet.log`.
- **`tests\test-racequiet.ps1`** — verifies the snapshot round-trips (including
  the recovery-action bytes), that a service the user had already disabled is
  left alone, and that the generated SYSTEM helper is valid, injection-safe
  PowerShell.

### Changed / Fixed
- **`Check-Quiet-Status.ps1` now reports startup type, not just running state.**
  A service that is stopped but still Manual is exactly the condition that let it
  return, and the old checker reported that as "quiet". It also flags an
  un-restored snapshot, warns when `WaaSMedic\PerformRemediation` is still
  enabled, and notes that the Medic tasks are invisible unless run elevated.
- **Fixed a latent crash in the SYSTEM helper generation.** The command string was
  built with the `-f` format operator around literal `try {` / `catch {` braces,
  which .NET parses as malformed placeholders — it would have thrown
  `FormatException` the first time a task refused to disable. Rebuilt using
  concatenation, with apostrophe escaping so a task name containing a quote
  cannot break out of the generated script.
- State lives in ProgramData rather than the script folder, which is not reliably
  writable by SYSTEM when the kit sits on a OneDrive-redirected Desktop.
- A stale state file blocks a second `Pre-Race-Quiet` run unless `-Force` is
  passed, so the original state cannot be overwritten with an already-quieted one.
- `Post-Race-Restore` falls back to Windows defaults, loudly, when no snapshot
  is found.

### Fixed — dashboard
- **Every page now opens at the right size.** `Show-Page` only toggled
  `Visibility`, which never made the window re-measure, so it kept whatever
  height the main page needed at startup and taller pages scrolled. Compounding
  it, a `ScrollViewer` reports a tiny desired height — it can always scroll — so
  `SizeToContent="Height"` had nothing to grow toward, and a `MaxHeight` safety
  net would have capped `ActualHeight` so an oversized page could never even be
  detected. The window now measures each page properly, resizes to fit, and
  scrolls only when a page genuinely exceeds the screen. It also refits when a
  section is expanded or collapsed, and re-centres so a tall page can't drop off
  the bottom of the display.

### Fixed — Process Lasso guidance
- **The pinning step was missing "Always".** Both the dashboard and the web guide
  said CPU Sets → tick cores, omitting the `Always` submenu that makes the
  setting persist. Without it the pin is silently lost when the sim closes —
  people followed the instructions, saw it work once, and lost the single
  biggest fix the next day with nothing to indicate it.
- **The dashboard never said to launch the sim first.** `iRacingSim64DX11.exe`
  only appears in Process Lasso's list while it is running. The web guide said
  so; the dashboard did not.
- **Contradictory power-plan advice on single-CCD chips.** `Get-X3DPinningAdvice`
  told single-CCD owners to set Bitsum Highest Performance while
  `Preflight-Check`, `Apply-Baseline` and the web guide all correctly said to
  keep Balanced.
- Added the CPU Sets dialog's **Cache** button as a shortcut, with a note that it
  is no help on a 9950X3D2 (both dies are cache, so it selects everything).

### Changed — web guide
- Chip picker expanded from three options to five, adding **9950X3D2** and
  **7600X3D / 5600X3D**, with a mapping line for every other supported chip
  including the mobile parts. Core numbers throughout follow the selection.
- Removed a stale instruction telling 12-core owners they may need "a one-line
  edit" in `scripts\README.txt` — that edit no longer exists, and anyone
  following it would hunt for something that isn't there.
- Dropped "Dual-CCD" from the title and meta description, and made the
  single-CCD paragraph chip-neutral rather than hardcoded to 8-core.

### Performance
- **WMI removed from the startup path.** Cache validation was calling
  `Get-CimInstance Win32_Processor` on every single launch just to confirm the
  CPU hadn't changed — a regression introduced in v2.2.0, where the previous code
  simply read the JSON. It now compares `[Environment]::ProcessorCount`, which is
  instant, and only falls back to WMI if that disagrees. Same correctness, same
  protection against a CPU swap. Measured 8.46 ms → 1.62 ms even where the WMI
  call fails instantly; on a real machine the saving is larger.
- **One CPU query instead of three.** `Get-X3DLogicalCount`,
  `Get-X3DPhysicalCount` and `Get-X3DProfile` each ran their own
  `Win32_Processor` query for identical data. Cached per process — the CPU cannot
  change while the app is running.
- **Single-pass XAML parse.** The markup was cast to `[xml]`, building an
  `XmlDocument` that an `XmlNodeReader` then walked to construct the object tree —
  two parses, with the document left resident for the whole session.
  `XamlReader::Parse` reads it directly and the string is released after.

### Known limitation
On some builds `WaaSMedic\PerformRemediation` is TrustedInstaller-owned and can
refuse to disable even as SYSTEM. Where that happens the service disable plus the
cleared recovery actions generally still hold; `-Verify` is how you confirm it per
machine. Clearing that last task would require a registry ownership change,
deliberately not included — invasive and hard to restore cleanly.

---

## v2.2.0 — Every X3D AMD has shipped

The kit recognised three chip layouts and guessed at anything else. It now knows
all 17 X3D processors, reads real CCD boundaries from the CPU's cache topology,
and validates every core number against the processors Windows actually reports.

If you run a 12- or 16-core X3D nothing about your setup changes — the numbers you
were given before were correct and are unchanged. If you run anything else, this is
the release that makes the kit work for you.

### Breaking
- **All CPU logic moved into `scripts\X3D-Profiles.ps1`.** Six scripts previously
  carried their own copy of the detection fallback and those copies had drifted
  apart. They now dot-source one shared module. **Mixing an old copy of any of
  those scripts with new ones produces inconsistent core numbers** — replace the
  whole folder rather than cherry-picking files.
- **`config.json` schema bumped to 3.** Saved profiles from earlier versions are
  discarded and re-detected on first launch. Profiles are also rejected when the
  logical processor count no longer matches, so a CPU swap can't leave stale core
  numbers behind. Nothing to clear by hand.

### Added
- **6-core X3D support** — 5500X3D, 5600X3D, 7500X3D, 7600X3D. These had no entry
  in the chip picker at all, so owners had to select the 8-core profile and got the
  wrong core numbers.
- **7700X3D, 9850X3D** (8-core single-CCD) and **9950X3D2 Dual Edition**.
- **Mobile HX3D support** — 7945HX3D, 9955HX3D. Detected as 16-core dual-CCD, with
  a warning that OEM power management can override the power plan and interrupt
  settings and that vendor control apps may revert them.
- **Non-X3D CPUs are allowed.** Defender exclusions, timer resolution, Game Bar /
  USB suspend, pre-race quieting, tracing and stutter scanning all run. Core
  pinning and interrupt steering are skipped rather than guessed at.
- **Cache-topology detection.** `GetLogicalProcessorInformationEx` finds real CCD
  boundaries and identifies which CCDs carry V-Cache by L3 size, so future chips
  resolve correctly without a catalog entry. Defensive by design: overlapping
  cache pools, asymmetric CCDs or coverage that doesn't match the reported CPU
  count all cause it to report "unknown" and hand off to the name catalog rather
  than act on bad data. `Preflight-Check` prints which layer answered.
- **CPU profile page** in the dashboard, replacing the *Reset system* button. Shows
  the detected chip, how it was identified and the core numbers in use, with a
  six-option manual picker covering every supported layout plus re-detect.
- **`X3D_FORCE_PROFILE`** makes the whole kit behave as any supported chip for
  testing. Everything that writes to the registry switches to dry-run.
- **`tests\`** — `test-integration.ps1` sweeps all 17 chips asserting every
  interrupt target, CPU-Set range and trace split is valid and in range;
  `test-xaml.ps1` verifies the markup and that every wired control exists.
  Development-only, safe to delete.

### Fixed
- **Invalid interrupt targets on 6-core chips.** The old code assumed anything that
  wasn't 12 or 16 cores had 8, steering GPU interrupts to CPU 8 and NIC/USB to CPUs
  9–11. With SMT enabled on a 6-core those processors happen to exist, so it looked
  fine while pointing at arbitrary cores. With SMT disabled, or cores capped in
  msconfig, they do not exist — the same class of fault documented earlier for
  single-CCD chips picking "16-core", which risked GPU Code 10 / no display on
  reboot. Targets are now derived from actual topology and validated before
  anything is written; an unusable target aborts with an explanation instead of
  writing a bad mask.
- **Components disagreed about the CPU.** `Preflight-Check` and `Tuning-Menu` used
  different fallbacks — on a 6-core the menu chose CPU 8 while Preflight expected
  CPU 6, producing a GPU-IRQ mismatch warning that wasn't real.
- **Wrong V-Cache range on single-CCD chips.** Preflight reported an 8-core
  single-CCD chip's V-Cache as CPUs `0-7` when all 16 logical processors share it.
- **SMT-disabled systems mis-numbered.** The dashboard derived the highest CPU index
  as `cores × 2 - 1`, wrong whenever SMT is off. Now uses the real logical count.
- **Core count could be under-reported.** Detection used
  `[Environment]::ProcessorCount`, which reflects process affinity. Now reads
  `NumberOfLogicalProcessors` from WMI.
- **FullTrace could drop rows.** A CPU missing from the performance counter set
  threw during the per-core lookup. Missing counters are now skipped, not fatal.
- **Contradictory advice on non-X3D chips.** The Optimize page said to skip the
  Process Lasso step, then a dialog asked whether you'd done it. That dialog no
  longer appears on non-X3D chips and the "steps by hand" heading is hidden.
  Single-CCD chips now correctly read *one* step (the power plan) rather than two.
- **`Create-Launchers`** no longer generates shortcuts for `X3D-Profiles.ps1` (a
  library, not a tool) or for anything in `tests\`.
- **`README.txt`** per-session section rewritten to describe precisely what the
  shipped scripts do: scan *tasks* are disabled and persist across a reboot, while
  the services and Defender recover on their own. The previous wording left it
  ambiguous which parts self-heal.

### Changed
- **9950X3D2 guidance rewritten.** V-Cache sits on both CCDs, so there is no good
  and bad die and no preferred CCD for the scheduler to target. Pinning still
  helps, but because keeping the sim on one die avoids reaching across to the other
  CCD's cache — not because one die is slower. Same CPU-Set (`0-15`), correct
  explanation. Note this chip reports 16 cores exactly like a 9950X3D, so
  core-count detection alone cannot separate them; it is identified by name and
  cache size.
- **Interrupt steering hidden when inapplicable.** On non-X3D chips, or when
  topology can't be determined confidently, the GPU-IRQ fix is dropped from the
  automatic run and its Advanced button is disabled with an explanation.
- `Test-UndervoltStability.ps1` prose is chip-neutral (it referenced the 9950X3D
  specifically). Its logic already read core count dynamically — unchanged.
- All kit files normalised to CRLF.

### Supported processors
- **6-core single-CCD** — 5500X3D, 5600X3D, 7500X3D, 7600X3D
- **8-core single-CCD** — 5700X3D, 5800X3D, 7700X3D, 7800X3D, 9800X3D, 9850X3D
- **12-core dual-CCD** — 7900X3D, 9900X3D
- **16-core dual-CCD** — 7950X3D, 9950X3D
- **16-core dual-CCD, both cached** — 9950X3D2 Dual Edition
- **Mobile** — 7945HX3D, 9955HX3D
- **Non-X3D** — general fixes only

### Validated
- All 17 chips resolve to valid, in-range interrupt targets, CPU-Set ranges and
  trace splits (141 assertions, `tests\test-integration.ps1`).
- Every script parses clean; XAML well-formed with all 54 wired controls present.
- Confirmed on a non-X3D laptop chip (Ryzen 7 8745HX): detected as 16 logical
  processors with no V-Cache, general fixes only, topology-specific steps skipped.
- Windows PowerShell 5.1 compatibility verified by inspection — no PS7-only syntax
  or cmdlets, and the cache probe's C# is C#5-clean for the 5.1 CodeDom compiler.
  PowerShell 7 is not required by any part of the kit.

### Not changed
FullTrace CSV column names are the same (`ccd0_cpu`, `ccd1_cpu`, `freqcore_int`,
`freqcore_dpc`) so existing traces and spreadsheets still work. On a single-CCD chip
those two columns represent the low and high halves of the CPU list rather than
separate dies; the console output labels this correctly while logging.

---

## v2.1.0 — Race-Quiet that actually holds

Field report: `wuauserv` and `UsoSvc` came back on their own roughly 10 minutes
after `Pre-Race-Quiet` ran, so background update scans resumed mid-session.

**Root cause.** v2.0.0 only *stopped* those services. A stopped service is
trivially restartable, and the Windows Update Medic (`WaaSMedicSvc`) plus the
UpdateOrchestrator tasks exist specifically to detect and undo update-stack
tampering — so they simply started them again. Stopping was never going to hold.

### Breaking
- **Quieting now survives a reboot.** Services are set to `Start=4` (Disabled),
  not merely stopped, so they stay off until `Post-Race-Restore` runs.
  This reverses the previous "per-session, self-heals on reboot" behavior.
  **`Post-Race-Restore.ps1` is now mandatory, not just tidy** — a forgotten
  restore leaves the machine without Windows Update (and, since Defender
  signature updates ride `wuauserv`/BITS, with stale definitions).

### Added
- **Snapshot / faithful restore.** `Pre-Race-Quiet` writes a JSON snapshot of the
  *actual* prior state — each service's `Start` and `DelayedAutostart` values,
  each task's prior state, whether Defender real-time was already off — and
  `Post-Race-Restore` replays exactly that instead of re-enabling blindly.
  Notably, Defender is left OFF on restore if it was already OFF beforehand.
  Snapshot is consumed (deleted) on a successful restore.
- **`WaaSMedic\PerformRemediation`** added to the disabled-task list — the task
  that drives the ~10-minute revert.
- **SYSTEM context by default.** Both scripts re-run themselves as SYSTEM via a
  temporary scheduled task (created, run, deleted) so TrustedInstaller-locked
  Orchestrator/Medic tasks can be disabled. Requires nothing from the user beyond
  the existing admin prompt. `-NoSystem` opts out.
- **`-Verify` / `-VerifyDelay`** (default 180s) — after doing the work, waits, then
  re-reads each service's `Start` value and re-checks the disabled tasks, reporting
  anything that reverted. This is the definitive test of whether a refused task
  actually matters on a given machine.
- **`bits` and `DoSvc`** added to the quieted services (update transfer/delivery).
  Both are in a clearly-labeled array at the top of each script if you'd rather
  trim them — `wuauserv` and `UsoSvc` do the bulk of the scan work.
- **Windows Update pause backstop** (`-PauseDays`, default 2) via the UX +
  policy registry keys, cleared on restore. Limits exposure if a restore is missed.
- **Self-elevation** in both scripts (they relaunch elevated instead of erroring out).
- **`-SkipDefender`** to leave real-time protection alone, and **`-Force`** to
  re-snapshot when a stale state file exists.

### Changed / Fixed
- **State and log moved to `C:\ProgramData\RaceQuiet\`.** The script folder is not
  reliably writable by SYSTEM when it sits on a OneDrive-redirected Desktop or a
  network share — which would have silently lost the snapshot and left nothing to
  restore from. ProgramData is writable by both the Admin and SYSTEM runs, so the
  two scripts always agree on the path.
- A stale state file now blocks a second `Pre-Race-Quiet` run (a prior session was
  never restored) unless `-Force` is passed, so the original state can't be
  overwritten with an already-quieted one.
- `Post-Race-Restore` falls back to sane Windows defaults, loudly, if no snapshot
  is found.
- Both scripts append to a shared `RaceQuiet.log`; the SYSTEM run tails it back to
  the console, since a SYSTEM task has no visible window (session 0).
- Task handling reverted to the v2.0.0 **curated list** rather than wildcard path
  matching — the wildcard approach produced a dozen spurious "access denied" lines
  for tasks that don't matter.

### Retained from v2.0.0
Edge auto-update tasks (`MicrosoftEdgeUpdateTaskMachine*`), `PushToInstall`
(LoginCheck / Registration), `ReconcileLanguageResources`, `InstallService` and
`UpdateOrchestrator` scan tasks, `WSearch`, and the Defender real-time toggle with
its Tamper-Protection guidance. Output remains compatible with
`Check-Quiet-Status.ps1`.

### Validated
Confirmed on the target rig (dual-CCD X3D):

- **`WaaSMedic\PerformRemediation` = `Disabled`** — the default SYSTEM hop cleared
  the task that drives the revert. No registry ownership change was needed.
- **Held 30+ minutes** with no return of `wuauserv` / `UsoSvc`, against a prior
  failure mode of ~10 minutes. `Check-Quiet-Status.ps1` still reported race-ready.
- Both scripts parse and run clean; brace/paren balance and the shared
  `C:\ProgramData\RaceQuiet\` state path verified across the pair.

Not yet exercised: the full `Post-Race-Restore` round-trip on that machine.

### Known limitation
On some builds `WaaSMedic\PerformRemediation` is TrustedInstaller-owned and can
refuse to disable **even as SYSTEM** (it did not on the test rig). Where that
happens the service disable plus the update pause generally still hold, and
`-Verify` is how you confirm it per-machine. Clearing that last task would require
a registry ownership change, deliberately not included — invasive and hard to
restore cleanly.

Note: the `WaaSMedic` tasks are not visible to a **non-elevated** `Get-ScheduledTask`
— CIM reports "no matching objects" rather than access denied. Query them from an
elevated prompt or the state will look absent when it isn't.

### Follow-ups
- ~~`README.txt` still describes the per-session routine as not surviving a reboot.~~
  Closed in v2.2.1, which ships the disable-not-stop behavior and documents it.
- ~~Optional deadman switch under consideration.~~ Shipped in v2.2.1 as `-Deadman`.

---

## v2.0.0 — WPF GUI Dashboard

The text menu was replaced with a modern dark-themed graphical dashboard
(`Tuning-Menu.ps1`, "upgraded").

### Added
- **Real GUI.** WPF dark-theme dashboard with page-based navigation
  (Main / Troubleshoot / Each-Race / Advanced / Help), STA self-correct, and a
  hidden console window for an app-like feel.
- **Automatic detection.** Detects CPU/GPU on first launch and picks the right
  single- vs dual-CCD profile; config saved to `%APPDATA%\iRacingX3DTuning`.
- **Collapsible tool menus** on Advanced and Troubleshoot pages — each item expands
  to a plain-English description and a Run button. Admin actions marked orange,
  undo actions red.
- **Guided Optimize.** Lays out the manual Process Lasso steps first (dynamically
  hidden for single-CCD chips), then runs all automatic fixes in a single
  one-UAC elevated window.
- **Help page + per-button tooltips**, an "Am I race-ready?" status check, and a
  **Reset / re-detect** button (replaced by the CPU profile page in v2.2.0).
- One-click Web Guide link.

### Changed / Fixed
- **Window auto-sizing** (`SizeToContent="Height"` + per-page `ScrollViewer`) so
  buttons are never clipped; scrollbar only appears when a page is taller than the screen.
- Corrected the header background-core range math.
- Startup wrapped in try/catch so a load failure shows a dialog instead of vanishing.
- Validated: PowerShell parses clean, XAML well-formed, all 35 wired controls exist
  in the markup (the classic WPF crash — clean).
- Noted dependency on three timer-resolution scripts
  (`Watch-TimerResolution`, `Enable-/Undo-GlobalTimerResolution`); the menu degrades
  gracefully if any are absent.

---

## Interactive menu polish (`Tuning-Menu.ps1`)

- Corrected **core-vs-CPU labeling** throughout (the affinity numbers `0-15` / `16-31`
  were always correct — they address logical processors — but were mislabeled
  "cores"). Header now reads e.g. `Sim -> V-Cache cores 0-7 (CPUs 0-15)`.
- Added physical-core mapping alongside CPU ranges in the setup prompt, requirements
  screen, and Process Lasso wizard step; same treatment for the 12-core 9900X3D.
- Reflowed the navigation into a clean, aligned `[Key] Option` grid.
- Added `Ensure-CoreLabels` — backfills the new core fields on load for users whose
  saved `config.json` predates them (backward compatibility).

---

## Broaden hardware support & fix topology bugs

- **Single-CCD safety (5800X3D / 7800X3D / 9800X3D).** Identified that the GPU-IRQ
  step is a dual-CCD trick with no second die to offload to on single-CCD chips —
  and that picking "16-core" targeted a non-existent CPU 16, risking a GPU
  Code 10 / no-display on reboot. Made topology handling explicit: single-CCD chips
  have nothing to pin and skip the GPU-IRQ step; IRQ scripts fall back to half the
  logical-processor count as a safe target for any X3D.
- **8-core topology check off-by-one.** Fixed the Step-1 check that false-flagged
  correctly-configured 8-core/16-thread chips (9800X3D, 9850X3D) by treating "16"
  as a required index rather than a count. Made it dynamic: pass when
  `logical == 2 × physical` regardless of 16/24/32, and only warn about msconfig
  core-capping when logical is actually below that.

---

## The script kit ("iRacing stuttering issue" main build)

The bulk of the tool was built and tested here — a folder of PowerShell scripts
plus launchers and a repo, targeting dual-CCD Ryzen X3D + NVIDIA.

**Diagnostics (read-only)**
- `FullTrace.ps1` — main logger; race, then read the CSV. Time-gaps in it = whole
  system stalls.
- `Scan-Stutter-Events.ps1` — rebuilt to **auto-read the latest trace** from the
  Desktop (replacing an earlier version with hardcoded timestamps) and list the
  scheduled tasks / events around each stutter.
- `Preflight-Check.ps1` — pre-session sanity check (template tuned to the example rig).
- `Enable-DiagnosticLogs.ps1` — turns on the TaskScheduler log that Scan-Stutter reads.

**Fixes (change settings)**
- `Repair-PerfCounters.ps1` — rebuild broken perf counters (fixes empty per-core columns).
- `Set-GPU-IRQ-Affinity.ps1` / `Undo-…` — steer GPU interrupts onto the frequency CCD
  and off CPU 0.
- `Set-NIC-USB-IRQ-Affinity.ps1` / `Undo-…` — steer NIC + USB interrupts off CPU 0.
- `Pre-Race-Quiet.ps1` / `Post-Race-Restore.ps1` — per-session lever that quiets
  Windows Update / Search (and optionally Defender real-time), then restores them.
- `Add-Defender-Exclusions.ps1`, `Apply-Guide-Extras.ps1` / `Undo-…` — Defender
  exclusions, USB Selective Suspend off, Game Mode/Bar off.
- Power plan via **Bitsum Highest Performance** (Process Lasso); sim pinned to
  V-Cache cores (`0-15` on 16-core, `0-11` on 12-core).

**Packaging & UX**
- `Apply-Baseline.ps1` — applies every fix in one elevated run.
- `Create-Launchers.ps1` — generates a double-click `.lnk` next to each script;
  admin scripts auto-elevate.
- `Start-Tuning-Menu.bat` and shortcuts that launch with
  `-ExecutionPolicy Bypass` so they run regardless of policy / Mark-of-the-Web.
- Repo + `README.txt` documenting the suggested first-time order and per-session routine.
- A shareable **progress report card** image (grade + before→after stat cards +
  GPU-utilization bar chart, built from real capture data).

**Verified findings during testing**
- Confirmed the sim stays on CCD0 (busiest core is consistently a CCD0 core);
  even CCD averages were just CCD1 carrying VR compositor + overlays by design.
- Diagnosed recurring ~5–6 min stalls as **Windows Update background scans**, fixed
  by running `Pre-Race-Quiet` before each session.
- Added `Check-Quiet-Status.ps1` — a read-only "Am I race-ready?" checker (services,
  scheduled tasks, Defender state), clarifying that Pre-Race-Quiet is per-session and
  does **not** survive a reboot.

---

## Research & diagnosis (the "why")

Before any tool existed, the core theory and measurement method were worked out.

- **V-Cache CCD vs. clocks.** Established that iRacing is cache- and
  memory-latency-bound, so the 3D V-Cache die (CCD0) can beat the higher-clocking
  die (CCD1) despite lower clocks. Concluded that per-core clock benchmarks are
  misleading and the only honest test is a repeatable in-game workload measuring
  1% / 0.1% lows, not average FPS.
- **Whole-system Process Lasso policy.** Built a full CPU-affinity policy
  (~212 changes) that re-isolates CCD0 for the game, pushes OS/`svchost`/background
  work to CCD1 (`16-31`), promotes racing companions (VoiceMeeter, Moza, SteamVR
  compositor, SimHub, Pimax runtime) to fast cores, and demotes updaters/telemetry.
  Included a pre-apply `prolasso.ini` backup for one-shot revert.
- **Trace analysis breakthrough.** Analysis of a `FullTrace` CSV revealed the real
  limiter: a **single core pinned at 100% for ~72% of a session** (a classic
  single-thread bottleneck) while both CCDs averaged ~25–28% and the GPU sat at
  ~60%. Confirmed the busy core was often **core 0** (worst case, shared with OS/DPC
  work), and that iRacing simulates **particles on the CPU main thread** — so
  particles High→Medium was a genuine lever.
- **Side experiment:** `rpy_parser.py`, a parser for iRacing `.rpy` replay headers
  (driver, session, track, entrants). Only the header is decodable; per-frame
  telemetry has no public spec.

---

## Notes

- **Per-session routine:** run `Pre-Race-Quiet` before racing, `Post-Race-Restore`
  after. **As of v2.1.0 quieting survives a reboot** (services are disabled, not
  just stopped), so the restore step is required — it is no longer optional.
  Historical entries below describe the older stop-only behavior.
- **Launch reliably** via the `.bat` / shortcuts (they use `-ExecutionPolicy Bypass`),
  and `Unblock-File` the kit once after unzipping.
- **As of v2.2.0 all CPU detection lives in `scripts\X3D-Profiles.ps1`.** Don't
  delete it and don't mix script versions across releases — six scripts depend on it.
- Every settings-changing script has an undo or is reversible; review before running
  on another PC.
