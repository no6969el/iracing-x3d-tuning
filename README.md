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

**In this repo** (the guide's [download](https://github.com/no6969el/iracing-x3d-tuning/archive/refs/heads/main.zip) gets you all of it): `Apply-Baseline.bat` — one-shot optimizer · `Start-Tuning-Menu.bat` — guided menu with undo for everything · `scripts/` — the individual tools ([inventory](scripts/README.txt)) · [changelog](CHANGELOG.md).

### Measuring it: FullTrace

`scripts/FullTrace.ps1` is the read-only logger the whole method is built on. Run it, race, press `Ctrl+C`, and you get a 1 Hz CSV on your Desktop covering per-CCD load, CPU 0 versus frequency-core interrupt/DPC time, GPU utilisation, power, clocks, voltage, temperature, fan, PCIe load and active limiter, sim and VR CPU, hard pagefaults, free RAM, and the power plan. The live console shows the readable subset and colours each line — grey normal, yellow if the power plan drifted mid-session or the GPU is power/temperature limited, red on a hard-pagefault spike.

GPU voltage, fan RPM, memory temperature, framerate and the limiter flags come from MSI Afterburner's shared memory, so start Afterburner first if you want them. Anything your card does not expose stays blank and the rest still logs.

> **Changed in v3.2.0:** a skipped second in the trace is no longer treated as proof of a system stall on its own. Measurement showed the logger could occasionally overrun its own one-second budget on a healthy machine. The loop is now cheaper, and a gap should be corroborated against the `tot_dpc`, `tot_int` and `hardfaults_s` columns before you call it a freeze.

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

Without admin or without the toolkit it behaves exactly as before and says so in the banner; `-NoHardFaultTrace` skips it deliberately. The plain **Run** button still needs no admin and produces the same 39-column CSV.

### Bonus: iRacing Tuner Mini

If you do not want the full troubleshooting workflow and just want the baseline fixes, use the lightweight launcher in [mini-tuner/Small-Tuning-Menu.ps1](mini-tuner/Small-Tuning-Menu.ps1) or [mini-tuner/Start-Small-Tuning-Menu.bat](mini-tuner/Start-Small-Tuning-Menu.bat). It keeps the initial CPU detection, then offers **Optimize My PC**, the before/after race routine, **Defender Exclusions**, and **Guide Extras**. This is a lower-profile companion tool rather than a major release update.

> ⚠️ **Note:** The `mini-tuner` folder is not included in the main ZIP download. It is only available in the GitHub repository and can be downloaded separately.

Needs **Windows PowerShell 5.1**, built into Windows 10 and 11. PowerShell 7 is not required.

**Upgrading?** From v3.2.5 or earlier, replace the whole `scripts/` folder **and `Tuning-Menu.ps1`** — v3.3.0 adds `scripts/Kit-Common.ps1`, which the quiet, restore, status and trace scripts all now read, so a partial copy will not run; `FullTrace.ps1` is v3; and the dashboard gains the **Hard faults (Admin)** button that goes with it. Run `Post-Race-Restore` on your current version *before* swapping the files. From v3.2.0 or earlier, replace `scripts/Pre-Race-Quiet.ps1`, `scripts/Post-Race-Restore.ps1` and `scripts/Check-Quiet-Status.ps1` — v3.2.5 adds nine scheduled tasks to the pre-race disable list and fixes a status screen that could report "race ready" while tasks were still live. Run `Post-Race-Restore` on your current version *before* swapping the files. From v3.1.0 or earlier, also replace `scripts/FullTrace.ps1` — v3.2.0 fixes a GPU-voltage column that logged a constant value. From v2.2.0 or earlier, replace the whole folder — six scripts now share `scripts/X3D-Profiles.ps1`, and mixing versions produces wrong core numbers. See the [release notes](RELEASE-NOTES.md).

> ⚠️ These scripts change Windows settings (power, registry, services, Defender). All reversible, nothing runs without your approval — review before running, at your own risk.
> 
> ⚠️ **`Post-Race-Restore.ps1`** Pre-race quieting *disables* the update services for the racing session. This prevents Windows Update Medic from restarting them mid-race, which would cause stuttering. Post-Race-Restore is required to restore your system to its original state after racing.

Adapted for dual-CCD from the single-CCD guide by [rcsracing93](https://rcsracing93.github.io/iracing-stutter-fix) · MIT licensed · share freely.
