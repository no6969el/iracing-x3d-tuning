# VR resolution preview

Free headset test for render resolutions a game cannot hold. It is an OpenXR app (D3D11) that draws a scene around you and multiplies the runtime's recommended per-eye size. SteamVR's own resolution slider can stay at 100%.

The scale uses the same rule as SteamVR: the percent counts **pixels**, and the per-axis scale is `sqrt(percent / 100)`.

| Percent | Axis scale | Pixels vs 100% |
|---:|---:|---:|
| 100 | 1.000x | 1x |
| 150 | 1.225x | 1.5x |
| 200 | 1.414x | 2x |
| 300 | 1.732x | 3x |

On a 3840x3840-per-eye micro-OLED headset, iRacing at SteamVR 100% renders about **4184x3256** per eye. This app's 100% is the OpenXR recommended swapchain at the current SteamVR slider. With this program's per-app SteamVR setting left at 100%, the number in the headset is the real scale. 300% of 4184x3256 is about **7248x5640** per eye.

## Run it

1. Install SteamVR and set it as the active OpenXR runtime (SteamVR Settings, OpenXR). Leave any vendor OpenXR runtime switched off.
2. Start SteamVR and put the headset on.
3. In SteamVR's per-application video settings, leave **vr-res-preview.exe at 100%**. Raising that slider and the in-app percent multiplies them.
4. From the kit, double-click `Start-Tuning-Menu.bat` and choose **VR RESOLUTION PREVIEW**. Or run `Launch-VrResPreview.bat` in this folder, or run `vr-res-preview.exe`.

The Windows build is the `vr-res-preview-win64` artifact on the [VR resolution preview](https://github.com/no6969el/iracing-x3d-tuning/actions/workflows/vr-res-preview.yml) workflow. Unzip it so `vr-res-preview.exe` is in `tools\vr-res-preview\dist\`. The dashboard looks there.

The first launch downloads a CC0 8K HDRI (Poly Haven, "Kloofendal 48d Partly Cloudy", about 75 MB) into `cache` next to the exe. Until that finishes, the sky is procedural and the test patterns are already up. `--sky 16k` fetches the 16K file (about 260 MB). `--sky 4k` is smaller. `--sky none` skips the download. `--sky path\to\file.hdr` loads a local equirectangular HDR or image.

A mirror window on the desktop shows the left eye. The GPU time on the HUD does not include that mirror.

## What you are looking at

- 360 sky (the HDRI once it has downloaded).
- Siemens stars and line / chirp panels at a few distances. These are drawn in the shader, so they stay sharper than any texture.
- The same eye chart at **1 m, 5 m, 20 m, and 100 m**, with an orange post so the far ones are findable.
- A chain-link card (alpha test, which MSAA does not clean up) plus thin posts, wires, and gantries (real geometry, which MSAA does change).
- A straight piece of track, kerbs, and a simple open-wheel car.

Scenes, cycled with `V`: All, Sharpness, Charts, Fence, Track, Sky.

## Controls

| Action | Keyboard | Controller |
|---|---|---|
| Previous / next preset | `[` `]` or Left / Right | Left / right trigger |
| Fine step −5% / +5% pixels | `,` `.` or `-` `=` | Left / right grip |
| Jump to 100, 120, 150, 200, 250, 280, 300 | `1`–`7` | |
| MSAA off → 2x → 4x → 8x | `M` | A (Index / Touch) or menu (Vive / WMR) |
| Save this scale as A / B | `F5` / `F6` | Left A or X. Each press alternates A then B |
| Flip A and B | `Space` | B or Y (Index / Touch), trackpad or stick click (Vive / WMR) |
| Next scene | `V` or `Tab` | Left stick click, Y, or left trackpad |
| Help in the headset | `H` | |
| Quit | `Esc` or close the window | |

Presets stop at 300%. Fine steps run from 50% to 400%, and the size is clamped to what the runtime allows. The HUD says **CLAMPED** when that happens. Changing the percent recreates the swapchains immediately. You do not restart the app.

A/B starts with A = 100% and B = 300%. `Space` turns A/B on and swaps. While A/B is on, changing the scale edits the slot you are looking at.

## HUD and CSV

The panel in front of you shows per-eye resolution, the SteamVR-equivalent percent, axis scale, MSAA, GPU frame time, CPU submit time, the refresh budget, missed frames since you selected this setting, the scene, and the A/B slots.

`vr-res-preview.csv` is written next to the exe.

- `sample` is one row per second.
- `summary` is written when you change scale, MSAA, or scene, and again when you quit. That row is the average for the setting you just left.

GPU time is a D3D11 timestamp around both eyes, read a couple of frames later. A missed frame is one whose CPU submit time or GPU time exceeded the display period. The desktop mirror is outside the timer.

## Build

The workflow above produces the exe. To build locally, from this folder, with Visual Studio 2022 and CMake:

```
cmake -S . -B build -A x64
cmake --build build --config Release
build\bin\Release\vr-res-preview.exe --smoke
```

`--smoke` renders one frame with the software rasterizer, checks the pixel-percent math, and writes a CSV. It does not need a headset.

## Licenses

The app is MIT, same as the rest of this kit. The OpenXR loader is Apache-2.0 (Khronos). Image decode uses the public-domain stb_image library. The default sky is Poly Haven's "Kloofendal 48d Partly Cloudy", CC0, downloaded at runtime and not bundled.
