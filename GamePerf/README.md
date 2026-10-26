# GamePerf — frame-time logger + AI analyst

Log any game, on a monitor or in VR. Play it, then find out exactly what is costing you frames, and what to change to keep the highest quality your PC can hold.

```
  Start logging ──► play ──► Stop ──► report + AI brief ──► (optional) AI analysis in the app
        │                                   │
        │   per-frame timing (PresentMon)   ├─ report.md      what happened, in plain numbers
        │   1 Hz system log (FullTrace's    ├─ ai-prompt.md   everything an AI needs, configs included
        │   method, any game)               └─ summary.json   for the app's charts
        │   your game's config files
        └── press Scroll Lock whenever you feel a hitch
```

GamePerf is built on the kit's **FullTrace** logger. It uses the same measurement rules, the same locale-safe CSV and the same honesty about what `hardfaults_s` does and does not mean. It is generalised to any game and to VR, adds per-frame timing, and is cheaper to run.

---

## Quick start

1. Double-click **`GamePerf.exe`** in this folder. The first launch offers to put a GamePerf icon on your desktop and in the Start menu.
2. **Settings → Download PresentMon** once. This is Intel's free frame-timing tool. GamePerf keeps the download only if it carries Intel's signature.
3. Optional, recommended: **Settings → Allow it for my account**. It asks for admin once, then you sign out and back in. After that, per-frame timing never asks for admin again.
4. On **Record**, pick the game, or leave it on *Auto-detect*. Choose **Monitor** or **VR headset**, and set the target FPS: your headset refresh rate in VR (90, 120…), or 0 to use the monitor's.
5. Press **START LOGGING** and play. The window gets out of the way. Press **Scroll Lock** whenever you feel a stutter.
6. Press **STOP**, or just quit the game if *Stop when the game closes* is on. When the analysis is ready, GamePerf's taskbar button flashes; open it to see the Results.

> **"Windows protected your PC"** may appear the first time you open `GamePerf.exe`. The exe is new and not code-signed, so SmartScreen has never seen it. Click **More info → Run anyway**. If you prefer, build your own copy on your PC. A locally built exe never triggers SmartScreen. Run `powershell -ExecutionPolicy Bypass -File launcher\Build-Launcher.ps1`, which uses the C# compiler that comes with Windows. `Start-GamePerf.bat` also starts the same app.

Then, from Results:
- Use **Analyse with AI** if you connected a provider in Settings.
- Or use **Copy AI brief** and paste it into Grok, ChatGPT, Claude, Gemini or any AI chat. Your game's config files are already inside.

---

## What a session gives you

Each session is a folder in `Documents\GamePerf\Sessions\<date>-<label>\`:

| File | What it is |
|---|---|
| `report.md` | The readable report: verdict, frame pacing, what limited the frames, findings, the worst stutters with what the PC was doing at each one, your markers, and a comparison with your previous session |
| `ai-prompt.md` | The same report packaged for an AI analyst. It includes your goals, a guide to the data, a 10-second timeline and the full text of the game's config files |
| `summary.json` | Every number, plus chart data (the app reads this) |
| `frames-N.csv` | Raw PresentMon frames: one file per launch of the game |
| `system.csv` | 1 Hz timeline, 66 columns (below) |
| `events.csv` | Markers, game start/exit, focus changes, power-plan and timer changes, background CPU users every 30 s |
| `session.json` | Machine snapshot: CPU / X3D layout, GPU, driver, PCIe link, RAM, display, Windows build, HAGS, Game Mode, Game DVR, VBS/HVCI, power plan, timer resolution, VR runtime and OpenXR layers |
| `configs\` | A copy of the game's config files as they were when you played, so the next session can show what changed |
| `ai-analysis-*.md` | Saved AI conversations |

### How frames are judged

PresentMon records every frame: how long it took, and how long the **GPU** and the **CPU** were busy producing it.

- **GPU-bound**: the GPU was busy for at least 90% of the frame. GPU-heavy settings are the lever.
- **CPU-side**: the GPU waited for the game thread, the driver or sync. CPU-heavy settings (opponents, draw distance, mirrors, crowds, physics) are the lever. GPU settings will not help.
- **Capped**: the frame met the target with time to spare. That spare time is **headroom**, and it is where "max quality" comes from.
- **Stutter**: a frame at least 2× the median of the 60 around it **and** at least 6 ms slower. Each one is tagged as a *GPU spike*, a *game-thread spike*, or a *stall* (neither was busy: disk streaming, shader compilation, a lock or the OS). The system log around it is then checked for disk bursts, hard faults, DPC spikes, clock dips, power or thermal limits, a full VRAM, focus changes and background CPU.

Loading screens and pauses (frames over 1 s) are excluded and counted separately.

> **`hardfaults_s` is system-wide** — same rule as FullTrace. A traced 25-minute iRacing session attributed 14 of 4,712 hard faults to the sim. A burst near a stutter is a lead, not a verdict. Use FullTrace's **Hard faults (Admin)** run to name the process.

### The 1 Hz system log

CPU total, and per CCD on dual-CCD X3D chips. Busiest core. Effective CPU clock. CPU 0 and interrupt-target-core interrupt/DPC. Total interrupt/DPC.

The game's CPU, plus its **busiest thread as % of one core** (the main-thread bottleneck tell). The game's working set and affinity mask. VR runtime CPU.

Free RAM, commit %, hard faults/s. Disk read/write MB/s, busy %, queue.

GPU load, memory-controller load, VRAM, power, clocks, temperature, fan, P-state and the driver's clock-event (throttle) reasons. From MSI Afterburner, if it is running: voltage, the power/temp/voltage/no-load limiter flags, PCIe bus load, memory temperature and FPS.

Per-second frame stats from PresentMon. Timer resolution. Power plan. And the logger's own time per sample.

---

## Using an AI

You choose one of two ways.

**In the app.** Pick a provider in **Settings**:

| Provider | Notes |
|---|---|
| **xAI Grok** | OpenAI-compatible API at `api.x.ai`. Key from console.x.ai |
| **OpenAI** | |
| **Anthropic Claude** | Adds an *effort* setting |
| **Google Gemini** | Through Gemini's OpenAI-compatible endpoint |
| **OpenRouter** | Any model OpenRouter serves |
| **Ollama / LM Studio** | Local models, free, nothing leaves your PC |
| **Custom** | Any OpenAI-compatible server |

Model names change often. **List models** asks the provider for its current list, so the default is only a starting point. **Test connection** checks the key.

**Anywhere else.** No provider needed: **Copy AI brief** and paste. The brief tells the AI your goals, how to read the data, and what to answer:

1. A ranked diagnosis, tied to the evidence.
2. Concrete setting changes, as file → setting → current → new value.
3. Fixes outside the game, only where the data points there.
4. What to change and measure next time.

### Config files

GamePerf finds them in three ways:

1. **Catalog.** It knows where popular sims and games keep their settings: iRacing, ACC, Assetto Corsa (plus CSP), AC EVO, AMS2, rFactor 2, Le Mans Ultimate, RaceRoom, EA WRC, F1 24/25, BeamNG, MSFS 2020/2024, DCS, X-Plane 12, Elite Dangerous, Star Citizen and Cyberpunk 2077. It also finds Steam libraries on any drive.
2. **Search.** For any other game, it scans the install folder and any *Documents / Saved Games / AppData* folder whose name matches the game. It looks for small config files with names like *graphics*, *video*, *render* or *settings*, which finds most Unreal Engine `GameUserSettings.ini` files too.
3. **You.** On the AI page use **Add file…**, or paste text. Tick *Remember* and the files are included automatically for that game from then on.

In VR mode it also adds SteamVR's `steamvr.vrsettings`, the active OpenXR runtime and every **implicit OpenXR API layer** with its on/off state. That is how a forgotten quad-views or foveated-rendering layer gets caught: it runs on every frame even when you think it is off.

### Your goals

These are set in **Settings → Your goals** and sent with every analysis. The default matches the kit's philosophy:

> Perfect, stutter-free frame pacing at my target frame rate, at the highest visual quality my hardware can hold. Render at native resolution: no quad views, no foveated rendering (fixed or eye-tracked), and no upscaling. Native-resolution AA such as MSAA or DLAA is fine. When something has to give, cut what costs the most performance for the least visible difference first.

---

## Getting good answers

- **Test the same way every time:** same track, car, weather and number of opponents, or the same replay. Otherwise a comparison measures the scene, not the setting.
- **Change one or two things per session** and type them in *What did you change?*. The next report diffs your config files and compares the numbers with the previous session of the same game.
- **Use the marker.** A stutter you *felt* is worth more than ten the log found. Map Scroll Lock to a button-box button for VR.
- **VR:** set the target to the headset's refresh rate. Every frame over budget is a reprojected frame.
- **Run as administrator** (the default). PresentMon needs it unless your account is in *Performance Log Users*. Without it the 1 Hz log still works, but there is no per-frame data.
- **MSI Afterburner** is optional. When it is running it adds GPU voltage, limiter flags and PCIe load. On AMD/Intel GPUs it is also where GPU load and temperature come from.

---

## Silent while you play

The recorder must never be the thing that causes a stutter, or that pulls you out of the game.

- **No window, ever.** The recorder runs inside `GamePerf.exe`, a Windows GUI program with no console. Everything it starts (`nvidia-smi`, PresentMon) has no console either. The power plan is read through the power API, so nothing is launched every few seconds.
- **No sound** unless you turn on the marker click in Settings.
- **No focus stealing.** When a session ends, the app flashes its taskbar button and waits. It does not jump in front of the game or the desktop.
- **The app holds it all.** The Record page shows the recorder's live readings and its latest messages. Stop, or closing the app, ends it cleanly. A recorder that loses its app stops by itself.
- **No admin prompt mid-flow** once *Allow it for my account* is done. Per-frame timing uses Windows event tracing. The built-in *Performance Log Users* group allows exactly that, without being an administrator.

## Light on resources

- The logger is a separate, hidden process. Its per-second work runs in compiled code. Each sample is three performance-counter reads, one long-running `nvidia-smi` (not one launch a second), a shared-memory read and a tail of PresentMon's file.
- It records its own cost. `loop_ms` is in every row, and `session.json` has the logger's average CPU, which is typically well under 1% of one core.
- On dual-CCD X3D chips with V-Cache on CCD0, the logger, `nvidia-smi` and PresentMon pin themselves to the frequency die. They never compete with the game for V-Cache cores. The kit's `scripts\X3D-Profiles.ps1` decides which die is which.
- The app minimises while you play and reads one small status file a second. It renders in software, so it never touches the GPU the game is using.

---

## Command line

```powershell
# record (Ctrl+C to stop); omit -Game to follow whatever game you focus
powershell -ExecutionPolicy Bypass -File GamePerf\lib\GamePerf-Logger.ps1 -Game iRacingSim64DX11.exe -Mode VR -TargetFps 90 -Label "shadows high"

# re-run the analysis of a session
powershell -ExecutionPolicy Bypass -File GamePerf\lib\GamePerf-Analyze.ps1 -SessionDir "$env:USERPROFILE\Documents\GamePerf\Sessions\<session>"
```

Logger switches: `-NoFrames`, `-PresentMon <path>`, `-MarkerKey ScrollLock|Pause|F8|F9|F10|Insert|NumPad0`, `-StopWithGame`, `-Beep`, `-NoAnalyze`, `-MaxMinutes`.

`GamePerf.exe --logger <session folder>` and `GamePerf.exe --analyze <session folder>` do the same windowlessly. The app uses these, reading the options from the session's `request.json`.

---

## Privacy

- **Nothing leaves your PC unless you press Analyse.** Even then, it goes only to the provider you chose.
- **Briefs are scrubbed** of your Windows user name, PC name, and any value whose key looks like a password, token, API key, e-mail or licence key. You can turn that off in Settings.
- **You can check what is sent.** **Preview what is sent** shows the exact text first.
- **API keys are encrypted** with Windows DPAPI for your account, in `%APPDATA%\GamePerf\settings.json`. Alternatively, GamePerf reads the provider's usual environment variable: `XAI_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY` or `OPENROUTER_API_KEY`.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| "PresentMon stopped immediately" / no frames | Use **Settings → Allow it for my account**, or keep *Ask for admin when per-frame timing needs it* on and accept the prompt. |
| `GamePerf.exe` does nothing | See `%LOCALAPPDATA%\GamePerf\launcher.log`. Antivirus may have quarantined the new exe. Build your own copy with `launcher\Build-Launcher.ps1`, or use `Start-GamePerf.bat`. |
| CPU columns blank | Performance counters are damaged. Run the kit's `scripts\Repair-PerfCounters.ps1` (admin), then reboot. |
| No GPU data on AMD/Intel | Start MSI Afterburner. Without it, GamePerf falls back to Windows' GPU counters (load and VRAM only). |
| The wrong game was picked | Choose it in the list instead of *Auto-detect*. Auto-detect takes the first known game it sees running, otherwise the app that keeps focus for 4 s. |
| The analysis failed | **Results → Re-analyse**. The raw data is never lost. |
| A killed logger left `nvidia-smi` or PresentMon running | The next session cleans them up automatically. |

---

## Files

| File | Role |
|---|---|
| `GamePerf.exe` | The starter you double-click: hosts the app and the recorder on Windows' built-in PowerShell 5.1 engine, with no window of its own |
| `GamePerf.ps1` | The app (WPF) |
| `Start-GamePerf.bat` | Fallback starter, if your antivirus holds the exe back |
| `launcher\` | `GamePerf.exe`'s source, icon and manifest, plus `Build-Launcher.ps1` to rebuild it |
| `lib\GamePerf-Logger.ps1` | Recording worker (also usable on its own) |
| `lib\GamePerf-Analyze.ps1` | Analysis → `summary.json`, `report.md`, `ai-prompt.md` |
| `lib\GamePerf-AI.ps1` | AI providers |
| `lib\GamePerf-Games.ps1` | Game catalog, config-file discovery, OpenXR context |
| `lib\GamePerf-Common.ps1` | Settings, CSV safety, PresentMon download, redaction |
| `lib\GamePerf.Native.cs` | Compiled hot-path helpers (counters, process/thread CPU, Afterburner, PresentMon parsing, statistics) |
| `tools\` | PresentMon goes here when downloaded |

Needs **Windows PowerShell 5.1** (built into Windows 10 and 11). The kit's `scripts\X3D-Profiles.ps1` is used when present, for the CCD split and X3D-specific checks. Without it, everything else still works.
