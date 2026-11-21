# Behaving like a Mac game: full screen, Game Mode, the Metal HUD, shutting down (2026-11-15)

The aim: a game runs with Metal drawing straight to the display, and macOS still behaves as
it does around a Mac game, so that nothing reminds the user the game was not made for the Mac.

## Full screen

A Windows game goes full screen by making a borderless window the size of the screen. Wine
raises such a window above the menu bar and the Dock. The game then covers everything, the
menu bar can never appear, and macOS does not see a full-screen app at all.

`patches/runtime/0012` adds two other ways to present such a window, chosen per prefix
("Full screen" in the Configuration tab; `FINEWINE_FULLSCREEN` underneath):

| Setting | What happens | Menu bar at the top edge | Swipe to the desktop | Notifications over the game | Mission Control |
|---|---|---|---|---|---|
| Mac full screen (default) | The window gets a full-screen Space of its own, as a Mac game's does | Yes | Yes | Yes | Shown as an app |
| Borderless window | The window stays on the desktop; the menu bar and Dock hide until the pointer reaches the edge | Yes | To other desktops | Yes | A window |
| Exclusive | Wine's own behaviour | No | No | macOS decides | A window |

Details of the default:

- The window enters its Space when it is on screen and covers the display, and leaves it when
  the game makes it smaller again (switching to windowed mode). If the user takes it out
  (green button, Control-Command-F), it stays out until the game resizes it.
- The menu bar appears only if the pointer can get to the top edge. A game that has captured
  the pointer keeps it, exactly as with a Mac game.
- One window per program gets a Space. A second window covering the screen stays put.
- While in a Space a game cannot minimise itself (Wine tells it that it was restored), so a
  game that minimises when it loses focus stays in its Space when you switch away.
- Metal presents directly to the display in a full-screen Space; that is macOS's doing and
  needs nothing from us.

**On a display with a camera housing** a full-screen Space ends below it, as for every Mac
app: 1512x949 of 1512x982 points on a 14-inch MacBook Pro. Zenless Zone Zero (Unity) sized its
window to the whole display and kept it so, while macOS kept the window at the Space's size:
the bottom of the picture was cut off and clicks landed 33 points low. In this mode the
display therefore *is*, for Windows programs, the part below the housing
(`patches/runtime/0025`): it is reported at that height (3024x1898 pixels), and Windows'
screen coordinates start there, so pointer positions agree. A first attempt changed the
reported height alone and made the click offset permanent; the coordinate shift is the part
that matters. `FINEWINE_KEEP_CAMERA_ROWS=1` turns it off. Tested with a full-screen test
window (size, position and pointer agree on both sides); not yet seen with the game.

**A picture smaller than its window is upscaled with MetalFX** (`patches/dxmt/0004`, Direct3D
10 and 11). When a game renders at a lower resolution than its window has display pixels (a
resolution picked in the game, or any program while Retina mode is off), DXMT upscales it to
the window's pixels with MetalFX's spatial scaler instead of leaving the stretch to the
window server. A game whose own upscaler is on already produces a window-sized picture, so
nothing is done to it. `FINEWINE_METALFX_AUTO=0` turns it off.

**Tested** with `tests/runtime/fullscreen.c`, which covers the display, waits, goes windowed
and exits, while a probe read what macOS did: Wine's own mode puts the window at level 26
(above the menu bar), the other two at level 0; in the default mode the active Space is a
full-screen one, and it is the desktop again after the program goes windowed.
`FINEWINE_TEST_FULLSCREEN=1 scripts/test-finewine-runtime.sh` repeats it. It covers the display
for a few seconds, which is why it only runs when asked.

**Not tested:** the menu bar actually appearing, swiping, and notifications. Those follow from
being in a real full-screen Space, but nobody has moved a pointer in one yet. No game has been
run in it, and nothing here was tried with more than one display.

## Game Mode

See [22-performance.md](22-performance.md) for how programs are recognised as games. What
changed on the way to making it work:

- macOS reads "is a game" from the Info.plist of the **app bundle** the executable is in. The
  Info.plist Wine embeds in its loader is not used for this: LaunchServices registered a bare
  loader with no bundle identity at all, and Game Mode stayed off.
- The game loader is therefore a small app bundle beside the plain loader:
  `lib/wine/aarch64-unix/FineWine Game.app` (`scripts/lib/make-game-loader.sh`). The loader
  finds the rest of Wine from inside it (`patches/runtime/0011`).
- **Confirmed:** a program run with it is registered as `org.finewine.game`, and
  `gamepolicyctl game-mode status` reports "Game mode is on" while its window is in a
  full-screen Space.
- **The Dock shows the program's own name.** The Dock labels a program with the name of the
  bundle its executable is in, and ignores the name a process gives itself, so every game was
  "FineWine Game" there. Each program is now started through a bundle of its own name, made in
  its prefix when first needed: `.finewine-apps/game/<name>.app` (or `…/program/…` for the
  plain loader), holding only a link to the loader and the loader's Info.plist under that name
  (`patches/runtime/0024`). Game Mode still turns on for a game run this way (tested). The
  folders are small and can be deleted; they come back.

## The Metal HUD

`patches/runtime/0012` adds a **View** menu to every Wine program's menu bar with
**Show Metal HUD / Hide Metal HUD**, and **Option-F12** does the same from the keyboard.

Metal only has its overlay in a process that was started with `MTL_HUD_ENABLED=1`; in such a
process each Metal layer's `developerHUDProperties` decide whether it is drawn (measured: a
layer shows it with `mode: default` and hides it with `mode: off`, and neither does anything
without the variable). FineWine therefore always starts programs with the overlay available,
and the prefix setting only decides whether it starts out shown (`FINEWINE_METAL_HUD`).

**Not tested:** pressing the key or choosing the menu item in a running game. What is tested
is the Metal behaviour it relies on, natively, and that programs start and render with the
variables set.

## Shutting a prefix down

Two commands, in the prefix's toolbar, its Wine Tools tab and the menu bar popover:

- **Shut Down** does what shutting Windows down does: every program is asked to close and may
  ask to save (`wineboot --shutdown`). FineWine does not wait for it, since a program that has
  frozen will never answer.
- **Force Shut Down** ends everything at once. Wine's server is told to end its processes;
  then whatever is still alive is killed directly. That second step is for the case where the
  server itself is stuck or gone.

Finding "whatever is still alive" needed a change in the runtime. Wine replaces each process's
arguments with its Windows command line, which also hides its environment from `ps`, so a Wine
program cannot be traced to its prefix from outside. Every process now keeps
`<prefix>/.finewine-alive` open (`patches/runtime/0013`), and `lsof` lists who has it open.

**Tested** against a real program stopped in its tracks with SIGSTOP: the marker listed it and
the prefix's other processes, the server's own shutdown ended it, and nothing was left. The
direct-kill step is covered by a unit test with a stand-in process; it has not been needed
against a real stuck server.

## Game Mode's icon (2026-11-17)

The Dock showed a game's own icon, but Game Mode's menu bar item and notice showed a blank app
icon. The Dock takes the icon the running program gives it (patch 0030); Game Mode, like other
system screens, reads the icon from the app bundle on disk, and the bundles programs start from
(`.finewine-apps/<game|program>/<name>.app`, patch 0024) had none. Patch 0032 writes the same
picture into that bundle as `Contents/Resources/AppIcon.icns` (16 to 1024 pixels), names it in
`CFBundleIconFile`, and re-registers the bundle with LaunchServices. It is only rewritten when
the icon changes. On a game's first launch with this, Game Mode can switch on before the icon
is written; from the next launch on it is already there. `FINEWINE_BUNDLE_ICONS=0` turns it off.
Checked by `scripts/test-finewine-runtime.sh`; not yet seen in Game Mode's own menu.

## Game Mode for games started by a launcher (2026-11-18)

Genshin Impact started from FineWine's "HoYoPlay" entry ran without Game Mode: HoYoPlay's
`launcher.exe` imports no rendering API, and the "this program rendered" marker is only created
once the game draws, too late for that launch, since macOS decides whether an app is a game when
it starts and the game inherits its launcher's loader. The "Genshin Impact" entry for the same
`launcher.exe` already had a marker, but markers were only looked up per entry.

A program is now started as a game also when another entry for the same executable has a marker,
and always when it is a HoYoverse game or HoYoPlay (the programs the Steam stand-in recognises),
so their first launch is in Game Mode too. Tested by `GameModeLaunchTests`.

## A game that sets its own display mode (2026-11-21)

Older games, and every Direct3D 9 game in "exclusive" full screen, set a display mode of
their own choice: Portal asks for 960x600. Until runtime patch 0047 that changed the Mac's
real mode even with full screen in a Space: every other window on the Mac was resized, macOS
lost the display for the duration, the game's picture sat in a corner, and putting the mode
back failed afterwards.

In the Space and borderless modes a mode is now only emulated (Wine's `EmulateModeset`). The
program sees the screen it asked for; its picture is brought to the size of the Space, keeping
its shape (a 4:3 mode is centred with bars at the sides):

| Picture drawn with | Brought to size by |
|---|---|
| Direct3D 10/11 (DXMT), Vulkan and Direct3D 12 (MoltenVK) | MetalFX, as for a render size |
| OpenGL, which Direct3D 9 and older are (WineD3D) | Wine's own blit into a surface of the real size |

Two things had to agree with that. The Mac driver gave every OpenGL surface the program's
size, also when Wine scales the picture itself and needs one of the real size. And WineD3D
sized the full-screen window in the program's units instead of real pixels: for a program that
is not DPI aware in a prefix with 192 DPI (a Retina prefix) the window came out twice the size
of the screen the program saw, and the pointer reached a quarter of it.

**Games are run as DPI aware.** Portal does not use Direct3D's exclusive mode: through SDL
it sets the mode and sizes its own window. It does not declare itself DPI aware, and in a
Retina prefix (192 DPI) Wine then tells it a screen half the size of the display modes it is
offered; sized by the mode, its window came out twice the screen. Windows has the same trap
and the same way out ("Override high DPI scaling behaviour: Application"). FineWine does that
for games: `FINEWINE_DPI_AWARE=1`, set for a program that draws with a rendering API itself
and for everything Steam starts (`LaunchPlanner.dpiAwareEnvironment`). A launcher is left
alone: scaling a program that is not DPI aware is what makes desktop programs readable.

**The screen size a DPI aware program is told.** Portal 2 then came up half a screen down
and to the right, with three quarters of its window off the screen. The Mac driver doubled
the size `GetDeviceCaps` reports for the screen in high-resolution mode, which was right when
the size underneath was in Mac points and is wrong now that it is in the program's own units:
a DPI aware program was told 6048x3796, and Portal 2 centres its window by that. The doubling
is gone.

`FINEWINE_EMULATE_MODES=0` goes back to changing the real mode. With "exclusive" chosen as the
prefix's full-screen mode nothing changes: there the Mac's mode is the game's.

Checked with Portal (its main menu fills the Space at 3024x1898, seen in a capture of its
window) and with `tests/runtime/d3d9-fullscreen.c` (in the test script with
`FINEWINE_TEST_FULLSCREEN=1`). Not checked: a window being resized by hand while a game draws,
and switching away from a game and back.
