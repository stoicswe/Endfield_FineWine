# Hardware Specs & Real-World Performance

> **Tested Machine:** Apple **M4 Pro** (MacBook Pro, 12-core CPU: 8P + 4E), **24 GB Unified Memory**, macOS 27.0, CrossOver 26.2.0 / 26.3.0.
> Also tested on M3 / macOS 26.5.

---

## Frame Rate & Quality Settings

| Mac Tier | Recommended Settings | Expected FPS |
|---|---|---|
| M4 Pro / M3 Pro / M4 Max (24 GB+) | Medium, 100% render scale | ~60 FPS |
| Base M1 / M2 / M3 / M4 (16 GB) | Low / Very Low | 30–45 FPS |
| MacBook Air (any chip) | ❌ **Not recommended** — see below | — |

For tuning notes specific to 16 GB machines, see [14 — Performance on 16 GB Macs](14-performance-on-16gb-macs.md).

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
* Use `-force-d3d11` launch flag (or select "Launch with DirectX 11" in the Gryphline launcher). Vulkan is experimental and may introduce additional overhead.
* Set in-game resolution to **1080p** or use the **70–80% render scale** slider to reduce GPU memory pressure if you experience VRAM-induced stutters.
* Enable **MSync** in the CrossOver bottle settings (already configured by `create-bottle.sh`).
