# Direct3D 9 on Vulkan: where it stands

Status on 2026-11-21: **built, shipped in the runtime, off by default, and not yet good enough
for the one real game it was tried with.** Portal 2 reaches its main menu on it and fails while
the first level loads. On the default path (WineD3D on Apple's OpenGL) Portal 2 runs correctly.
This page records what was built, what was found on the way, and where the work stopped, so
that it can be picked up again.

## Why it was tried

Direct3D 9 and older reach Metal through three layers by default: WineD3D turns Direct3D into
OpenGL, Apple's OpenGL turns that into Metal. A measurement of Portal 2 on that path showed the
GPU as the limit (91 to 95% busy) and about a fifth of the render thread's time spent copying
vertex data in and out of the 32-bit address range. A Vulkan path is one layer shorter, and
what only exists for Metal layers (the Metal HUD, MetalFX upscaling) would reach these games.
It needed Vulkan to work in 32-bit programs first, which it did not.

## What exists

- **Vulkan in 32-bit programs** (runtime patch 0048). Wine gives a 32-bit program mapped GPU
  memory it can reach by allocating it in the program's address window and handing it to
  MoltenVK (`VK_EXT_external_memory_host`). Two places assumed 32-bit addresses below 4 GB.
  With it, 32-bit Direct3D 12 also starts (a clear and a present pass).
- **The prefix setting "Direct3D 9 and older on Vulkan"** (`legacyDirect3DOnVulkan`, off by
  default). With it on, FineWine puts DXVK's `d3d9.dll` ahead of Wine's (`WINEDLLPATH`), sets
  `FINEWINE_DXVK_FEATURES=1`, `DXVK_LOG_LEVEL=none` and `DXVK_STATE_CACHE_PATH` (a folder in
  the prefix, `.finewine-dxvk-cache`). Direct3D 10 and 11 stay on DXMT. The switch is greyed
  out for a runtime without DXVK. Changing it clears the prefix's shader caches.
- **DXVK's Direct3D 9** (`scripts/build-dxvk.sh`): DXVK 1.10.3 from CrossOver's source
  archive plus `patches/dxvk`, for 32-bit and 64-bit programs, installed as `lib/dxvk` and
  listed in `runtime.json` as `dxvk-d3d9`.
- **MoltenVK** reports the features DXVK will not start without (geometry shaders, cull
  distances, 64-bit floats, depth clamping) when `FINEWINE_DXVK_FEATURES=1`
  (`patches/moltenvk/0007`). Direct3D 9 uses none of them.

## What was tried first: WineD3D's own Vulkan renderer

The setting first meant `WINE_D3D_CONFIG=renderer=vulkan`. Portal 2 needed one fix after
another, each found from the game's log and reproduced in a test:

| Symptom in Portal 2 | Cause | Fix |
|---|---|---|
| Black screen, sound plays | An antialiased back buffer was presented with a blit, which Vulkan does not allow from a multisampled image | runtime patch 0049 |
| Green and magenta garbage over the menu | L8, A8L8, L16, X1R5G5B5, A2R10G10B10, X8B8G8R8, ATI1N and ATI2N missing from the Vulkan format table | runtime patch 0050 |
| The world drawn as garbage, 43,000 failed pipelines | UBYTE4 and SHORT vertex elements given to shaders as integers; Direct3D 9 shaders read floats | runtime patch 0051 |
| Noise over every surface | The sampler's largest mip level (`D3DSAMP_MAXMIPLEVEL`, `SetLOD`) not applied, so textures still loading showed unfilled levels | runtime patch 0052 |

After those the picture was still wrong (washed-out colours, magenta panels, missing font
glyphs) at about 12 frames per second, and a run with Wine's diagnostics on reported nothing
unhandled except sRGB: that renderer has no sRGB reading or writing for Direct3D 9 at all
(`srgb_read_control` and `srgb_write_control` are off, and no format reports sRGB support). With
the renderer unable to say what else it lacks, the setting was moved to DXVK. The four patches
are kept, and `tests/runtime/d3d9-formats.c` still compares WineD3D's two renderers.

## DXVK: what was fixed

| Symptom in Portal 2 | Cause | Fix |
|---|---|---|
| Froze at start, every thread waiting | Not DXVK: a lost wake-up in 32-bit programs. The emulator's lock wait took the wake-up meant for the program's wait | runtime patch 0053 (helps every 32-bit program) |
| Black screen, sound plays | DXVK declares a colour and a depth-comparing variable at one binding for every sampler; Metal has no two resources at one index, so no shader that samples a texture compiled | `patches/dxvk/0002`: one variable per sampler |
| Froze while the level loaded, "Lost VkDevice ... Internal Error" | A slip in DXVK 1.10.3 (`pushConstSize = m_pushConstOffset`) left pixel shaders older than 3.0 without declared push constants; MoltenVK then bound none and the shader read an unbound buffer | `patches/dxvk/0003` |

## Where it stopped

Portal 2 still loses the GPU device while the first level loads.

- Without Metal's validation: one line, `Lost VkDevice after MTLCommandBuffer "vkQueueSubmit
  ..." execution failed (code 1): Internal Error (0000010d)`.
- With validation (API and shader): no errors, only warnings about unused bindings and empty
  passes, then five command buffers end in `GPU Timeout Error
  (kIOGPUCommandBufferCallbackErrorTimeout)` and the internal error follows.
- Neither Metal nor MoltenVK names the pass. `MVK_CONFIG_DEBUG=1` adds nothing for this error.
- It does not happen in any test here: drawing with vertex and pixel shaders, antialiasing,
  every texture format, depth textures, and 1,500 frames of making and freeing textures and
  buffers all pass under validation.

Not tried: the game with antialiasing off, or at a lower resolution (both can be set from its
menu, which works), which would say whether the failing pass depends on either.

The next step that was planned: a diagnostic mode in the runtime's MoltenVK that submits every
render pass as its own labelled command buffer, so that the log names the one that fails.

## Known shortcomings of the DXVK path

- **Depth-comparing sampling is gone** (`patches/dxvk/0002`). A depth texture is sampled as
  plain values, so shadows a game draws by comparing against a depth texture are wrong:
  `tests/runtime/d3d9-shadow.c` gives white and black on OpenGL and the raw depth on DXVK.
  The proper fix is a binding of its own for the depth variant inside DXVK.
- **Pixel shaders older than 2.0 can only sample 2D textures**, for the same reason.
- **DXVK 1.10.3 is old.** It is the version CrossOver publishes with its changes for MoltenVK.
- **MetalFX upscaling of a small swapchain** (MoltenVK patch 0006) uses an output texture that
  is not in private storage, which Metal's validation flags. Seen while testing; not fixed,
  and not specific to Direct3D 9.

## How failures were found

What worked, in order of how much it told:

1. The game's own log (`~/Library/Application Support/FineWine/Logs/<prefix>/`): MoltenVK's
   `[mvk-error]` lines name shader compile errors and lost devices.
2. Metal's validation, set as environment variables of the prefix: `MTL_DEBUG_LAYER=1`,
   `MTL_DEBUG_LAYER_ERROR_MODE=nslog`, `MTL_DEBUG_LAYER_WARNING_MODE=nslog`,
   `MTL_SHADER_VALIDATION=1`. It named the unbound buffer directly. The game runs slowly with
   them.
3. Wine's own channels in the prefix's debug field
   (`err+d3d,fixme+d3d,err+d3d_shader,fixme+d3d_shader`), for WineD3D's renderer.
4. For the freeze: `WINEDEBUG=+sync,+tid` on a test run that froze, which showed two wake-ups
   sent to one thread in a row and the thread never running again.

Each cause was then reproduced in a small test before it was fixed:
`tests/runtime/d3d9-draw.c` (shaders, antialiasing, the alpha test), `d3d9-formats.c`,
`d3d9-shadow.c` and `d3d9-churn.c`. The last two are not in
`scripts/test-finewine-runtime.sh` yet.
