# scripts/

Helper scripts for the capture → build → swap → test loop.

| Script | Stage | Purpose | Status |
|---|---|---|---|
| `01-capture-failure.sh` | diagnose | Launch Endfield via CrossOver with `CX_LOG` + `--wait-children`, collect logs + crash reports, auto-classify the failure (now recognizes the stage-1 protector loop). | ✅ working |
| `fetch-dwproton-patches.sh` | 2 | Pull the Endfield-relevant dw-proton patch set into `../patches/stage2-dwproton/`. | ✅ working |
| `build-wine.sh` | build | Build a **64-bit-only** CrossOver 26.2 Wine from source (standard toolchain, no `win32on64`/`cx-llvm`). `deps\|fetch\|configure\|build\|all`. | ⚙️ scaffold — needs first-run iteration (milestone 4) |
| `swap-into-crossover.sh` | build | Place the built Wine into a `CrossOver_patched.app`, keep `apple_gpt`, ad-hoc re-sign, de-quarantine. | ⚙️ scaffold — verify file mapping on first build |

## The loop
```
1. scripts/01-capture-failure.sh                      # baseline: capture the 0x6CD268 fault
2. scripts/build-wine.sh all                          # build vanilla 64-bit CrossOver Wine
3. scripts/swap-into-crossover.sh build/wine-build64  # -> build/CrossOver_patched.app (re-signed)
4. CX_APP=build/CrossOver_patched.app scripts/01-capture-failure.sh   # confirm parity vs stock
5. apply a stage-1 experiment (docs/12), rebuild, re-swap, re-capture, compare 0x6CD268 behavior
```

⚠️ `build-wine.sh` / `swap-into-crossover.sh` are milestone-4 scaffolds: the CrossOver-26.2 configure flags and the raw-build→bundle file mapping are **not yet verified on a real build**. First real run will need iteration — that's expected and is milestone 4 in [../docs/09-implementation-roadmap.md](../docs/09-implementation-roadmap.md).
