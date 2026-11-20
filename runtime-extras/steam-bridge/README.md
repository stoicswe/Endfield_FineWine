# Steam bridge

What lets a Windows game that FineWine starts from the Mac Steam client use Steam: sign-in,
ownership, achievements and the rest of the Steamworks API. It is built into FineWine's runtime
by [`scripts/build-steam-bridge.sh`](../../scripts/build-steam-bridge.sh) and switched on only
by FineWine's Steam tool.

## How it works

A game reaches Steam through `steam_api64.dll`, which loads Steam's client library for Windows,
`steamclient64.dll`, from the Steam folder in the prefix. On a Mac there is no Windows Steam
behind that library. Three parts stand in for it:

| Part | What it does | Where it comes from |
|---|---|---|
| Loader change | When `steamclient64.dll` is loaded, its exports are pointed at `lsteamclient.dll` | [`patches/runtime/0042`](../../patches/runtime) |
| `lsteamclient` | Implements Steam's Windows interfaces on top of the Mac's own `steamclient.dylib`, which talks to the running Steam client. A Windows half (`lsteamclient.dll`) and a Mac half (`lsteamclient.so`) | Valve's, from Proton, with the files in [`lsteamclient/`](lsteamclient) over it |
| `steam.exe` | Starts the game: tells it where Steam's client library is (registry), then runs it | [`steam-helper/`](steam-helper), a port of Proton's helper |
| `overlay-shim.dylib` | Helps Steam's own overlay library, which the bridge loads into the game: starts its Metal hooks and keeps input from the game while the overlay is open | [`overlay-shim/`](overlay-shim), from NotProton |

Valve's own Windows client files (`steamclient64.dll`, `tier0_s64.dll`, `vstdlib_s64.dll`) are
needed in the prefix as well. They are Valve's, are not in this repository or in the runtime,
and are fetched from Valve on the user's Mac.

FineWine does not patch the Steam client. Steam only offers compatibility tools on a Mac when
[NotProton](https://github.com/NotProtonNot/NotProton) or
[Bridgeplay](https://github.com/raymondchins/Bridgeplay) has switched that on; FineWine's tool
sits beside theirs.

## What is in this folder

- `lsteamclient/` — the three source files, one patch and one header that replace or add to
  Valve's `lsteamclient` tree. Valve's tree itself is downloaded at the commit
  [`finewine-sources.lock`](../../finewine-sources.lock) names and checked against a digest.
- `steam-helper/` — the sources of `steam.exe`, with JsonCpp.
- `overlay-shim/` — the overlay helper, one Objective-C file.

All three were taken from NotProton at commit `42c1a9174d2a742cfdfe7808d76d133417d441dc`, where they
are the macOS ports of Valve's code. They are unchanged here.

## Building

```bash
./scripts/build-steam-bridge.sh
```

It needs the runtime's Wine tree (`scripts/build-finewine-runtime.sh` up to `build`, and
`package` for the install step). It builds `lsteamclient.dll` for ARM64 and x64 programs,
`lsteamclient.so` for the Mac side, `steam.exe` as an x64 program (it loads Steam's x64
library itself) and the overlay helper, and installs them into `build/finewine-runtime/lib/steam-bridge`.

## Limits

- 64-bit games only: the runtime cannot run 32-bit programs.
- The Steam overlay is untested with this runtime. The helper for it is built and passed to
  the game, as NotProton does for CrossOver's ARM64 Wine.
- Valve Anti-Cheat does not work through this bridge, as on Proton.

## Licences

Most of these parts are **not** under this repository's GPL-3.0-or-later:

| Part | Licence |
|---|---|
| `lsteamclient/` and Valve's tree it is laid over | Steamworks SDK licence: [`lsteamclient/LICENSE`](lsteamclient/LICENSE) |
| `steam-helper/steam.cpp`, `posix_compat.h`, `dlfcn.h`, `Makefile.in` | BSD 3-Clause, Valve Corporation: [`steam-helper/LICENSE`](steam-helper/LICENSE) |
| `steam-helper/jsoncpp.cpp`, `steam-helper/json/` | JsonCpp: public domain or MIT, as their headers say |
| `overlay-shim/` | GPL-3.0, from NotProton (the same licence as this repository) |

`steam.exe` is compiled against Steamworks SDK headers (Steamworks SDK licence), OpenVR
headers (BSD 3-Clause) and Wine headers (LGPL-2.1-or-later). The built files carry both licence
texts beside them in the runtime (`lib/steam-bridge/LICENSE.*`).

## Credits

- **[Valve](https://github.com/ValveSoftware/Proton)** — `lsteamclient` and the Steam helper,
  from Proton.
- **[NotProton](https://github.com/NotProtonNot/NotProton)** by NotProtonNot and its
  contributors — the macOS ports used here, and the work of enabling Steam Play in the Mac
  client that this depends on.
- **[Bridgeplay](https://github.com/raymondchins/Bridgeplay)** by Raymond Chin — the fork that
  showed the same bridge on Wine builds other than CrossOver's.
