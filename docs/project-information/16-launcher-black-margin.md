# 16 — The black margin around the Gryphline launcher

> **Status: fixed by `patches/stage1-macos/0009`, tested on one machine (Nov 2026).** The launcher's
> rounded window used to sit inside a square black box. It now has real transparent corners and
> its soft shadow, and the game still starts from it and stays opaque.

## Cause

`Games.exe` is a Qt window whose rounded shape and shadow are drawn inside a transparent margin.
Qt calls `DwmEnableBlurBehindWindow` and leaves the compositing to DWM, which Wine stubs. On macOS
three separate things then force the window opaque:

| Layer | Code | Stock behaviour |
|---|---|---|
| Window | `macdrv_SetLayeredWindowAttributes` | `UpdateLayeredWindow` enables per-pixel alpha, then Qt's first `SetLayeredWindowAttributes` call disables it for good |
| Metal view | `WineMetalView` | Always opaque, with a black layer background |
| Window surface | `updateLayer` | Opaque image drawn behind the Metal view |

The launcher's main window presents through D3DMetal. A separate small WGL window only appears for
a moment at startup.

## Why dwproton's patch doesn't port

dwproton's fix ([`50182fc3f58c`](https://dawn.wine/dawn-winery/wine-dwproton/commit/50182fc3f58c))
gives the window an ARGB X11 visual in `winex11`. macOS uses `winemac`, so only the idea and the
path check carry over.

## The patch

All of it is gated on `launcher_alpha`, set once per process from the image path: under
`\GRYPHLINK\` but not `\GRYPHLINK\games\` (plus the Epic install path dwproton uses).

- Layered windows keep per-pixel alpha across `SetLayeredWindowAttributes`.
- `WineMetalView` and its layer are non-opaque with a clear background.
- `WineMetalLayer` refuses `setOpaque:YES`, in case D3DMetal sets it.
- The window surface isn't drawn once a Metal view exists anywhere below the content view. The
  check must walk descendants: D3DMetal attaches the Metal view to the child client view, not the
  window's content view.

## Measurements

Captured with `screencapture -o -l <window id>`, so overlapping windows don't affect the numbers.

| Build | Corner RGBA | Fully transparent | Partly transparent |
|---|---|---|---|
| Stock `winemac.so` | `(0,0,0,255)` | 0% | 0% |
| Patched, checking only the content view (bug) | `(255,255,255,255)` | 0% | 0% |
| Patched | `(0,0,0,0)` | 6.9% | 5.6% |

The middle row showed that D3DMetal passes alpha through: one shadow pixel read 64 over black and
228 over white.

Started from the patched launcher, the game ran and its window measured 100% opaque.

## Testing notes

- **Test copies must live in `/Applications`.** A byte-identical copy of the patched app run from
  `build/` or the scratchpad aborted (`EXCEPTION_WINE_ASSERTION`) as `nvngx.dll` loaded in
  `Games.exe`, even with stock `winemac.so`. The cause is unknown.
- **Running a copy rewrites the bottle's registry.** Font paths in `user.reg` and `system.reg` follow
  the app path, so back them up first.
- **`CX_LOG` replaces `WINEDEBUG`.** Use `CX_DEBUGMSG` to choose debug channels.
- **A build of `winemac.so` lacks the stock `lib64` rpath.** The scripts add it.

## Not yet tested

Dragging, resizing, minimising, the launcher's settings dialogs, and machines other than the one
this was developed on.
