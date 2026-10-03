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
    Unity -->|DirectX 11 mode| D3DMetal["Apple D3DMetal (DirectX -> Metal)"]
    D3DMetal --> Metal["Apple Silicon GPU (Metal 3 / 4)"]
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

```
Endfield Engine (DirectX 11)
       │
       ▼
CrossOver D3DMetal (Apple GPTK)
       │ (Direct translation: DX11 -> Metal)
       ▼
Metal Framework / Apple Silicon GPU
```

### Why DirectX 11 is Recommended
* **DirectX 12:** CrossOver uses `vkd3d` for DX12. The game's complex DXIL / Shader Model 6 shaders fail to compile (`Cannot load DXIL conversion library`), causing a white/blank screen.
* **Vulkan (experimental):** Vulkan now renders via MoltenVK when using MoltenVK **1.4.2+** (see [KhronosGroup/MoltenVK#2722](https://github.com/KhronosGroup/MoltenVK/issues/2722)). CrossOver 26.2's bundled MoltenVK 1.2.10 has a swapchain recreation bug that causes a black window after an FPS change — upgrading to 1.4.2 (as `swap-into-crossover.sh` now does by default) resolves this. Treat Vulkan as **experimental**.
* **DirectX 11:** Routes directly into **Apple D3DMetal** (GPTK 3.0 / 4.0) with zero intermediate hops. It renders fully, supports MetalFX upscaling (spoofed as NVIDIA DLSS), and maintains stable frame times.

For the most stable experience, launch the game with **"Launch with DirectX 11"** from the Gryphline launcher or use `-force-d3d11`. Vulkan may be used experimentally with MoltenVK 1.4.2+.

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
