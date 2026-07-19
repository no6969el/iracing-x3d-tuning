# iRacing Tuning — Ryzen X3D + NVIDIA

Zero hiccups in iRacing on Ryzen X3D — dual-CCD (9950X3D / 7950X3D / 9900X3D / 7900X3D) **and** single-CCD (7800X3D / 9800X3D / 5800X3D). Six steps, measured on a real rig, all reversible. The guide and menus detect your chip and only ever show the fixes that are safe for it.

<h2 align="center">👉 <a href="https://no6969el.github.io/iracing-x3d-tuning/">OPEN THE GUIDE</a> 👈</h2>
<p align="center">Everything is there: the steps, the download, the explanations, and the troubleshooting.</p>

---

**In this repo** (the guide's [download](https://github.com/no6969el/iracing-x3d-tuning/archive/refs/heads/main.zip) gets you all of it): `Apply-Baseline.bat` — one-shot optimizer · `Start-Tuning-Menu.bat` — guided menu with undo for everything · `scripts/` — the individual tools ([inventory](scripts/README.txt)).

When you select Option ("Troubleshoot a stutter") in the `Start-Tuning-Menu.bat` and complete a race session, the script parses that exact file, isolates the timestamps matching your race, and filters out the exact names of the tasks running at that moment. 

> ⚠️ These scripts change Windows settings (power, registry, services, Defender). All reversible, nothing runs without your approval — review before running, at your own risk.

Adapted for dual-CCD from the single-CCD guide by [rcsracing93](https://rcsracing93.github.io/iracing-stutter-fix) · MIT licensed · share freely.
