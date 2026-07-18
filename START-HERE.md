# Start Here — Guided Walkthrough 🧭

**This is the hand-holding version.** It walks you through the whole process step by step, assuming you've never run a PowerShell script before. You don't need to know anything technical — you just need to follow directions carefully and in order.

If you're already comfortable, the [full guide (README)](README.md) has all the detail and reasoning. This page is the "just tell me what to click" version.

> ## 🖱️ Easiest of all: use the interactive menu
> After you unzip the kit, just **double-click `Start-Tuning-Menu.bat`**. It opens a clean menu that runs every step *for you* in its own window, detects your CPU/GPU on first launch (and remembers it), sets the right core numbers automatically, and shows you what's happening the whole time. **If you use the menu, you can skip the manual instructions below** — they're here for reference and for anyone who prefers doing it by hand.

> ⚠️ **These scripts change Windows settings** (power, registry, services, Defender). Every one is reversible (there's an *Undo* for anything that changes something). Nothing here is dangerous if you follow the order, but go slowly and don't skip the reboots.

---

## Before you start — a 3-minute setup

1. **Download the files.** Get the `.zip` from the [top of this repo](./) (the green **Code ▸ Download ZIP** button) or the guide's download button.
2. **Unzip it to a permanent folder** you'll keep — for example `C:\iRacingTuning\`. **Don't** run it from your Downloads or a temp folder (shortcuts would break later).
3. **Find your CPU's core split** (you'll need this once):

   | Your CPU | V-Cache cores (the sim goes here) | Frequency cores (everything else) |
   |---|---|---|
   | 9950X3D / 7950X3D | **0–15** | **16–31** |
   | 9900X3D / 7900X3D | **0–11** | **12–23** |

   If you have a **12-core** chip, you'll open two scripts and change one number — the walkthrough tells you exactly when.

4. **Install Process Lasso** (free version is fine) — it's a third-party app we use for one step (pinning the sim to the V-Cache cores). Get it from bitsum.com.

---

## Part 1 — How to run these scripts (read this once)

A PowerShell script is a `.ps1` file. **Double-clicking one does NOT run it** — Windows opens it in an editor instead. So we run them one of two ways.

### The easy way: make double-click shortcuts (do this first!)

The kit includes a helper called **`Create-Launchers.ps1`**. Its whole job is to create a **clickable shortcut next to every script**, so from then on you just double-click. The shortcuts are set up correctly for you — the ones that need admin rights will ask for permission automatically, and the logging ones stay open so you can read the results.

**Run it once, like this:**

1. Open your `scripts` folder.
2. **Right-click `Create-Launchers.ps1`** → click **"Run with PowerShell."**
3. If Windows asks about an execution policy, type **`Y`** and press Enter.
4. Done — you'll now see a `.lnk` shortcut next to each script. **From now on, just double-click the shortcut for whatever script you want.**

> If "Run with PowerShell" isn't in the right-click menu, use the manual way below just for this one script, then the shortcuts work for everything else.

### The manual way (backup method)

1. Click **Start**, type **PowerShell**.
2. To run a normal script: click **Windows PowerShell**. To run an **admin** script: **right-click it → "Run as administrator"** and click Yes. (The window title will say *Administrator* — that's how you know.)
3. In the black window, type this, then drag your `.ps1` file onto the window (it pastes the path), and press Enter:
   ```
   powershell -ExecutionPolicy Bypass -File "PASTE THE FILE PATH HERE"
   ```
   *(The `-ExecutionPolicy Bypass` part just lets this one script run; it doesn't change any Windows setting.)*

**Which scripts need "Run as administrator"?** Any script that *changes* a setting. Each is marked **(ADMIN)** in the checklist below and in `scripts/README.txt`. The double-click shortcuts handle this for you automatically.

---

## Part 2 — The step-by-step checklist

Do these **in order**. Check each box as you go. Don't rush the reboots — a couple of these only take effect after restarting.

### ✅ Phase 1 — Set up & get a "before" picture
- [ ] Unzip the kit to a permanent folder (e.g. `C:\iRacingTuning\`).
- [ ] Run **`Create-Launchers.ps1`** once (Part 1 above) so everything is double-click from here.
- [ ] Double-click **`FullTrace`**, then go race ~10 minutes, then press **Ctrl+C** to stop. This saves a CSV to your Desktop — it's your **"before" measurement**. (Optional but recommended — it lets you prove the difference later.)

### ✅ Phase 2 — Fix the foundation
- [ ] **(ADMIN)** Run **`Repair-PerfCounters`** *only if* your FullTrace's per-core columns came back blank. Then **reboot**.
- [ ] **Set the power plan to "all cores unparked."** In Process Lasso (or ParkControl), select **Bitsum Highest Performance** (or Windows **High Performance**) and make it active. If you use **ParkControl**: set Parking = **Off** and **uncheck "Dynamic Boost."** *(Details in the [main guide](README.md#the-fixes--highest-impact-first), fix #1.)*
- [ ] **Pin the sim to the V-Cache die in Process Lasso.** Right-click `iRacingSim64DX11.exe` → **CPU Sets** → choose your V-Cache cores (**0–15**, or **0–11** on a 12-core). Also right-click it → **ProBalance** → exclude it. *(Main guide, fix #2.)*
- [ ] **12-core owners only:** before the next step, open **`Set-GPU-IRQ-Affinity.ps1`** in Notepad and change `$TargetCore = 16` to `$TargetCore = 12`. Save.
- [ ] **(ADMIN)** Run **`Set-GPU-IRQ-Affinity`**. Then **reboot**.

### ✅ Phase 3 — Quiet the system (do each once)
- [ ] **(ADMIN)** Run **`Add-Defender-Exclusions`** — stops Defender scanning iRacing's files.
- [ ] **(ADMIN)** Run **`Apply-Guide-Extras`** — turns off USB Selective Suspend + Game Bar.
- [ ] **Adjust iRacing's in-game settings** (with iRacing **fully closed**): texture preload on, replay spooling off, crowds off. *(Main guide, fix #8.)*
- [ ] **Set the NVIDIA Control Panel** options for iRacing. *(Main guide, fix #9.)*

### ✅ Phase 4 — Every race (the per-session routine)
- [ ] **(ADMIN)** Run **`Pre-Race-Quiet`** *before* you race.
- [ ] Race. 🏁
- [ ] **(ADMIN)** Run **`Post-Race-Restore`** *after* — this turns Windows Update, Search, and Defender back on. **Don't skip it.**

### ✅ Phase 5 — Prove it worked
- [ ] Run **`Preflight-Check`** — it prints a green **READY** if everything's set.
- [ ] Double-click **`FullTrace`**, race, Ctrl+C. Open the CSV and compare to your "before."

---

## Part 3 — How to tell it worked

Open the FullTrace CSV (it opens in Excel or Notepad). You want:
- **No skipped seconds** in the timestamp column — a jump like `12:04:40` → `12:04:42` means a system-wide stall happened. Fewer/none = better.
- The **`power_plan`** column stayed on your unparked plan the whole time.
- The **`gpu_util`** column stays steady while racing (no sudden drops to single digits).

If it's smooth on track and the timestamps have no gaps, you're done. 🎉

---

## Part 4 — If something feels wrong (undo anything)

Nothing here is permanent. To reverse a change, run its **Undo** (ADMIN), then reboot:
- `Undo-GPU-IRQ-Affinity` — reverts the GPU interrupt change
- `Undo-NIC-USB-IRQ-Affinity` — reverts the NIC/USB change (if you ran it)
- `Undo-Guide-Extras` — turns USB Suspend + Game Bar back on
- `Post-Race-Restore` — turns Windows Update/Search/Defender back on
- Power plan / Process Lasso / iRacing settings — just set them back in their apps

---

## Part 5 — Plain-English glossary

- **CCD** — one of the two core clusters on your CPU. One has extra cache (V-Cache), one clocks higher.
- **CPU Set** — a gentle "please run here" hint that steers a program onto certain cores. Used because iRacing blocks the forceful kind.
- **DPC / interrupt** — tiny background jobs the CPU must handle for your hardware (GPU, network, USB). If too many pile on the sim's core, you get micro-stutters.
- **Hard pagefault** — the PC pausing to read data off the disk. Bursts during *loading* are normal; constant ones *while racing* aren't.
- **Reboot** — restart the PC. A few changes only apply after one.

---

**Stuck on a step?** The [main guide](README.md) explains the *why* behind each one. Take it slow, do them in order, and you'll get there. 🏁
