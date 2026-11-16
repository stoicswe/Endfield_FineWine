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
app. Here that is 1512x949 of 1512x982 points. The game is told its window is that size. A
game that insists on the full height will be told otherwise by macOS; this was stable in the
test and has not been tried with a real game.

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
