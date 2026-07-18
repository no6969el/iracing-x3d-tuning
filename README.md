# iRacing Tuning Guide — Dual-CCD Ryzen X3D + NVIDIA

> ### 🧭 New to this, or never run a PowerShell script? → **[Start Here: Guided Walkthrough](START-HERE.md)**
> A step-by-step, hand-holding version that walks you through the whole process — including exactly how to run the scripts and how to make one-click shortcuts. No experience needed, just follow the steps in order.

**Goal: zero hiccups.** A measurement-driven method for eliminating frametime spikes, freezes, and micro-stutters in iRacing on **dual-CCD Ryzen X3D** systems (9950X3D, 7950X3D, 9900X3D, 7900X3D) with **NVIDIA** GPUs — flatscreen or VR.

> This guide was built by diagnosing a real rig (Ryzen 9 **9950X3D** + RTX **5090**, Pimax VR) from session-ending freezes down to zero perceptible hiccups, using live logging and LatencyMon at every step. Every fix here was *measured*, not guessed.

---

## Who this is for

- **CPU:** a dual-CCD Ryzen X3D — one die has the 3D V-Cache, the other is a plain frequency die.
- **GPU:** NVIDIA (RTX 30/40/50).
- **Sim:** iRacing (DX11), flatscreen or VR.
- **You’re chasing:** the occasional stutter, freeze, or frametime spike that ruins an otherwise smooth session.

If you have a **single-CCD** X3D (7800X3D, 9800X3D), most of this still helps — but **skip the CCD-pinning and power-plan sections**, they’re specific to dual-CCD. (More on that below — it’s the #1 thing single-CCD guides get wrong for us.)

---

## The one thing to understand first: your two CCDs

A dual-CCD X3D chip is really two 8-core (or 6-core) clusters:

- **CCD0 — the V-Cache die.** Huge L3 cache, slightly lower clocks. **Games love this die** — the cache is worth more than raw MHz in a sim.
- **CCD1 — the frequency die.** Higher clocks, normal cache.

The whole game is: **keep the sim on the V-Cache die, and keep everything else off it.** Get that right and the sim gets the cache it craves without fighting background junk for cores.

### Core numbering (memorize your split)

| CPU | V-Cache CCD (put the sim here) | Frequency CCD (everything else) |
|---|---|---|
| **9950X3D / 7950X3D** (16-core) | logical cores **0–15** | logical cores **16–31** |
| **9900X3D / 7900X3D** (12-core) | logical cores **0–11** | logical cores **12–23** |

Throughout this guide, wherever we say **“core 16”** (the first frequency-CCD core), a 12-core owner uses **“core 12”** instead. Every script has this as an editable value at the top.

---

## Golden rules (learned the hard way)

1. **EasyAntiCheat blocks external CPU-affinity changes to iRacing.** You *cannot* hard-pin `iRacingSim64DX11.exe` — the game rejects it and reverts to all cores a few seconds after launch. Use **soft CPU Sets** instead (a scheduler *hint* that EAC can’t block). The affinity mask will still read `0xFFFFFFFF` — that’s **normal** for CPU Sets, not a failure.
2. **Use the “all cores unparked” power plan — NOT Balanced.** This is the big one single-CCD guides get wrong. On a *single*-CCD chip, the AMD Balanced plan keeps V-Cache prioritization firmware active, so it’s recommended. **On a dual-CCD chip with a VR compositor, Balanced is a disaster** — its core parking strands your VR runtime on a parked die and the GPU starves (we measured it drop from ~55% util to ~11%, unplayable). **Keep all cores unparked** (Bitsum Highest Performance or High Performance) so both dies stay fully available.
3. **Measure, don’t guess.** Frametime hiccups rarely show up without instrumentation. The toolkit below catches them.
4. **Change one thing at a time**, then re-log. Stacking changes hides which one helped (or hurt).

---

## The toolkit (measure first)

All scripts are in the `scripts/` folder. Run PowerShell scripts with:
```
powershell -ExecutionPolicy Bypass -File "<path to .ps1>"
```

- **`FullTrace.ps1`** — the main logger. Samples ~1/sec while you race and writes a CSV: power plan, per-CCD CPU load, CPU-0 vs frequency-die interrupt/DPC time, GPU util/power/clocks/throttle, sim & VR CPU, hard pagefaults. **Gaps in the timestamps = a system-wide stall caught in the act.**
- **`Preflight-Check.ps1`** — run before a session; confirms every fix is live (cores, power plan, GPU-IRQ steering, Process Lasso).
- **[LatencyMon](https://www.resplendence.com/latencymon)** (free, 3rd-party) — names the driver behind any DPC latency spike. Essential for the last mile.
- **`Repair-PerfCounters.ps1`** — if FullTrace’s per-core columns come back empty, your Windows performance counters are broken (common). This rebuilds them.

**How to read a result:** during racing you want CCD0 (V-Cache) busier than CCD1, GPU util steady with no collapses, no time-gaps, and hard pagefaults near zero (big pagefault bursts during *loading* are normal).

---

## The fixes — highest impact first

### 1. Power plan: all cores unparked (NOT Balanced)
Use **Bitsum Highest Performance** (Process Lasso installs it) or Windows **High Performance** — anything that keeps **core parking off / 100% cores unparked**. Verify with `powercfg`. If you use **ParkControl**, set Parking = **Off** and — critically — **disable “Dynamic Boost”** (it flips the active plan mid-race and causes hard freezes; this was our single worst offender).

### 2. Process Lasso: pin the sim to the V-Cache die
- Add a **CPU Set** for `iRacingSim64DX11.exe` = your V-Cache cores (**0–15**, or 0–11 on 12-core). *Not* a hard affinity — EAC blocks that.
- Put **background/VR processes on the frequency die** (16–31): your VR runtime, overlays (SimHub, telemetry), wheel software, browsers, etc.
- **Exclude iRacing from ProBalance** so it never gets throttled.
- Optional: set iRacing **I/O priority High**, **memory priority high**, and **CPU priority High**.

### 3. GPU interrupt affinity: get it off CPU 0
iRacing’s sim thread favors **CPU 0**; NVIDIA’s GPU interrupts also default near CPU 0 — they collide and cause DPC spikes. **Steer GPU interrupts to a frequency-die core (CPU 16).** Run **`Set-GPU-IRQ-Affinity.ps1`** (admin) → reboot → verify in LatencyMon that `nvlddmkm.sys` DPCs moved off CPU 0. Note: on MSI-mode GPUs the setting may not survive a reboot — re-run if so.

### 4. NIC + USB interrupt affinity
Same trick for the next offenders. **`Set-NIC-USB-IRQ-Affinity.ps1`** steers your network card and USB host controllers (wheel, VR) onto frequency-die cores (17–19), draining more DPC load off CPU 0.

### 5. Repair performance counters (if needed)
If your traces show empty per-core data, run **`Repair-PerfCounters.ps1`** (admin) → reboot. You can’t tune what you can’t measure.

### 6. Quiet the background + Defender
- **`Pre-Race-Quiet.ps1`** (admin, before racing): disables Windows **Update / Update Orchestrator / Search** scans (these fire on a ~5–7 min cadence and cause periodic stalls) and optionally drops Defender real-time protection for the session (needs **Tamper Protection off**).
- **`Post-Race-Restore.ps1`** (admin, after): turns it all back on.
- **`Add-Defender-Exclusions.ps1`** (admin, once): excludes iRacing’s install + `Documents\iRacing` so Defender stops scanning every texture read mid-race. Persistent and safe — keeps protection everywhere else.

### 7. HAGS / Game Bar / USB Selective Suspend
**`Apply-Guide-Extras.ps1`** (admin): turns off **USB Selective Suspend** (stops your wheel/VR USB power-cycling — a real DPC source) and **Game Mode/Bar/DVR**. **HAGS** (Hardware-Accelerated GPU Scheduling) is a genuine toss-up on newer cards — test it both ways rather than blindly disabling.

### 8. iRacing in-game settings
- **Texture preload:** in `rendererDX11*.ini`, set **`LoadTexturesWhenDriving=0`** so textures load up front instead of streaming off disk mid-lap (a continuous micro-stutter source). Also `CacheSwap3HighResCars=0`.
- **Replay spooling off:** in `app.ini`, **`spoolingEnabled=0`** — stops continuous replay-to-disk writes during the session.
- **Crowds off:** `CrowdDetail=0` — near-zero visual impact, fewer draw calls.
- Edit these with **iRacing fully closed** (it rewrites the files on exit).

### 9. NVIDIA Control Panel (per-app: iRacingSim64DX11.exe)
Low Latency Mode = **On** (not Ultra — Ultra caused present-queue stalls), Power Management = **Prefer Max Performance**, Vertical Sync = **Off**, Threaded Optimization = **On**, Shader Cache = **Unlimited**, Anisotropic Filtering = **16x**. **Disable the in-game overlay** (GeForce Experience / NVIDIA App) — it adds DirectX hooks and DPC for no benefit.

### 10. Remove monitoring overlays
**RTSS / MSI Afterburner** are notorious DPC + hard-pagefault sources (and can hide inside capture tools). If you don’t strictly need them, close them — especially while diagnosing.

---

## VR: clarity without hiccups

- **Supersampling beats MSAA for clarity.** MSAA only anti-aliases polygon edges — it does nothing for the fences, distant tarmac lines, and specular shimmer that actually bother most people. **Render resolution (supersampling) anti-aliases everything.** Keep **MSAA at 4x** (8x often crashes iRacing in VR from framebuffer memory blowout) and spend your GPU headroom on resolution.
- **Set resolution in ONE place.** If you use the headset runtime’s quad-view/render-quality panel, control resolution *there* and leave iRacing’s in-sim resolution at 100% — don’t stack both (they multiply and you’ll miss frame deadlines).
- **Quad-views / foveated rendering** (e.g. Pimax’s Advanced Quad-View) is a big free win: it renders the sharp center where you look and a low-res periphery, freeing GPU. When the runtime provides it, **the runtime’s panel is authoritative** — the sim just renders into it. Keep the sim’s VR mode set to “quad view” and tune the foveation in the runtime panel (center resolution = your crispness; peripheral resolution = your savings; smooth/alpha transition to hide the boundary).
- **Sharpening amplifies shimmer.** If you hate shimmer, *lower* in-game sharpening and let resolution do the work.
- **Keep ~15% GPU headroom.** Tune so util peaks stay under ~85% — VR punishes any frame that misses the deadline with reprojection judder, which looks worse than slightly lower settings.

---

## Verify: proof of zero hiccups

Run **`FullTrace.ps1`** for a full race, then check the CSV:
- **No time-gaps** (no skipped seconds) = no system-wide stalls.
- **Power plan** stayed on your unparked plan the whole time.
- **CCD0 busier than CCD1** = sim on the V-Cache die.
- **CPU-0 interrupt time low, frequency-die core higher** = interrupts steered off the sim.
- **GPU util steady** with no collapses; **hard pagefaults ~0** during racing.

If a stall still shows, run **`Scan-Stutter-Events.ps1`** (after enabling the TaskScheduler log with `Enable-DiagnosticLogs.ps1`) to catch a scheduled task on that timestamp, and **LatencyMon** to name a DPC driver.

---

## Why this differs from single-CCD guides

This method was adapted from an excellent single-CCD guide ([rcsracing93.github.io/iracing-stutter-fix](https://rcsracing93.github.io/iracing-stutter-fix)). Most of it transfers — but **two things flip on a dual-CCD chip**:

1. **Power plan:** single-CCD says use *Balanced* (to keep V-Cache firmware active). On dual-CCD with VR, Balanced’s core parking **starves the VR compositor** — use an **all-cores-unparked** plan instead.
2. **CCD pinning matters** (single-CCD has nothing to pin — every core is a V-Cache core). Getting the sim onto the V-Cache die and everything else off it is half the battle on dual-CCD.

---

## Scripts included

See `scripts/` and its `README.txt`. Order of operations for a fresh setup: repair perf counters → set power plan → Process Lasso CPU Set → GPU IRQ affinity → NIC/USB IRQ affinity → reboot → run Preflight → Defender exclusions → guide extras → iRacing in-game settings → verify with FullTrace.

*Built collaboratively and measured end-to-end. Share freely.*
