# Technical Architecture & Under the Hood — Endfield_FineWine

This document provides a comprehensive technical overview of the compatibility architecture, the newly-discovered Rosetta 2 bug fixes, the anti-cheat patch ports, and the graphics translation pipeline that allow **Arknights: Endfield** to run on Apple Silicon macOS under CrossOver Wine.

For the full step-by-step implementation logs and research papers, see the [docs index](README.md).

---

## 1. How It Works (Summary)

Arknights: Endfield was previously rated *"Installs, Will Not Run"* on macOS because it was blocked by three independent layers:
1. **VMProtect / TenProtect ("tpshell") protector layer** (`EndfieldBase.dll`)
2. **ACE (Anti-Cheat Expert) Anti-Cheat** (`ACE-Base64.dll`, `ACE-Service64.exe`, and kernel driver `ACE-BASE.sys`)
3. **Graphics translation pipeline** (Unity IL2CPP rendering via D3DMetal / DirectX 11)

The solution combines **two novel Rosetta 2 signal handling fixes**, a port of the Linux **dw-proton** anti-cheat patches, dynamic linker `LC_RPATH` corrections, and surgical module replacement into CrossOver.

```mermaid
flowchart TD
    Game["Endfield.exe (Unity IL2CPP, 64-bit)"] --> Armor["Protector Armor (VMProtect / TenProtect)"]
    Armor -->|0F 1F multi-byte NOPs| RosettaFix1["Rosetta Fix 1: Decode & skip NOP faults"]
    RosettaFix1 --> ACE["ACE Anti-Cheat (ACE-BASE.sys)"]
    ACE -->|mov cr3 privileged probe| RosettaFix2["Rosetta Fix 2: Deliver EXCEPTION_PRIV_INSTRUCTION"]
    Armor -->|KiUser*Dispatcher hooking (tpshell workaround)| Spoof["kernel32.dll int3 dispatcher spoof"]
    ACE -->|Kernel routines| Ntoskrnl["ntoskrnl.exe 17 backported functions"]
    ACE -->|Timing checks| QPC["ntdll.so NtDelayExecution relative QPC wait"]
    Game --> Unity["Unity Engine Renderer"]
    Unity -->|"DirectX 11 (-force-d3d11)"| DXMT["DXMT (D3D11 → Metal translation)"]
    DXMT --> Metal["Apple Silicon GPU (Metal 3 / 4)"]
```

---

## 2. The Novel Discoveries: Rosetta 2 Bug Fixes

Both core fixes reside in `dlls/ntdll/unix/signal_x86_64.c` (in Wine's x86_64 Unix signal handler). They fix bugs in how Apple's **Rosetta 2** translates and raises CPU exceptions for x86_64 instructions on ARM64 hardware.

### Bug 1: Rosetta faults on a multi-byte NOP (`0F 1F`)
* **Problem:** VMProtect emits multi-byte `0F 1F` NOPs by the hundreds of thousands (e.g. `0F 1F C1` = `nop ecx`). Under standard x86 hardware, these are valid no-op instructions with zero side effects. Under Rosetta 2, some forms of `0F 1F` erroneously raise an illegal-instruction fault (`EXC_BAD_INSTRUCTION`), triggering Wine's SEH exception handling. This resulted in an infinite SEH recursive fault loop ("collided unwind") and stack overflow before the game even loaded.
* **Fix:** When an illegal instruction fault is received on `0x0F 0x1F`, decode the instruction length (mod/rm, SIB byte, and displacement) and increment `RIP` past the instruction.
* **Result:** VMProtect executes smoothly without crashing.

### Bug 2: Rosetta mis-classifies privileged instructions (`mov reg, cr3`)
* **Problem:** The ACE kernel driver (`ACE-BASE.sys`) reads the `CR3` control register (`mov rbx, cr3`) as an anti-virtual-machine probe. On real x86 hardware or Linux KVM/Wine, executing this in user space causes a General Protection Fault (`#GP`), which Wine converts to `EXCEPTION_PRIV_INSTRUCTION`. ACE's SEH handler catches `EXCEPTION_PRIV_INSTRUCTION` and continues. Under Rosetta 2, however, executing `mov rbx, cr3` generates an *invalid opcode* fault instead of `#GP`. Wine translated this into `EXCEPTION_ILLEGAL_INSTRUCTION`. ACE received the wrong exception code, failed internal verification, and aborted with **"driver error 13"**.
* **Fix:** In `segv_handler`, before defaulting to `EXCEPTION_ILLEGAL_INSTRUCTION`, inspect the faulting opcode with Wine's `is_privileged_instr()`. If the instruction is privileged, deliver `EXCEPTION_PRIV_INSTRUCTION` matching Linux behavior.
* **Result:** ACE's anti-VM check passes completely.

---

## 3. The Anti-Cheat Port (from Linux dw-proton)

Linux's [dw-proton (Dawn Winery)](https://dawn.wine/) solved ACE anti-cheat execution under Proton. We ported these patches to CrossOver's Wine 11.0:

1. **`ntoskrnl.exe` backports (17 kernel routines):**
   ACE communicates with its Windows kernel driver (`ACE-BASE.sys`) which expects standard NT kernel exports. We backported implementations and stubs for missing functions:
   * Guarded mutex primitives: `KeAcquireGuardedMutex`, `KeReleaseGuardedMutex`
   * Process and session metadata: `PsGetProcessSessionId`, `PsGetProcessCreateTimeQuadPart`, `PsGetThreadProcess`, `PsGetProcessImageFileName`, `SeLocateProcessImageName`
   * Token & security: `PsReferencePrimaryToken`
   * Bug check callbacks: `KeRegisterBugCheckCallback`, `KeRegisterBugCheckReasonCallback`, `KeDeregisterBugCheckReasonCallback`
   * Memory & thread tracking: `MmGetVirtualForPhysical`, `MmGetPhysicalMemoryRanges`, `PsGetContextThread`, `KeCapturePersistentThreadState`
2. **`KiUser*Dispatcher` int3 spoof (`kernel32.dll`):**
   **tpshell** (VMProtect/TenProtect in `EndfieldBase.dll`) hooks `KiUserApcDispatcher` and `KiUserCallbackDispatcher` to detect debugger presence and intercept dispatchers. The patch spoofs `GetProcAddress` for these symbols to return an `int3` stub, satisfying the hook without exposing real dispatcher addresses. (Patch comment: `/* workaround for tpshell */`.)
3. **`NtDelayExecution` via QPC timing (`ntdll.so`):**
   ACE performs timing checks sensitive to sleep granulary. Replacing relative waits with high-resolution QueryPerformanceCounter (QPC) spin loops avoids anti-cheat timeouts.

---

## 4. The Surgical Module Swap Architecture

Instead of compiling and replacing the entire monolithic CrossOver app (which bundles proprietary components, custom Clang builds, and graphics runtimes), we build a **minimal 64-bit-only Wine** and swap **only three core modules**:

| Module | Location in CrossOver | Responsibility |
|---|---|---|
| `ntdll.so` | `lib/wine/x86_64-unix/ntdll.so` | Rosetta 2 signal handling fixes, NOP skip, QPC timing |
| `kernel32.dll` | `lib/wine/x86_64-windows/kernel32.dll` | `KiUser*Dispatcher` int3 spoof |
| `ntoskrnl.exe` | `lib/wine/x86_64-windows/ntoskrnl.exe` | 17 backported NT kernel functions |

All other libraries (graphics, audio, window management, fonts, TLS) remain stock CodeWeavers binaries.

### The `LC_RPATH` / `cxcompatdb.so` Dependency
CrossOver's `ntdll.so` dynamically loads `cxcompatdb.so` at process startup to configure graphics backends (e.g., `CX_GRAPHICS_BACKEND=d3dmetal`). `cxcompatdb.so` depends on `@rpath/libgnutls.30.dylib` in `lib64/`. 

dyld resolves rpaths through the calling binary (`ntdll.so`). Because our minimal build did not carry the custom rpath, `cxcompatdb.so` would silently fail to load, falling back to WineD3D and producing error `80004005` (DirectX device creation failure).

Our scripts (`swap-into-crossover.sh` and `PatcherEngine.swift`) bake `@loader_path/../../../lib64` directly into `ntdll.so`'s `LC_RPATH` using `install_name_tool`, ensuring D3DMetal initializes correctly.

---

## 5. Graphics Translation Pipeline

### Recommended Configuration (October 2026)

| Setting | Value |
|---|---|
| **CrossOver Backend** | `dxmt` (`CX_GRAPHICS_BACKEND=dxmt`) |
| **Launch Flag** | `-force-d3d11` |
| **GPTK Patch** | v4 (Game Porting Toolkit 4) — **highly recommended** |
| **Upscaling** | **TAAU** or **AMD FSR3** on stock DXMT; **DLSS via MetalFX** with the NGX fix below |
| **Mods (EFMI)** | ✅ Loads and works |

> [!IMPORTANT]
> **GPTK4 (Game Porting Toolkit v4) is highly recommended.** The performance gains documented here (120fps, 50% RAM reduction) were achieved with the GPTK4 patch installed. Without GPTK4, you may see significantly worse performance and shader translation issues. Mount the Apple "Evaluation environment for Windows games" DMG and use the patcher or `swap-into-crossover.sh` to install it.

```
Endfield Engine (DirectX 11, via -force-d3d11)
       │
       ▼
DXMT (CrossOver's D3D11-to-Metal translation layer)
       │ (Thin, direct DX11 → Metal API mapping)
       ▼
Metal Framework / Apple Silicon GPU
```

### Backend Comparison

| Backend | Flag | Rendering | Mods (EFMI) | Performance | Notes |
|---|---|---|---|---|---|
| **DXMT** | `-force-d3d11` | ✅ Full 3D | ✅ Working | ⭐ Best | **Recommended.** Smooth, fast, with GPTK4 patch |
| **D3DMetal** | `-force-metal` | ✅ Full 3D | ✅ Working | 🔶 Slower | Works but noticeably lower FPS than DXMT path |
| **D3DMetal** | `-force-d3d11` | ✅ Full 3D | ✅ Working | 🔶 OK | Functional but DXMT outperforms it |
| **DXMT** | *(no flag)* | ⚠️ 2D only | ❌ N/A | N/A | Black/grey screen — no 3D rendering without flag |
| **DXVK** | `-force-d3d11` | ⚠️ Partial | ❌ Fails | 🔴 Slow | Heavy shader compilation stutter, EFMI won't load |
| **DirectX 12** | N/A | ❌ Broken | ❌ N/A | N/A | `Cannot load DXIL conversion library` — white screen |

### DLSS under DXMT: stock and patched builds

DXMT's `nvngx.dll` already implements DLSS upscaling through **MetalFX Temporal**. In CrossOver 26.3's bundled DXMT 0.80, Endfield hits a parameter-conversion bug: the game stores input textures through `SetVoidPointer`, while `NVSDK_NGX_D3D11_EvaluateFeature` retrieves them as `ID3D11Resource *`. The missing conversion in `castable()` makes that lookup fail, producing `NGX: missing evaluation parameter Color` and a black scene.

[3Shain/dxmt#235](https://github.com/3Shain/dxmt/pull/235) proposes the resource-pointer conversions, preserving the original pointer. It addresses [3Shain/dxmt#233](https://github.com/3Shain/dxmt/issues/233), reported by LANCYPANCY; windlandneko supplied the PR and an Endfield A/B gameplay test on DXMT 0.80. See [FineWine #48](https://github.com/stoicswe/Endfield_FineWine/issues/48) for the discussion and test details.

- **Stock CrossOver 26.3 / DXMT 0.80:** use **TAAU** or **AMD FSR3**. FineWine 1.2.3 updates Wine and MoltenVK while retaining the source CrossOver app's DXMT modules, so installing that release alone leaves this bug in place.
- **DXMT with the NGX fix:** DLSS upscaling has been tested working in Endfield's D3D11 path. Enable the bottle's **DLSS (MetalFX)** toggle (`DXMT_ENABLE_NVEXT=1`) and select DLSS in the game's graphics settings.

For a stock installation, follow the upstream PR and CrossOver release notes for inclusion of the fix. GPTK updates affect the separate D3DMetal backend; this DXMT fix belongs in `nvngx.dll`.

### Why DXMT + `-force-d3d11` Wins

1. **Thinner translation layer:** DXMT maps D3D11 API calls almost 1:1 to Metal, avoiding the heavier abstraction that D3DMetal introduces.
2. **GPTK4 synergy:** The Game Porting Toolkit v4 patch improves Metal shader compilation and resource management, which benefits DXMT's direct pipeline more than D3DMetal's internal pipeline.
3. **Mod compatibility:** EFMI's 3DMigoto `d3d11.dll` wrapper correctly chains through DXMT's D3D11 implementation, meaning the proxy → real-d3d11 handoff works cleanly.
4. **Stable frame pacing:** No shader compilation stutter (unlike DXVK), and frame times are consistent.
5. **Dramatically lower memory usage:** DXMT uses ~8–12 GB RAM vs D3DMetal's ~16 GB — up to a **50% reduction** — making the game viable on 16 GB machines with headroom to spare.

### Measured Performance (October 2026)

| Metric | D3DMetal (`-force-metal`) | DXMT (`-force-d3d11`) |
|---|---|---|
| **RAM Usage** | ~16 GB | ~8–12 GB (fluctuates) |
| **Max Settings FPS** | Playable but lower | **120 fps** |
| **Shader Stutters** | Occasional | Occasional (less frequent) |
| **Upscaling** | DLSS via MetalFX | TAAU / FSR3; DLSS via MetalFX with the NGX fix |
| **Mod Support** | ✅ | ✅ |
| **CPU Cores Used** | ~4 cores | ~4 cores |

> [!NOTE]
> Occasional shader compilation stutters may occur during first-time encounters with new effects or areas. These diminish over time as DXMT's shader cache warms up.

> [!TIP]
> **Mod pre-loading:** When using EFMI/3DMigoto character mods (e.g., costume swaps), the mod's shader overrides need to be "triggered" by viewing the character or scene for the first time. On the initial encounter, you'll see a brief flash of broken/shiny textures as the shader replacement compiles; after that first load the mod renders correctly for the rest of the session.

### Other Backend Notes

* **Vulkan:** Vulkan renders via MoltenVK when using MoltenVK **1.4.2+** (see [KhronosGroup/MoltenVK#2722](https://github.com/KhronosGroup/MoltenVK/issues/2722)). CrossOver 26.2's bundled MoltenVK 1.2.10 has a swapchain recreation bug that causes a black window after an FPS change — upgrading to 1.4.2 (as `swap-into-crossover.sh` now does by default) resolves this.
* **DXVK:** Theoretically viable but shader compilation is extremely slow and EFMI injection fails under this path. Not recommended.

---

## 6. Deep Dive References

For detailed logs, code diffs, and historical write-ups, see:
* [01 — ACE Anti-Cheat and Endfield Analysis](01-ace-anticheat-and-endfield.md)
* [02 — dw-proton ACE Patches Inventory](02-dwproton-ace-patches.md)
* [03 — CrossOver Wine Architecture on macOS](03-crossover-wine-architecture.md)
* [04 — Building CrossOver Wine from Source](04-building-crossover-wine.md)
* [05 — Swapping Modules into CrossOver](05-swapping-into-crossover.md)
* [06 — Graphics and GPTK Overview](06-graphics-and-gptk.md)
* [07 — Rosetta 2 and Windows Spoofing](07-rosetta-and-windows-spoofing.md)
* [10 — Milestone 1 Diagnostic Results](10-milestone-1-results.md)
* [11 — Linux vs macOS Execution Comparison](11-linux-vs-macos-comparison.md)
* [12 — Stage 1 Protector Fault Investigation](12-stage1-protector-fault.md)
* [13 — The Working Solution (Milestone 2 & 3)](13-working-solution.md)
* [14 — Performance Measurements on 16 GB Macs](14-performance-on-16gb-macs.md)
