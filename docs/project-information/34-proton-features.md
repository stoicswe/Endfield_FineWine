# What was taken over from Proton

Status on 2026-11-23: **in progress.** This page lists what Proton has that FineWine now has,
what it has that cannot work on a Mac, and what is still to do.

## Can a game be told it is on Proton?

No, because Proton has no name of its own that a game asks for. A game finds out where it runs
in one of four ways:

| How | What Proton does | FineWine |
|---|---|---|
| The Steam client | Its `steam.exe` helper and `lsteamclient` connect the game to the real Steam client | The Steam bridge does the same with the Mac's Steam client ([`runtime-extras/steam-bridge`](../../runtime-extras/steam-bridge)); a stand-in covers games not started by Steam (page 24) |
| Environment variables | `SteamGameId`, `SteamAppId`, `STEAM_COMPAT_*` | Passed on from Steam for games Steam starts |
| Looking for Wine | Nothing by default; a per-program option hides Wine's functions | Prefix setting "Hide Wine from programs" (below) |
| Anti-cheat | Easy Anti-Cheat and BattlEye ship Linux libraries that Proton loads | **Not possible.** Those are Linux programs that talk to the Linux kernel |

So "works on Proton" mostly means "works on Wine with Proton's fixes", and the way there is
to have the fixes. A game whose anti-cheat needs Proton's runtime will not run, whatever it is
told.

## Compatibility switches (runtime patch 0058)

Switches for programs that depend on a detail of Windows or of the machine. They are read
from the environment under the names Proton uses, so a setting known to help a game on Proton
can be put in a prefix's or a program's variables as it is.

| Variable | What it does |
|---|---|
| `WINE_HEAP_DELAY_FREE=1` | Freed memory is kept for a while before it is reused, for programs that read memory they have just freed |
| `WINE_HEAP_ZERO_MEMORY=1` | Memory is handed out zeroed, for programs that read memory they never wrote |
| `WINE_HEAP_TOP_DOWN=1` | Heaps are placed from the top of the address space down |
| `WINE_CPU_TOPOLOGY=n` | No more than n processors are reported. Proton also pins the program to chosen processors; macOS has no way to do that, so only the count is used |
| `WINE_RAM_REPORTING_BIAS=n` | n megabytes less memory is reported than there is |
| `WINE_DISABLE_SFN=1` | Files have no 8.3 short names |
| `WINE_BLOCK_HOSTS=a;b` | Host names under `a` or `b` are not found |
| `FINEWINE_HIDE_WINE_EXPORTS=1` | Programs do not find `wine_get_version` and its two siblings in ntdll. Prefix setting "Hide Wine from programs", off by default |

Not taken over: `WINE_SIMULATE_WRITECOPY` (it builds on Proton's tracking of write-copy pages,
which this Wine does not have), `WINE_LARGE_ADDRESS_AWARE` (32-bit programs here already have
the whole 4 GB), and the switches for Linux's synchronisation, window system and NVIDIA
libraries.

Tested by `tests/runtime/compat-switches.c` for ARM64, x64 and 32-bit programs, with the
switches and without.

## Known fixes for games (the app)

Proton's launch script has a table of games that need one of the switches. FineWine has the
same table (`GameFixes.swift`) and applies it by itself when it knows the game's Steam app id:

- for a game Steam started, the id Steam gave;
- otherwise from a `steam_appid.txt` beside the program or up to two folders above, or from
  the Steam library the game is installed in.

What the table holds: 8 games with delayed heap free, 3 with zeroed heap memory, 2 with
top-down heaps, 19 with a processor limit, 56 whose OpenSSL must not use the processor's SHA
instructions, and 8 that need their own copy of a system library used first.

A prefix's or a program's own variables override the table. Prefix setting "Known fixes for
games", on by default.

## The processor count (FEX patch 0015)

Found while testing the processor limit: x64 and 32-bit programs were told of one processor
more than the Mac has (9 on an 8-core Mac). FEX replaced Wine's count with its own plus one.
Programs that pin a thread to the last processor asked for one that does not exist. Fixed;
the count is now Wine's, so it also follows `WINE_CPU_TOPOLOGY`.

## The Steam helper

Proton starts every game through a helper named `steam.exe`. FineWine has two:

- **For games Steam starts**, a port of Proton's helper (in the Steam bridge). It was an older
  version; it now also sets the flag that stops Xbox Game Studios titles running
  `GamingRepair.exe` (about 20 seconds, and it cannot succeed), puts back the EA app's folder
  link when the EA updater left it missing, and gives the game `SteamPath` and
  `ValvePlatformMutex`.
- **For games not started by Steam**, the stand-in (page 24). It now also writes Steam's list of
  game libraries, sets the same `GamingRepair` flag for a numeric id, and answers the
  start-up handshake of programs wrapped in Steam's own copy protection.

## Not possible on a Mac

- Easy Anti-Cheat's and BattlEye's Proton runtimes.
- Proton's synchronisation (fsync, ntsync): Linux kernel features. FineWine has MSync.
- The full-screen and FSR hack: tied to Linux's window system. FineWine has MetalFX upscaling.
- Virtual reality (OpenVR, OpenXR).
- DXVK and vkd3d-proton for Direct3D 10 to 12: FineWine uses DXMT and MoltenVK.

## Single-game cases (runtime patch 0059)

Proton's Wine does something different for one game in about forty places, told by the Steam
app id. Twelve of them, for thirteen games, do not depend on Linux and are now in FineWine's
Wine, each a few lines beside the code it changes:

| Game (Steam app id) | What is different for it |
|---|---|
| VRChat (438100) | Sending on a UDP socket succeeds when the network is unreachable, as on Windows |
| Far Cry 4 (298110), The Witcher 3 (292030) | No new search for controllers on every call about one that is not there |
| TouHou Makuka Sai (882710, 1031480) | GDI+ measures a lone line break as a space |
| 1416260 | Direct2D ignores the text rendering parameters it sets |
| Skyrim Special Edition (489830) | The game and its launcher start DPI aware |
| 1364780 | Cryptographic key containers are not kept between runs |
| 2767030 | Its launcher page has queued messages dispatched before a navigation |
| 3600700 | DirectDraw's gamma ramp is ignored |
| STAR WARS Starfighter (32350) | Direct3D 8 reports multisampling as unavailable |
| Guilty Gear XX Accent Core Plus R (348550) | A change in what the "application activated" message names |
| 563560 | Fonts are not hinted |
| 39210 | Its launcher page gets the newest document mode |

Left out: the cases for Linux's window systems and Proton's full-screen hack, the OpenGL
ones (they are about Linux's drivers), the ones in parts FineWine does not have, and three
that reach deeper than a few lines (Darksiders' audio buffers, .NET assembly search, a fake
network adapter for Forza Horizon 4).

None of these games was run. One case is checked by a test with its id and without
(`tests/runtime/game-cases.c`); the rest were compiled and read against Proton's code.

## Controllers (SDL2)

Proton reads controllers through SDL2. Wine then shows each one to Windows programs in one
standard layout, so a PlayStation or a Switch controller works in a game that only knows the
Xbox one. FineWine's runtime was built without SDL2 and read controllers through macOS's own
HID support, each in its own layout.

The runtime now includes SDL2 2.32.10, built from libsdl.org's source with only its controller
parts (no video, audio or rendering; 1.2 MB), for the same oldest macOS as the rest. Wine's
controller service starts on it.

- **Checked:** the library is in the runtime, Wine finds it, and its controller service runs on
  it; the full test suite passes with it.
- **Not checked:** an actual controller. None was connected when this was done.
- **Not taken over:** Proton's Steam Input handling, which is about the virtual controllers the
  Linux Steam client makes.

## Media playback (GStreamer, runtime patch 0060)

Proton's video and audio support runs on GStreamer with FFmpeg. FineWine's runtime had no
GStreamer at all, so Media Foundation and DirectShow could open nothing.

The runtime now includes GStreamer 1.24.4 and GLib 2.78, built from the sources in CrossOver's
archive, with **macOS's own decoders** in place of FFmpeg (GStreamer's applemedia plugin, on
VideoToolbox and AudioToolbox). Only the plugins playback needs are built: about 30 plugins,
5.6 MB, plus the libraries.

| Plays | Does not play |
|---|---|
| H.264 and HEVC video, AAC and MP3 audio, PCM | WMV and WMA, Bink, VP8/VP9, Theora, Vorbis: macOS has no decoder for them, and FFmpeg is not included |
| MP4/MOV, Matroska, AVI, MPEG-TS/PS, FLV, WAV containers | ASF (the WMV container) |

Many older games ship WMV or Bink video, so this is a first step, not Proton's coverage.
Adding FFmpeg (through GStreamer's libav plugin) is what would close the gap; it is a large
build and a licensing choice, and was not done.

Wine is told where the runtime's plugins are by itself (patch 0060), so no variable has to be
set, and a GStreamer the Mac happens to have is not mixed in.

- **Checked:** `tests/runtime/media.c` opens an MP4 with H.264 video and AAC audio through
  Media Foundation's source reader and gets a decoded 320x240 frame and decoded sound, as an
  ARM64 and as an x64 program; and an AAC file alone.
- **Not checked:** a game's video, DirectShow, 32-bit programs, HEVC, long files, seeking.

Three small sources GLib needs are not in CrossOver's archive and are fetched when the
dependencies are built: PCRE2 10.42, proxy-libintl 0.4 and gvdb, each pinned in GLib's own
build files.

## Still to do

- FFmpeg-backed formats (WMV, WMA, Bink, VP9) for media playback.
- A controller test with real hardware.
- The three single-game cases that reach deeper (Darksiders' audio, .NET assembly search, a
  fake network adapter for Forza Horizon 4).
