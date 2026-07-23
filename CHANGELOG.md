# Changelog — iRacing X3D Tuner / Optimizer


The project ships as a script kit plus a web guide at
`https://no6969el.github.io/iracing-x3d-tuning/`.

---

## v2.1.0 — Race-Quiet that actually holds (current)

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
- `README.txt` still describes the per-session routine as not surviving a reboot;
  that line needs updating for the new behavior.
- Optional deadman switch under consideration: `Pre-Race-Quiet` registers a
  one-shot task to auto-run `Post-Race-Restore` at next boot, deleted on a normal
  restore, so a forgotten session self-heals.

---

## v2.0.0 — WPF GUI Dashboard

The text menu was replaced with a modern dark-themed graphical dashboard
(`Tuning-Menu.ps1`, "upgraded"). This is the current version.

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
  **Reset / re-detect** button.
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
- Every settings-changing script has an undo or is reversible; review before running
  on another PC.
