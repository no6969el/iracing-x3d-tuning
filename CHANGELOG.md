# Changelog — iRacing X3D Tuner / Optimizer


The project ships as a script kit plus a web guide at
`https://no6969el.github.io/iracing-x3d-tuning/`.

---

## v3.3.0 — one list, and a trace tool that could only see half of it (current)

Two root causes, both the same shape: **a fact that lived in more than one place
drifted, and nothing was watching.**

The first was measured. An xperf HARD_FAULTS trace of a real 25-minute
Nordschleife session — kernel providers, with filenames, not inference —
captured 4,712 hard faults. `iRacingSim64DX11.exe` accounted for **14** of them.
Five services the kit was not touching accounted for **1,547**, led by the
Microsoft Store deciding to update apps mid-race (829 faults on
`WinStore.App.dll` alone). The kit was aimed correctly and still missing the
largest single non-kernel offender.

The second was structural, and it is the more important one. The service list
lived in four separate copies and the task list in four more, each with a
hand-written *"must mirror Pre-Race-Quiet"* comment above it. Those comments were
an admission that the lists drift — and v3.2.5's own entry, immediately below,
is that drift shipping as a bug. This release removes the duplication rather
than adding another comment asking people to be careful.

### Breaking

- **`scripts/Kit-Common.ps1` is new and required.** `Pre-Race-Quiet`,
  `Post-Race-Restore`, `Check-Quiet-Status` and `Trace-QuietReverts` all
  dot-source it and will refuse to run without it. Copy the whole `scripts/`
  folder; a partial upgrade will not work. Run `Post-Race-Restore` on your
  current version **before** swapping files.

### Fixed — `Trace-QuietReverts` was blind to five services

`$Watched` was six hand-typed service names. `Pre-Race-Quiet` disables eleven.
The five added by the hard-faults work could revert without the forensic tool
ever mentioning them — and its scheduled-task filter was a six-folder regex
against a list that had grown to 22 folders.

Both are now derived from the shared list, so the trace cannot fall behind what
the quiet script does. If you have been chasing the `wuauserv` revert, re-run
this: it can now see things it previously could not.

### Fixed — a restore could enable a task the quiet never disabled

`PI\Secure-Boot-Update` was commented out in `Pre-Race-Quiet` but present in
`Post-Race-Restore`'s no-snapshot fallback. A fallback restore therefore turned
**on** a task the kit had never turned off. One shared list makes that class of
mismatch impossible.

### What's new

- **One place to edit what gets quieted.** `Kit-Common.ps1` holds `$KitVersion`,
  `$ServicesToQuiet` (11), `$TasksToDisable` (39) and the no-snapshot restore
  defaults. All four race-quiet scripts read it. The provenance comments — which
  trace, how many faults, why each entry earned its place — moved with the data.
- **Added to the quiet list** from the HARD_FAULTS trace: `InstallService`,
  `edgeupdate`, `edgeupdatem`, `PcaSvc`, `TabletInputService`, 19 further
  scheduled tasks, and the Store auto-download policy. `-KeepTouchKeyboard`
  leaves `TabletInputService` alone if you use the touch keyboard in VR.
- **GPU interrupt steering is now vendor-neutral.** `Set-GPU-IRQ-Affinity` and
  its undo detect the display adapter by PCI vendor ID (NVIDIA `VEN_10DE`, AMD
  `VEN_1002`, Intel `VEN_8086`) instead of assuming NVIDIA. The interrupt-affinity
  policy attaches to the device instance, not the driver, so the mechanism was
  always identical across vendors. This replaces the manual file-swap that the
  `AMD Related Optimizer files/` folder used to require; that folder is gone.
- **The undo is gentler.** It removes only `DevicePolicy` and
  `AssignmentSetOverride`, then deletes the key only if nothing else is left,
  rather than removing the key outright. Running it when no policy was applied
  now reports "nothing to undo" instead of doing nothing silently.
- **`$KitVersion` drives the banners.** Runtime version strings and the snapshot's
  `Tool` field read from one constant. Four files previously claimed four
  different versions.
- **`.gitattributes`** pins text files to CRLF. Four of the most-edited scripts
  had drifted to LF against the project's own convention.

### What's new — FullTrace v3 names the process, not just the number

The five services above were found with an external xperf capture. That tool now
lives in the kit, because the trace that found them also proved the kit's own
headline diagnostic could not have.

`hardfaults_s` is a **system-wide** counter. It always was. Nothing in the kit
said so, and the number is alarming — tens of thousands per second during a race
looks exactly like a sim starved for I/O. It is not. In the traced session:

| faults | process | what it was reading |
|-------:|---------|---------------------|
| 1,729 | `System (4)` | `$Mft`, `$UsnJrnl` — NTFS metadata |
| 829 | `backgroundTaskHost.exe` | `WinStore.App.dll` |
| 251 | `MicrosoftEdgeUpdate.exe` | |
| 245 | `SearchHost.exe` | Start-menu web components |
| 201 | `TabTip.exe` | touch keyboard |
| 170 | `ctfmon.exe` | |
| **14** | **`iRacingSim64DX11.exe`** | a font cache, `$UsnJrnl`, the shader cache |

Fourteen out of 4,712 — 0.3%. Not one texture, not one `.dat`. Total iRacing
*content* faulting for the whole session was 17 events on `tracks.dat` and the
car's `.dat`, all during track load, which is exactly where they belong.

Read that column as sim I/O and you will tune storage for days and fix nothing.

- **`FullTrace.ps1` is v3.** Run elevated with the Windows Performance Toolkit
  present and it starts a kernel `PROC_THREAD+LOADER+HARD_FAULTS+FILENAME`
  session alongside the existing per-second sampling. On exit it attributes every
  fault and adds three columns — `sim_hardfaults_s`, `top_fault_proc`,
  `top_fault_file` — so each row says *who* faulted that second and *what* they
  read. It also writes `iRacing-HardFaults-<stamp>.csv` with every event, and
  prints a ranked per-process summary ending in the percentage attributable to
  the sim.
- **It degrades, it does not fail.** No admin, no xperf, or `-NoHardFaultTrace`
  and it behaves exactly as v2 did, says so in the banner, and still writes the
  same 39-column CSV. The "no admin needed" promise is intact; the extra columns
  are the only thing you give up.
- **The sampling loop is wrapped in `try/finally`** so the ETW session is stopped
  on Ctrl+C as well as a clean exit. A kernel trace left running writes to disk
  indefinitely — the one way this script could have cost somebody something. It
  also calls `xperf -stop` before starting, to clear a session orphaned by a
  previous run. Manual escape hatch: `xperf -stop`.
- **The CSV is rebuilt, not edited in place.** If attribution throws, the
  recorded trace is still on disk and only the extra columns are lost.
- **New GUI button.** Troubleshoot → *1) Record a race* now has **Run** and
  **Hard faults (Admin)** side by side. Both launch the same script; v3 decides
  for itself whether to trace, so `-Admin` is the entire difference and there are
  no arguments to keep in sync between the menu and the script.

### Fixed — `Scan-Stutter-Events` could not see a whole class of stutter

It triggered on one thing: a gap in the timestamps. A burst of hard faults can
stall a frame without the logger ever missing a second, so those stutters were
invisible to the analysis step even when the capture step had recorded them
perfectly.

- **A fault burst is now an incident in its own right,** tagged `FAULT` where a
  missing second is tagged `GAP`. A synthetic trace carrying both confirms each
  detector fires independently.
- **Every incident names the process and the file** that faulted at that second
  instead of leaving you to infer it from a list of scheduled tasks. Where the
  sim faulted zero times, the report says so explicitly and names who did.
- **A session-wide attribution table** ranks which process was the top faulter in
  the most seconds, with the sim's own row marked.
- **It parses with `Import-Csv` now.** The old code took field `[0]` of a raw
  string split, which could not see any other column — and the new fault columns
  are quoted, which a naive split would have mangled.
- Traces without the fault columns are detected and the report says exactly which
  button to use to get them, rather than silently omitting the section.

### Fixed — the xperf lookup was about to become the next drifted fact

This release exists because facts stated in two places drift. The hard-fault work
then hardcoded the Windows Performance Toolkit paths, the provider string and the
output filenames into `FullTrace`, and `Scan-Stutter-Events` and `Preflight-Check`
each needed the same knowledge. That is three copies, shipping in the release
that removes duplicate copies.

`Kit-Common.ps1` now also owns `$HardFaultSessionName`, `$HardFaultProviders`,
`$FullTraceCsvPattern`, `$HardFaultCsvPattern`, `$HardFaultColumns`, `Find-Xperf`
and `Test-HardFaultTraceRunning`. `FullTrace` keeps a fallback so it still runs
if copied out of the kit, but prefers the shared definitions — and a test asserts
that it does.

### What's new — Preflight reports hard-fault readiness

- **Section 8 says whether the *Hard faults* button will actually work** — that
  is, whether the Performance Toolkit is installed. Without this the button
  produces blank columns and only a grey console line explains why.
- **It detects a kernel trace session left running.** Force-close the FullTrace
  window instead of pressing Ctrl+C and the ETW session survives, writing to disk
  until something stops it. That is the one way this release could cost somebody
  something, so it now counts as a **NOT READY** item with the exact command to
  clear it. Detection uses `logman`, not `xperf`, so it works even on a machine
  where the toolkit was never installed.

### Fixed — `.gitattributes` was documented but absent

The v3.3.0 notes said it pins text files to CRLF. The file was not in the
repository. Every file happened to be CRLF anyway, so the claim held by luck
rather than by enforcement — the same class of documented-but-missing reference
as the `Validate-Repo.ps1` mentions removed elsewhere in this release. The file
now exists, covers the kit's real extensions, and marks generated diagnostic
output (`iRacing-FullTrace-*.csv`, `iRacing-HardFaults-*.csv`,
`stutter-events.txt`) as `-text` so Git never rewrites a captured trace.

### Tests

- `test-kitcommon.ps1` asserts the hard-fault constants exist, that
  `$HardFaultProviders` still contains **both** `HARD_FAULTS` and `FILENAME`
  (drop `FILENAME` and every fault comes back nameless — the trace still "works"
  and is useless), that `Find-Xperf` never throws when the toolkit is absent, and
  that all three consumers load the shared file.
- `test-xaml.ps1` asserts both FullTrace buttons exist, are wired, sit in the
  same horizontal `StackPanel`, that the plain **Run** button has **not** gained
  `-Admin` — the kit's no-admin promise for the read-only tracer — and that no
  `x:Name` is duplicated, which is a runtime `XamlParseException` rather than a
  parse error and would otherwise sail past the well-formedness check.

### Documentation

- `FullTrace.ps1`'s header now opens with the attribution table above, before any
  of its column documentation. The `hardfaults_s` warning is the first thing a
  reader meets, because the misreading is the expensive part.
- `scripts/README.txt` marks FullTrace as `(ADMIN opt)` and carries the same
  system-wide caveat.
- `README.txt`'s "what gets disabled" inventory said 6 services and 20 tasks
  under a v3.2.5 heading. It now matches the shipped lists (11 and 39) and points
  at `Kit-Common.ps1` as authoritative.
- Removed the `Validate-Repo.ps1` / `Validate-Repo.bat` references from
  `README.md`. They were listed twice and announced in this changelog, but the
  files have never existed in the repository.
- `index.html` no longer describes the GPU fix as NVIDIA-only, and the
  each-race note now says 39 tasks / 11 services instead of v3.2.5's 20 and 6.

### Validated

- All 28 scripts parse clean under PowerShell 7 AST parsing (Linux sandbox).
- The shared lists resolve to 11 services and 39 tasks, and every service in
  `$ServicesToQuiet` has a matching entry in `$ServiceDefaults`.
- The derived task-path regex matches every folder in `$TasksToDisable`.

**On Windows, on real hardware** (9950X3D / RTX 5090 / Win11, elevated):

- `FullTrace.ps1` v3 parses and runs; `-NoHardFaultTrace` produces a byte-for-byte
  compatible 39-column CSV, confirming the v2 path is untouched.
- Diffed against v2: three lines changed, all version strings or the rewritten
  `hardfaults_s` doc line. Nothing removed.
- `Tuning-Menu.ps1` XAML parses as XML; the FullTrace expander contains exactly
  two buttons in a horizontal `StackPanel`; all 48 `FindName` targets resolve
  against 56 unique `x:Name` declarations with no duplicates; both click handlers
  wire to the expected script and switch.
- The underlying capture, dump and per-file attribution were exercised end to end
  on a 25-minute session — that trace is the source of the table above.
- The whole test suite passes: `test-kitcommon`, `test-xaml`, `test-racequiet`,
  `test-profiles` and `test-integration`.
- `Scan-Stutter-Events` was run against a synthetic trace built to carry a
  timestamp gap **and** a sim fault burst at a second with no gap. Both were
  detected and tagged separately, attribution named the right process and file
  for each, and the session table ranked correctly — confirming the new detector
  catches the case the old one structurally could not.
- Every edited file is CRLF, checked byte-by-byte rather than assumed.

### Not yet validated

- **The in-script hard-fault path has not been run against a full race.** The
  capture, dump and attribution logic was proven as a standalone tool; folding it
  into FullTrace's `finally` block is validated by parse and by a short dry run,
  not by a complete session ending in Ctrl+C. Watch the first one.
- The GUI has not been rendered — WPF could not be hosted in the validation
  environment, so the two buttons are verified structurally rather than visually.
  Check the label fits your window width on first launch.
- **The race-quiet round trip is still outstanding.** `Pre-Race-Quiet` →
  `Post-Race-Restore` has not been exercised end to end on a real machine, and
  that has been true since v3.1.0. The diagnostic half of this release has now
  been run on Windows; the half that changes system state has not.
- The vendor-neutral GPU scripts have not been exercised on an AMD or Intel
  adapter; the NVIDIA path is unchanged in behaviour but is also untested here.
- The `wuauserv` revert reported from the field is **not** fixed by this release.
  The trace tool can now see the five previously invisible services, which may
  identify the healer, but the cause is still open.

### Bonus — iRacing Tuner Mini    ****REMOVED TEMPORARILY**** 

`mini-tuner/Small-Tuning-Menu.ps1` and `mini-tuner/Start-Small-Tuning-Menu.bat`,
for people who want the baseline fixes without the full troubleshooting
workflow. It keeps the initial CPU detection, then offers **Optimize My PC**, the
before/after race routine, **Defender Exclusions** and **Guide Extras**. A
lower-profile companion rather than a headline feature. Not included in the main
ZIP download — GitHub repository only.

---

## Guide update — Trading Paints conflict documented
*(documentation only — no script changes, no new release)*

A user reported far more plain white cars than usual. Traced to Step 6 of the
guide, not to anything in the script kit.

`LoadTexturesWhenDriving=0` and `CacheSwap3HighResCars=0` stop iRacing loading
textures while you're driving. Trading Paints works the opposite way: it fetches
each opponent's livery *during* the session and asks iRacing to reload that car.
So any paint arriving after you roll out is never applied and that car stays
white for the session — which is why it shows up as *more* white cars rather than
all of them. Paints that landed before the session finished loading are fine.

Trading Paints documents `LoadTexturesWhenDriving` as the setting to change when
cars stay white, so this is a genuine trade-off between the two tools rather than
a fault in either.

- Both table rows in Step 6 now carry a warning marker.
- A trade-off callout after the table spells out the choice: liveries
  (set both to `1`) or minimum mid-lap streaming (leave at `0`).
- New troubleshooting entry, "Lots of plain white cars since I followed this
  guide", with the fix and the correct renderer filename for VR or flatscreen.
- It also states plainly that the script kit doesn't affect Trading Paints —
  the pre-race quieting doesn't touch it and Defender exclusions only add
  permissions — so nobody wastes time reinstalling the kit over this.

Only `index.html` changed.

---

## v3.2.5 — the quiet list was incomplete, and the status screen agreed with it

A trace came in from another user's machine — an 8-core X3D rig, not the
development box. In a 17-minute window, **14 scheduled tasks launched**. Not one
of them was on the kit's disable list. Two of them ran `usoclient.exe`, roughly
ten minutes apart.

The list had been built from the Windows Update stack outward. Everything in it
was correct; it just stopped short. The telemetry and flighting tasks Windows
runs alongside updates were never in scope, and nobody had looked because there
had been no trace from a machine other than the one it was written on.

Worse, `Check-Quiet-Status` only checked 8 of the 11 tasks the kit disabled, and
its verdict passed if **one** was off. On a machine with the update tasks quieted
and everything else live, it printed "RACE-QUIET is ACTIVE — good to race." That
is the failure mode that matters most: a green light over a machine that will
still stutter.

### Added — nine tasks now disabled before a race

| Task | Why |
| --- | --- |
| `UpdateOrchestrator\Schedule Work` | Runs `usoclient.exe`. Observed firing mid-session. |
| `UpdateOrchestrator\Start Oobe Expedite Work` | Runs `usoclient.exe` on the expedited-update path. |
| `Flighting\FeatureConfig\ReconcileFeatures` | Reconciles staged feature rollout with Microsoft. |
| `Flighting\FeatureConfig\UsageDataReceiver` | Feature-usage telemetry. Fired three times in 17 minutes. |
| `Flighting\FeatureConfig\UsageDataFlushing` | Flushes buffered telemetry to disk and network. |
| `Flighting\OneSettings\RefreshCache` | Pulls Microsoft's remote config blob, writes registry. |
| `Windows Error Reporting\QueueReporting` | Compresses and uploads queued crash dumps. |
| `DeviceDirectoryClient\RegisterUserDevice` | Device registration call-out. |
| `WindowsAI\Settings\InitialConfiguration` | Windows AI / Copilot settings initialisation. |

All nine are telemetry or update scheduling. None of them do anything you need
during a race, and all nine are restored afterwards like everything else.

`PI\Secure-Boot-Update` is present in `Pre-Race-Quiet.ps1` but **commented out**.
It carries Secure Boot DBX revocations and TPM maintenance, it fires rarely, and
it is short. Uncomment it only if you have traced it landing inside a session.
`Post-Race-Restore` re-enables it either way, so uncommenting is a one-way door
only until the next restore.

### Fixed — the status screen no longer passes a machine that isn't ready

- **`Check-Quiet-Status` now checks all 20 tasks**, not 8. `UUS Failover Task`,
  `ScanForUpdatesAsUser` and `Registration` had been missing since they were
  added to `Pre-Race-Quiet`.
- **The verdict now requires every visible task to be off.** It previously
  passed on one. A new **PARTLY QUIET** result covers the middle case: services
  down, tasks still live. It lists every task still enabled by full path and
  points at `Trace-QuietReverts.ps1` if re-running as admin doesn't clear them.
- **Tasks absent from the Windows build are counted separately** and never held
  against the verdict. Windows 10 has no `WindowsAI\Settings`; some builds have
  no `Flighting` tasks. The screen now says "4 not present on this Windows build"
  instead of quietly shrinking the denominator.

### Fixed — a re-quiet would have skipped every new task

Found on live hardware, not in review. `Check-Quiet-Status` reported
**11 of 19 disabled** on a machine holding a snapshot written by v3.2.0.

When an un-restored snapshot exists, `Pre-Race-Quiet` deliberately re-applies
from it rather than re-snapshotting — capturing a quieted machine would record
the quieted state as "original" and strand the services off forever. Correct.
But it also meant the task list came from the *snapshot*, not from
`$TasksToDisable`, so a machine quieted under v3.2.0 would never pick up the
nine additions no matter how many times you re-ran it.

A re-quiet now compares the saved snapshot against the current list. Any task
the snapshot has never heard of was never touched by the earlier run, so its
present state **is** its original state — it is captured, appended, and the
snapshot is re-saved so `Post-Race-Restore` knows to put it back. A task you had
already disabled yourself is captured as `Disabled` and stays off on restore, as
it always has. If the snapshot can't be re-saved the run says so in red rather
than disabling tasks it can't account for.

### Fixed — restore could leave a task disabled forever

- **`Post-Race-Restore`'s no-snapshot fallback list** still held the old 11. If
  the snapshot was missing or discarded, the nine new tasks would never be
  re-enabled by anything. The fallback now carries all 21, including
  `Secure-Boot-Update`.
- **A task hidden from the restoring context is no longer skipped in silence.**
  Protected tasks report "no matching objects" rather than access denied, so the
  old check read that as "not on this machine" and walked away — leaving a task
  the kit had disabled switched off permanently. When the snapshot says the kit
  disabled it, it is now handed to the SYSTEM helper instead. Without a snapshot
  the behaviour is unchanged, because there is no evidence the task ever existed.

### Validated

- All three scripts parse clean (PowerShell AST).
- The task list in `Pre-Race-Quiet`, `Post-Race-Restore` and
  `Check-Quiet-Status` cross-checked programmatically: **identical, 20 entries,
  no duplicates**, with `Secure-Boot-Update` present only in the restore
  fallback, by design.
- `Check-Quiet-Status` verdict exercised against five simulated states — all
  disabled, partly disabled, tasks missing from the build, services stopped but
  still Manual, nothing quieted. Each produced the correct result; the
  tasks-missing case correctly still reports race-ready.
- The restore loop's new branch tested both ways: with a snapshot a hidden task
  is handed to the SYSTEM helper, without one it is skipped as before.
- Snapshot extension tested against a stale snapshot: newly-listed tasks are
  captured at their true current state, a task already disabled by the user is
  recorded as `Disabled` and left off by the restore, and a task absent from the
  build is skipped.
- **Confirmed on live hardware.** A 9800X3D-class machine holding a v3.2.0
  snapshot reported `PARTLY QUIET - 11 of 19 disabled` and named all eight live
  tasks by path. That is the new status screen doing exactly its job: the old one
  would have printed "RACE-QUIET is ACTIVE" over the same machine.

### Not validated

- No live-hardware run of this build yet. The nine tasks are drawn from an
  observed trace, but whether each one accepts `Disable-ScheduledTask` from an
  elevated prompt, needs the SYSTEM hop, or refuses both has not been measured.
  `RaceQuiet.log` names each outcome per task — read it after the first run.
- `WindowsAI\Settings\InitialConfiguration` and `PI\Secure-Boot-Update` are the
  likeliest to be TrustedInstaller-owned. The SYSTEM hop solves permission, not
  ownership. If either reports `SYSTEM FAIL`, it needs the same ownership round
  trip the Medic key gets, against a different target — a scheduled task lives in
  both `System32\Tasks\` and the `TaskCache\Tree` registry hive.

### Known gap, unchanged

The three task lists are maintained separately and must agree by hand. They agree
today and each carries a comment naming the other two. A shared module would
remove the risk; it was left alone here because this release should not be
reshaping how the scripts load each other.

---

## v3.2.0 — FullTrace can see the GPU properly, and stops crying wolf

Undervolt tuning on the target rig ran into the limits of the tracer. Six sessions
were logged across three different curves — one of which hard-crashed the machine
mid-race — and the CSV could not answer the one question that mattered: what
voltage was the card actually running at? This release closes that gap, fixes two
things the tracer was reporting wrongly, and retires a diagnostic claim the data
no longer supports.

### Added
- **GPU core voltage, fan, PCIe bus load and the active limiter now appear on the
  console line**, not only in the CSV. The original single-line layout is
  otherwise unchanged. Everything still reaches the CSV regardless of what the
  console shows.
- **Line colouring.** Grey is normal. Yellow means the power plan drifted from
  whatever was active on the first sample, or the GPU is power/temperature
  limited. Red means hard pagefaults above 50/sec. Red wins over yellow — a
  paging storm deserves more of your attention than a power cap.
- **Fifteen new CSV columns**, appended after the original twenty-four so existing
  traces and spreadsheets still parse unchanged: `gpu_volt_mv`, `fan_pct`,
  `mem_ctrl_util`, `vram_used_mb`, `mem_temp_c`, `gpu_fps`, `gpu_frametime_ms`,
  `pstate`, `volt_limit`, `power_limit`, `temp_limit`, `noload_limit`, `fan_rpm`,
  `pcie_bus_pct`, `fb_usage_pct`. The Afterburner-sourced ones need MSI
  Afterburner running; anything your card does not expose stays blank rather than
  failing the row.

### Fixed
- **`gpu_volt_mv` logged a constant `1` on every row of every trace.** Afterburner
  publishes core voltage in volts on some cards and millivolts on others, and the
  column assumed millivolts — so `1.05 V` rounded to `1`, and 826 consecutive
  samples recorded the same meaningless number. The value is now unit-detected by
  magnitude rather than trusting the units string, which is not reliably
  populated. Anyone who traced an undervolt on an earlier build was logging a
  constant, not a measurement.
- **The limiter display read `idle` in the middle of a race.** Afterburner's
  "No load limit" flag and nvidia-smi's `0x1` throttle reason are both asserted
  whenever nothing else binds, including at 90%+ GPU utilisation. Taken at face
  value that printed `idle` for the majority of a session under full load. `idle`
  is now shown only when the GPU genuinely is idle; above 50% utilisation it
  falls through to `--`.
- **The power-plan warning was hardcoded to Bitsum Highest Performance.** Correct
  for dual-CCD rigs, wrong for every single-CCD owner the guide tells to stay on
  Balanced — they would have seen every line flagged yellow. It now captures the
  plan active on the first sample and warns only when it *changes* mid-session,
  which is both chip-neutral and a closer match to the real failure mode
  (ParkControl or Dynamic Boost flipping the plan mid-race).

### Changed — a timestamp gap is no longer treated as proof of a stall
The guide has said since the first release that a skipped second in the trace is a
system-wide freeze. Measured across six sessions on one machine, that does not
hold. Gaps appeared at a near-constant **~2 per 10 minutes in every session** —
regardless of load, of which undervolt curve was applied, or of whether the
machine went on to crash — and were **always exactly 2.0 seconds**, never longer.
A genuine stall would vary in length and cluster with load. The rows either side
of every gap showed `tot_dpc` and `tot_int` at 0–1% and `hardfaults_s` at zero.

The cause was this script. Each iteration spawned `nvidia-smi` **twice** and
`powercfg` once, on top of three CIM queries and a process enumeration — three
process creations every second. When that work exceeded the one-second budget the
sleep was skipped and the next timestamp landed two seconds later.

- **One `nvidia-smi` call per sample instead of two.** The throttle-reason field
  was queried separately only because drivers disagree on its name
  (`clocks_throttle_reasons.active` versus `clocks_event_reasons.active`). That
  name is now resolved once at startup and folded into the main query.
- **`powercfg` is polled every tenth sample rather than every one.** The plan
  cannot change without something actively changing it, and a switch is still
  caught within ten seconds.
- **Guide and script header corrected.** A gap is now described as worth
  investigating rather than as proof, and counts as a stall only when the
  surrounding rows corroborate it — raised DPC or interrupt time, a
  `hardfaults_s` spike, or a GPU utilisation collapse. `Scan-Stutter-Events` is
  unchanged and still useful; it was the interpretation of a bare gap that was
  overstated.

### Validated
- Parses clean under AST validation; brace and paren balance verified. No
  PowerShell 7-only syntax or cmdlets.
- Voltage unit detection exercised across both representations (`1.05` → 1050 mV,
  `1050` → 1050 mV) and the blank case.
- Limiter and colour logic replayed against real captured trace rows: a
  6%-utilisation row correctly reads `idle`, 86–94% racing rows read `PWR` or
  `--` where the previous build read `idle`, and the row carrying a 22,599/sec
  pagefault spike correctly renders red.
- The per-core safe accessor from v2.2.0 — a CPU missing from the counter set
  must not kill the loop — is retained unchanged.

### Known gaps
`gpu_fps` and `gpu_frametime_ms` stayed blank across all six validation sessions:
RTSS was not hooking the OpenXR runtime on the test rig. That also means stutter
detection still has no direct measure and must be inferred from the other
columns. `mem_temp_c` was likewise unavailable on the test card. All three log
correctly where the sensor exists; none has been confirmed on hardware that
exposes it.

---

## v3.1.0 — Name the culprit, and force it if you must

v3.0.0 disabled the update services properly, which holds on most machines. On
some it didn't: users reported everything switching back on about ten minutes in,
exactly as before. This release adds the tooling to find out *why* on a given
machine, and an optional way through when the answer is Windows Update Medic.

### Added
- **`scripts\Trace-QuietReverts.ps1`** — read-only forensics answering "something
  turned the quiet back on, what was it?" `-Verify` told you *that* something
  reverted; this tells you *who*. It reads the kit's own log (filtered to
  operations it was refused), Service Control Manager **event 7040** — the
  definitive record of a service's start type being changed — the WaaSMedic
  operational log, and the Task Scheduler log, then lays them out as a timeline
  against the current state. Ends with a verdict pointing at one of four causes:
  Medic survived, Medic ran anyway, an explicit change from something else
  (Group Policy or MDM, which will win regardless), or a reboot with logging off.
  **Run it elevated** — the WaaSMedic tasks are invisible to a normal user and
  will look absent when they are not.
- **`-UnlockMedic`** on `Pre-Race-Quiet` (opt-in, off by default). On some builds
  `WaaSMedicSvc`'s registry key is owned by TrustedInstaller and refuses to be
  disabled even as SYSTEM — so Medic keeps repairing the update stack mid-race.
  This takes ownership of that one key, disables the service, verifies the write
  actually took, and hands ownership straight back within the same run. The
  original security descriptor is captured *before* anything changes and saved
  both to the snapshot and to a separate `.sddl` file.
- **`Post-Race-Restore` restores registry permissions**, verifies both the ACL
  and the owner, falls back to the `.sddl` file if the snapshot is gone, and
  **refuses to delete the snapshot** while any key remains unrestored — a
  half-finished restore cannot be silently forgotten. If it can't finish it
  prints the exact commands to fix it by hand, with your own descriptor filled in.
- **`scripts-medic-unlock\`** — an optional replacement pair with the unlock on
  by default, for handing to someone who has already confirmed Medic is their
  problem and shouldn't have to remember a switch. Identical to the standard
  scripts otherwise; `-NoUnlock` reverts to standard behaviour. Its README leads
  with "you probably don't need this" and tells the reader to run
  `Trace-QuietReverts` first.

### Validated
Confirmed on the machine that reported the problem. It was the TrustedInstaller
case: `WaaSMedicSvc`'s registry key refused to be disabled even as SYSTEM, so
Windows Update Medic kept repairing the update stack roughly every ten minutes,
mid-session. `Trace-QuietReverts` identified it, the unlock cleared it, and the
user reports the stutter is gone.

That also exercises the ownership round trip end to end on a real machine —
capture, take ownership, disable, verify, hand back — which had previously only
been verified by inspection.

### Notes
The unlock is deliberately **not** the default in the main scripts. Most machines
hold fine without it, and a kit that routinely reassigns ownership of system
registry keys is a different proposition from one that flips documented settings.
Keeping it opt-in, behind a diagnostic that proves it is necessary, is what keeps
it defensible.

---

## v3.0.0 — Race-Quiet that actually holds

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

## v2.1.0 — Disable, don’t stop: the first Race-Quiet fix

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
- **As of v3.2.0 a timestamp gap in a FullTrace CSV is not on its own proof of a
  stall.** Earlier entries below describe it that way; that guidance is superseded.
  Corroborate a gap against `tot_dpc` / `tot_int` / `hardfaults_s` before treating
  it as a system freeze.
- Every settings-changing script has an undo or is reversible; review before running
  on another PC.
