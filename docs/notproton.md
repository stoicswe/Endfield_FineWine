# NotProton Integration

How to use **Arknights: Endfield** through Steam on macOS using **NotProton** and the **FineWine-patched CrossOver**.

---

## Overview

[NotProton](https://github.com/NotProtonNot/NotProton) is an open-source project that enables Steam Play (Proton-style compatibility tools) on macOS by wrapping CodeWeavers CrossOver as a Steam compatibility tool.

FineWine integrates directly into NotProton's runner system:
- **Steam Play Compatibility**: Exposes the FineWine-patched CrossOver as a dedicated compatibility tool inside Steam (`CrossOver 26.3 - Endfield FineWine - Rosetta`).
- **Complete Isolation**: The standalone workflow (`CrossOver_Endfield_Patch.app`, `scripts/launch-endfield.sh`, and the FineWine Patcher app's Automated Setup) remains 100% intact and unaffected.
- **Per-Game Selection**: Only games you explicitly select in Steam use the FineWine runner; other Windows games in Steam can continue using stock NotProton CrossOver builds.

---

## Requirements

| Component | Requirement | Notes |
|---|---|---|
| **Mac** | Apple Silicon (M-series) | M1/M2/M3/M4, 16 GB+ recommended |
| **macOS** | 15 (Sequoia) or newer | Tested on macOS 26.5 & 27.0 |
| **Rosetta 2** | Installed & active | `softwareupdate --install-rosetta --agree-to-license` |
| **Patched CrossOver** | CrossOver 26.3 with FineWine patches | Built via `scripts/swap-into-crossover.sh` or Patcher app |
| **Steam for macOS** | Installed | Default path `~/Library/Application Support/Steam` |
| **NotProton** | Installed | Default path `~/Library/Application Support/notproton` |

---

## 1. Quick Start: Register FineWine in NotProton

Run the registration script from the repository root:

```bash
./scripts/notproton-register.sh
```

The script will automatically:
1. Locate your patched CrossOver app (`/Applications/CrossOver_Endfield_Patch.app` or via bundle ID `com.codeweavers.CrossOvEF`).
2. Verify all anti-cheat modules are present (`ntdll.so`, `kernel32.dll`, `ntoskrnl.exe`).
3. Stage the runner into NotProton's directory:
   `~/Library/Application Support/notproton/runners/crossover-finewine-26.3/CrossOver`
4. Create the Steam compatibility tool entry in:
   `~/Library/Application Support/Steam/compatibilitytools.d/notproton-finewine-rosetta/`
5. Configure `toolmanifest.vdf`, `compatibilitytool.vdf`, and the launch bridge script.
6. Write optimal defaults for Endfield (`D3DMetal`, `MetalFX`, `MSync`, `ROSETTA_ADVERTISE_AVX=1`).

### Custom Registration Options

If you have custom paths or want a custom display name in Steam:

```bash
# Point to a specific patched CrossOver app
./scripts/notproton-register.sh --app /path/to/CrossOver_Endfield_Patch.app

# Custom Steam display name
./scripts/notproton-register.sh --display-name "Endfield FineWine (Custom)"

# Specify custom Steam or NotProton directories
./scripts/notproton-register.sh --steam-root "$HOME/Steam" --np-support "$HOME/notproton"

# View all options
./scripts/notproton-register.sh --help
```

---

## 2. Configure Steam

1. **Restart Steam**: Quit Steam completely (`⌘Q`) and relaunch it so it re-scans `compatibilitytools.d`.
2. **Select Compatibility Tool**:
   - In your Steam Library, right-click **Arknights: Endfield** (or your Non-Steam Game shortcut).
   - Click **Properties…** → **Compatibility**.
   - Check **"Force the use of a specific Steam Play compatibility tool"**.
   - From the dropdown, select **CrossOver 26.3 - Endfield FineWine - Rosetta**.
3. **Set Launch Options**:
   - In the game's **Properties…** → **General** tab.
   - Under **Launch Options**, enter:
     ```
     -force-d3d11
     ```
   - *Why*: The game defaults to DirectX 12, which does not currently initialize under the macOS D3DMetal/Wine translation layer. `-force-d3d11` selects the DirectX 11 backend, which translates cleanly via D3DMetal with Apple Silicon GPU acceleration.
4. **Launch**: Click **Play** in Steam.

---

## 3. How It Works Under the Hood

```
Steam Game Launch
      │
      ▼
~/Library/Application Support/Steam/compatibilitytools.d/notproton-finewine-rosetta/run
      │
      ├─► Sets CX_ROOT to ~/Library/Application Support/notproton/runners/crossover-finewine-26.3/CrossOver
      ├─► Configures WINEPREFIX: ~/Library/Application Support/Steam/steamapps/compatdata/<AppID>/pfx
      ├─► Exports Endfield graphics & sync settings (D3DMetal, MetalFX, MSync, Rosetta AVX)
      │
      ▼
FineWine-patched CrossOver Wine (x86_64 under Rosetta 2)
      │
      ├─► lib/wine/x86_64-unix/ntdll.so       (Rosetta signal fixes & NtDelayExecution QPC timing)
      ├─► lib/wine/x86_64-windows/kernel32.dll (KiUser*Dispatcher int3 spoof)
      ├─► lib/wine/x86_64-windows/ntoskrnl.exe (ACE kernel service stubs)
      │
      ▼
Arknights: Endfield (ACE Anti-Cheat & Game Engine initialized successfully)
```

### Wine Prefix Location
Under Steam Play / NotProton, each game maintains its isolated Wine prefix:
```
~/Library/Application Support/Steam/steamapps/compatdata/<AppID>/pfx/
```
The game's save data, cache, and Windows registry live inside this prefix under `drive_c/users/steamuser/`.

### Logging & Diagnostics
When launched via Steam, a launch and diagnostic log is written to:
```
~/Library/Application Support/Steam/steamapps/compatdata/<AppID>/finewine-run.log
```
Check this file if the game fails to start or exits prematurely.

---

## 4. Anti-Cheat & Steam Overlay / `lsteamclient`

- **Anti-Cheat Support**: FineWine's patches specifically resolve the Anti-Cheat Expert (ACE) initialization fault (memory protection page-fault loops and timer-resolution checks under Rosetta 2).
- **Steam Overlay**: NotProton includes an optional `ntdll-patch` binary patcher that modifies CrossOver's stock `ntdll.so` to load `lsteamclient.dll` (which powers the Steam in-game overlay and achievements). Because FineWine's `ntdll.so` is rebuilt from source with our custom signal and timing modifications, byte patterns in NotProton's stock binary patcher may not match.
  - If the patch cannot be applied, `scripts/notproton-register.sh` will issue a warning and continue.
  - The game itself launches, connects online, and plays with full performance; only the Steam in-game overlay (`Shift+Tab`) is unavailable.

---

## 5. Architecture: ARM vs. x86_64 (Rosetta vs. FEX)

A frequent question is whether Endfield FineWine can run under native ARM or FEX translation:

- **Current State (x86_64 + Rosetta 2)**:
  - Arknights: Endfield ships as an x86_64 PE32+ Windows binary.
  - The ACE anti-cheat protector inspects CPUID, low-level instruction pointers, and register context during signal/exception handling.
  - Our `ntdll.so` patch directly fixes the Rosetta 2 kernel-signal context (`ucontext_t` Rosetta register translation for `RCX` and `R10`).
  - Therefore, the runner is configured with `FLAVOR=rosetta` and uses CrossOver's x86_64 Wine loader.
- **ARM64 / FEX Status**:
  - Running under FEX or experimental ARM Wine creates different CPU context structures and signal delivery semantics that trigger ACE protector faults.
  - ARM/FEX support is undergoing separate research and testing. Use the default `rosetta` flavor for stable gameplay.

---

## 6. Unregistering / Removing the Integration

If you ever wish to remove the FineWine compatibility tool from Steam:

```bash
./scripts/notproton-register.sh --unregister
```

This safely removes:
- `~/Library/Application Support/Steam/compatibilitytools.d/notproton-finewine-rosetta`
- `~/Library/Application Support/notproton/runners/crossover-finewine-26.3`
- The entry from NotProton's `tools` manifest

Restart Steam, and the entry will no longer appear in your compatibility dropdown. Your standalone CrossOver installation and game files remain completely unaffected.

---

## 7. Troubleshooting

### The runner does not appear in Steam's Compatibility dropdown
1. Completely quit Steam (`⌘Q`) and reopen it. Steam only enumerates `compatibilitytools.d` on startup.
2. Verify that `~/Library/Application Support/Steam/compatibilitytools.d/notproton-finewine-rosetta/compatibilitytool.vdf` exists and is readable.
3. Check permissions on `~/Library/Application Support/Steam/compatibilitytools.d/notproton-finewine-rosetta/run` (`chmod +x run`).

### Black screen or game crashes on start
1. Verify launch options contain `-force-d3d11` (DirectX 12 is not supported).
2. Check `~/Library/Application Support/Steam/steamapps/compatdata/<AppID>/finewine-run.log` for error messages.
3. If leftover `wineserver` processes exist from a previous crashed run, kill them:
   ```bash
   pkill -9 wineserver || true
   pkill -9 Endfield.exe || true
   ```
4. Verify your patched CrossOver app still has all 3 patched modules:
   ```bash
   ./scripts/notproton-register.sh
   ```
