# iRacing Tuning Guide — Dual-CCD Ryzen X3D + NVIDIA

**Goal: zero hiccups.** A measurement-driven method for eliminating frametime spikes, freezes, and micro-stutters in iRacing on **dual-CCD Ryzen X3D** systems (9950X3D, 7950X3D, 9900X3D, 7900X3D) with **NVIDIA** GPUs — flatscreen or VR.

Built by diagnosing a real rig (9950X3D + RTX 5090, Pimax VR) from session-ending freezes down to zero perceptible hiccups. Every fix here was *measured*, not guessed.

## Pick your path

| You are… | Go here |
|---|---|
| 🖱️ **Anyone** (easiest) | Unzip and double-click **`Start-Tuning-Menu.bat`** — an interactive menu that detects your system, sets the right core numbers, and runs every step for you. |
| 🧭 **New to PowerShell / want hand-holding** | **[Guided Walkthrough](https://no6969el.github.io/iracing-x3d-tuning/start-here.html)** — step-by-step, no experience needed. |
| 🔧 **Comfortable, want the why** | **[Full guide](https://no6969el.github.io/iracing-x3d-tuning/)** — every fix with the reasoning and how to verify it. |

## What's in the repo

- **`Start-Tuning-Menu.bat`** + **`Tuning-Menu.ps1`** — the interactive menu (recommended way to run everything)
- **`scripts/`** — the individual PowerShell tools: diagnostics (FullTrace logger, Preflight-Check, stutter scanner, timer watcher) and fixes (IRQ steering, timer resolution, Defender exclusions, pre/post-race routines), each with an undo. See [`scripts/README.txt`](scripts/README.txt) for the full inventory.

> ⚠️ These scripts change Windows settings (power, registry, services, Defender). Everything is reversible and nothing runs without you choosing it — but review before running, at your own risk.

## Who it's for

Dual-CCD Ryzen X3D (one V-Cache die + one frequency die), NVIDIA RTX 30/40/50, iRacing (DX11), flatscreen or VR, on Windows 11. Single-CCD X3D owners (7800X3D/9800X3D): most of the guide still helps, but skip the CCD-pinning and power-plan sections — see [why this differs from single-CCD guides](https://no6969el.github.io/iracing-x3d-tuning/#why-differs).

---

Adapted for dual-CCD from the excellent single-CCD guide by [rcsracing93](https://rcsracing93.github.io/iracing-stutter-fix). MIT licensed. Built collaboratively and measured end-to-end — share freely.
