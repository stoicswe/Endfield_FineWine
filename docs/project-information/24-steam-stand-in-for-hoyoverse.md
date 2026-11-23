# Starting HoYoverse games as Steam does (2026-11-15)

On Linux, Genshin Impact, Zenless Zone Zero and Honkai Impact 3rd are run with Proton's Steam
helper: the game is started by a program called `steam.exe` that leaves what a running Steam
client leaves, with Steam's variables set. DWProton does this automatically for these games
and recommends it for Genshin and Zenless Zone Zero. FineWine now does the same.

## What was built

- `runtime-extras/steam-helper/steam.c`: FineWine's own small `steam.exe` (x64). It creates
  the two named events and the hidden window a Steam client has, writes Steam's registry
  values (`HKCU\Software\Valve\Steam`: path, executable, the running client's process id),
  sets `SteamPath` and `ValvePlatformMutex`, starts the program it was given, and stays until
  nothing else is running in the prefix. It provides no Steam service; there is no Steam API
  behind it. Built by `scripts/lib/build-steam-helper.sh` into
  `share/finewine/steam/steam.exe` of a runtime.
- The app copies it to `C:\Program Files (x86)\Steam\steam.exe` in the prefix before a
  launch (never over a real Steam installed there) and starts the program through it with
  `SteamGameId` and `SteamAppId` set.
- It applies to `GenshinImpact.exe`, `ZenlessZoneZero.exe`, `BH3.exe`, and `launcher.exe` in
  a `HoYoPlay` folder: the list DWProton uses. Honkai: Star Rail is not on it; DWProton
  handles that game with other tricks (refusing a connection, faking a signature lookup).
  Those were left out at first and ported on 2026-11-23, see "Honkai: Star Rail" below.
- Prefix setting "Start HoYoverse games as Steam does", on by default.

## What is and is not known

- **Tested:** a test program started through the stand-in finds the variables, the event,
  the window, the registry values, a live process behind the registered id, and `steam.exe`
  as its parent (`tests/runtime/steam-probe.c`, part of `scripts/test-finewine-runtime.sh`).
- **Not known:** which of these a HoYoverse game actually looks at, and so whether this is
  enough. No game has been run with it. DWProton's own fix script for these games was not in
  the checkout that was read; the ids (`zenlesszonezero`, `genshin`) are what its launcher
  is believed to pass and are unverified.
- **Not ported from Proton's helper:** `lsteamclient` (the bridge to a real Steam client,
  which DWProton also switches off for these games), Steam's client files, VR and Discord
  setup.

## A caution

This tells the game it was started by Steam. HoYoverse does not support its games on a Mac
this way, and what its anti-cheat makes of it is its decision. The setting says so, and can
be turned off.

## Honkai: Star Rail

Added 2026-11-23, on the project owner's decision, after a report that the game does not start
(the logs of issue 128: the engine and the sound come up, and about ten seconds after the start
the game is gone, with nothing in its log and no crash record).

The game is not started through the Steam stand-in. What the Linux build this page follows
(DWProton) has for it, and all it has for it, is two special cases in Wine for a program whose
file is `StarRail.exe`. Both are now in the runtime (patch 0057):

- **The first connection is refused.** The program's first call to `connect` fails with
  "connection refused"; every later one is untouched (`dlls/ws2_32/socket.c`).
- **The first signature-catalogue lookup succeeds.** Windows keeps catalogues of the signatures
  of its own files; Wine has none. The first call of each of the three functions a lookup uses
  answers with success (`dlls/wintrust/crypt.c`).

They get the game past a check of its own. Prefix setting "Start-up workarounds for Honkai:
Star Rail", on by default; off sends `FINEWINE_STARRAIL_WORKAROUNDS=0`. `=1` turns them on for
any program, which is how the test asks for them.

DXMT also reports the same GPU to `StarRail.exe` as to Genshin Impact and Zenless Zone Zero
(an AMD Radeon Pro 5300M; `patches/dxmt/0009`). The game had been told "Apple M5" with vendor
and device id 0. Its engine got past device creation with that, so this is not known to matter.

- **Tested:** `tests/runtime/starrail-start.c`, x64 and 32-bit: on for `StarRail.exe` and when
  asked for, off for another program and when switched off; the made-up catalogue handle is
  accepted by the two other functions and nothing follows it.
- **Not tested:** the game. It is not on the development Mac. Whether the two are enough on
  macOS, where the game runs through an emulator as well, is not known.
- **Looked for and not found in DWProton:** anything else for this game. No entry in its table
  of games started as Steam, no launch-script case, no other code naming it.

