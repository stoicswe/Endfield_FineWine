# Prefixes on external drives

A FineWine prefix (a Windows environment and everything installed in it) can be kept on an
external drive as well as on the Mac. This page covers where prefixes go, what a drive needs, and
what happens when it is unplugged and plugged back in.

## Where prefixes are

Users choose a **drive**, never a folder (the user's decision, 2026-11-17), so prefixes are
always in one of two predictable places:

| Drive | Folder |
|---|---|
| This Mac (as before) | `~/Library/Application Support/FineWine/Prefixes/<prefix>` |
| Any other drive | `<drive>/FineWine/Prefixes/<prefix>` |

Each prefix is one folder, named after the prefix plus the start of its ID (`Zenless-Zone-Zero-1a2b3c4d`).
`<drive>/FineWine/.finewine-drive.json` is a short note saying what the folder is. It also lets
FineWine recognise a drive that was set up on another Mac.

## Choosing the drive

- **New Prefix** has a **Drive** picker: This Mac, then every drive plugged in that can hold
  prefixes, with its free space. A drive that can't is listed under the picker with the reason.
- **Settings → Drives** sets the drive new prefixes go on by default. It also lists every drive
  FineWine has used: connected or not, free space, number of prefixes, Show in Finder, and
  Forget. When the default drive is unplugged, new prefixes go on this Mac and the setting is
  kept.
- Prefixes FineWine makes for a file opened from Finder go on the default drive too.

Every prefix in the sidebar, the menu bar panel and its Details tab says which drive it is on.

## What a drive needs

- **APFS or Mac OS Extended.** A prefix's drive letters are Unix symbolic links
  (`dosdevices/c: -> ../drive_c`), and Wine relies on Unix permissions. exFAT, FAT and NTFS have
  neither. Network shares are refused too: they are slow and can disappear mid-game. Disk Utility
  can reformat a drive, which erases it.
- **A volume UUID**, which every APFS and Mac OS Extended volume has. FineWine finds a drive by
  it, whatever the drive is called and wherever macOS mounts it (`/Volumes/T7`, `/Volumes/T7 1`).
- **At least 1.5 GB free.** A new prefix is about 755 MB before anything is installed. On a full
  drive Wine fails part way, with errors about missing DLLs and folders it couldn't make that
  never mention space. FineWine checks first and says so.

"Ignore ownership on this volume", which macOS turns on for most external drives, is fine: Wine
sees the files as the user's.

## Unplugged and plugged back in

- FineWine watches for drives being plugged in, ejected and renamed.
- **Plugged back in:** its prefixes reappear on their own, ready to run, and a short status says
  so ("“T7” is connected — Ready to run: …"). A drive with FineWine prefixes that FineWine
  doesn't know yet is remembered too.
- **Unplugged:** its prefixes leave the list. FineWine remembers their names, so they can be
  shown greyed out under "On Drives Not Connected", with the drive to connect.
  Settings → Drives → "Show prefixes on drives that aren't connected" turns that listing on or
  off. It is also in the right-click menu of those entries.
- A shortcut app for a prefix on an unplugged drive says which drive to connect.
- A prefix's name stays taken while its drive is away, so two prefixes can't end up with the same
  name when it comes back.
- **Forget** removes a drive from the list and leaves its prefixes on it. Plugging it in again
  brings them back.

## Checked

- **Unit tests** (`PrefixDriveTests`, with stand-in drives):
  - which file systems are accepted;
  - the folder layout;
  - unplugging, and plugging back in under another mount path;
  - the default falling back to this Mac;
  - forgetting a drive and finding it again;
  - a full drive refused before Wine starts;
  - duplicate and delete staying on the drive.
- **A real APFS volume** (a disk image, mounted with "ignore ownership" like most external
  drives), with `RealDriveCycleTests`:
  - FineWine set the prefix up there through Wine;
  - with the drive ejected, the prefix was remembered and the default fell back to this Mac;
  - with the drive reattached, the prefix was back and ready;
  - an x64 program ran from it under FEX.
- **The size problem** was found on a 600 MB image: the prefix didn't fit.

## Not checked

- **A real USB or Thunderbolt drive**, and ejecting one while a program from it runs. macOS
  refuses to eject a drive with files open, so that should not happen short of pulling the cable.
- **exFAT on a real volume:** creating exFAT images isn't permitted in the environment the tests
  ran in. That a prefix can't live there is Wine's known behaviour (no symbolic links).
- **The new screens** (the Drive picker, Settings → Drives, the not-connected listing) have not
  been looked at on screen.
