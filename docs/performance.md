# Hardware Specs & Real-World Performance

> **Tested Machine:** Apple **M4 Pro** (MacBook Pro, 12-core CPU: 8P + 4E), **24 GB Unified Memory**, macOS 27.0, CrossOver 26.2.0 / 26.3.0.
> Also tested on M3 / macOS 26.5.

---

## Frame Rate & Quality Settings

> **Optimal DX11 setup:** **DXMT (`CX_GRAPHICS_BACKEND=dxmt`) + `-force-d3d11`**. DXMT is independent of the D3DMetal/GPTK payload, so GPTK4 is not required for this path.
> TAAU is the recommended first upscaler on stock DXMT. DLSS upscaling works through MetalFX when DXMT includes the [NGX resource-parameter fix](technical.md#dlss-under-dxmt-stock-and-patched-builds).

| Mac Tier | Configuration | Expected FPS |
|---|---|---|
| M4 Pro / M3 Pro / M4 Max (24 GB+) | **Max Settings**, DXMT + `-force-d3d11` + TAAU | **~120 FPS** (occasional minor stutters) |
| M4 Pro / M3 Pro (D3DMetal fallback) | Medium, 100% render scale, D3DMetal | ~60 FPS |
| **M3 (base, 8-core)** — 14" MBP, 24 GB | Custom; D3DMetal or DXMT — **cap 60 FPS**, 1080p-class | ~45–60 FPS (GPU-bound above ~1440p) |
| Base M1 / M2 / M3 / M4 (16 GB) | Medium / Low, DXMT + `-force-d3d11` + TAAU | ~45–60 FPS |
| MacBook Air (any chip) | ❌ **Not recommended** — see below | — |

> [!WARNING]
> **CrossOver 26.3's bundled DXMT 0.80 needs an NGX fix for DLSS.** Use **TAAU** or **AMD FSR3** on that build. With the fix proposed in [3Shain/dxmt#235](https://github.com/3Shain/dxmt/pull/235), Endfield can use DLSS upscaling via MetalFX. FineWine 1.2.3 alone does not install this DXMT fix.

> [!IMPORTANT]
> **GPTK4 note:** GPTK4 upgrades the separate D3DMetal backend. It is not loaded by DXMT, so it should not be expected to change DXMT FPS or shader translation behaviour.

For tuning notes specific to 16 GB machines, see [14 — Performance on 16 GB Macs](14-performance-on-16gb-macs.md).

---

## Base M3 / 8-core Macs (measured)

> **Measured on:** MacBook Pro 14" (Mac15,3), Apple **M3** — **8-core CPU (4 P + 4 E)**, 10-core GPU, **24 GB** unified memory, macOS 27.2, patched CrossOver 26.3 with **GPTK 4 (D3DMetal backend)**, 2026-10-16. The game was rendering at **2560×1600**, Custom quality, Volumetric Fog/Cloud high — i.e. the *harder* end of what this chip will be asked to do.

The base M3 is a different machine from the M4 Pro the rest of this page targets. On M4 Pro the GPU has headroom and the Unity main thread is the bottleneck; on the 8-core M3 the **GPU becomes a co-bottleneck** above roughly 1440p, *on top of* the CPU and memory limits. Expect the transient "momentary freeze" hiccups below to be visible at high resolution even when the game is otherwise playable.

| Metric (observed in play) | Value |
|---|---|
| GPU utilisation (`ioreg` "Device Utilization %") | **67–99 %** |
| GPU memory in use | ~6.2 GB |
| `Endfield.exe` physical footprint | **~11.8 GB** |
| Free memory / compressor | **~32–151 MB free**, **~9.3 GB** compressed |
| Page-ins | ~1,300/s sustained |
| Load average | **13–16** on 8 cores |
| Game CPU (`ps`) | 265–352 % |
| `MTLCompilerService` | **126–218 % CPU, continuous** |

**What the momentary freezes are.** Two effects stack on the 8-core M3:

1. **Pipeline-compilation stutter.** A `sample` of the game during play is dominated by `MTLCompiler` and `AGXMetal`, and `MTLCompilerService` sits at one-to-two cores for the whole session. Each first-seen shader/pipeline is compiled synchronously, so the frame stalls until it lands. The game's own PSO warm-up (`HGPsoRecordManager` … `enablePsoWarmup:1`) helps but does not eliminate it, and a compressed/paged-out shader cache under memory pressure makes it come back.
2. **Memory-reclaim stalls.** With under ~150 MB free and ~9 GB sitting in the compressor, macOS is continuously compressing, decompressing and paging in pages; that work lands as micro-stalls. This is the milder cousin of the permanent *memory-pressure freeze* documented in [14 — Performance on 16 GB Macs](14-performance-on-16gb-macs.md#the-memory-pressure-freeze).

**What helps, in order of impact:**

- **Cap the frame rate.** Set in-game **60 FPS**; with the D3DMetal backend you can also export **`D3DM_MAX_FPS=60`**. At 67–99 % GPU utilisation a capped frame loop paces far more evenly than an uncapped, GPU-saturated one, and it lowers sustained heat and memory-bandwidth contention.
- **Lower the render load.** Drop to a **1080p-class resolution** (or ~70–80 % render scale) and lower **Texture Quality** — resolution/AA is GPU work and textures are the main *memory* lever. **Volumetric Fog and Volumetric Cloud** are the most expensive GPU effects here; set them low or off.
- **Prefer the DXMT backend for memory headroom.** On DXMT the game uses roughly **half the RAM** of the D3DMetal path, which directly relieves the compressor/page-in pressure above. Note that CrossOver 26.3's stock DXMT still needs **TAAU** or **AMD FSR3** — DLSS is broken until the [NGX resource-parameter fix](technical.md#dlss-under-dxmt-stock-and-patched-builds) — so DXMT trades DLSS for memory. GPTK4 does not affect the DXMT path.
- **Close background apps.** On this 24 GB machine the launcher's own `Games.exe` (~1 GB) and `PlatformProcess.exe` (~1.16 GB) stayed resident alongside Discord, Apple Music, LM Studio and Safari. Every gigabyte another app holds is a gigabyte the compressor has to juggle; the single most effective zero-risk action is to quit everything you are not using.
- **Watch for the permanent freeze.** As in [14](14-performance-on-16gb-macs.md#the-memory-pressure-freeze): if swap climbs to several GB with free memory near zero and the picture freezes *while the sound keeps playing*, it is not going to recover — force-quit `Endfield.exe` (progress is saved server-side) and relaunch.

**Diagnosing it live.** These are enough to tell a shader-compile hitch from a memory-reclaim hitch on your own machine:

```bash
sysctl vm.swapusage                                   # swap used
memory_pressure | tail -1                             # system-wide free %
ioreg -r -d 1 -w 0 -c IOAccelerator \
  | grep -oE '"(Device Utilization %|In use system memory)"=[0-9]+'   # GPU busy / VRAM
ps -M -p "$(pgrep -f 'Endfield[.]exe' | head -1)"     # per-thread CPU of the game
sample "$(pgrep -f 'Endfield[.]exe' | head -1)" 5 1   # 5 s of call stacks (look for MTLCompiler / AGXMetal)
```

You can also view real-time FPS, frame timing, and Metal memory directly on screen using Apple's **Metal Performance HUD**: enable it via **Tools → Metal HUD…** in the patcher app, or set `METAL_HUD=1` when running `scripts/create-bottle.sh` (or `UPDATE=1 METAL_HUD=1 ./scripts/create-bottle.sh`). Restart the bottle after toggling.


---

## Thermal & CPU Behaviour

* **CPU Utilization:** Expect CPU to be **completely maxed out**. Rosetta 2 x86_64 JIT translation overhead combined with the Unity IL2CPP main render thread pegs at least one core at ~100% sustained.
* **Temperatures:** Expect the chip to reach **~90 °C** under sustained play on actively cooled machines. This is normal for this workload; Apple Silicon chips are designed to operate up to 100–105 °C before hard throttling.
* **Swap Pressure:** Gameplay performance is almost entirely dictated by **CPU single-core strength and RAM capacity / bandwidth**, not the GPU. Unified memory means GPU VRAM allocations (5–6 GB) and system RAM share the same pool. Even an M4 Pro experiences significant swap pressure under sustained play. **Quit background applications** (browsers, Discord, heavy apps) before launching.

---

## ⚠️ MacBook Air — OFF LIMITS

MacBook Airs have **no active cooling fans**. Sustained CPU translation under Rosetta generates intense, continuous heat, causing the device to severely thermal-throttle into heavy stuttering, freezes, and stalls very quickly. **An actively cooled Mac (MacBook Pro, Mac Studio, Mac mini) is required** for this workload.

---

## Bottleneck Summary

Gameplay performance is overwhelmingly **CPU and RAM bound**, not GPU:

1. **Rosetta 2 JIT overhead** — every x86_64 instruction block is translated to ARM64 at runtime; tpshell's VMProtect obfuscation dramatically increases the number of unique instruction blocks that must be JIT-compiled.
2. **Unity IL2CPP single-threaded render dispatch** — the game's main thread is extremely hot.
3. **Unified memory pressure** — 5–6 GB GPU VRAM competes directly with the OS and game for the same physical RAM pool.

---

## Tips to Improve Performance

* Close browsers, Discord, and other heavy background apps before launching.
* Use `-force-d3d11` launch flag (or select "Launch with DirectX 11" in the Gryphline launcher). Vulkan is also supported.
* Set in-game resolution to **1080p** or use the **70–80% render scale** slider to reduce GPU memory pressure if you experience VRAM-induced stutters.
* Enable **MSync** in the CrossOver bottle settings (already configured by `create-bottle.sh`).
