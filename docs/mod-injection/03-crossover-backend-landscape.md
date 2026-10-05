# 03 — CrossOver's D3D11 backends, and why D3DMetal is the odd one out

> **Sources:** direct inspection of `/Applications/CrossOver_Endfield_Patch.app` (v26.2) and
> `/Applications/CrossOver.app` (v26.3), the bottle `~/Library/Application Support/CrossOver/Bottles/
> Arknights Endfield`, plus the parent docs (docs/06, docs/13) for backend semantics.
> Every file claim below was verified by reading the bundle, and the d3d11/dxgi hashes were compared
> with `shasum`. `[overall confidence: high]`

## 1. There are four different `d3d11.dll`s inside CrossOver 26.x

Measured in the **patched app** we actually use (`CrossOver_Endfield_Patch.app`):

| # | `d3d11.dll` | Size | What it is |
|---|---|---|---|
| 1 | `lib/wine/x86_64-windows/d3d11.dll` | 425 552 B | Wine **wined3d** D3D11 (the "stock" one, also copied into the bottle's `system32`) |
| 2 | `lib64/apple_gptk/wine/x86_64-windows/d3d11.dll` | 114 240 B | **D3DMetal / GPTK shim** — a thin forwarder into `D3DMetal.framework` |
| 3 | `lib/dxmt/x86_64-windows/d3d11.dll` | 4 772 768 B | **DXMT** — full native D3D11→Metal implementation (3Shain/dxmt) |
| 4 | `lib/dxvk/x86_64-windows/d3d11.dll` | 3 165 760 B | **DXVK** — full native D3D11→Vulkan implementation |

The same four-way split exists for `dxgi.dll` (218 KB stock, 93 KB GPTK shim, DXMT/DXVK full) and
for `d3d12.dll` / `nvapi64.dll` / `nvngx.dll`. DXMT also ships `winemetal.dll` + a unix-side
`winemetal.so` (its Metal backend).

**Consequence that matters for a hooking framework:** a *real*, full D3D11 implementation exists as
a normal PE DLL for DXMT and DXVK — the same kind of file 3DMigoto/ReShade hook on Windows and
Linux. The D3DMetal path is a **shim**, not a full implementation. `[confidence: high]`

## 2. How a backend is selected (and what is *not* how it works)

`lib/wine/x86_64-unix/cxcompatdb.so` is the per-process backend selector. Strings from our patched
app's copy:

```
CX_ACTIVE_GRAPHICS_BACKEND
CX_GRAPHICS_BACKEND
d3dmetal
dxmt
dxvk
lib/dxmt
lib/dxvk
lib/vkd3d-proton
redirect_nvngx_to_d3dmetal
HACK: redirecting nvngx.dll to D3DMetal original
D3DMetal nvngx.dll cannot be accessed at %s
set_graphics_backend
using %s as the graphics backend
%s was set as the graphics backend but it is unusable
```

Key facts established from this + the parent docs:

- The backend is chosen **per process** from the bottle's `CX_GRAPHICS_BACKEND`, applied by
  `cxcompatdb.so`, which our patched `ntdll.so` dlopens. (The parent docs' docs/13 records that a
  missing `lib64` rpath on `ntdll.so` silently breaks this and silently falls back to wined3d — our
  swap script adds that rpath, verified present.)
- **The bottle's `system32/d3d11.dll` is NOT rewritten.** Hash comparison:
  - `CrossOver_Endfield_Patch.app/.../lib/wine/x86_64-windows/d3d11.dll`
    `5af798c9a40b65b3be756cc3bb3ec0cfd9fb0f17`
  - `Bottles/Arknights Endfield/drive_c/windows/system32/d3d11.dll`
    `5af798c9a40b65b3be756cc3bb3ec0cfd9fb0f17` → **identical** (stock wined3d)
  - same result for `dxgi.dll` (`26228513c51c01b66a7fab8b28171daca7acd80b`)
  So the backend is applied by redirecting the *load*, not by copying files into the prefix.
  The stray `*.wined3d.bak` files in the bottle are leftovers from an earlier manual swap, and the
  current files are back to stock.
- Our patched build does **not** touch any of this: only `ntdll.so`, `kernel32.dll` and
  `ntoskrnl.exe` are swapped, plus the GPTK4 `D3DMetal.framework`/`libd3dshared.dylib` refresh under
  `lib64/apple_gptk/external/`.

## 2a. What our bottle is currently set to (verified)

```
$B/cxbottle.conf:
  "DXMT_ENABLE_NVEXT" = "1"
  "CX_GRAPHICS_BACKEND" = "d3dmetal"
  "CX_ACTIVE_GRAPHICS_BACKEND" = "d3dmetal"
  "WINEMSYNC" = "0"
```

- Bottle arch: `win64`. No per-app `DllOverrides` for `Endfield.exe`; the bottle-wide
  `[Software\\Wine\\DllOverrides]` list contains **no** entry for `d3d11`, `dxgi`, `d3dcompiler_47`
  or `nvapi64`.
- Game folder: `…/GRYPHLINK/games/Arknights Endfield/` with `Endfield.exe`, `Endfield_Data/`,
  and the game's own native `d3dcompiler_47.dll` (4 524 496 B).
- **No XXMI / EFMI installation anywhere in the bottle** (searched for `*XXMI*`, `*EFMI*`,
  `3dmloader.dll`, `d3dx.ini`, `loader.exe`) → nothing has actually been attempted in this context yet.

## 3. Why D3DMetal is the awkward case for 3DMigoto

3DMigoto hooks at the D3D11 API boundary: it wants to become/interpose the `d3d11.dll` the game
loads, and (for the injected variant) hook device creation and the immediate-context vtables.

- **On Linux/Proton**, the game loads DXVK's `d3d11.dll` — a full, self-contained native PE with a
  conventional export table. A second `d3d11.dll` injected/overlaid on top has a normal module to
  hook. This is the configuration the whole gacha-modding ecosystem is validated against.
- **On CrossOver with `d3dmetal`**, the game's `d3d11.dll` is the **114 KB GPTK shim** that hands
  off to `D3DMetal.framework`. There is still a normal PE to hook, but it is a *forwarder*, and the
  real implementation lives in a macOS framework on the other side of the shim. Whether 3DMigoto's
  hooks survive that indirection is **unmeasured**. `⚠️ macOS unknown`
- **On CrossOver with `dxmt`**, the game loads DXMT's full 4.7 MB native `d3d11.dll` — the closest
  structural match to what works on Linux, and it is the backend under which **ReShade is
  independently reported working on macOS** (see [05](05-known-issues-and-references.md)).
- **On CrossOver with `dxvk`**, same shape as DXMT but via Vulkan→MoltenVK (extra hop, no DLSS).

**Working hypothesis for the experiment plan:** DX11 + **DXMT** is the backend that structurally
resembles "Linux/Proton with DXVK" and therefore the most likely to accept a 3DMigoto hook;
D3DMetal is the one to keep for unmodded play, not the one to debug against.
`[confidence: medium — this is a structural argument, not a measurement]`

## 4. Endfield-side constraint that cuts across all of this

- XXMI/EFMI is **DX11-only**. Endfield defaults to Vulkan/DX12; the parent docs established that
  DX12 (→`vkd3d`) and native Vulkan (→MoltenVK) both fail to render under CrossOver 26.2 and that
  `-force-d3d11` is required. EFMI itself passes `-force-d3d11`, so a *launcher-driven* launch is
  consistent with what the game needs anyway.
- Community confirmation, r/linux_gaming *Modding Arknights: Endfield*: *"XXMI only supports DX11.
  So even if you have everything set up correctly, if the game is running DX12, the mods won't
  load."*
- Consequence: the renderer choice and the backend choice are **two independent dials** —
  (game → DX11) is required regardless of (bottle → d3dmetal/dxmt/dxvk). `[confidence: high]`

## 5. Summary table of what we would be hooking, per backend

| Bottle backend | `d3d11` the game gets | Full implementation? | Hookable by 3DMigoto? | Evidence |
|---|---|---|---|---|
| `d3dmetal` (current) | GPTK shim → `D3DMetal.framework` | no (shim) | unknown | structural only |
| `dxmt` | DXMT native `d3d11.dll` | yes | plausible — ReShade precedent on macOS | r/macgaming report, CodeWeavers tip page |
| `dxvk` | DXVK native `d3d11.dll` → Vulkan → MoltenVK | yes | plausible — this is the Proton-shaped case | structural |
| wined3d (no backend) | Wine builtin `d3d11.dll` | yes, but Wine's own | worst case for overrides; collides with native | Wine loader semantics |

> Note for the implementation phase (not done now): the parent docs already warn against
> overwriting `lib/wine/x86_64-windows/{d3d11,d3d12,dxgi}.dll` with the `apple_gptk` copies
> (error 1114). The backend switch is a **bottle configuration** change
> (`CX_GRAPHICS_BACKEND`), not a file swap.
>
> **How a mod DLL should be layered on top of whichever backend is active** — including the exact
> in-bottle paths to chain to — is covered in [07-load-ordering-and-chaining.md](07-load-ordering-and-chaining.md).