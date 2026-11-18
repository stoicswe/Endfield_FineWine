# Moving prefixes and snapshots

A prefix can be moved between this Mac and any drive FineWine can use (see
[27-prefixes-on-external-drives.md](27-prefixes-on-external-drives.md)). A snapshot saves the
whole prefix, so it can be put back later or brought back after the prefix is deleted.

## Moving

- **Where to find it:** the prefix's right-click menu (**Move To**) and the Details tab (**Move
  To**, next to Show in Finder). The menu lists this Mac and every plugged-in drive that can hold
  prefixes, with its free space. A drive not used yet is made ready when chosen.
- **What moves:** the prefix folder, under the same folder name and id. Shortcut apps launch by
  id, and logs are kept by folder name, so both keep working. Nothing inside the prefix names its
  own location: Wine's drive letters are relative links (`c:` → `../drive_c`), and the registry
  files were checked for the old path after a move.
- **How:**
  - On the same volume, a move is a rename.
  - Between volumes, the prefix is copied next to where it is going (`.copying-<folder>`), then
    swapped in. The original is deleted only once the copy is complete.
  - A drive without room for the copy plus 200 MB is refused before anything is written.
- **Programs must be closed.** Wine keeps a prefix's registry in memory and writes it out when
  the prefix shuts down. Open programs stop a move (the message names them). Wine's own
  background processes, which linger a few seconds after the last program closes, are ended
  first.
- **Progress and cancelling:** the prefix's header and the status window show the percentage
  and size copied. **Cancel** removes the partial copy and leaves the prefix where it was.

## Snapshots

- **Where to find them:** the **Snapshots** card in the Details tab (take, restore, restore as a
  new prefix, show in Finder, delete) and **Take Snapshot** in the right-click menu (no note,
  next to the prefix). Settings → Snapshots lists the snapshots of deleted prefixes, which can be
  restored as new prefixes.
- **Layout:** `<FineWine>/Snapshots/<prefix folder>/<yyyy-MM-dd HH.mm.ss>/`, holding
  `snapshot.json` (id, prefix id and name, note, date, size) and `Prefix/` (the copy).
  `<FineWine>` is `~/Library/Application Support/FineWine` on this Mac, or `FineWine` at the top
  of a drive, next to `Prefixes`.
- **Where to keep one:**
  - **Next to the prefix:** on APFS the copy is a clone. It is made at once and takes space only
    as the prefix changes afterwards. In a test, a 400 MB file took 4 KB.
  - **On another drive:** a full copy. It takes as much space as the prefix, and survives if the
    prefix's drive fails. This is the one that works as a backup.
- **Restore** puts the prefix's files, settings and programs back as they were. The prefix keeps
  its current name, id and place.
  - By default the current state is saved as a snapshot first ("Before restoring"), so a restore
    can be undone. The tick box in the confirmation turns that off.
  - Shortcut apps follow the programs: a program that comes back keeps its shortcut, and the
    shortcut of a program that is gone is removed.
- **Restore as New Prefix** makes a new prefix next to the snapshot, with its own id and no
  shortcuts. It works for any snapshot, including one whose prefix was deleted.
- **Snapshots stay when their prefix is deleted.** Deleting a snapshot is the only way they go.
- **A snapshot on an unplugged drive** isn't listed until the drive is back.

## Copying a prefix safely

`FolderCopy` (in `FineWineCore`) does the copying for moves, snapshots and restores:

- **Symbolic links are copied as links, never followed.** `dosdevices/z:` points at `/`; following
  it would copy the whole Mac.
- **Each file is copied with `copyfile(COPYFILE_CLONE | COPYFILE_ALL)`:** a clone where the file
  system allows it, otherwise a copy of the data with its permissions, dates and extended
  attributes.
- **Progress** is counted per file and inside large files, from `COPYFILE_STATE_COPIED`. A cancel
  is checked between files and inside large ones.

## Interrupted work

A swap puts the old folder aside as `.leaving-<folder>` while the copy is renamed in. This
covers moves, restores and restoring as new. If FineWine stops part way (it quits, the Mac loses
power, a drive is pulled), the next refresh puts things right:

- A `.copying-` folder is always incomplete and is deleted.
- A `.leaving-` folder is renamed back if its prefix isn't anywhere else. Otherwise it is deleted.
- Hidden folders are never listed as prefixes or snapshots.
- The clean-up skips itself while a move, snapshot or restore is running in the app.

## Testing

- **Unit tests** (`PrefixMoveSnapshotTests`, with stand-in drives) cover:
  - links kept as links;
  - progress reaching the total;
  - a cancel leaving nothing behind;
  - moving to a drive and back;
  - refusals for low space, an unplugged drive and the same place;
  - snapshot and restore, keeping the current name;
  - a snapshot on another drive outliving its prefix, and restoring it as new;
  - two snapshots in one second;
  - a full drive;
  - deletes refused outside FineWine's folders;
  - recovery after an interruption;
  - running programs stopping the work;
  - shortcuts after a restore.
- **A real APFS volume** with `RealDriveCycleTests`, phase `copies` (`FINEWINE_TEST_EXE` is an
  x64 program printing "hello from x64", built from `tests/runtime/x64-hello.c`). On an 800 MB
  prefix, the program ran after every step:
  - moving from the drive to this Mac took 3.1 s;
  - a clone snapshot took 1.3 s, and a snapshot copied onto the drive took 2.6 s;
  - restoring from the drive took 2.6 s;
  - moving back took 2.7 s.

  Nothing was left over on either side, and the drive's used space returned to what it was.

## Not checked

- **The new screens** (Move To, the Snapshots card and sheet, Settings → Snapshots, the progress
  bar with Cancel) haven't been looked at on screen.
- **A slow USB drive:** the timings above were on a disk image on the internal SSD.
- **Pulling a drive in the middle of a copy.**
