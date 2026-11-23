# The Mac's open and save panels for Windows programs

Status on 2026-11-23: **built into the runtime (patch 0056), on by default, with a prefix
setting to turn it off.** Every path through it is tested by a program that is given the
panel's answer; choosing in a panel by hand had not been tried when this was written.

## What it does

A Windows program that asks for a file or a folder used to get Wine's own dialog. It shows the
Mac's disk as drive `Z:`, has no Finder sidebar, does not name external drives, and knows
nothing of iCloud or of search. Now the program's request is shown as the Mac's own
`NSOpenPanel` or `NSSavePanel`, and the program is handed Windows paths for what was chosen.

The path of what was chosen is converted by Wine's own `wine_get_dos_file_name`: through a
drive letter that reaches the folder when the prefix has one (`C:\…` for a file inside the
prefix, a letter mapped to an external drive), and through `Z:\…` otherwise. The folder a
program asks the dialog to start in goes the other way (`wine_get_unix_file_name`).

## Which dialogs

A program asks in one of three ways, and all three are covered:

| How the program asks | Used by | Where |
|---|---|---|
| The item dialog: `IFileOpenDialog`, `IFileSaveDialog` | Current programs, Qt (HoYoPlay), Electron, .NET | `dlls/comdlg32/itemdlg.c` |
| `GetOpenFileName`, `GetSaveFileName` (A and W) | Older programs and installers | `dlls/comdlg32/filedlg.c` |
| `SHBrowseForFolder` (A and W) | Installers' "choose a folder" | `dlls/shell32/brsfolder.c` |

What goes over to the panel: the title and the button's text; the list of file types, as a
pop-up under the browser, with the one that is selected; the folder to start in; the name to
suggest and the default extension; whether files, folders, one or several can be chosen;
hidden files; "New Folder".

What comes back, besides the paths, is what each API promises its caller: the item dialog's
results, selection, folder, file name and file type index, with `OnTypeChange`,
`OnFolderChange` and `OnFileOk` sent to the program; `OPENFILENAME`'s offsets, file title,
filter index, flags and the "buffer too small" answer; the folder dialog's item list, display
name and icon.

A program can refuse a choice (`OnFileOk` returning a failure, a folder callback that
disables OK). The panel then opens again where it was.

## When Wine's dialog is still shown

- The program put controls of its own into the dialog (`IFileDialogCustomize`, a menu on the
  open button), hooks it (`OFN_ENABLEHOOK`) or gives it a template. A panel has no place for
  those, and a hook has no dialog to hook. MFC programs hook the dialog as a matter of course,
  so they keep Wine's.
- The Windows 3.1 look (`OFN_ALLOWMULTISELECT` without `OFN_EXPLORER`).
- Browsing for a computer or a printer, or below a root that is not a folder on disk.
- The program has captured the displays (a changed display mode, or Wine's
  `CaptureDisplaysForFullscreen` setting): a panel would be behind the game. A full-screen
  window that only covers the menu bar (the "Exclusive" full-screen setting) does get the
  panel, which is put above it.
- The setting is off, or the driver is not the Mac one.

## The setting

Configuration > Appearance > **Mac open and save panels**, on by default
(`PrefixSettings.macFileDialogs`). Off sets `FINEWINE_NATIVE_FILE_DIALOGS=0` for the prefix's
programs. A runtime says it has the panels with the capability `macFileDialogs`
([finewine-runtime-format.md](../finewine-runtime-format.md)).

## How it is built

- **The driver** (`dlls/winemac.drv/cocoa_filepanel.m`) has three calls: show a panel for a
  request, ask whether it has closed and with what, and forget it. The panel runs modally on
  the main thread, started from the run loop: it stays in front of the program's windows and
  they take no clicks meanwhile. The driver's other work on that thread goes on, because its
  request source is in the common run loop modes.
- **comdlg32** (`dlls/comdlg32/macpanel.c`) builds the request, calls the driver's Unix
  library by the handle of `winemac.drv`, and waits while handling the thread's window
  messages, with the owner window disabled as a modal dialog's is. The request is one block
  of memory without pointers and the parameter structs are the same for 32-bit and 64-bit
  programs, so no separate 32-bit entry points were needed.
- **shell32** calls comdlg32's function for the folder dialog.
- A hidden Edit menu exists while a panel is open: Wine's menu bar has none, and without one
  the panel's text fields get no Command-V.

## Testing

`tests/runtime/file-dialogs.c`, run by `scripts/test-finewine-runtime.sh` as x64, ARM64 and
32-bit programs. The answer the panel gives is set from outside:

| Variable | Meaning |
|---|---|
| `FINEWINE_FILE_PANEL_ANSWER` | `cancel`, or the Unix paths that were "chosen", one a line. With it no panel is shown. |
| `FINEWINE_FILE_PANEL_ANSWER_FILTER` | The file type that was "selected", counted from 0. |
| `FINEWINE_FILE_PANEL_ANSWER_DELAY` | Show a real panel for this many milliseconds, then give the answer. |

Covered: one and several files, a folder, saving to a file that does not exist, cancelling,
the ANSI functions, a buffer that is too small, a program that refuses the first choice (both
APIs that can), a path inside the prefix and one outside it, the off switch, and with a real
panel on screen an answer after a delay and `IFileDialog::Close` from another thread.

Not covered by a test, and to be tried by hand: choosing with the mouse, changing the file
type in the pop-up (an open panel should then grey out other files), typing a name into a
save panel and having the extension added, Command-V in the name field, a panel over a
full-screen Space, and a real program that uses each API (HoYoPlay's "locate game" is the
item dialog picking a folder).

## Why

Issue 128: a launcher that crashed when a second installed game was located. Where it crashed
was not known when this was built; if it was inside Wine's dialog, this takes that dialog out
of the path. Apart from that, finding a game on an external drive through `Z:\Volumes\…` in a
Windows tree view was the least Mac-like step left in installing one.
