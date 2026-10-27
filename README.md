# iRacing Tuning — Ryzen X3D + NVIDIA     (If you like this project give it a STAR!)

Zero hiccups in iRacing on Ryzen X3D — **every X3D AMD has shipped**, from the 6-core 5600X3D to the dual-cached 9950X3D2. Six steps, measured on a real rig, all reversible. The guide and menus detect your chip and only ever show the fixes that are safe for it.

<h2 align="center">👉 <a href="https://no6969el.github.io/iracing-x3d-tuning/">OPEN THE GUIDE</a> 👈</h2>
<p align="center">Everything is there: the steps, the download, the explanations, and the troubleshooting.</p>

---

### Supported processors

| Layout | Chips | What you do |
|---|---|---|
| **6-core single-CCD** | 5500X3D · 5600X3D · 7500X3D · 7600X3D | No pinning — all cores share the V-Cache |
| **8-core single-CCD** | 5700X3D · 5800X3D · 7700X3D · 7800X3D · 9800X3D · 9850X3D | No pinning — all cores share the V-Cache |
| **12-core dual-CCD** | 7900X3D · 9900X3D | Pin the sim to CPUs `0-11` |
| **16-core dual-CCD** | 7950X3D · 9950X3D | Pin the sim to CPUs `0-15` |
| **16-core, V-Cache on both** | 9950X3D2 Dual Edition | Pin to `0-15` — one die, avoids cross-CCD latency |
| **Mobile** | 7945HX3D · 9955HX3D | As 16-core, but OEM power management may override |

**Not an X3D?** The kit still works. Defender exclusions, the timer fix, Game Bar / USB suspend, pre-race quieting, tracing and stutter scanning all apply — core pinning and interrupt steering are skipped automatically rather than guessed at.

Your chip is detected on first launch. If it gets it wrong, **CPU profile** in the dashboard lets you set it by hand.

---

New here? Read [START-HERE.txt](START-HERE.txt). **In this repo** (the guide's [download](https://github.com/no6969el/iracing-x3d-tuning/archive/refs/heads/main.zip) gets you all of it): `Apply-Baseline.bat` — one-shot optimizer · `Start-Tuning-Menu.bat` — guided menu with undo for everything · `scripts/` — the individual tools ([inventory](scripts/README.txt)) · [changelog](CHANGELOG.md).

### Measuring it: FullTrace

`scripts/FullTrace.ps1` is the read-only logger the whole method is built on. Run it, race, press `Ctrl+C`, and you get a 1 Hz CSV on your Desktop covering per-CCD load, CPU 0 versus frequency-core interrupt/DPC time, GPU utilisation, power, clocks, voltage, temperature, fan, PCIe load and active limiter, sim and VR CPU, hard pagefaults, free RAM, and the power plan. The live console shows the readable subset and colours each line — grey normal, yellow if the power plan drifted mid-session or the GPU is power/temperature limited, red on a hard-pagefault spike.

Framerate and frame time come from the SteamVR compositor when SteamVR is already running. Start SteamVR yourself before the logger, or any time during the session (it retries about every five seconds). The script never launches SteamVR and never takes scene focus. If SteamVR is not running, the `vr_*` columns stay blank and the rest of the CSV still logs. `-NoSteamVr` skips the client. MSI Afterburner / RTSS is not required for FPS.

The same columns are filled in iRacing's OpenVR mode and its OpenXR mode. Both submit through the SteamVR compositor, including a Pimax that runs as a native SteamVR headset.

`gpu_fps` and `gpu_frametime_ms` stay on Afterburner when Afterburner is running, so older comparisons stay valid. When Afterburner leaves either one blank, SteamVR fills it. `gpu_timing_source` says which: `afterburner`, `steamvr`, or `afterburner+steamvr`. Voltage, fan RPM, memory temperature and the limiter flags still need Afterburner. Anything the card does not expose stays blank.

The new columns are appended after `fb_usage_pct`. Hard-fault columns, when you use the elevated run, are still appended after these. The history buffer is 128 frames, which is a full second at 72 / 90 / 120 Hz. Above that, `vr_fps` still counts every frame index the compositor advanced; the averages cover the newest 128.

| Column | Unit |
|---|---|
| `gpu_timing_source` | `afterburner`, `steamvr`, `afterburner+steamvr`, or blank |
| `vr_fps` | app frames/s (frame-index delta over the window) |
| `vr_fps_presented` | presented frames/s, including frames the compositor repeated |
| `vr_frametime_ms`, `vr_frametime_max_ms` | ms, mean and max time between the app's pose waits. Blank when every interval is 0 (compositor up, no scene app) |
| `vr_app_gpu_ms`, `vr_app_gpu_max_ms` | ms, app GPU work |
| `vr_comp_gpu_ms`, `vr_comp_cpu_ms` | ms, compositor GPU and CPU |
| `vr_gpu_ms` | ms, total GPU frame time |
| `vr_idle_cpu_ms` | ms, compositor idle, time the app could still have used |
| `vr_submit_ms` | ms, time inside Submit |
| `vr_over_budget` | frames in the sample over 1.02× the refresh interval. Blank when the refresh rate is unknown |
| `vr_reprojected`, `vr_reproj_cpu`, `vr_reproj_gpu`, `vr_motion` | frame counts. A frame counts as reprojected when it was presented more than once, or the CPU, GPU, or motion-smoothing flag is set. The async-mode flag does not count |
| `vr_dropped`, `vr_mispresented`, `vr_throttled` | frame counts. Dropped and reprojected prefer the compositor's cumulative counters when those cover frames that rotated out of the 128-frame history |
| `vr_frames` | frames actually averaged this second |
| `vr_hz` | headset refresh, Hz |
| `vr_target_w`, `vr_target_h` | pixels, recommended render target per eye (includes the resolution scale) |
| `vr_res_scale` | ratio, 1.0 = 100%. Per-app `resolutionScale` wins over the global supersample scale |
| `vr_predict_ms` | ms, estimated prediction: (1 + extra frames) × frame interval + vsync-to-photons. Blank unless both the refresh and the headset property are known |
| `vr_predict_extra` | mean extra frames the runtime predicted ahead |
| `vr_vsync_to_photons_ms` | ms, headset property |
| `vr_transfer_ms` | ms, texture transfer latency when the runtime's timing struct includes it |
| `vr_scene_app`, `vr_scene_pid` | process the compositor considers the scene app |
| `vr_renderer` | process that rendered the last frame, or `compositor` |
| `vr_hmd` | headset model string |

`Scan-Stutter-Events` reads these and flags a second as `DROPPED` (any dropped frame), `LATE` (5 or more frames over budget), `MISPRESENT` (5 or more mispresented frames), or `REPROJ` (8 or more reprojected frames, and only when the session is not already reprojecting steadily).

> **Changed in v3.2.0:** a skipped second in the trace is no longer treated as proof of a system stall on its own. Measurement showed the logger could occasionally overrun its own one-second budget on a healthy machine. The loop is now cheaper, and a gap should be corroborated against the `tot_dpc`, `tot_int` and `hardfaults_s` columns before you call it a freeze.

### Any game, monitor or VR: GamePerf (new)

[`GamePerf/`](GamePerf/README.md) takes FullTrace's method to **any game**. Double-click **`GamePerf\GamePerf.exe`**; the first launch offers a desktop and Start-menu icon. Press **Start logging**, play, press **Stop**. You get:

- **Per-frame timing:** in VR from the **SteamVR compositor**, through the same `scripts/SteamVR-Timing.ps1` reader FullTrace uses (no Afterburner, no admin), and on a monitor from Intel PresentMon. 1% / 0.1% lows, stutters, SteamVR reprojection and dropped frames, and whether each frame was **GPU-bound or held up on the CPU side**.
- **A 1 Hz system log** on FullTrace's columns, plus the game's busiest-thread load.
- **A report** that lines up every stutter with what the PC was doing at that moment.
- **`ai-prompt.md`**: your goals, the data and the game's config files, found automatically for iRacing, ACC, AMS2, LMU, rF2, MSFS, DCS and more. Paste it into Grok / ChatGPT / Claude / Gemini, or connect a provider and get the analysis inside the app.

It also lets you press Scroll Lock to mark a hitch you felt. It compares each session with the previous one, including what changed in the config files. In VR it flags any quad-views or foveated OpenXR layer that is still enabled.

The recorder is silent while you play: no window, no sound, and it never steals focus. It is light, and on dual-CCD X3D chips it keeps itself off the V-Cache die. The dashboard's **GAMEPERF** button opens it too.

### `hardfaults_s` is not the sim — read this before you tune storage

That column counts hard page faults for the **whole machine**. It is easy to see tens of thousands per second during a race and conclude iRacing is starved for disk I/O. It almost never is.

A kernel `HARD_FAULTS` trace of a real 25-minute session captured 4,712 faults and attributed them like this:

| faults | process |
|-------:|---------|
| 1,729 | `System (4)` — NTFS metadata (`$Mft`, `$UsnJrnl`) |
| 829 | `backgroundTaskHost.exe` — the Microsoft Store updating apps |
| 251 | `MicrosoftEdgeUpdate.exe` |
| 245 | `SearchHost.exe` |
| 201 | `TabTip.exe` — the touch keyboard |
| **14** | **`iRacingSim64DX11.exe`** |

Fourteen out of 4,712. Not one texture, not one `.dat` — a font cache, the NTFS journal and the shader cache. The sim's total *content* faulting was 17 events during track load, which is where it belongs.

So a big number there means **Windows is busy**, not that your storage is too slow. Chasing it as sim I/O costs days and fixes nothing.

### Finding out who is actually faulting (v3.3.0)

Run FullTrace **elevated** — or click **Hard faults (Admin)** next to **Run** in the dashboard's *Troubleshoot a stutter → 1) Record a race* — and if the [Windows Performance Toolkit](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install) is installed it also runs a kernel `PROC_THREAD+LOADER+HARD_FAULTS+FILENAME` session alongside the normal sampling.

You get three extra CSV columns — `sim_hardfaults_s`, `top_fault_proc`, `top_fault_file` — so every row says *who* faulted that second and *what* they read, plus `iRacing-HardFaults-<stamp>.csv` with every event, and a ranked per-process summary in the console when you stop.

Without admin or without the toolkit it behaves exactly as before and says so in the banner; `-NoHardFaultTrace` skips it deliberately. The plain **Run** button still needs no admin. Its CSV is the original columns plus the SteamVR columns above (blank when SteamVR is down). The three fault columns are still only on the elevated run.


Needs **Windows PowerShell 5.1**, built into Windows 10 and 11. PowerShell 7 is not required.

**Upgrading?** From **v3.3.2**, replace the whole folder — `FullTrace.ps1` now reads SteamVR frame timing through `scripts/SteamVR-Timing.ps1` and no longer needs Afterburner/RTSS for FPS. From **v3.3.1** (or v3.3.0), the [v3.3.2 release zip](https://github.com/no6969el/iracing-x3d-tuning/releases/tag/v3.3.2) notes still apply on the way up: CrowdDetail docs, stutter-scan empty-log handling, and the HardFault/RaceQuiet module split. From v3.2.5 or earlier, replace the whole `scripts/` folder **and `Tuning-Menu.ps1`** — v3.3.0 adds `scripts/Kit-Common.ps1` (quiet lists) plus hard-fault / race-quiet shared helpers the quiet, restore, status and trace scripts now read, so a partial copy will not run; `FullTrace.ps1` is v3; and the dashboard gains the **Hard faults (Admin)** button that goes with it. Run `Post-Race-Restore` on your current version *before* swapping the files. From v3.2.0 or earlier, replace `scripts/Pre-Race-Quiet.ps1`, `scripts/Post-Race-Restore.ps1` and `scripts/Check-Quiet-Status.ps1` — v3.2.5 adds nine scheduled tasks to the pre-race disable list and fixes a status screen that could report "race ready" while tasks were still live. Run `Post-Race-Restore` on your current version *before* swapping the files. From v3.1.0 or earlier, also replace `scripts/FullTrace.ps1` — v3.2.0 fixes a GPU-voltage column that logged a constant value. From v2.2.0 or earlier, replace the whole folder — six scripts now share `scripts/X3D-Profiles.ps1`, and mixing versions produces wrong core numbers. See the [release notes](RELEASE-NOTES.md).

> ⚠️ These scripts change Windows settings (power, registry, services, Defender). All reversible, nothing runs without your approval — review before running, at your own risk.
> 
> ⚠️ **`Post-Race-Restore.ps1`** Pre-race quieting *disables* the update services for the racing session. This prevents Windows Update Medic from restarting them mid-race, which would cause stuttering. Post-Race-Restore is required to restore your system to its original state after racing.

Adapted for dual-CCD from the single-CCD guide by [rcsracing93](https://rcsracing93.github.io/iracing-stutter-fix) · MIT licensed · share freely.
