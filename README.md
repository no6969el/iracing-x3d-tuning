# iRacing Tuning — Ryzen X3D + NVIDIA

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

**In this repo** (the guide's [download](https://github.com/no6969el/iracing-x3d-tuning/archive/refs/heads/main.zip) gets you all of it): `Apply-Baseline.bat` — one-shot optimizer · `Start-Tuning-Menu.bat` — guided menu with undo for everything · `scripts/` — the individual tools ([inventory](scripts/README.txt)) · `Validate-Repo.ps1` / `Validate-Repo.bat` — local reference checker · [changelog](CHANGELOG.md).

### Bonus: iRacing Tuner Mini

If you do not want the full troubleshooting workflow and just want the baseline fixes, use the lightweight launcher in [mini-tuner/Small-Tuning-Menu.ps1](mini-tuner/Small-Tuning-Menu.ps1) or [mini-tuner/Start-Small-Tuning-Menu.bat](mini-tuner/Start-Small-Tuning-Menu.bat). It keeps the initial CPU detection, then offers **Optimize My PC**, the before/after race routine, **Defender Exclusions**, and **Guide Extras**. This is a lower-profile companion tool rather than a major release update.

Needs **Windows PowerShell 5.1**, built into Windows 10 and 11. PowerShell 7 is not required.

To verify this repo's local references and package files, run `Validate-Repo.ps1` or double-click `Validate-Repo.bat` from the kit folder.

**Upgrading from v2.2.0 or earlier?** Replace the whole folder — six scripts now share `scripts/X3D-Profiles.ps1`, and mixing versions produces wrong core numbers. See the [release notes](RELEASE-NOTES.md).

> ⚠️ These scripts change Windows settings (power, registry, services, Defender). All reversible, nothing runs without your approval — review before running, at your own risk.
> 
> 💡 **Quieting not holding?** If Windows Update switches itself back on mid-session, run `scripts/Trace-QuietReverts.ps1` **elevated** — it reads the Windows event logs and names what did it. If the answer is Windows Update Medic, the kit now includes the medic unlock functionality as standard.
> 
> ⚠️ **`Post-Race-Restore.ps1` is required, not optional.** Pre-race quieting *disables* the update services rather than stopping them — stopping didn't hold, because Windows Update Medic restarts them within about ten minutes. Nothing self-heals on reboot, so until you restore, the PC has no Windows Update and no fresh Defender definitions.

Adapted for dual-CCD from the single-CCD guide by [rcsracing93](https://rcsracing93.github.io/iracing-stutter-fix) · MIT licensed · share freely.
