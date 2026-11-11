import Foundation
import CryptoKit

/// Fixes the exception-dispatch bug that froze Endfield at the Gryphline logo on CrossOver ARM.
///
/// ARM64EC `ntdll.dll` looks up every unwound pc in `EcCodeBitMap` without a bounds check, so a junk
/// pc reads outside the map and faults. That fault dispatches, reaches the same pc and faults again
/// until Wine kills the game's main thread. CrossOver ARM's ntdll can't be rebuilt, because its
/// source isn't published, so each lookup's index is clamped in place: `lsr xd, xn, #18` becomes
/// `ubfx xd, xn, #18, #29`, which keeps the 47 user address bits the map covers. Upstream Wine
/// 11.21's `RtlIsEcCode` still has no bounds check.
enum ArmNtdllFix {
    static let subpath = "lib/wine/aarch64-windows/ntdll.dll"

    /// One CrossOver ARM build's ntdll.dll: its stock and fixed hashes, and the file offset and
    /// expected `lsr xd, xn, #18` encoding of each lookup. These nine are the only `lsr #18` in
    /// either file, in the same order and with the same registers; only their offsets move.
    struct Build {
        let name: String
        let stockSHA256: String
        let fixedSHA256: String
        let sites: [(offset: Int, instruction: UInt32)]
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
              fixedSHA256: "d998d34c9a806d27d7440e7ce86af3117e58404c44d200e7de467480b5798f63",
              sites: [
                (0xc8380, 0xd352fd71), (0xcd21c, 0xd352fe69), (0xcd7b4, 0xd352fc09),
                (0xcd83c, 0xd352fd0a), (0xcd9c8, 0xd352fd0a), (0xcdc24, 0xd352fd0a),
                (0xcdf8c, 0xd352fc29), (0xce5ac, 0xd352fd0a), (0xce814, 0xd352fec9),
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

    /// Applies the fix to a CrossOver root, accepting only the exact files it was written for.
    static func apply(toCrossOverRoot cxr: URL) throws {
        let url = cxr.appendingPathComponent(subpath)
        let data = try Data(contentsOf: url)
        let hash = sha256Hex(data)
        if builds.contains(where: { $0.fixedSHA256 == hash }) { return }
        guard let build = builds.first(where: { $0.stockSHA256 == hash }) else {
            throw PatchError("This CrossOver ARM build's ntdll.dll isn't one FineWine knows how to fix, so the game would freeze at the Gryphline logo.")
        }
        let fixed = try clampLookups(in: data, build: build)
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
