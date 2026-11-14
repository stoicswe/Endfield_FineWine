import Foundation
import CryptoKit

/// Fixes two ARM64EC `ntdll.dll` bugs in CrossOver ARM that froze or crashed Endfield: at the
/// Gryphline logo, and when loading into the world.
///
/// 1. `RtlWalkFrameChain`, behind `RtlCaptureStackBackTrace`, keeps unwinding when
///    `RtlLookupFunctionEntry` finds no function. The x64 rule for that case treats the word at the
///    stack pointer as the return address, so the walk slides up the stack through stale data until
///    it reads junk unwind data and faults. il2cpp captures stack traces this way, and the fault's
///    own dispatch walks the same stack and derails too. A three-instruction cave in the `.text`
///    padding adds the `if (!func) break;` that the x86_64 version has (upstream Wine 11.21 lacks it).
/// 2. Every unwound pc is looked up in `EcCodeBitMap` without a bounds check, so a junk pc reads
///    outside the map and faults, and those faults recurse until Wine kills the main thread.
///
/// ARM64EC `ntdll.dll` looks up every unwound pc in `EcCodeBitMap` without a bounds check, so a junk
/// pc reads outside the map and faults. That fault dispatches, reaches the same pc and faults again
/// until Wine kills the game's main thread. Each lookup's index is clamped in place:
/// `lsr xd, xn, #18` becomes `ubfx xd, xn, #18, #29`, which keeps the 47 user address bits the map
/// covers. Upstream Wine 11.21's `RtlIsEcCode` still has no bounds check.
///
/// A third edit is a compatibility setting, not a crash fix: `IsWow64Process2` reports an emulated
/// x64 process as `AMD64` on `ARM64` instead of "not WOW64" on `ARM64` (see `machineEdits`).
///
/// CrossOver ARM's source isn't published, so ntdll can't be rebuilt and both fixes are byte edits.
enum ArmNtdllFix {
    static let subpath = "lib/wine/aarch64-windows/ntdll.dll"

    /// One CrossOver ARM build's ntdll.dll: its stock and fixed hashes, and the file offset and
    /// expected `lsr xd, xn, #18` encoding of each lookup. These nine are the only `lsr #18` in
    /// either file, in the same order and with the same registers; only their offsets move.
    ///
    /// `walkEdits` are the frame-walk fix's words: file offset, expected word and replacement.
    /// `machineEdits` change what `IsWow64Process2` reports, in the same form.
    /// `earlierFixedSHA256` lists files from earlier FineWine releases (lookups clamped, with or
    /// without the later edits), which are upgraded by applying whichever edits are missing.
    struct Build {
        let name: String
        let stockSHA256: String
        let fixedSHA256: String
        let sites: [(offset: Int, instruction: UInt32)]
        var walkEdits: [(offset: Int, from: UInt32, to: UInt32)] = []
        var machineEdits: [(offset: Int, from: UInt32, to: UInt32)] = []
        var earlierFixedSHA256: [String] = []
    }

    static let builds: [Build] = [
        Build(name: "27.0.0.41073 (preview 20261015, Wine 11.17)",
              stockSHA256: "a6678f9d0818e1cdb325e1ce8a07a540433f544b6f756c52a6ab1cfd3f632408",
              fixedSHA256: "810e9e7ff7697d6974085dba060bed59fb1b8bf26e95e814500ada229cdc9d80",
              sites: [
                (0xc7910, 0xd352fd71), (0xcc790, 0xd352fe69), (0xccd28, 0xd352fc09),
                (0xccdb0, 0xd352fd0a), (0xccf3c, 0xd352fd0a), (0xcd198, 0xd352fd0a),
                (0xcd500, 0xd352fc29), (0xcdb20, 0xd352fd0a), (0xcdd88, 0xd352fec9),
              ]),
        Build(name: "27.0.0.41303 (preview 20261111, Wine 11.21)",
              stockSHA256: "3c2d6459113d4418a1135d7d5afe3a47c4a8c017aec389a987efa991bfeceda8",
              fixedSHA256: "22dbe4f708540b4fd41076e4617eafd532c616bf18e9fb4638e44f96c536b703",
              sites: [
                (0xc8380, 0xd352fd71), (0xcd21c, 0xd352fe69), (0xcd7b4, 0xd352fc09),
                (0xcd83c, 0xd352fd0a), (0xcd9c8, 0xd352fd0a), (0xcdc24, 0xd352fd0a),
                (0xcdf8c, 0xd352fc29), (0xce5ac, 0xd352fd0a), (0xce814, 0xd352fec9),
              ],
              // RtlWalkFrameChain at 0x1800ce7b8. After RtlLookupFunctionEntry returns in x0:
              //   0x1800ce848  ldr x1, [sp, #0x510]  ->  b 0x180101dc0
              // and in the int3 padding after .text's last x64 thunk:
              //   0x180101dc0  cbz x0, 0x1800ce8e4   (the loop's exit: return the frames so far)
              //   0x180101dc4  ldr x1, [sp, #0x510]  (the moved instruction)
              //   0x180101dc8  b 0x1800ce84c
              walkEdits: [
                (0xce848, 0xf9428be1, 0x1400cd5e),
                (0x101dc0, 0xcccccccc, 0xb4e65920),
                (0x101dc4, 0xcccccccc, 0xf9428be1),
                (0x101dc8, 0xcccccccc, 0x17ff32a1),
              ],
              // ARM64EC RtlWow64GetProcessMachines, behind IsWow64Process2, asks ntdll.so for
              // SystemSupportedProcessorArchitectures (181), which hides the AMD64 entry on ARM64,
              // so an x64 process comes back as process 0 (not WOW64), native ARM64. Asking for
              // SystemSupportedProcessorArchitectures2 (230) keeps the entry, giving process AMD64,
              // native ARM64; a native ARM64 process still reports 0.
              //   0x1800b78a4  mov w0, #0xb5  ->  mov w0, #0xe6
              // Wine's tests expect 0 on Windows on ARM; a user report says hardware gives AMD64.
              // It doesn't change ACE (tested 2026-11-13) and is kept at the project's choice.
              machineEdits: [
                (0xb78a4, 0x528016a0, 0x52801cc0),
              ],
              earlierFixedSHA256: [
                "d998d34c9a806d27d7440e7ce86af3117e58404c44d200e7de467480b5798f63",
                "cb06b76445b106f5ddb8ae2df437c12b8982264b3ce529e4a21fa6fec2cab4b2",
              ]),
    ]

    private static let immsMask: UInt32 = 0x3f << 10
    private static let clampedImms: UInt32 = 46 << 10

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Rewrites `build`'s lookups in `data`. Throws if any site doesn't hold the expected instruction.
    static func clampLookups(in data: Data, build: Build) throws -> Data {
        var bytes = [UInt8](data)
        for site in build.sites {
            guard site.offset + 4 <= bytes.count else {
                throw PatchError("CrossOver ARM's ntdll.dll is smaller than expected.")
            }
            let found = bytes[site.offset..<site.offset + 4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard found == site.instruction else {
                throw PatchError("CrossOver ARM's ntdll.dll has unexpected code at offset \(site.offset).")
            }
            let clamped = (found & ~immsMask) | clampedImms
            for index in 0..<4 { bytes[site.offset + index] = UInt8((clamped >> (8 * UInt32(index))) & 0xff) }
        }
        return Data(bytes)
    }

    /// Applies `build`'s frame-walk fix to `data`. Throws if any word isn't the expected one.
    static func fixFrameWalk(in data: Data, build: Build) throws -> Data {
        try applyEdits(build.walkEdits, to: data, acceptApplied: false)
    }

    /// Applies `build`'s `IsWow64Process2` change to `data`.
    static func reportProcessMachine(in data: Data, build: Build) throws -> Data {
        try applyEdits(build.machineEdits, to: data, acceptApplied: false)
    }

    /// Replaces each edit's word. With `acceptApplied`, a word that already holds the replacement
    /// is left alone, which is what upgrading an earlier fixed file needs.
    private static func applyEdits(_ edits: [(offset: Int, from: UInt32, to: UInt32)], to data: Data,
                                   acceptApplied: Bool) throws -> Data {
        var bytes = [UInt8](data)
        for edit in edits {
            guard edit.offset + 4 <= bytes.count else {
                throw PatchError("CrossOver ARM's ntdll.dll is smaller than expected.")
            }
            let found = bytes[edit.offset..<edit.offset + 4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            if acceptApplied && found == edit.to { continue }
            guard found == edit.from else {
                throw PatchError("CrossOver ARM's ntdll.dll has unexpected code at offset \(edit.offset).")
            }
            for index in 0..<4 { bytes[edit.offset + index] = UInt8((edit.to >> (8 * UInt32(index))) & 0xff) }
        }
        return Data(bytes)
    }

    /// Every edit, from the stock file.
    static func fix(_ data: Data, build: Build) throws -> Data {
        let walked = try fixFrameWalk(in: clampLookups(in: data, build: build), build: build)
        return try reportProcessMachine(in: walked, build: build)
    }

    /// Applies the fix to a CrossOver root, accepting only the exact files it was written for: the
    /// stock file, or one an earlier FineWine release fixed.
    static func apply(toCrossOverRoot cxr: URL) throws {
        let url = cxr.appendingPathComponent(subpath)
        let data = try Data(contentsOf: url)
        let hash = sha256Hex(data)
        if builds.contains(where: { $0.fixedSHA256 == hash }) { return }
        let fixed: Data
        let build: Build
        if let stock = builds.first(where: { $0.stockSHA256 == hash }) {
            build = stock
            fixed = try fix(data, build: build)
        } else if let earlier = builds.first(where: { $0.earlierFixedSHA256.contains(hash) }) {
            build = earlier
            fixed = try applyEdits(build.walkEdits + build.machineEdits, to: data, acceptApplied: true)
        } else {
            throw PatchError("This CrossOver ARM build's ntdll.dll isn't one FineWine knows how to fix, so the game would freeze at the Gryphline logo or when loading into the world.")
        }
        guard sha256Hex(fixed) == build.fixedSHA256 else {
            throw PatchError("The ntdll.dll fix produced an unexpected file.")
        }
        try fixed.write(to: url, options: .atomic)
    }

    static func isApplied(inCrossOverRoot cxr: URL) -> Bool {
        guard let data = try? Data(contentsOf: cxr.appendingPathComponent(subpath)) else { return false }
        let hash = sha256Hex(data)
        return builds.contains { $0.fixedSHA256 == hash }
    }
}
