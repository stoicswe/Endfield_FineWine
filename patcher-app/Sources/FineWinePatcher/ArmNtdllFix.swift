import Foundation
import CryptoKit

/// Fixes the exception-dispatch bug that froze Endfield at the Gryphline logo on CrossOver ARM.
///
/// ARM64EC `ntdll.dll` looks up every unwound pc in `EcCodeBitMap` without a bounds check, so a junk
/// pc reads outside the map and faults. That fault dispatches, reaches the same pc and faults again
/// until Wine kills the game's main thread. CrossOver ARM's ntdll can't be rebuilt, because its
/// source isn't published, so each lookup's index is clamped in place: `lsr xd, xn, #18` becomes
/// `ubfx xd, xn, #18, #29`, which keeps the 47 user address bits the map covers.
enum ArmNtdllFix {
    static let subpath = "lib/wine/aarch64-windows/ntdll.dll"
    static let stockSHA256 = "a6678f9d0818e1cdb325e1ce8a07a540433f544b6f756c52a6ab1cfd3f632408"
    static let fixedSHA256 = "810e9e7ff7697d6974085dba060bed59fb1b8bf26e95e814500ada229cdc9d80"

    /// File offset and expected `lsr xd, xn, #18` encoding of each lookup.
    static let sites: [(offset: Int, instruction: UInt32)] = [
        (0xc7910, 0xd352fd71), (0xcc790, 0xd352fe69), (0xccd28, 0xd352fc09),
        (0xccdb0, 0xd352fd0a), (0xccf3c, 0xd352fd0a), (0xcd198, 0xd352fd0a),
        (0xcd500, 0xd352fc29), (0xcdb20, 0xd352fd0a), (0xcdd88, 0xd352fec9),
    ]

    private static let immsMask: UInt32 = 0x3f << 10
    private static let clampedImms: UInt32 = 46 << 10

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Rewrites the lookups in `data`. Throws if any site doesn't hold the expected instruction.
    static func clampLookups(in data: Data) throws -> Data {
        var bytes = [UInt8](data)
        for site in sites {
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

    /// Applies the fix to a CrossOver root, accepting only the exact file it was written for.
    static func apply(toCrossOverRoot cxr: URL) throws {
        let url = cxr.appendingPathComponent(subpath)
        let data = try Data(contentsOf: url)
        switch sha256Hex(data) {
        case fixedSHA256:
            return
        case stockSHA256:
            let fixed = try clampLookups(in: data)
            guard sha256Hex(fixed) == fixedSHA256 else {
                throw PatchError("The ntdll.dll fix produced an unexpected file.")
            }
            try fixed.write(to: url, options: .atomic)
        default:
            throw PatchError("This CrossOver ARM build's ntdll.dll isn't one FineWine knows how to fix, so the game would freeze at the Gryphline logo.")
        }
    }

    static func isApplied(inCrossOverRoot cxr: URL) -> Bool {
        guard let data = try? Data(contentsOf: cxr.appendingPathComponent(subpath)) else { return false }
        return sha256Hex(data) == fixedSHA256
    }
}
