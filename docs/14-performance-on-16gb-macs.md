# 14 — Performance on 16 GB Macs (measured)

> **Measured on:** MacBook Pro 14", Apple **M4** (10-core CPU), **16 GB** unified memory, macOS 27.0, CrossOver 26.2.0 with this repo's modules, Endfield 1.5.3 in DirectX 11 mode, display at "More Space" (1800×1169). Two sessions, 2026-09-23: one on CrossOver's bundled **D3DMetal 3.0**, one on **GPTK 4.0b2**. The repo's original test machine was an M4 Pro with 24 GB. Tools: `top`, `vm_stat`, `sysctl vm.swapusage`, `memory_pressure`, `ps -M`, and the AGX GPU statistics in `ioreg`.

## TL;DR

- **Endfield runs on a 16 GB Mac, and at mostly Low settings it is very playable — but memory is the limit, not the GPU.** Unified memory means the game's 5–6 GB of GPU allocations come out of the same 16 GB as everything else; a PC with 16 GB of RAM *plus* an 8 GB graphics card has effectively half again as much.
- **Quit other apps before playing** — browsers, chat, Creative Cloud, AI assistants. With them open the machine was deep in swap before the game got going.
- The **frame-rate limit is the Unity main thread under Rosetta** (~100% of one core); the GPU sat at 55–65% busy. Spend spare GPU capacity on image quality, not on settings that add draw calls or memory.

## What was measured

| | Session 1: D3DMetal 3.0, other apps open | Session 2: GPTK 4.0b2, browsers/chat closed |
|---|---|---|
| Endfield.exe memory (`top` MEM) | 8.9 GB | 7.7 GB → 11 GB as areas loaded and settings were raised |
| GPU memory in use (AGX "In use system memory") | 5.4 GB | 5.3 → 6.2 GB |
| GPU busy (AGX "Device Utilization %") | 56% | 54–66% |
| Swap used | 6.8 GB of 8 GB (1.1 M swap-outs); compressor holding 8.9 GB in 4.8 GB | 2.4 GB at launch → 4.9 GB |
| Free memory (`memory_pressure`) | ~23% reported, ~80 MB of truly free pages | 70% at launch → 20–30% in play |
| Busiest game threads (`ps -M`) | one at ~100% | ~100%, 27–36%, 20–26% |
| `kernel_task` (includes the memory compressor) | 47% CPU | not measured |
| Outcome | stutter; **froze** after teleporting into a large area (below) | "seriously very playable", no freeze |

Other large memory users in session 1: Chrome ~2.1 GB, the game's own `PlatformProcess.exe` ~1.4 GB, WindowServer ~1.2 GB, the Gryphline launcher ~1 GB, Discord and Creative Cloud ~0.4 GB each.

⚠️ **Several things changed between the sessions** — the D3DMetal version, how much else was running, and later the in-game settings — so the improvement can't be pinned on GPTK 4 alone. More free memory at launch was certainly a large part of it.

## The memory-pressure freeze

In session 1, teleporting into a large area froze the picture while **the sound kept playing**. What the machine looked like during the freeze:

- one game thread (the Unity main/render thread) at ~99–100% CPU for 5+ minutes, ~20% of it in the kernel, with very high context-switch and Mach-call counts — spinning on something that never arrived;
- **GPU memory in use collapsed from 5.4 GB to 0.4 GB**, GPU mostly idle, and no GPU hang/restart in the system log;
- no `Player.log` output after the new area's assets finished loading;
- disk paging had calmed down to a few MB/s — the stall persisted after the swapping did.

It never recovered. Force-quit `Endfield.exe` (progress is saved server-side), free memory, and relaunch. A useful early warning while playing: swap climbing past ~6 GB with free memory near zero.

## Settings that work on 16 GB

A starting point that was very playable in session 2: Graphics Quality *Very Low*, then customised; Resolution 1800×1169 fullscreen; FPS 120, V-Sync off; Global and Teammate Skill Effects *Low*; Shadow Quality *Very Low*; **Texture Quality *Medium***; Volumetric Fog off, Volumetric Cloud *Very Low*; Anisotropic ×4; Ambient Occlusion *Very Low*; Scene / Ambient Details and Vegetation Density *Low*; Screen Space Reflections off; Image Enhancement **NVIDIA DLSS → DLAA**, Sharpening 0; NVIDIA Reflex on; Contact Shadows on.

What each lever costs on a Mac:

- **Texture Quality** is the main *memory* lever — textures live in unified memory. Low or Medium on 16 GB; drop it first if large areas hitch or freeze.
- **Shadows, Scene Details, Vegetation Density** add draw calls, i.e. work for the main thread that is already the bottleneck.
- **Resolution / anti-aliasing** is GPU work, and the GPU has headroom. **DLSS works**: D3DMetal presents the GPU as an NVIDIA adapter and CrossOver serves DLSS with MetalFX (the log shows `redirect_nvngx_to_d3dmetal`). **DLAA** (native-resolution AA) looked sharpest; switch to Quality if you need frames.
- **Chromatic Aberration** is a deliberate colour-fringe blur — turning it off sharpens the image for free; a little **Sharpening** (0.3–0.5) helps with DLSS.
- **Frame cap:** 120 is fine if it holds; a 60 cap gives steadier pacing when it doesn't.
- The in-game **"Device Load: Hardware overloaded"** warning can be ignored: the game is judging the spoofed NVIDIA adapter and a Rosetta-bound main thread.

Not measured, but worth trying for sharpness: macOS **Displays → Default** size (1512×982 on a 14"). With High Resolution Mode off, CrossOver renders at the "looks like" resolution; Default maps 2:1 onto the Retina panel, while "More Space" (1800×1169) is stretched 1.68×, which looks soft — and Default is ~30% fewer pixels. Keep **High Resolution Mode off** (white screen, [#2](https://github.com/stoicswe/Endfield_FineWine/issues/2); it would also quadruple the pixel count).

## Vulkan renderer (experimental)

Same Mac, 2026-09-24, CrossOver 26.2, launched with `GFXARGS=-force-vulkan scripts/launch-endfield.sh` ([what it needs](graphics-performance.md#experimental-the-vulkan-renderer)). Each column is a few minutes of sampling in the open world, and the settings differed between sessions, so treat it as a rough comparison. The patched MoltenVK from `patches/moltenvk` wasn't measured.

| | Vulkan, CrossOver's MoltenVK 1.2.10 | Vulkan, stock MoltenVK 1.4.2 | DX11, GPTK 4.0b2 (session 2) |
|---|---|---|---|
| Endfield.exe memory (`top` MEM) | 7.9 → 8.4 GB | 8.7–9.0 GB | 7.7 → 11 GB |
| GPU memory in use | 1.1–3.1 GB | 2.8–3.6 GB | 5.3 → 6.2 GB |
| GPU busy | 26–94% | 39–98% | 54–66% |
| Swap used | 5.6–5.8 GB, flat | 5.6 GB, flat | 2.4 → 4.9 GB |
| Outcome | smooth until an FPS change turned it black | smooth; FPS, V-Sync and frame-generation changes were fine | "seriously very playable" |

It felt smoother than DX11, with better frame pacing. The main thread is still at ~100% under Rosetta, but the GPU is busier and uses about half the memory.

Settings that played best (stock 1.4.2): Graphics Quality *Custom*; Fullscreen 1800×1169; **FPS 60, V-Sync off**; Global and Teammate Skill Effects *Low*; Shadow Quality *Very Low*; **Texture Quality *High***; Volumetric Fog off, Volumetric Cloud *Very Low*; Anisotropic ×1; Ambient Occlusion *Very Low*; Scene / Ambient Details and Vegetation Density *Low*; Chromatic Aberration off; Screen Space Reflections off; Image Enhancement **AMD FSR3 → Native AA**, Sharpening 0; Frame Generation off; Contact Shadows on. There's no DLSS under Vulkan, and FSR Frame Generation made it slower.

## Checking your own machine

```bash
sysctl vm.swapusage                                   # swap used
memory_pressure | tail -1                             # system-wide free percentage
top -l 1 -o mem -n 10 -stats command,mem              # biggest memory users
ioreg -r -d 1 -w 0 -c IOAccelerator | grep -oE '"(Device Utilization %|In use system memory)"=[0-9]+'
ps -M -p "$(pgrep -f 'Endfield[.]exe' | head -1)"     # per-thread CPU of the game
```
