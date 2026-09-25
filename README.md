[![build](https://github.com/stoicswe/Endfield_FineWine/actions/workflows/build.yml/badge.svg)](https://github.com/stoicswe/Endfield_FineWine/actions/workflows/build.yml) [![nightly](https://github.com/stoicswe/Endfield_FineWine/actions/workflows/nightly.yml/badge.svg)](https://github.com/stoicswe/Endfield_FineWine/actions/workflows/nightly.yml) [![Generate Wiki Documentation](https://github.com/stoicswe/Endfield_FineWine/actions/workflows/update-wiki.yml/badge.svg)](https://github.com/stoicswe/Endfield_FineWine/actions/workflows/update-wiki.yml)

# Endfield_FineWine — Arknights: Endfield on Apple Silicon

Run **Arknights: Endfield** on an Apple Silicon Mac through a **custom-patched CrossOver Wine**. This project aims to provide the necessary compatibility edits needed to bring Arknights: Endfiled to a near-native macOS gaming experience. Patches by the `DW-Proton` project have been used as the basis for getting the game's VMProtect/TenProtect armor, the **ACE anti-cheat**, and rendering commands to run properly on macOS. This project does **NOT** bypass anticheat, but rather adjusts the crossover env to allow for Endfield's anticheat services to run uninterupted. Additiionally, we aim optimize the translated calls from DX11/Vulkan to Apple's **D3DMetal**.

CodeWeavers rated Endfield *"Installs, Will Not Run"* and the community consensus was that CrossOver + Endfield was impossible; this repository is the first known working setup, plus the full engineering write-up of how it was found.

> **What this is:** a set of **patches** to CrossOver's (LGPL) Wine, plus **scripts** and **documentation** to build and deploy them. It does **not** contain or redistribute CrossOver, Wine, Apple's Game Porting Toolkit, or the game — you bring your own licensed copies of each.
>
> **Scope & ethics:** own the game; this is compatibility work (the same category as Valve's Proton on Linux) — no in-game advantage, no modified game logic, no DRM circumvention. Running the game in an unsupported configuration may violate its Terms of Service; that risk is yours (see [LICENSE](LICENSE)). Not affiliated with Gryphline/Hypergryph, Tencent, CodeWeavers, or Apple.

---

## Hardware Specs & Real-World Performance

Tested on an Apple **M4 Pro** (MacBook Pro 12-core, 24 GB), macOS 27.0, CrossOver 26.2/26.3 — ~**60 FPS on Medium** at 100% render scale. ⚠️ **MacBook Air is OFF-LIMITS** (no active cooling). Expect ~90 °C thermals and a fully maxed CPU on any Mac; performance is CPU + RAM bound, not GPU.

➜ See **[docs/performance.md](docs/performance.md)** for the full breakdown: per-chip FPS targets, thermal behaviour, swap pressure, and optimisation tips.

---

## Quick Start

### Using the Patcher.app
Use the latest available release patcher found on the [releases page](https://github.com/stoicswe/Endfield_FineWine/releases).

### Manual Build and Installation

#### Dependancies
| | |
|---|---|
| **Mac** | Apple Silicon (M-series); **Intel not supported** |
| **macOS** | 15 (Sequoia) or newer — tested on 27.0 / 26.5 |
| **Rosetta 2** | required: `softwareupdate --install-rosetta --agree-to-license` |
| **CrossOver** | **26.3**, licensed, from [codeweavers.com](https://www.codeweavers.com/crossover) |
| **Xcode CLT / Homebrew** | `xcode-select --install` · [brew.sh](https://brew.sh) |
| **Disk / time** | ~5 GB for the build tree; build ~10 min on a 10-core M4, longer on fewer cores (1.5–2.5 h cold on the 3-vCPU CI runner) |


#### Cloning and Building Locally
```bash
git clone <your-fork-url> Endfield_FineWine && cd Endfield_FineWine

./scripts/build-wine.sh all          # 1. build the patched Wine (deps -> fetch -> patch -> configure -> build)

./scripts/swap-into-crossover.sh     # 2. deploy into a copy of CrossOver -> /Applications/CrossOver_Endfield_Patch.app

./scripts/create-bottle.sh           # 3. create the "Arknights Endfield" bottle (Win11 64-bit, D3DMetal + DLSS + MSync)
                                     #    …then install the Gryphline launcher into it via CrossOver's GUI

open /Applications/CrossOver_Endfield_Patch.app   # 4. run the game — NOT the stock CrossOver app
                                     #    in the launcher: dropdown next to Start -> "Launch with DirectX 11"
                                     #    (the plain Start button uses the game's default Vulkan renderer:
                                     #    experimental, see docs/graphics-performance.md)
```

Full requirements, a manual (auditable) deployment, the bottle/Gryphline setup, and launch options: **[docs/installation.md](docs/installation.md)**.

---

## Technical Architecture (Under The Hood)

Curious about how this works under the hood without cluttering up the setup guide? Read **[docs/technical.md](docs/technical.md)** for the full architectural deep dive, including:
- **Two novel Rosetta 2 CPU bug fixes:** skipping multi-byte `0F 1F` NOP exception loops and fixing privileged `mov cr3` opcode classification in `signal_x86_64.c`.
- **dw-proton anti-cheat port:** 17 `ntoskrnl.exe` kernel backports, `KiUser*Dispatcher` int3 spoofer, and high-resolution QPC timing loops.
- **Surgical module swap & dynamic linking:** why only 3 Wine modules are swapped and how `@loader_path/../../../lib64` rpath is injected so D3DMetal can load.
- **Graphics translation mechanics:** Direct DirectX 11 → Metal pipeline vs broken DX12/Vulkan paths.
- Complete subsystem research and milestone reports in [docs/](docs/).

---

## License

- **Scripts (`scripts/`) and documentation (`docs/`, README):** [MIT](LICENSE).
- **Patches (`patches/`):** these are modifications to **Wine**, so they are **LGPL-2.1-or-later** (Wine's license) — MIT cannot relicense them. The `stage2-dwproton/` patches originate from the **dw-proton (Dawn Winery)** project and retain their upstream authors' rights. See [patches/README.md](patches/README.md).
- This repo's **source** does not include Wine, CrossOver, Apple's GPTK, or the game. Built artifacts (e.g. `FineWine Patcher.app`) bundle the patched Wine modules (**LGPL-2.1-or-later**) and MoltenVK (**Apache-2.0**) — see [patcher-app/README.md](patcher-app/README.md) for the corresponding-source offer. Get CrossOver, GPTK and the game from their own sources, under their own licenses.

## Credits

- **[dw-proton / Dawn Winery](https://dawn.wine/)** — the Linux ACE/Endfield patches that stage 2 ports.
- **[CodeWeavers CrossOver](https://www.codeweavers.com/crossover)** and the **[Wine](https://www.winehq.org/)** project — the foundation this builds on.
- **[Apple Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit/)** — D3DMetal.
- **[Khronos Group MoltenVK](https://github.com/KhronosGroup/MoltenVK)** — the Vulkan-on-Metal layer (Apache-2.0); bundled patched in the patcher app.
- **WineHQ Bug 45083** reporters — the prior art that framed the Rosetta VMProtect problem.

## Contributing / upstreaming

The two Rosetta signal-handling fixes are general CrossOver-on-Apple-Silicon bugs and are worth reporting to **CodeWeavers** (with Bug 45083 as reference). PRs to improve the build/deploy scripts, packaging (e.g. a CXPatcher-style overlay), and testing on more chips/macOS versions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).