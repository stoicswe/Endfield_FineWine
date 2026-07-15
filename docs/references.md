# References (consolidated)

All sources fetched/consulted during research, grouped by topic. Confidence and caveats are in the per-subsystem docs. Sites marked ⚠️ blocked automated fetching (Anubis proof-of-work wall or HTTP 403) — use a browser.

## ACE anti-cheat & Endfield
- GE-Proton issue #433 (the fix identification) — <https://github.com/GloriousEggroll/proton-ge-custom/issues/433>
- dw-proton fix commit `b816be489…` — <https://dawn.wine/dawn-winery/dwproton/commit/b816be489049a10453b470c6a12dcf552ea41773.patch>
- PCGamingWiki: Anti-Cheat Expert — <https://www.pcgamingwiki.com/wiki/Anti-Cheat_Expert>
- PCGamingWiki: Arknights: Endfield — <https://www.pcgamingwiki.com/wiki/Arknights:_Endfield>
- Wikipedia: Anti-Cheat Expert — <https://en.wikipedia.org/wiki/Anti-Cheat_Expert>
- CVE-2024-22830 (ACE-BASE.sys) — <https://nvd.nist.gov/vuln/detail/CVE-2024-22830> · advisory <https://github.com/advisories/GHSA-q4jw-jxm3-52jh> · loldrivers <https://www.loldrivers.io/>
- AreWeAntiCheatYet #1905 (Endfield status) — <https://github.com/AreWeAntiCheatYet/AreWeAntiCheatYet/issues/1905>
- rhea.dev: Endfield on Linux — <https://rhea.dev/articles/2026-01/windows-games-on-linux-endfield>
- ⚠️ WineHQ bug 59411 — <https://bugs.winehq.org/show_bug.cgi?id=59411>

## dw-proton / GE-Proton / Wine ntoskrnl patches
- ⚠️ dw-proton repo (Gitea, Anubis-walled) — <https://dawn.wine/dawn-winery/dwproton>
- ⚠️ dw-proton **Wine fork** (where the patches now live, branch `base`) — <https://dawn.wine/dawn-winery/wine-dwproton>
- dw-proton GitHub mirror — <https://github.com/dawn-winery/dwproton-mirror>
- Wine-fork proxy mirror (used to read current sources) — <https://github.com/NelloKudo/wine-dwproton>
- Historical `patches/wine/` tree mirror — <https://github.com/TomerGamerTV/dwproton>
- `Etaash-mathamsetty/wine-ntoskrnl` — <https://github.com/Etaash-mathamsetty/wine-ntoskrnl>
- wine-staging `ntdll-Hide_Wine_Exports` — <https://github.com/wine-staging/wine-staging/blob/master/patches/ntdll-Hide_Wine_Exports/0001-ntdll-Add-support-for-hiding-wine-version-informatio.patch>
- wine-staging ntoskrnl stubs — <https://github.com/wine-compholio/wine-staging/tree/master/patches/ntoskrnl-Stubs>
- Wine `dlls/ntdll/version.c` — <https://github.com/wine-mirror/wine/blob/master/dlls/ntdll/version.c>
- Proton version-spoof commit (Death Stranding build) — <https://github.com/ValveSoftware/wine/commit/e9264df6e63b5df87d81e950675df7290ad43615>

## CrossOver Wine architecture & building
- CrossOver source — <https://www.codeweavers.com/crossover/source> · ⚠️ tarball dir <https://media.codeweavers.com/pub/crossover/source/>
- Git mirror `tbodt/crossover-wine` — <https://github.com/tbodt/crossover-wine>
- `Gcenx/winecx` (`crossover-wine` branch) — <https://github.com/Gcenx/winecx>
- `Gcenx/wine-on-mac` — <https://github.com/Gcenx/wine-on-mac>
- `Gcenx/macOS_Wine_builds` — <https://github.com/Gcenx/macOS_Wine_builds>
- sarimarton compile gist (+ comments) — <https://gist.github.com/sarimarton/471e9ff8046cc746f6ecb8340f942647>
- Alex4386 compile gist — <https://gist.github.com/Alex4386/4cce275760367e9f5e90e2553d655309>
- `GabLeRoux/macos-crossover-wine-cloud-builder` — <https://github.com/GabLeRoux/macos-crossover-wine-cloud-builder> (issue #51: cx-llvm unavailable)
- MacPorts wine-crossover — <https://ports.macports.org/port/wine-crossover/>
- carette.xyz CrossOver deep-dive — <https://carette.xyz/posts/deep_dive_into_crossover/>
- CrossOver 27 "what's in/out" — <https://www.codeweavers.com/blog/mjohnson/2026/6/11/whats-in-and-whats-out-for-crossover-27>
- ⚠️ CodeWeavers ARM64 preview — <https://www.codeweavers.com/blog/mjohnson/2025/11/6/twist-our-arm64-heres-the-latest-crossover-preview>
- CrossOver 25 / Wine 10 (Phoronix) — <https://www.phoronix.com/news/CrossOver-25.0-Released>
- Wikipedia: CrossOver — <https://en.wikipedia.org/wiki/CrossOver_(software)>
- AppleGamingWiki: CrossOver — <https://www.applegamingwiki.com/wiki/CrossOver>

## Swapping into CrossOver / code-signing / SIP
- `italomandara/CXPatcher` — <https://github.com/italomandara/CXPatcher> (README, `Utils.swift`, `Config.swift`)
- CXPatcher Discussion #239 (can't inject ntsync) — <https://github.com/italomandara/CXPatcher/discussions/239>
- `Gcenx/CrossOver-fixes` — <https://github.com/Gcenx/CrossOver-fixes>
- CodeWeavers: change bottle directory — <https://support.codeweavers.com/change-the-bottle-directory-in-crossover-mac>
- CodeWeavers: advanced config — <https://support.codeweavers.com/advanced-crossover-mac-configuration>
- Wikipedia: System Integrity Protection — <https://en.wikipedia.org/wiki/System_Integrity_Protection>
- Apple: About SIP — <https://support.apple.com/en-us/102149>
- HackTricks: dangerous entitlements — <https://book.hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-dangerous-entitlements.html>

## Graphics: GPTK / D3DMetal / DXMT / DXVK
- Apple GPTK — <https://developer.apple.com/games/game-porting-toolkit/> · AppleGamingWiki <https://www.applegamingwiki.com/wiki/Game_Porting_Toolkit>
- GPTK4 coverage — <https://appleinsider.com/articles/26/06/17/apples-game-porting-toolkit-4-is-a-big-improvement-for-modern-game-coders> · <https://korben.info/en/game-porting-toolkit-4-windows-games-smooth-mac.html>
- CrossOver 26 Advanced Settings — <https://support.codeweavers.com/en_US/advanced-settings-in-crossover-mac-26>
- CrossOver changelog — <https://www.codeweavers.com/crossover/changelog>
- `3Shain/dxmt` — <https://github.com/3Shain/dxmt> (README, wiki, releases)
- Endfield: force DX11 — <https://nerdschalk.com/arknights-endfield-disable-vulcan-force-directx-11/>
- CrossOver compatibility: Endfield — <https://www.codeweavers.com/compatibility/crossover/arknights-endfield>
- Whisky — <https://frankea.github.io/Whisky/>

## Rosetta 2 & Wine detection
- Apple: Rosetta translation environment — <https://developer.apple.com/documentation/apple-silicon/about-the-rosetta-translation-environment>
- hexacorn: detecting Wine via internal/legacy APIs — <https://www.hexacorn.com/blog/2016/03/27/detecting-wine-via-internal-and-legacy-apis/>
- Rosetta AVX SIGILL — <https://medium.com/macoclock/m1-rosetta-2-limitation-illegal-hardware-instruction-a3b48fae02e>
- Rosetta internals (Linux VM context) — <https://blog.inoki.cc/2026/02/28/Apple-Rosetta-Linux-VM-Secret-en/>
- Kernel-level anti-cheat overview — <https://research.meekolab.com/understanding-kernel-level-anticheats-in-online-games>

## The user's original research notes
- `Arknights Endfield on macOS Crossover.md` (in `~/Downloads`) — the preliminary conversation that seeded this project.
