# 01 — How XXMI Launcher / EFMI loads mods

> **Sources:** the `SpectrumQT/XXMI-Launcher` repository (read directly from source,
> `core/utils/dll_injector.py`, `core/packages/migoto_package.py`,
> `core/packages/model_importers/efmi_package.py`, `core/packages/model_importers/model_importer.py`),
> the `SpectrumQT/EFMI-Package` README, the XXMI release notes, and the upstream `bo3b/3Dmigoto`
> design. Everything in §1–§4 was read from source, not inferred. `[overall confidence: high]`

## 1. What the pieces are

| Piece | What it is |
|---|---|
| **3DMigoto** (bo3b/DarkStarSword/Chiri) | The original DX11 modding framework. A *replacement* `d3d11.dll` that intercepts the game's D3D11/DXGI calls and swaps shaders, buffers and textures at draw time. GPLv3. |
| **XXMI Launcher** (SpectrumQT) | A PyInstaller-packaged Windows GUI app (also distributed as a "Portable" build that runs under **WINE 9.22+**). It is a *modding platform*: package manager, per-game importer configs, and the **injector**. It does not itself contain mod logic. |
| **EFMI** (`SpectrumQT/EFMI-Package`) | An *XXMI package* — the Arknights: Endfield-specific 3DMigoto build plus its `d3dx.ini` profile and mod loader API. Distributed and driven by XXMI Launcher. |
| **3dmloader.dll** | The small injector DLL that XXMI loads to perform injection. Its `Inject` export (v0.7.5+) does `CreateRemoteThread` + `LoadLibraryW`; its `HookLibrary`/`WaitForInjection` pair implements the older `SetWindowsHookEx` method. |
| **Mods** | Plain folders under `Mods/` containing `.ini` (hash-matched resource replacements) and textures/meshes. |

## 2. Package layout on disk

When you press **Install** on the EFMI page in XXMI, the launcher downloads
`EFMI-PACKAGE-vX.Y.Z.zip` (signature-verified) and unpacks it into the importer folder
(`<AppData>/<XXMI Launcher>/EFMI/` by default). The files that matter:

```
EFMI/
  d3d11.dll            ← the XXMI/3DMigoto core (the DLL that gets injected)
  d3dcompiler_47.dll   ← Microsoft's HLSL compiler, shipped by XXMI
  3dmloader.dll        ← the injector library (loaded by the launcher itself)
  d3dx.ini             ← 3DMigoto config; contains [Loader] loader = XXMI Launcher.exe
  Core/EFMI/main.ini   ← EFMI version marker
  Mods/                ← mods go here (extracted folders)
```

Deployed-signature bookkeeping lives in the launcher config (`deployed_migoto_signatures`);
`unsafe_mode` controls whether third-party `d3d11.dll`s are allowed to stay instead of being
replaced (`migoto_package.py::should_deploy_package_file`).

## 3. The launch + inject sequence (this is the part that matters)

`EFMIPackage.get_start_cmd()` returns:

- executable: the game's `Endfield.exe`
- arguments: **`-force-d3d11`** (Endfield defaults to Vulkan/DX12 — the mod stack is DX11-only)
- work dir: the game exe's directory

`EFMIConfig` also sets `use_hook: bool = False` and `custom_launch_inject_mode = 'Inject'`.

With the default settings (`MigotoInjector.run()`):

```
use_hook == False  →  run_direct_injector()
use_hook == True   →  run_hook_injector()
```

### 3a. Direct inject (EFMI's default)

1. **Start the game process.** `DllInjector.open_process()` calls
   `subprocess.Popen([Endfield.exe, '-force-d3d11'], cwd=<game dir>)` — an ordinary
   Windows `CreateProcess` from inside the (Wine-hosted) launcher.
2. **Poll for the target.** `inject_libraries()` loops over `psutil.process_iter()` looking for a
   process whose *name* matches (`Endfield.exe`), up to `timeout` seconds (default 15).
3. **Inject.** For each DLL it calls `3dmloader.dll!Inject(pid, "<…>/EFMI/d3d11.dll")`.
   Per the XXMI architecture docs this is `pyinjector`-style low-level injection:
   `OpenProcess` → `VirtualAllocEx` → `WriteProcessMemory(dll path)` →
   `CreateRemoteThread(LoadLibraryW, <path>)`.
4. **Verification.** The launcher then waits for the game window
   (`wait_for_process(..., with_window=True)`) and reports failure if injection did not take.

Failure codes surfaced to the user come straight from the injector:
`100 PROCESS_NOT_FOUND`, `110 INVALID_DLL_PATH`, `120 KERNEL32_FAIL`,
`130 LOADLIBRARY_FAIL`, `200 REMOTE_ALLOC_FAIL`, `300 WRITE_MEMORY_FAIL`,
`400 THREAD_FAIL`, `500 THREAD_TIMEOUT`, `510 THREAD_WAIT_FAIL`,
`600 INJECTION_FAILED`, `700 UNKNOWN` (`dll_injector.py::InjectError`).
The special-cased message is: **"Failed to inject d3d11.dll"** when `d3d11.dll` is the only
library being injected — i.e. the *core* mod failed, as opposed to an extra library
(ReShade etc.) failing.

> XXMI's own release notes record the history here: *"[WWMI]: Switched default XXMI DLL injection
> method to direct Inject one (hooking no longer works)."* — i.e. the `SetWindowsHookEx` method was
> found unreliable and `Inject` became the default. EFMI inherits that default (`use_hook=False`).

### 3b. Hook method (`use_hook = True`)

`HookLibrary(dll, &hook, &mutex)` installs a **Windows hook** (`SetWindowsHookEx`) that makes Windows
load the DLL into any process that receives the hook event, then `WaitForInjection(dll, process,
timeout)` waits for the named process to appear and pick the DLL up. Error `300` here is
*"Library `<path>/d3d11.dll` is missing expected entry point!"* — the loader loaded *something*
named `d3d11.dll` but it did not export 3DMigoto's entry point. That error is the single most
important Wine-related symptom (see [02](02-wine-dll-loading-and-mod-dlls.md)).

### 3c. Custom Launch modes

| Mode | What happens |
|---|---|
| Default | launcher starts the exe itself, then injects the XXMI `d3d11.dll` |
| Hook | same, but via `HookLibrary` instead of `Inject` |
| Inject | same as default, with the ability to add extra libraries |
| **Bypass** | launcher does **not** inject the XXMI dll at all; it only injects whatever the user listed under **Inject Libraries** |

Bypass + Inject Libraries is how third-party stacks (ReShade, RenoDX, OptiScaler) are combined with
EFMI — e.g. the RenoDX Endfield instructions tell users to check *Custom Launch → Bypass*, then add
`ReShade64.dll` **and** EFMI's `d3d11.dll` to Inject Libraries.

## 4. How the injected DLL actually does the modding

3DMigoto's `d3d11.dll` is a **drop-in replacement / wrapper** for `d3d11.dll`. DeepWiki's
description of upstream matches what the XXMI builds do:

> "The game loads what it believes is the system `d3d11.dll`, but actually receives 3DMigoto's
> version. The initialization sequence in `DllMain` and `InitializeDLL` sets up the hooking
> infrastructure."

Consequences worth spelling out:

- The injected module is **named `d3d11.dll`**, and it must become *the* `d3d11` the game resolves
  when the game later calls `LoadLibrary("d3d11.dll")` / links its imports. That is why the
  injection has to happen **before** the game creates its D3D11 device — the community workaround
  for the injection race is literally *"change Start method to Shell … give enough time for d3d11.dll
  to be injected before Endfield.exe starts"*.
- It chains to the real D3D11 implementation (there is a `proxy_d3d11=` chain-load option in
  `d3dx.ini`, used when another wrapper such as ReShade must also be loaded).
- Everything else in the mod flow is 3DMigoto-standard: `d3dx.ini` sections, `Mods/` folders,
  hash-matched buffer replacement, `[Loader]` for the standalone loader path.
- `d3dcompiler_47.dll` is shipped alongside because mods ship pre-compiled HLSL and EFMI needs a
  *real* Microsoft compiler — see the flat-mesh Wine issue in [05](05-known-issues-and-references.md).

## 5. What "the launcher is not working and injecting" means concretely

Given the above, there are only a handful of places it can break, each with a distinct signature:

| Stage | Symptom the launcher shows | Meaning |
|---|---|---|
| Launcher itself won't start under Wine | nothing / Python traceback | Wine version too old — XXMI portable requires **WINE 9.22+** (see issue #76 "Launcher crashes with WINE 9.21 and below"). |
| `Inject` returns `100/110` | "Process not found" / "Invalid DLL path" | The launcher never saw `Endfield.exe` (wrong prefix, wrong exe name), or the path it tries to load isn't visible to the game process. |
| `Inject` returns `130 LOADLIBRARY_FAIL` / `300 WRITE_MEMORY_FAIL` / `400 THREAD_FAIL` | "Failed to inject d3d11.dll: …" | The remote `LoadLibraryW` failed inside the game process. Under Wine this is where **builtin-vs-native module-name collisions** bite (see [02](02-wine-dll-loading-and-mod-dlls.md)). |
| Injection "succeeds" but the game never renders mods | no error, game runs unmodded | The DLL loaded but never hooked, **or** the game is running DX12/Vulkan — XXMI is DX11-only, and Endfield defaults to Vulkan. |
| Game crashes at/near launch | `0x80000003`/`0xC0000005` in `UnityPlayer.dll`, no `3DM-*.dmp` | ACE killed the process before/during hooking (see #343, and the analogous DLSSG report in [05](05-known-issues-and-references.md)). |

## 6. What is *not* part of the mod-loading path (and therefore probably not our problem)

- The launcher does **not** copy `d3d11.dll` next to `Endfield.exe`. The game folder stays clean;
  the DLL lives in the EFMI folder and is injected by absolute path. (Verified in
  `deploy_package_files`: the package files are deployed to `importer_path`, not the game dir.)
- It does **not** touch the graphics backend selection. That is entirely CrossOver's
  `cxcompatdb.so` + the game's own renderer choice — see [03](03-crossover-backend-landscape.md).
- It does **not** use `AppInit_DLLs`, `LoadLibraryEx` flags tricks, or kernel drivers.