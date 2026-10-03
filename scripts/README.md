# scripts/

Helper scripts for the capture → build → swap → test loop.

| Script | Stage | Purpose | Status |
|---|---|---|---|
| `01-capture-failure.sh` | diagnose | Launch Endfield via CrossOver with `CX_LOG` + `--wait-children`, collect logs + crash reports, auto-classify the failure (now recognizes the stage-1 protector loop). | ✅ working |
| `fetch-dwproton-patches.sh` | 2 | Pull the Endfield-relevant dw-proton patch set into `../patches/stage2-dwproton/`. | ✅ working |
| `build-wine.sh` | build | Build a **64-bit-only** CrossOver 26.3 Wine from source (standard toolchain, no `win32on64`/`cx-llvm`). `deps\|fetch\|apply\|configure\|build\|all`. | ✅ working |
| `build-moltenvk.sh` | build | Build a patched x86_64 **MoltenVK** (`libMoltenVK.dylib`) from source into `build/moltenvk-out`. `fetch\|apply\|deps\|build\|all`. | ✅ working |
| `package.sh` | package | Bundle `build/wine-out` + `build/moltenvk-out` into `dist/endfield-wine-modules` (+ tarball/checksums) for `apply-modules.sh` and the Patcher app. | ✅ working |
| `apply-modules.sh` | install | Install the packaged Wine modules **and** MoltenVK into a copy of CrossOver (`CrossOver_Endfield_Patch.app`). | ✅ working |
| `swap-into-crossover.sh` | build | Build `CrossOver_Endfield_Patch.app` from `CrossOver.app`: swap in the 3 patched modules (+ optional GPTK4 D3DMetal; MoltenVK is downloaded unless `SKIP_MVK=1`), re-seal, verify. | ✅ working |
| `create-bottle.sh` | setup | Create the `Arknights Endfield` bottle (Windows 11 64-bit, D3DMetal + DLSS + MSync), or re-apply those settings with `UPDATE=1`. | ✅ working |
| `launch-endfield.sh` | play | Launch `Endfield.exe` directly through the patched app (adds `-force-d3d11`); optional Wine logging via `DEBUG=`. | ✅ working |

## The loop
```
1. scripts/01-capture-failure.sh                      # baseline: capture the 0x6CD268 fault
2. scripts/build-wine.sh all                          # build vanilla 64-bit CrossOver Wine
3. scripts/swap-into-crossover.sh build/wine-build64  # -> build/CrossOver_patched.app (re-signed)
4. CX_APP=build/CrossOver_patched.app scripts/01-capture-failure.sh   # confirm parity vs stock
5. apply a stage-1 experiment (docs/12), rebuild, re-swap, re-capture, compare 0x6CD268 behavior
```

`build-wine.sh` / `swap-into-crossover.sh` are verified working on the reference setup (Apple M4 Pro, macOS 27.0, CrossOver 26.3.0 — the full story is [../docs/13-working-solution.md](../docs/13-working-solution.md)). On other macOS/CrossOver versions expect some iteration; the loop above is how to debug it. How to use these scripts as a user: [../docs/installation.md](../docs/installation.md).
