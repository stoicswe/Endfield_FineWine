# 04 — Building CrossOver's Wine from source on Apple Silicon

> Source area: `build-from-source` (re-researched). Reliability: **high on mechanism, medium on exact v25 flags**. ⚠️ The exact flag strings below were reconstructed via a summarizing fetcher — **clone the repos and read `build_local.sh` + `.github/actions/configure_wine/action.yml` byte-for-byte before running.**

## ⚡ Build-viability findings (verified 2026-07-14 on the target Mac — Apple M3, macOS 26.5, Homebrew, Xcode CLT clang 21)

These resolve the doc's earlier open questions and **change the recommended build path**:

1. **`cx-llvm` (the prebuilt patched CrossOver clang bottle) is GONE.** `brew tap gcenx/wine` now provides **only casks**, no `cx-llvm` formula. (Confirms GabLeRoux issue #51.)
2. **The CrossOver 26.2.0 source tarball does NOT bundle `clang`/`llvm`.** It's ~142 MB at `https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.2.0.tar.gz` and its `sources/` contains `android, cabextract, freetype, glib, gnutls, makedep, moltenvk, po4a, vkd3d, wine` — **no `clang`, no `llvm`**. So you cannot build the patched `win32on64` compiler from this tarball either. (27.0.0 source is not published at that URL — HTTP 404.)
3. **✅ We almost certainly don't need `win32on64` at all.** Arknights: Endfield is **64-bit only** — `Endfield.exe` loads at `0x140000000`, `EndfieldBase.dll` and all game DLLs at 64-bit addresses ([docs/10](10-milestone-1-results.md)). `win32on64`/`cx-llvm` exist only to run **32-bit** guest code. A **64-bit-only Wine** builds with the **standard toolchain** (Apple/Homebrew clang + `mingw-w64`), no custom compiler. **This is the recommended path** and it sidesteps the `cx-llvm` blocker.
4. **Toolchain gaps on this machine:** system `bison` is 2.3 (need ≥3.0 → `brew install bison` and put it first on PATH); `mingw-w64` and `meson` are missing (`brew install mingw-w64 meson`). `pkg-config`, `git`, `make`, `flex` present.
5. Build target = **CrossOver 26.2 source** (the release whose `CrossOver.app` is installed; source is available). The game fails identically on 26.2 and 27-Preview, so 26.2 is a fine build/swap target.

> ⚠️ Still to verify before the first build: that CrossOver 26.2's `sources/wine` configures and builds **64-bit-only with stock clang** (i.e. CrossOver has moved to new-WoW64 / no longer needs the custom compiler for a 64-bit build). This is the first thing the build script must prove ([09](09-implementation-roadmap.md) milestone 4).

## The single most important fact for this project

**The DIY FOSS build produces x86_64 (Intel) Wine binaries that run under Rosetta 2 — it is NOT a native arm64 Wine.** `[confidence: high]`
- GabLeRoux's `build_local.sh` hard-forces this with the shebang `#!/usr/bin/env arch -x86_64 bash`.
- ✅ **This is good news for the port:** the dw-proton int3 hack is `#ifdef __x86_64__`, and this build path is exactly an x86_64 build — so the hack *will* compile in. The architecture concern in [08](08-risks-unknowns-open-questions.md) is about CrossOver's *future* native-arm64 direction, not the DIY x86_64 build you'd make today.
- Native arm64 CrossOver is a **separate CodeWeavers effort** (FEX + ARM64EC + LLVM 21, no Rosetta) and is **not** what these community recipes build. There is no known community "build native arm64 CrossOver from source" recipe yet.

## Two canonical recipes

| | sarimarton gist | GabLeRoux cloud builder |
|---|---|---|
| Compiler source | builds CodeWeavers' **bundled** `clang/llvm` + `clang/clang` from the source tree (multi-hour) | installs prebuilt **`gcenx/wine/cx-llvm`** Homebrew bottle (skips LLVM compile) |
| Runs where | local (last validated on 2017 Intel MBP) | **GitHub Actions on `macos-latest`** |
| Status | **unmaintained** since Jan 2023 | version matrix tops out at **22.0.1 (2022)** — stale for CrossOver 25 |
| Output | `wine32on64` | `wine64` + `wine32on64` tarball artifacts |

⚠️ **Both are aging.** GabLeRoux **issue #51 (May 2025): `cx-llvm` is no longer available** from the tap — a live blocker. Reproducing against current CrossOver (25.x / Wine 10, or 26 / Wine 11) will require adapting these recipes and probably compiling the bundled clang/LLVM from the modern source tarball yourself.

## Source download

- Page: <https://www.codeweavers.com/crossover/source> (⚠️ 403s to automated fetchers; use a browser).
- Tarball pattern: `https://media.codeweavers.com/pub/crossover/source/crossover-sources-<VERSION>.tar.gz`
- Current line: **CrossOver 25.x** (25.0 released 2025-03-11) atop **Wine 10.0**; **CrossOver 26** (Feb 2026) atop **Wine 11.0 + NTSync**. The old community recipes target CrossOver 19–22 (Wine 4–7 era).

## The `win32on64` compiler requirement

`win32on64` (32-bit Windows code inside a 64-bit x86_64 Mach-O) **requires CodeWeavers' patched clang/LLVM.** Stock Homebrew `llvm` will **not** correctly build `--enable-win32on64`. `[confidence: high]` You get the patched compiler by either:
- `brew install gcenx/wine/cx-llvm` (fast, but see issue #51), **or**
- compiling the `clang/llvm` + `clang/clang` directories inside the CrossOver source tarball (slow, but self-contained and version-matched).

## Dependencies (Homebrew)

```bash
# toolchain
brew install bison gcenx/wine/cx-llvm flex mingw-w64 pkgconfig
# runtime libs
brew install freetype gnutls molten-vk sdl2
# workflow also pulls: gphoto2 gst-plugins-base krb5 sane-backends
# CrossOver < 22 additionally: faudio little-cms2 libpng mpg123
# DXVK (v21+): meson glslang
```

⚠️ **The #1 documented failure: `bison`.** Homebrew's `bison` must be **≥ 3.0 and ahead of macOS's system bison (2.3) on PATH**, or configure dies with "Your bison version is too old" — often *after* a multi-hour build (issue #4). Verify with `which bison` (must NOT be `/usr/bin/bison`).

## Environment setup (from GabLeRoux `build_local.sh`)

```bash
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/Library/Apple/usr/bin"
export CC="$(brew --prefix cx-llvm)/bin/clang"
export CXX="${CC}++"
export BISON="$(brew --prefix bison)/bin/bison"
export MACOSX_DEPLOYMENT_TARGET=10.14        # avoids "segment DLL" / linker errors
export BUILDROOT="$PWD/build"
export INSTALLROOT="$PWD/install"
```

## Build order (two-stage: wine64, then wine32on64)

```bash
# 1) (sarimarton path only) build bundled clang/llvm then clang/clang, prepend their bin/ to PATH.

# 2) build the 64-bit tree
mkdir -p "$BUILDROOT/wine64" && cd "$BUILDROOT/wine64"
CC=clang CXX=clang++ CROSSCFLAGS="-g -O2" \
CFLAGS="-g -O2 -Wno-implicit-function-declaration -Wno-deprecated-declarations -Wno-format" \
LDFLAGS="-Wl,-headerpad_max_install_names" \
<src>/configure --enable-win64 --with-vulkan --disable-tests \
  --without-alsa --without-capi --without-dbus --without-inotify --without-oss \
  --without-pulse --without-udev --without-usb --without-v4l2 --without-gsm \
  --without-quicktime --without-x
make -j$(sysctl -n hw.ncpu)

# 3) build the 32-on-64 tree against the 64-bit tree
mkdir -p "$BUILDROOT/wine32on64" && cd "$BUILDROOT/wine32on64"
CC=clang CXX=clang++ <same CFLAGS/LDFLAGS> \
<src>/configure --enable-win32on64 --with-wine64="$BUILDROOT/wine64" \
  --without-cms --without-openal --without-gstreamer --without-gphoto --without-krb5 \
  --without-sane --without-vulkan --disable-vulkan_1 --disable-winedbg \
  --disable-winevulkan --disable-tests
make -j$(sysctl -n hw.ncpu)
```

Notes:
- The `configure_wine` composite action does **not** set `--prefix` or a `--host`/`--build` triple.
- Pre-22 builds appended `-fcommon` to `CROSSCFLAGS`/`CFLAGS` and used `--without-vkd3d` in the 32on64 tree.
- **Minimal sarimarton single-tree example** (Intel, historical): `CC=clang CXX=clang++ ./configure --enable-win32on64 --disable-winedbg --without-x --without-vulkan --disable-mscms && make`.
- If configure/make complains about a missing `wine/include/distversion.h`, **create it by hand** (exact macro body not captured — check the gist comments). `[confidence: medium]`

## Output & de-quarantine

- Binaries land in `usr/local/bin/` (`wine64`, `wine32on64`) inside the install/artifact tree.
- Strip quarantine: `sudo xattr -r -d com.apple.quarantine <folder>`.
- Build time: **multi-hour** (the bundled-LLVM compile is the long pole; the `cx-llvm` bottle is what makes GabLeRoux fast).

## For orientation only: the upstream WoW64 / arm64 alternative

Modern **upstream** Wine replaces `win32on64` with `--enable-archs=i386,x86_64` (x86) or, for Apple-Silicon-native builds, an ARM64EC combination roughly `--enable-archs=arm64ec,aarch64,i386` with an llvm-mingw / LLVM-21 toolchain. `[confidence: medium — verify against the Wine 10/11 README]` **The CrossOver community recipes do NOT use `--enable-archs`** — they use `--enable-win32on64`. Don't mix the two mental models.

## Open questions
- ⚠️ Does `gcenx/wine/cx-llvm` still install, or must you now compile bundled clang/LLVM from the v25/v26 tarball? (issue #51)
- Exact CrossOver 25/26 (Wine 10/11) configure flags — all captured flags are from the 19–22 era and may have been renamed/added (DXMT, vkd3d, MoltenVK).
- Verbatim `distversion.h` contents.
- Whether the paid CrossOver vs. a FOSS build makes any difference for Endfield specifically.

## Primary sources
- sarimarton gist (+ comments) — <https://gist.github.com/sarimarton/471e9ff8046cc746f6ecb8340f942647>
- GabLeRoux cloud builder — <https://github.com/GabLeRoux/macos-crossover-wine-cloud-builder> (read `build_local.sh` and `.github/actions/configure_wine/action.yml` directly)
- GabLeRoux issue #51 (cx-llvm unavailable) — <https://github.com/GabLeRoux/macos-crossover-wine-cloud-builder/issues>
- Gcenx/wine-on-mac — <https://github.com/Gcenx/wine-on-mac>
- MacPorts wine-crossover — <https://ports.macports.org/port/wine-crossover/>
- CrossOver 25 / Wine 10 (Phoronix) — <https://www.phoronix.com/news/CrossOver-25.0-Released>
- CodeWeavers ARM64 preview blog — <https://www.codeweavers.com/blog/mjohnson/2025/11/6/twist-our-arm64-heres-the-latest-crossover-preview>
