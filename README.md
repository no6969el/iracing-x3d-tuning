# iRacing Tuning Guide — Dual-CCD Ryzen X3D + NVIDIA

**Goal: zero hiccups.** A measurement-driven method for eliminating frametime spikes, freezes, and micro-stutters in iRacing on **dual-CCD Ryzen X3D** systems (9950X3D, 7950X3D, 9900X3D, 7900X3D) with **NVIDIA** GPUs — flatscreen or VR.

Built by diagnosing a real rig (9950X3D + RTX 5090, Pimax VR) from session-ending freezes down to zero perceptible hiccups. Every fix here was *measured*, not guessed.

> ## → **[Open the guide](https://no6969el.github.io/iracing-x3d-tuning/)** ←
> Six steps, ~30 minutes plus a reboot. Pick your CPU once and every core number on the page adjusts. Progress boxes remember themselves across the reboot. Expandable detail everywhere for the tech-minded.

## The short version

1. **[Download the kit](https://github.com/no6969el/iracing-x3d-tuning/archive/refs/heads/main.zip)** and unzip to a permanent folder.
2. **Process Lasso** (free): activate Bitsum Highest Performance, launch iRacing into a race once, then CPU-Set the sim to the V-Cache cores + exclude from ProBalance. Exact clicks in [Step 2](https://no6969el.github.io/iracing-x3d-tuning/#do-it).
3. Double-click **`Apply-Baseline.bat`** — all five script fixes, one admin prompt. (Prefer step-by-step? **`Start-Tuning-Menu.bat`** is the guided version with troubleshooting and undos.)
4. **Reboot**, verify with FullTrace, then do the graphics pass last.

## What's in the repo

- **`Apply-Baseline.bat`** — one-shot optimizer: every script fix in one go
- **`Start-Tuning-Menu.bat`** — interactive guided menu: same fixes step-by-step, plus troubleshooting tools and undo for everything
- **`scripts/`** — the individual PowerShell tools: diagnostics (FullTrace logger, Preflight-Check, stutter scanner, timer watcher) and fixes (IRQ steering, timer resolution, Defender exclusions, pre/post-race routines), each reversible. Inventory: [`scripts/README.txt`](scripts/README.txt)

> ⚠️ These scripts change Windows settings (power, registry, services, Defender). Everything is reversible and nothing runs without you choosing it — but review before running, at your own risk.

## Who it's for

Dual-CCD Ryzen X3D (one V-Cache die + one frequency die), NVIDIA RTX 30/40/50, iRacing (DX11), flatscreen or VR, on Windows 11. Single-CCD X3D owners (7800X3D/9800X3D): most of it still helps — see [why this differs](https://no6969el.github.io/iracing-x3d-tuning/#why-differs).

---

Adapted for dual-CCD from the excellent single-CCD guide by [rcsracing93](https://rcsracing93.github.io/iracing-stutter-fix). MIT licensed. Built collaboratively and measured end-to-end — share freely.
