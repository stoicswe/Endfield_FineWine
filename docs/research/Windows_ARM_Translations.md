# Running Windows Games on macOS: Compatibility-Layer Research Notes

**Date:** 2026-11-11
**Scope:** What it would take to build a better Windows-game compatibility layer for macOS,
derived from an investigation into running *Marathon* on Apple silicon.
**Status:** Research synthesis. Archival links current as of Nov 2026.

---

## 0. TL;DR

- A better macOS compatibility layer is **buildable**, but not by adding translation stages —
  by **removing** them: one conformant Vulkan driver (KosmicKrisp) instead of two imperfect
  ones, and one CPU path that survives Rosetta 2's removal.
- **Kernel-mode anti-cheat is out of scope permanently.** Wine emulates the Windows kernel in
  user space, so a signed kernel driver cannot load. No user-space layer built on Wine can host
  BattlEye, EAC, Vanguard, or Denuvo's kernel component.
- The **hard deadline is Rosetta 2**: CodeWeavers states it will be "largely discontinued with
  macOS 28 in 2027." ARM64 Wine + FEX is the replacement, and it is where upstream work is live.
- Realistic 2027 target: **every non-kernel-AC Windows game on Apple silicon, at good framerates.**

---

## 1. Origin: the *Marathon* question

*Marathon* (Bungie, launched March 2026) was the test case. It fails on macOS for reasons that
generalize to the whole problem space.

| Route | Where it breaks | Fixable? |
|---|---|---|
| Wine / CrossOver / Proton | BattlEye returns "Unsupported Platform" — Bungie never enabled the Linux flag | Only by Bungie |
| Windows-on-Arm VM | Parallels caps at DirectX 11.1; *Marathon* requires DX12 | Not with current VMs |
| Native macOS | Windows/PS5/Xbox only | No |
| Cloud streaming | Works today (Xbox Cloud, Boosteroid) | ✅ |

**Key evidence:** ProtonDB lists *Marathon* as **Borked** with the reason stated plainly —
"BattlEye Linux flag not enabled by Bungie. Game never reaches title screen on any Proton
version." Experimenting with `PROTON_BATTLEYE_RUNTIME=1` and manual BattlEye runtime installs
does not help; the same report notes "BattlEye supports Linux natively — Bungie opted out.
Identical situation to Destiny 2." Valve's compatibility data rates it Unsupported for Steam
Deck / SteamOS citing "unsupported anti-cheat configuration."
Source: <https://www.protondb.com/app/3065800>

The game itself is *not* the obstacle: within days of launch the community fixed the actual
breakage (a missing `winhttp.dll` implementation in Wine) and got it to the login screen, where
BattlEye refuses. **One Steamworks setting separates the Wine path from working.**

⚠️ Forum users claim Bungie bans non-Windows play rather than merely refusing it. Treat as
unverified forum chatter, not policy — but do not risk a paid account on it.

---

## 2. Anti-cheat: the structural constraints

### 2.1 Linux — runs, but user-mode only
BattlEye runs on Linux as a native **Ring 3** library. It cannot be a kernel module because the
Linux kernel is GPL; an open-sourced anti-cheat defeats the obscurity it depends on. Support is
**opt-in per developer**, confirmed by the BattlEye team. Titles like ARMA 3 work; *Marathon*
does not because Bungie never flipped the switch.

### 2.2 Windows on Arm — the Arm64 kernel driver is real
BattlEye ported its **kernel driver** to native Arm64 for **Windows 11 on Arm** (24H2, build
26100.863, mid-2024), in partnership with Microsoft and Qualcomm. This required Microsoft to
modify the Prism emulator so the driver could load alongside x86-emulated games. It is
**necessary but per-game**: some titles work, others (Destiny 2, GTA V Enhanced, PUBG) still fail.

**This has nothing to do with macOS.** macOS never loads it — Apple forbids third-party kernel
extensions of this kind. Under Parallels you are running genuine Windows-on-Arm, and the driver
loads there.

### 2.3 Diagnostic table for VM attempts
Distinguish the failure mode before investing effort:

| Symptom | Cause | Remedy |
|---|---|---|
| "Unsupported Platform" at login | Developer never enabled Arm BE | None; it's a Bungie decision |
| Driver load error 1275 | BE service won't initialise in VM | Not a VM-detection check |
| "Disallowed program: virtual machine" | Actual VM detection | Policy wall (below) |

Reports suggest *Marathon* has **never been confirmed launching on Windows-on-Arm at all**, so
no-one knows which wall applies. A stock VM test with a throwaway account answers it cheaply.

### 2.4 VM detection: documented field, wrong project
VM hiding is public and mature — [VMAware](https://github.com/NotRequiem/VMAware) implements
~90 detection techniques across CPUID, firmware/ACPI (SMBIOS, ACPI signatures), hardware
(PCI IDs, MAC prefixes), filesystem/registry (guest tools, virtio), and behavioural signals
(RDTSC timing, VM-exit latency, trap flags, thread counts), claiming detection of ~70 hypervisor
brands.

Two reasons not to pursue it:
1. **Technical:** the string-based checks are cosmetic and hackable; the timing checks are
   inherent to hardware virtualization exits and require *hypervisor-level* patching. On Apple
   silicon the hypervisor is Apple's, signed and closed — that layer is not yours.
2. **Policy:** BattlEye's stated position is that plain VM users get **kicked**, while users
   detected *actively evading VM detection* get **banned**. Evasion is precisely the carve-out.

**Conclusion: treat anti-cheat as out of scope in any layer you build, and say so in the README.**

---

## 3. Why "VM with DX12→Metal translation" doesn't work

The proposed architecture (Arm Windows guest, trimmed down, DX12 translated through to host
Metal) is coherent in principle but blocked at the GPU-driver layer.

| Layer needed | Status |
|---|---|
| WDDM driver exposing a virtual GPU to Windows | ❌ No Metal-backed WDDM driver exists. Apple's paravirtualized graphics is macOS-guest only; even a basic virtio-level WDDM driver for Windows on AVF is an open feature request |
| Guest-side D3D12 → host Metal | ❌ D3DMetal is Apple-proprietary, macOS-side, Wine-specific, and "incompatible with vanilla wine/wine-staging" |
| Alternative: vkd3d-proton → Vulkan → MoltenVK *in guest* | ❌ Needs a Vulkan driver for the virtual GPU; Parallels exposes none to Windows guests |
| BattlEye Arm64 kernel driver | ⚠️ Exists; per-game opt-in; no *Marathon* evidence |

**Parallels' DX12 status is contested and should not be built on.** Its KB states 3D acceleration
is capped at **DirectX 11.1 / OpenGL 4.3**; engineering confirmed PD20 reached DDI 12 at feature
level **11_1**; a Feb 2026 thread asking about PD27's DX12 support got no roadmap answer. Some
marketing copy now claims DX12, which conflicts with their own KB. Rare DX12 titles reported
working are likely falling back rather than truly using FL12_0.

**"Minimal" doesn't help:** the constraint is architectural, not resource-based. A 4 GB VM and a
32 GB VM hit the same DX12 ceiling. And Parallels disables VBS and nested virtualization, so
Hyper-V-based isolation tricks are unavailable too.

Also note: Windows' own documentation states emulation supports **user-mode code only**, and
"any kernel mode components must be compiled as Arm64." That is why the Arm64 BE driver is the
*only* reason any BE title launches in an Arm VM at all.

---

## 4. The macOS stack today

| Layer | Current best | Status | Where leverage is |
|---|---|---|---|
| CPU / Win32 API | Wine 11 + CrossOver 26/27 | Mature | **ARM64 + FEX migration** |
| D3D10/11 → Metal | [DXMT](https://github.com/3Shain/dxmt) (open source), D3DMetal | Strong; DXMT pre-1.0 | Metal 4 backend, MetalFX perf mode |
| D3D12 → Metal | D3DMetal, or vkd3d-proton → Vulkan → MoltenVK | Works, fragile | **Swap MoltenVK for KosmicKrisp** |
| Vulkan → Metal | [MoltenVK](https://github.com/KhronosGroup/MoltenVK) / KosmicKrisp | Just transformed | Conformance gap now closable |
| Kernel-mode anti-cheat | — | ❌ Structurally impossible | Not a compat-layer problem |

---

## 5. The three inflection points

### 5.1 KosmicKrisp — Vulkan conformance arrives
[LunarG's driver](https://www.lunarg.com/products/kosmickrisp/) is a **Mesa-based, Vulkan 1.4
conformant, Metal 4** Vulkan driver, Google-sponsored, shipped in the Vulkan SDK and upstream in
Mesa. Passed the Vulkan 1.4 CTS in September 2026. MIT-licensed. Covers M1–M5 and A18 Pro.

**Requirements that shape any project:** macOS 26+ and Apple silicon only — it won't even be
enumerated on Intel or older OS versions.

Why it matters mechanically: LunarG's own writeup states MoltenVK *"is not a fully conformant
Vulkan Implementation, and has missing functionality from the base Vulkan API"* — developers
have been papering over that with per-app workarounds. vkd3d-proton is written against a
conformant Vulkan 1.3/1.4 baseline, so every MoltenVK gap became a special case in the D3D12
path. Conformance means those cases can be **deleted rather than worked around**.

Non-core coverage now includes tessellation, robustness2, and multi-draw. LunarG calls it "the
preferred and performant solution for Apple Silicon desktops."
Sources: <https://www.lunarg.com/kosmickrisp-achieves-vulkan-1-4-conformance-on-apple-silicon/>,
<https://www.lunarg.com/the-state-of-vulkan-on-apple-jan-2026/>

### 5.2 The Rosetta 2 cliff (the real deadline)
CodeWeavers, June 2026: *"Currently, CrossOver requires the use of Rosetta 2 to translate x86_64
instructions to ARM64. **Rosetta 2 will be largely discontinued with macOS 28 in 2027**, and our
ARM64 CrossOver build will run without Rosetta 2."*
Source: <https://www.codeweavers.com/blog/mjohnson/2026/6/11/whats-in-and-whats-out-for-crossover-27>

That is a cliff under the entire macOS gaming stack in roughly a year. PortJump clients are
being told outright their builds won't run on macOS 28 without migration.

### 5.3 ARM64 Wine + FEX — the replacement, already half-built
- Wine's macOS platform work: **x18 custom ABI mode** and per-thread **TSO** enablement via
  `thread_set_x86_64_compat()`, with the announcement that "all the pieces are now present in
  macOS to natively run ARM64 Wine." Discussion:
  <https://list.winehq.org/hyperkitty/list/wine-devel@list.winehq.org/thread/CKG5CEN2BE5VRXZ7O7NX4YUSBH3247WH/>
- CodeWeavers shipped an **ARM64 preview (July 31, 2026)** pairing ARM64 Wine with
  [FEX](https://github.com/FEX-Emu/FEX) for i386/x86-64 (ARM64EC) emulation. Requires
  **macOS 26.5+**; builds are universal, and **include ARM64 DXMT** — CodeWeavers recommends the
  DXMT graphics option for games. 32-bit bottles are discontinued as a consequence.
  <https://www.codeweavers.com/blog/mjohnson/2026/7/31/crossover-preview-the-right-to-bear-arm64-on-mac>
- Wine 10.0 (Jan 2025) included full ARM64EC support; Wine 11.0 (Jan 13, 2026) completed the new
  WoW64 architecture, added NTSync, and on macOS swaps `%gs` in the syscall dispatcher to avoid
  conflicts between the Windows TEB and the macOS thread descriptor.
  <https://gitlab.winehq.org/wine/wine/-/releases/wine-11.0>
- FEX is a DLL implementing Wine's WoW64 translator interface — not a Linux-only tool.
  Windows FEX modules purely handle CPU emulation; syscall translation happens on the Wine
  (WOW64) side or via the ARM64EC ABI, so native ARM64 `.so` libraries (Vulkan, etc.) can be
  used directly — no x86 rootfs and no FEX-side thunking.
  <https://wiki.fex-emu.com/index.php/Development:ARM64EC>

**If you contribute anywhere, contribute here.** Only part of the stack with a hard external
deadline, active upstream review, and a clear definition of done.

---

## 6. Open graphics work: DXMT's published roadmap

DXMT is the healthiest open translator, and its 1.0 plan is an explicit list of what's unfinished.

Source: <https://github.com/3Shain/dxmt/issues/151>

**Confirmed for 1.0**
- Stream-output from geometry shader (#28)
- `DXGI_SWAP_EFFECT_*_SEQUENTIAL`
- Null binding (#99)
- **Cross-process rendering** — *"Wine upstream changes required"* (#166, paired with
  Wine MR !11058: <https://gitlab.winehq.org/wine/wine/-/merge_requests/11058>)
- Shared keyed mutex (#195)

**1.0 candidates**
- Adopt `dxbc-spirv` as shader-converter middle-end (as bytecode parser for SM ≤5.1, plus DXBC
  lowering passes — the SPIR-V part is unused)
- Memory management / residency-set refactor (placement-heap suballocation, relocation, defrag)
- Latency control (mimic `D3D_Sleep`/`SetSleepMode`)
- Tessellation: isoline domain

**Post-1.0**
- Tiled resources
- D3D11 video device
- **Metal 4 backend** ← the join point with KosmicKrisp
- Tessellation-geometry pipeline

**Already solved, and instructive:** tessellation is largely implemented via **mesh-pipeline
emulation**, because DirectX's tessellation model is only partially expressible in Metal.
Feature level is 11.1 with known restrictions.
<https://github.com/3Shain/dxmt/discussions/19>

---

## 7. What will actually block you

Not graphics. These:

1. **Fragmentation.** Linux has one target (Proton + Steam Runtime + Mesa). macOS has two CPU
   paths (Rosetta vs FEX), two Vulkan drivers (MoltenVK vs KosmicKrisp), an OS gate at macOS 26
   (Metal 4), and Intel/AS divergence. **Pick Apple Silicon + macOS 26+ + KosmicKrisp and refuse
   the rest** — the only way the test surface stays tractable.
2. **No shader-graph escape hatch.** DXBC→MSL correctness is where games break. LunarG lists
   "MSL compiler being the biggest offender" among the workarounds they carry; independent
   efforts report taking titles "through an Apple compiler crash." Budget for this, not for API
   plumbing.
3. **Kernel-mode is a wall, not a gradient.** See §2.
4. **Apps, not just games.** Launchers, mDNS/networking, codecs, and middleware are the long
   tail. Proton absorbed that with thousands of community reports; there is no equivalent crowd
   on macOS.

---

## 8. Recommended plan

1. **Don't build another wrapper.** The packaging layer is crowded and commoditized; Whisky's
   trajectory showed the ceiling. Build or contribute to a *translator*.
2. **Start with a harness, not a feature.** Shape it after metalsharp/VKD3D-Proton-MacOS:
   reproducible builds with checksums, a D3D12 feature-level probe, a regression gate spanning
   mesh dispatch / sampler feedback / geometry-shader corpora, and trace tooling that reports
   which fence a queue is stuck on when Present stalls. Being able to say "FL12_1 rung passes,
   game hangs at first Present on fence X" is worth more than code.
3. **Then pick one, in value-per-hour order:**
   - ARM64 Wine + FEX (upstream, deadline-driven, CodeWeavers reviewing)
   - KosmicKrisp swap into the vkd3d-proton D3D12 path (highest structural payoff)
   - DXMT Metal 4 backend (joins the previous two)
   - DXMT MetalFX performance mode (small, self-contained, user-visible)
4. **Contribute upstream, don't fork.** DXMT's plan names the required Wine MRs; Wine's ARM64
   work is going through reviewed MRs. A fork of a translator dies; a merged MR compounds.

---

## 9. Corrections log

Claims revised during this research, recorded so they don't get re-cited:

| Earlier claim | Corrected position |
|---|---|
| "BattlEye kernel anti-cheat on ARM is why GTA Online works on Mac" | The Arm64 driver is for **Windows on Arm**, not macOS. It works under Parallels only because you're running Windows. macOS never loads it |
| "BattlEye has never run at kernel level on Linux" (implied success) | Correct but for a *licensing* reason (GPL), not a technical failure. User-mode BE works and ships |
| "GTA Online works under Parallels" | True for **GTA V Legacy**; **Enhanced** is reported to crash on Windows-on-Arm |
| "Parallels has weak Vulkan/DirectX support" | Overstated. Real constraint is **performance overhead**, plus a hard DX11.1 capability ceiling per their own KB |
| "Marathon under Wine fails on anti-cheat" | More precisely: the game *reaches login* after a community `winhttp.dll` fix; only BattlEye's platform check blocks it |
| "Arm64 BE driver might unblock the VM route" | Necessary but insufficient — DX12 requirement fails first on Parallels |
| "VM detection could be worked around" | Two independent blockers: timing checks need hypervisor-level patching (not yours on Apple HW), and evasion is the *bannable* category by BattlEye's own policy |

---

## 10. Open questions worth verifying

- Has **anyone** confirmed *Marathon* launching on Windows-on-Arm? (No public report found.)
- Does Bungie's own anti-cheat layer add requirements beyond BattlEye's Linux toggle, per their
  forum statements about "user-mode and kernel-mode components"?
- Does KosmicKrisp + vkd3d-proton actually clear the D3D12 titles D3DMetal handles today, and at
  what performance delta? (No independent benchmark found.)
- What is the concrete FEX gap — which games fail on CPU emulation correctness rather than
  graphics?
- MetalFX performance mode: is DXMT's open proposal (render-low/upscale-to-native) still active?

---

## Appendix: primary sources

| Topic | Link |
|---|---|
| KosmicKrisp product page | https://www.lunarg.com/products/kosmickrisp/ |
| KosmicKrisp 1.4 conformance | https://www.lunarg.com/kosmickrisp-achieves-vulkan-1-4-conformance-on-apple-silicon/ |
| State of Vulkan on Apple | https://www.lunarg.com/the-state-of-vulkan-on-apple-jan-2026/ |
| DXMT | https://github.com/3Shain/dxmt |
| DXMT 1.0 plan | https://github.com/3Shain/dxmt/issues/151 |
| DXMT cross-process PR | https://github.com/3Shain/dxmt/pull/166 |
| Wine 11.0 release notes | https://gitlab.winehq.org/wine/wine/-/releases/wine-11.0 |
| FEX ARM64EC wiki | https://wiki.fex-emu.com/index.php/Development:ARM64EC |
| CrossOver ARM64 preview | https://www.codeweavers.com/blog/mjohnson/2026/7/31/crossover-preview-the-right-to-bear-arm64-on-mac |
| Rosetta 2 phase-out | https://www.codeweavers.com/blog/mjohnson/2026/6/11/whats-in-and-whats-out-for-crossover-27 |
| ProtonDB: Marathon | https://www.protondb.com/app/3065800 |
| VMAware | https://github.com/NotRequiem/VMAware |
