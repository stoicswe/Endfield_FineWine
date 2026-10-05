# 05 — Known issues, reports and references

> Everything below was located and read during this research pass (2026-09-20). Each entry says what
> it **proves** rather than just existing. Kagi was used as the search/extract provider.

## 1. XXMI-Launcher / EFMI issue tracker (primary evidence)

| # | Title | State | What it tells us |
|---|---|---|---|
| [#51](https://github.com/SpectrumQT/XXMI-Launcher/issues/51) | `d3d11.dll is missing expected entry point` | closed (dup target) | The canonical Wine symptom. Maintainer: *"it may happen only if your OS serves wrong DLL (i.e. real d3d11.dll) via LoadLibraryExW."* → **the builtin-vs-native module-name collision.** |
| [#76](https://github.com/SpectrumQT/XXMI-Launcher/issues/76) | Launcher crashes with WINE 9.21 and below | closed | Portable launcher needs **WINE 9.22+** — first thing to check if the launcher itself won't start in our bottle. |
| [#87](https://github.com/SpectrumQT/XXMI-Launcher/issues/87) | ZZMI Loading failed (`d3d11.dll is missing expected entry point`) | closed | Same symptom on Arch Linux + Wine Staging 9.22; closed as duplicate of #51. |
| [#304](https://github.com/SpectrumQT/XXMI-Launcher/issues/304) | `[BUG] d3d11.dll is missing expected entry point` | closed | Reporter ran the **portable** launcher under plain Wine. Maintainer: *"XXMI Launcher isn't explicitly targeting Linux platform"* → AGMG Discord for Linux support. |
| [#316](https://github.com/SpectrumQT/XXMI-Launcher/issues/316) | `[BUG] Linux D3D11.dll is missing expected entry point` | closed | Same error launching ZZZ from Steam via plain Wine. |
| [#316-family](https://github.com/SpectrumQT/XXMI-Launcher/issues/304) | (see above) | — | **Conclusion: the #51/#87/#304/#316 cluster is the "Wine serves the wrong d3d11" failure.** |
| [#117](https://github.com/SpectrumQT/XXMI-Launcher/issues/117) | Some issues on M-series Mac | closed | ⭐ **The only macOS data point found.** CrossOver 25.0.0; user set `d3d11,d3dcompiler_47 = n,b`, deleted `nvapi` → mods load, with cosmetic gaps (some faces/outlines missing, JPG/PNG textures fail, some texture-hash mods fail, no outline). Maintainer: *"Mac is not a target platform, and will never be one."* |
| [#325](https://github.com/SpectrumQT/XXMI-Launcher/issues/325) | WWMI mods flatten body mesh on Linux/Proton | open | Root cause: **Wine's incomplete builtin `d3dcompiler_47`**. Fix: `"d3dcompiler_47"="native,builtin"` or `WINEDLLOVERRIDES="d3dcompiler_47=n,b"`. Reporter notes the *launcher already ships the DLL that fixes it*. A follow-up commenter reports the override alone didn't fix it in their Bottles/GE-Proton setup — i.e. treat the override as necessary-not-sufficient. |
| [#288](https://github.com/SpectrumQT/XXMI-Launcher/pull/288) | Swap 3dmloader inject function for a python implementation | merged | The `Inject` path was rewritten in Python (`pyinjector`: `CreateRemoteThread` + `WriteProcessMemory`) — injection is actively maintained. |
| [#343](https://github.com/SpectrumQT/XXMI-Launcher/issues/343) | `[EFMI] Game crash on injection since ~Sept 4 — 0x80000003 in UnityPlayer.dll (ACE detection)` | closed | ⚠️ The ACE risk made concrete. On Windows, after a ~2026-09-04 Endfield update, `3DM-*.dmp` files stopped appearing (3DMigoto never got in) and the game died with a deliberate breakpoint (`AutoVerifierV2`). Maintainer suspects anti-cheat / OS corruption; no other reports in the EFMI userbase at the time. |
| [#304](https://github.com/SpectrumQT/XXMI-Launcher/issues/304) | `[BUG] d3d11.dll is missing expected entry point` | closed | (see #51) |
| [#291](https://github.com/SpectrumQT/XXMI-Launcher/issues/291) | Is there a good way on linux to run WuWa through steam and run xxmi? | closed | Confirms the Steam/Proton + XXMI coexistence question is common. |
| [#207](https://github.com/SpectrumQT/XXMI-Launcher/issues/207) | Crash with Wine-GE | closed | Wine-version sensitivity. |
| [#253](https://github.com/SpectrumQT/XXMI-Launcher/issues/253) | Steam/Proton argument parsing compatibility | closed | Launch-argument plumbing matters when a Proton-style wrapper is in front of the game. |

## 2. Non-XXMI sources that carry the same signal

| Source | What it tells us |
|---|---|
| [sdli1995/dlssg_for_sm86 #81](https://github.com/sdli1995/dlssg_for_sm86/issues/81) (2026-09-10) | *"Arknights Endfield — Anti-cheat blocking DLL injection."* A **D3D12/`dinput8.dll` proxy** mod produced no logs at all on Endfield; reporter attributes it to ACE (`ACE-CSI64.dll` etc.). Confirms Endfield's ACE is willing to block proxy/injection DLLs, at least on the DX12 path, on Windows. ⚠️ The DX11/EFMI path is a different code path — do not over-generalise. |
| r/macgaming — [ReShade works on Crossover 25 with DXMT in DX11](https://www.reddit.com/r/macgaming/comments/1kmbi88/reshade_works_on_crossover_25_with_dxmt_in_dx11/) | ⭐ Precedent that a **d3d11/dxgi interposer works on macOS under CrossOver when the bottle backend is DXMT**, with a `dxgi = Native (Windows)` override. Steps mirrored on the [CodeWeavers tip page](https://www.codeweavers.com/compatibility/crossover/tips/reshade/reshade-setup). |
| CodeWeavers forums — [ReShade on Crossover](https://www.codeweavers.com/support/forums/general?t=27;forumcurPos=300;msg=301597) | Counter-example: on CrossOver 24.0.1, dropping `dxgi.dll` + override did **not** work. Reinforces that backend choice + CrossOver version matter, and that the DXMT path is the newer/better one. |
| r/linux_gaming — [Modding Arknights: Endfield](https://www.reddit.com/r/linux_gaming/comments/1v214ie/modding_arknights_endfield/) | *"XXMI only supports DX11. So even if you have everything set up correctly, if the game is running DX12, the mods won't load."* Also reports EFMI installed successfully via Heroic and linked to the game exe — i.e. **EFMI on Linux/Proton is a working configuration in the wild**. |
| [rhea.dev — Installing Windows games on Linux: Arknights: Endfield](https://rhea.dev/articles/2026-01/windows-games-on-linux-endfield) | Endfield runs on Linux via **dwproton** (the author explicitly moved off GE-Proton for this game). Useful as the canonical Linux baseline this research compares against. |
| [GameBanana — "Workaround tips for the d3d11.dll injection error" (thread 228030)](https://gamebanana.com/threads/228030) | *"I suspect the cause of this issue is that Endfield.exe launches before d3d11.dll is fully injected … 1. Open XXMI(EFMI) General → Start method = Shell 2. Advanced → check Custom Launch …"* → the injection **race** is real and has a known user-level workaround. |
| [GameBanana Q107232 — "Failed to inject EFMI/d3d11.dll"](https://gamebanana.com/questions/107232) | Same workaround in Q&A form: *Custom Launch → Bypass → check Inject Libraries → add the path to d3d11.dll*. |
| [Nexus — RenoDX for Arknights Endfield](https://www.nexusmods.com/arknightendfield/mods/14) | Real-world usage of the **Bypass + Inject Libraries** mode (ReShade64.dll + EFMI's `d3d11.dll`), i.e. third-party injectors coexisting with EFMI on Windows. |
| [EFMI on GameBanana (tool 21846)](https://gamebanana.com/tools/21846) | EFMI status/alpha warnings; *"tests on different PCs now indicate almost the same FPS as non-modded game in DX11 mode"* — DX11 is the supported mode, matching our `-force-d3d11` requirement. |
| [EFMI's shipped `d3dx.ini`](https://github.com/SpectrumQT/EFMI-Package/blob/main/EFMI/d3dx.ini) | ⭐ **Primary config source.** Confirms: `[Loader] target = Endfield.exe`, `loader = XXMI Launcher.exe`, `module = d3d11.dll`; a `[System]` section with `;proxy_d3d11=…` **commented out** and `load_library_redirect = 2`; `launch =` hard-codes `C:\Program Files\GRYPHLINK\games\EndField Game\Endfield.exe` (⚠️ folder name differs from our install's `Arknights Endfield`); `[Include] include_recursive = Mods` is how mods are pulled in. |
| [`SpectrumQT/XXMI-Libs-Package`](https://github.com/SpectrumQT/XXMI-Libs-Package) | The **XXMI DLL fork's source repo** ("XXMI DLL is a fork of 3dmigoto") — the tree to verify `[System] proxy_d3d11` handling against before building tooling around it. |
| [Wine 11.6 release notes](https://www.winehq.org/news/2026040301) / [GamingOnLinux write-up](https://www.gamingonlinux.com/2026/04/wine-11-6-is-an-exciting-release-to-make-modding-windows-games-on-linux-simpler/) | *"DLL load order heuristics to better support game mods"*; explanation of the non-Microsoft `CompanyName` rule. |
| [WineHQ bug 43727](https://bugs.winehq.org/show_bug.cgi?id=43727) | *"native dlls exists in the same exe directory wont first load before builtin same name dlls"* — the underlying loader bug. (Site is behind an Anubis PoW wall; title/summary only.) |
| [CodeWeavers forum — d3d11.dll wrapper mods do not work](https://www.codeweavers.com/support/forums/general/?t=27;forumcurPos=800;msg=288337) | Generic: d3d11 **wrapper** mods work under CrossOver **with DXVK** but "does not load when DXVK is disabled" — i.e. wrapper mods need a real native `d3d11.dll` present. Direct precedent for our backend question. |
| [WineHQ news — Wine 11.6 Released](https://www.winehq.org/news/2026040301) | Release note text for the heuristic. |
| Upstream Wine commit [a31ec8da](https://gitlab.winehq.org/wine/wine/-/commit/a31ec8da9572672e04ae46792a398da942649875) | The heuristic patch (fetched in full via the GitHub Wine mirror; GitLab itself is behind Anubis). |

## 3. Primary code read for this research

| Repo | Files read | Purpose |
|---|---|---|
| `SpectrumQT/XXMI-Launcher` (shallow clone) | `core/utils/dll_injector.py`, `core/packages/migoto_package.py`, `core/packages/model_importers/{model_importer,efmi_package,wwmi_package}.py`, `gui/windows/settings/frames/advanced_settings_frame.py` | The injection pipeline, EFMI config (`-force-d3d11`, `use_hook=False`, game exe names), Custom Launch/Inject Libraries semantics, unsafe mode. |
| `SpectrumQT/EFMI-Package` | `README.md` | Install flow, hotkeys, disclaimers, DX11 emphasis. |
| `wakka810/3dmigoto-arknights-endfield` | README | The standalone-loader alternative for Endfield. |
| `dawn-winery/wine-dwproton` (Wine submodule, all refs) | `dlls/ntdll/loader.c`, `dlls/kernelbase/loader.c` (optiscaler hacks), `VERSION` | Verified no EFMI patches; extracted the OptiScaler redirect mechanism. |
| `dawn-winery/dwproton` (local clone) | `CHANGELOGS.md`, `.gitmodules`, full-tree grep | Confirmed no mod-loader content; confirmed submodule layout. |
| upstream Wine | `dlls/ntdll/unix/{loader.c,loadorder.c,unix_private.h}` (via the 11.6 commit patch) | The heuristic, in full. |
| `/Applications/CrossOver_Endfield_Patch.app` + bottle | `cxbottle.conf`, `user.reg`, `cxcompatdb.so` strings, d3d11/dxgi hashes | The local context (see [03](03-crossover-backend-landscape.md)). |

## 4. Access notes (so a future session doesn't re-fight these walls)

- `dawn.wine` and `bugs.winehq.org` and `gitlab.winehq.org` sit behind **Anubis** proof-of-work
  pages for plain HTTP fetches. Workarounds that worked here: use the **GitHub Wine mirror**
  (`github.com/wine-mirror/wine/commit/<sha>.patch`) for Wine commits, and a blob-less git clone
  (`git clone --filter=blob:none --no-checkout`) of `wine-dwproton` to search history.
- `reddit.com` blocks plain fetches (403) and even `old.reddit/*.json`; **Kagi search snippets were
  sufficient** for the content needed, and Kagi Extract returned only the URL for the blocked
  threads. If a full Reddit thread is ever needed, use a logged-in browser session instead.
- GitHub issues are best fetched through `api.github.com` (works without auth for public repos).