# 01 — ACE Anti-Cheat & Arknights: Endfield specifics

> Source area: `ace-internals` (research + adversarial verify). Overall reliability: **high**. Nearly all evidence is Linux/Proton; macOS behavior is inferred unless stated.

## What ACE is

- **ACE = Anti-Cheat Expert**, Tencent Games' anti-cheat. It is a **rebrand of TenProtect ("TP")**, renamed in 2021. `[confidence: high]`
- This lineage is the single most useful fact for the Wine work: the *original* dw-proton patch that makes Endfield launch carried the comment **`/* workaround for tpshell */`** — tying the fix directly to the TenProtect "TPShell." `[confidence: high]` ⚠️ Note: that comment was **removed from current code** (`11.0-7`) when the patch was refactored — see [02](02-dwproton-ace-patches.md). Don't grep live sources for it.
- The Endfield global client historically used **`gsp`** — a custom ACE build protected with **VMProtect** — during beta, then switched to the standard ACE. The shell DLL is `gsp` / `gsp_core.dll`. `[confidence: medium]`
  - ⚠️ **VERIFIER CAUTION:** the specific RE claim that `gsp_core.dll` contains `TPShell` strings in an unobfuscated region is **UNVERIFIABLE** from accessible primary sources. The tpshell link is corroborated *only indirectly* via the patch comment.

## Architecture: kernel driver + user-mode

- ACE ships a real Windows **kernel driver `ACE-BASE.sys`** (aka "ACE-BASE64 NT Driver"), plus other `ACE-*.sys` files, installed under `System32\drivers` (they persist after uninstall). `[confidence: medium]`
  - Concrete identity: `ACE-BASE.sys` v1.0.2202.6217, **CVE-2024-22830** (CWE-284, local privilege escalation to SYSTEM/PPL via unguarded device I/O), signer "High Morale Developments Limited." This CVE is **CONFIRMED** on NVD and independently establishes the kernel-driver + user-mode-orchestrator model.
- **Wine cannot load a real Windows kernel driver.** Therefore:
  - Any ACE title that *hard-requires* the `.sys` driver is a **dead end** under Wine/CrossOver.
  - PCGamingWiki documents that **some** ACE titles ship a **user-mode-only variant** of ACE that runs on **Wine Staging 10.5+**. `[confidence: medium — CONFIRMED via PCGamingWiki]`
- **Endfield launches under dw-proton with no real kernel driver**, which means its live ACE takes the user-mode-capable path — but that user-mode code still calls into `ntoskrnl.exe` kernel APIs that stock Wine leaves unimplemented, and it probes for Wine.

### Process tree (observed under Wine)

Endfield spawns, among others: `QtWebEngineProcess.exe` (Qt WebEngine, Chromium-based), `CefViewWing.exe` (Chromium Embedded Framework), and **`ACE-Service64.exe` / `ACE-Setup64.exe`**. The launcher is `Program Files/GRYPHLINK/Launcher.exe`; the game is `Endfield.exe`; a shipping game binary named **`EM-Win64-Shipping.exe`** also appears (this matters — see the int3 gate below). `[confidence: high]`

## What actually makes it launch under Wine

GE-Proton's maintainer identified the fix as dw-proton commit **`b816be489049a10453b470c6a12dcf552ea41773`**, described as "4 misc patches imported from upstream wine" (GE issue #433). Full patch-level detail is in [02-dwproton-ace-patches.md](02-dwproton-ace-patches.md). In brief:

1. **int3-stub `GetProcAddress` hack** (`dlls/kernel32/module.c`): return a naked `int3` (`0xCC`) stub for `KiUserApcDispatcher` and `KiUserCallbackDispatcher` (the original patch carried the `/* workaround for tpshell */` comment, since removed). ACE resolves these ntdll dispatcher entry points to install hooks / detect the environment; the int3 stub defuses that. `[confidence: high — CONFIRMED verbatim from patch]`
   - **Guarded by `#ifdef __x86_64__`.** ⚠️ This is the pivotal macOS caveat: the hack only compiles into an **x86_64** Wine build. A native arm64 CrossOver Wine (`wowarm64`) would **not** contain it; an x86_64 Wine under Rosetta 2 **would**.
   - Gated by `needs_int3_hack()`, matching a process whose image name ends in **`Endfield.exe` OR `EM-Win64-Shipping.exe`** (via `wcsicmp`), or force-enabled with **`PROTON_ENABLE_INT3_HACK=1`**.
2. **`ntoskrnl.exe` backports** (the "em-backports" set): implement/stub the kernel functions ACE calls (full list in [02](02-dwproton-ace-patches.md)). `[confidence: high — CONFIRMED against patch filenames]`
3. **`NtDelayExecution` QPC reimplementation** (`dlls/ntdll/unix/sync.c`): relative (negative) waits computed via `NtQueryPerformanceCounter`, a single `NtYieldExecution`, then busy-`select()` until QPC reaches the target. Commit message: "Some applications are very timing sensitive." `[confidence: high — CONFIRMED verbatim]`
4. The "fourth" patch in `b816` was a **wintrust signature-check bypass** (`wintrust-Prevent-checking-if-winex11-winewayland-are-signed`). ⚠️ It was **real but has since been removed** from the tree, and is **macOS-irrelevant** anyway (it targets `winex11.drv`/`winewayland.drv`; CrossOver uses `winemac.drv`). It was dw-proton's *only* detection-evasion patch, and dw-proton dropped it. See [02](02-dwproton-ace-patches.md) for the full history and the definitive current-tree inventory.

## Endfield timeline of breakage (why this is a moving target)

- A **late-January-2026 Endfield update** changed ACE behavior and broke the game on **GE-Proton** and stock proton-experimental, while it **kept working on dw-proton** (which carries the anti-cheat patches; GE does not). `[confidence: medium — CONFIRMED in #433]`
- One GE-Proton-10-29/10-30 user reported `unimplemented function msimg32.dll.AlphaBlend`.
  - ⚠️ **VERIFIER CAUTION:** the ace-internals research called this "likely a separate GE-only regression, not the core anti-cheat blocker," but this is an **inference, not established**. In #433 the AlphaBlend abort *is* the actual error some users hit. It may be a co-occurring missing-function issue rather than clearly separate. **This ambiguity is why capturing the real macOS failure signature is experiment #1.**

## What is confirmed vs. unknown

**Confirmed:**
- ACE = rebranded TenProtect; the fix ties to "tpshell." (both CONFIRMED)
- The int3 hack, its two spoofed exports, the `#ifdef __x86_64__` guard, the process-name gate (incl. `EM-Win64-Shipping.exe`), and `PROTON_ENABLE_INT3_HACK=1`. (CONFIRMED)
- The `NtDelayExecution` QPC patch. (CONFIRMED)
- The em-backports ntoskrnl function list. (CONFIRMED against filenames)
- `ACE-BASE.sys` / CVE-2024-22830 / the user-mode-only variant on Wine Staging 10.5+. (CONFIRMED)

**Unknown / caution:**
- ⚠️ **Which exact `ntoskrnl.exe` function** (if any) aborts first for Endfield on stock Wine/CrossOver — the only documented Endfield abort is `msimg32.dll.AlphaBlend`, not ntoskrnl.
- Whether Endfield's live build requires `ACE-BASE.sys` on native Windows and silently falls back to user-mode when it's absent (behavior implies yes, but unconfirmed from ACE source).
- Whether Endfield ships specific SGuard/`sysdiag` user-mode components.
- ⚠️ **Whether any of this ports to macOS/Apple Silicon at all** — every source is Linux/Proton/Wine; the `#ifdef __x86_64__` guard is a concrete reason a native arm64 CrossOver build would differ.

## Key identifiers (for grepping / RE)

```
Anti-cheat:      ACE (Anti-Cheat Expert) = rebranded TenProtect / "TP" / "tpshell"
Kernel driver:   ACE-BASE.sys  (ACE-BASE64 NT Driver, CVE-2024-22830, v1.0.2202.6217)
User-mode procs: ACE-Service64.exe, ACE-Setup64.exe
Endfield shell:  gsp / gsp_core.dll  (VMProtect-obfuscated)
Launcher:        Program Files/GRYPHLINK/Launcher.exe   (Gryphline / Gryphlink)
Game process:    Endfield.exe   (and EM-Win64-Shipping.exe)
Distributor:     endfield.gryphline.com
Fix commit:      dwproton b816be489049a10453b470c6a12dcf552ea41773
Failure string:  "wine: Call from <addr> to unimplemented function ntoskrnl.exe.<name>, aborting"
                 (Endfield-specific documented abort: msimg32.dll.AlphaBlend)
WineHQ bug:      59411  "Endfield crashes on unimplemented function ntoskrnl.exe" (body behind Anubis wall)
```

## Primary sources
- GE-Proton issue #433 — <https://github.com/GloriousEggroll/proton-ge-custom/issues/433>
- dw-proton fix commit — <https://dawn.wine/dawn-winery/dwproton/commit/b816be489049a10453b470c6a12dcf552ea41773.patch>
- PCGamingWiki: Anti-Cheat Expert — <https://www.pcgamingwiki.com/wiki/Anti-Cheat_Expert>
- PCGamingWiki: Arknights: Endfield — <https://www.pcgamingwiki.com/wiki/Arknights:_Endfield>
- CVE-2024-22830 — <https://nvd.nist.gov/vuln/detail/CVE-2024-22830>
- AreWeAntiCheatYet #1905 — <https://github.com/AreWeAntiCheatYet/AreWeAntiCheatYet/issues/1905>
- rhea.dev Endfield-on-Linux writeup — <https://rhea.dev/articles/2026-01/windows-games-on-linux-endfield>
