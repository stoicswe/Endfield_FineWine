# 07 — Rosetta 2 detection surface & Windows/OS spoofing to satisfy ACE

> Source area: `rosetta-spoofing` (research + adversarial verify). Overall reliability: **high**.
>
> **Framing:** two distinct problem layers — do not conflate them. **(A)** Rosetta 2's fingerprint surface (mostly a non-issue, but real). **(B)** Wine-environment fingerprints and OS spoofing (the levers you can pull *for free*, no rebuild). The *actual* wall is Wine's missing `ntoskrnl.exe` surface ([02](02-dwproton-ace-patches.md)) — but the spoofs here are the cheap first thing to try (roadmap milestone 2).

## Layer A — Rosetta 2 detection surface

x86_64 code (Wine's x86_64 build **and** ACE's obfuscated x86_64 user-mode module) runs under Rosetta 2, which translates x86_64 → arm64. Rosetta reports CPUID **vendor = `GenuineIntel`, Family 6**, so a naive vendor check passes. But there are concrete tells ACE *could* use: `[confidence: high]`

1. **CPUID brand string contains `VirtualApple`** (CPUID leaves `0x80000002`–`0x80000004`; `machdep.cpu.brand_string` → "VirtualApple @ 2.50GHz"). **The single strongest Rosetta tell** an x86 process can self-detect.
   - ⚠️ **VERIFIER CAUTION:** much readily-available primary write-up on `VirtualApple` concerns Rosetta 2 **for Linux VMs** and the `/proc/cpuinfo` path — a Linux surface **not reachable** by ACE's Windows x86 code under Wine. On macOS the tell surfaces via **CPUID leaves**; don't conflate the two. The `sysctl.proc_translated == 1` form is a **macOS syscall** ACE's Windows-side code can't reach through Wine — it matters to CrossOver's own tooling, not to ACE.
2. **AVX / AVX2 / AVX-512** were unsupported under Rosetta 2 before macOS 15, raising **SIGILL** ("illegal hardware instruction"). macOS 15 (Sequoia) added **AVX and AVX2** — but **AVX-512 is still unsupported**, and residual SIGILL on some AVX2 binaries persists (Stockfish #5707). A binary probing for AVX (present on any real gaming CPU) can detect translation or crash. `[confidence: high — CONFIRMED, with the AVX-512 caveat added by verifier]`
3. Memory-ordering (Apple TSO mode) and instruction-timing side channels are theoretically usable, but **no evidence ACE uses them**.

**Net:** Rosetta adds a modest, real fingerprint surface (mainly `VirtualApple` + missing AVX-512), but it is **not** why the game fails to launch today.

## Layer B — Wine fingerprints & OS spoofing (the free levers)

### Wine-only exported symbols (the primary Wine fingerprint)
Real Windows never exports these; their presence betrays Wine: `[confidence: high — CONFIRMED against hexacorn]`
```
ntdll:     wine_get_version, wine_get_build_id, wine_get_host_version,
           wine_server_call, wine_nt_to_unix_file_name, wine_server_fd_to_handle,
           __wine_enter_vm86, __wine_set_signal_handler
kernel32:  wine_get_unix_file_name, wine_get_dos_file_name,
           __wine_dll_register_16, __wine_dll_unregister_16, __wine_kernel_init
legacy:    RegisterServiceProcess, OpenVxDHandle   (Win9x/ME-only; never on NT+)
```

### The `HideWineExports` patch (wine-staging → Proton)
`ntdll-Hide_Wine_Exports` filters the telltale exports out of `LdrGetProcedureAddress`. `[confidence: high — CONFIRMED]`
- **Gate:** registry `HKCU\Software\Wine` value **`HideWineExports`** (or per-app `HKCU\Software\Wine\AppDefaults\<app.exe>`); true values = `y`,`Y`,`t`,`T`,`1` (via `IS_OPTION_TRUE`).
- ⚠️ **VERIFIER CORRECTION:** the current wine-staging code guards with `if (proc && !is_hidden_export(proc))` (helper-based), **not** the inline `if (proc == &wine_get_version || …)` triple-comparison the research quoted. Behavior identical; the inline snippet is an older/paraphrased form.
- **Proton bundles this patch.** Whether CrossOver's Wine carries it, and whether it's on by default, is unverified — check the bottle and the CrossOver Wine tree.
- ⚠️ **Important context:** dw-proton itself does **not** hide Wine exports for Endfield ([02](02-dwproton-ace-patches.md)) — on Linux, ACE tolerates the telltale exports. So export-hiding is **not proven necessary**; it's a cheap thing to *try* (milestone 2), not a known requirement.

### Other environment tells (not covered by export-hiding)
- The `HKCU\Software\Wine` registry key itself. `[confidence: medium]`
- The **`Z:` drive** mapping the unix root (default Wine prefix behavior). `[confidence: medium]`
- Whether ACE actually enumerates these for Endfield is **unproven** — no ACE disassembly confirms which checks fire.

### OS version / build spoofing
`RtlGetVersion` / `RtlGetNtVersionNumbers` read `HKLM\Software\Microsoft\Windows NT\CurrentVersion` (mirrored under `Wow6432Node`): `[confidence: high — CONFIRMED in `dlls/ntdll/version.c`]`
```
Values:  CurrentMajorVersionNumber, CurrentMinorVersionNumber, CurrentVersion,
         CurrentBuild, CurrentBuildNumber, ProductName, CSDVersion
Wine built-in tables:  WIN10 = 10.0 build 19045   ·   WIN11 = 10.0 build 22000
RtlGetNtVersionNumbers applies (0xF0000000 | dwBuildNumber)
```
Setting **winecfg → Windows 10 / Windows 11** writes these so ACE reads a plausible build. **Free to try** (roadmap milestone 2). Open question: which exact build ACE minimally accepts — is 19045 enough, or does it want a specific 22H2 / Win11 build + matching `ProductName`?

## The `wine-ntoskrnl` companion project (for the kernel side)
`Etaash-mathamsetty/wine-ntoskrnl` — the basis for dw-proton's ntoskrnl work — implements kernel exports and CPU-flag/instruction emulation anti-cheats need: `[confidence: high — CONFIRMED against README]`
- `InitializeSynchronizationBarrier`, `EnterSynchronizationBarrier`, `DeleteSynchronizationBarrier`, `KeIpiGenericCall`, `MmMapLockedPagesSpecifyCache`.
- x86 instruction/flag emulation; the **`INT` instruction (`int 0x80`) is emulated and ignored** as an anti-VM check.
- Got "some XignCode3 games working." Project is marked **dead / being upstreamed**.
- ⚠️ **VERIFIER CORRECTION:** the README implemented flags **PF/SF/OF** but **AF was still a TODO** — the research's "PF/SF/OF/AF" overstates by listing AF as done. These are TODO/"needs tests" notes, not a guarantee the barrier functions are fully functional.

## ⚠️ The critical caveat threaded through this whole area
For **Arknights: Endfield specifically**, the only documented stock-Proton abort (GE #433) is **`unimplemented function msimg32.dll.AlphaBlend`** — **not** an `ntoskrnl.exe` function. So "ntoskrnl is *the* Endfield blocker" is **inference, not established**; the specific ACE-triggering export is unidentified. **This is why roadmap milestone 1 (capture the real failure) precedes everything.**

Also: the "ACE has a Steam Deck + Wine hardware allowlist" claim is **UNVERIFIABLE** — no primary source supports it; AreWeAntiCheatYet #1905 only says Endfield "launches with latest Proton-DW." **Do not build a strategy around ACE tolerating Wine by design.**

## Cheap spoofs to try with NO rebuild (roadmap milestone 2)
```
1. winecfg  →  set Windows version to Windows 10 (or 11)     # writes CurrentVersion keys
2. reg add "HKCU\Software\Wine" /v HideWineExports /d Y       # inside the bottle, via wine reg
   # or per-app: HKCU\Software\Wine\AppDefaults\Endfield.exe
3. retest Endfield; compare failure signature to the milestone-1 baseline
```
If ACE progresses further → blocker is environment detection. If it aborts identically → blocker is the kernel-API surface (needs the [02](02-dwproton-ace-patches.md) patches).

## Primary sources
- wine-staging `ntdll-Hide_Wine_Exports` — <https://github.com/wine-staging/wine-staging/blob/master/patches/ntdll-Hide_Wine_Exports/0001-ntdll-Add-support-for-hiding-wine-version-informatio.patch>
- Wine `dlls/ntdll/version.c` — <https://github.com/wine-mirror/wine/blob/master/dlls/ntdll/version.c>
- `Etaash-mathamsetty/wine-ntoskrnl` — <https://github.com/Etaash-mathamsetty/wine-ntoskrnl>
- hexacorn "Detecting Wine via internal and legacy APIs" — <https://www.hexacorn.com/blog/2016/03/27/detecting-wine-via-internal-and-legacy-apis/>
- Apple: Rosetta translation environment — <https://developer.apple.com/documentation/apple-silicon/about-the-rosetta-translation-environment>
- GE-Proton #433 — <https://github.com/GloriousEggroll/proton-ge-custom/issues/433>
