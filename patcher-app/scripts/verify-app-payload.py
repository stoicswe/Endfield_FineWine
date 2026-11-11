#!/usr/bin/env python3
"""Fail the build if FineWine Patcher.app doesn't carry a usable module payload.

The module lists come from PatcherEngine.swift, so this checks what the app will really install.

  x64: every module must be present, with the right architecture and rpath, and winemac.so must
       contain the launcher alpha patch (a stock winemac.so builds and ships without complaint).
  ARM: optional, but all or nothing. A partial payload is an error.

Usage: verify-app-payload.py "path/to/FineWine Patcher.app" [path/to/PatcherEngine.swift]
"""
import os
import re
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LAUNCHER_PATCH_MARKER = "__wine_dwm_blur_behind".encode("utf-16-le")
X64_RPATH = "@loader_path/../../../lib64"
PE_MACHINE_ARM64 = 0xaa64


def module_lists(engine_source):
    """Returns (x64 payload subpaths, ARM payload subpaths) from CrossOverVariant.modules."""
    with open(engine_source, encoding="utf-8") as handle:
        source = handle.read()
    body = source[source.index("var modules: [PayloadModule]"):]
    x64 = body[body.index("case .x64:"):body.index("case .arm:")]
    arm = body[body.index("case .arm:"):body.index("enum Payload")]
    subpaths = re.compile(r'payloadSubpath: "([^"]+)"')
    return sorted(set(subpaths.findall(x64))), sorted(set(subpaths.findall(arm)))


def tool(*args):
    return subprocess.run(args, capture_output=True, text=True).stdout


def pe_machine(path):
    with open(path, "rb") as handle:
        header = handle.read(4096)
    pe_offset = struct.unpack_from("<I", header, 60)[0]
    return struct.unpack_from("<H", header, pe_offset + 4)[0]


def check_mach_o(path, arch, rpath, errors):
    name = os.path.basename(path)
    if arch not in tool("lipo", "-archs", path).split():
        errors.append(f"{name} has no {arch} slice")
    if rpath and rpath not in tool("otool", "-l", path):
        errors.append(f"{name} is missing the rpath {rpath}")


def verify_x64(payload, modules, errors):
    missing = [m for m in modules if not os.path.isfile(os.path.join(payload, m))]
    errors.extend(f"x64 module missing: {m}" for m in missing)
    if missing:
        return
    check_mach_o(os.path.join(payload, "x86_64-unix/ntdll.so"), "x86_64", X64_RPATH, errors)
    winemac = os.path.join(payload, "x86_64-unix/winemac.so")
    check_mach_o(winemac, "x86_64", X64_RPATH, errors)
    check_mach_o(os.path.join(payload, "server/wineserver"), "x86_64", None, errors)
    check_mach_o(os.path.join(payload, "lib64/libMoltenVK.dylib"), "x86_64", None, errors)
    for module, patch in (("x86_64-unix/winemac.so", "0009"), ("x86_64-windows/dwmapi.dll", "0010")):
        with open(os.path.join(payload, module), "rb") as handle:
            if LAUNCHER_PATCH_MARKER not in handle.read():
                errors.append(f"{os.path.basename(module)} doesn't contain the launcher alpha patch "
                              f"(patches/x64/stage1-macos/{patch} was not applied)")


def verify_arm(payload, modules, errors):
    """Returns True when an ARM payload is bundled."""
    root = os.path.join(payload, "arm")
    if not os.path.isdir(root):
        return False
    missing = [m for m in modules if not os.path.isfile(os.path.join(root, m))]
    errors.extend(f"partial ARM payload, missing: {m}" for m in missing)
    for module in set(modules) - set(missing):
        path = os.path.join(root, module)
        if module.startswith("aarch64-unix/"):
            # The launcher-alpha library loaded into CrossOver ARM's own winemac.so.
            check_mach_o(path, "arm64", None, errors)
            if subprocess.run(["codesign", "--verify", path], capture_output=True).returncode:
                errors.append(f"ARM module isn't signed: {module}")
        elif pe_machine(path) != PE_MACHINE_ARM64:
            errors.append(f"ARM module isn't an ARM64 PE: {module}")
    return True


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    engine = sys.argv[2] if len(sys.argv) == 3 else os.path.join(
        HERE, "..", "Sources", "FineWinePatcher", "PatcherEngine.swift")
    payload = os.path.join(sys.argv[1], "Contents", "Resources", "payload")
    x64_modules, arm_modules = module_lists(engine)

    errors = []
    verify_x64(payload, x64_modules, errors)
    has_arm = verify_arm(payload, arm_modules, errors)

    for error in errors:
        print(f"::error::{error}")
    if errors:
        sys.exit(1)
    print(f"x64 payload OK ({len(x64_modules)} files, launcher alpha patch present)")
    print(f"ARM payload OK ({len(arm_modules)} files, launcher alpha library present)" if has_arm
          else "::notice::ARM payload not bundled: this app patches x64 CrossOver only")


if __name__ == "__main__":
    main()
