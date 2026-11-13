import Foundation
import CryptoKit

/// The CPU name CrossOver ARM's x64 emulator (FEX, `xtajit64.dll`) reports through CPUID, and
/// CPUID's "hypervisor present" bit.
///
/// FEX names the CPU from the chip's ID register, which Wine doesn't provide on a Mac, so the brand
/// string falls back to `Unknown ARM CPU`. This replaces that fallback with the Mac's own CPU name,
/// e.g. `Apple M3`. The hypervisor bit is cleared with FEX's own `FEX_HIDEHYPERVISORBIT=1` setting,
/// which Automated Setup writes into ARM bottles (`environment`). FEX's hypervisor vendor leaf
/// (`0x40000000`, `FEXIFEXIEMU`) is left as CrossOver ships it.
///
/// These are compatibility settings, not crash fixes, so nothing here fails a patch or a setup: a
/// file that isn't a known build is left alone. Wine loads the emulator from the bottle's
/// `system32`, which bottle creation copies from the app, so both copies are edited.
enum ArmEmulatorIdentity {
    static let appSubpath = "lib/wine/aarch64-windows/xtajit64.dll"
    static let bottleSubpath = "drive_c/windows/system32/xtajit64.dll"
    /// `[EnvironmentVariables]` entries for ARM bottles.
    static let environment: [(key: String, value: String)] = [("FEX_HIDEHYPERVISORBIT", "1")]

    /// One CrossOver ARM build's `xtajit64.dll`. `nameOffset` is the file offset of the 16-byte
    /// `Unknown ARM CPU` literal the brand string falls back to.
    struct Build {
        let name: String
        let stockSHA256: String
        let nameOffset: Int
    }

    static let builds: [Build] = [
        Build(name: "27.0.0.41303 (preview 20261111, FEX in Wine 11.21)",
              stockSHA256: "94a64d852a3b6205ac2cdcaabe128629e0861f944e1de17718d8295ab1ed033a",
              nameOffset: 0x2284c0),
    ]

    static let stockName = "Unknown ARM CPU"
    static let nameFieldSize = 16
    private static var stockField: [UInt8] { Array(stockName.utf8) + [0] }

    /// The Mac's CPU name as macOS reports it, e.g. `Apple M3`.
    static func hostCPUName() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// The name as it fits the literal: printable ASCII, at most 15 bytes. `nil` if nothing is left.
    static func fieldName(_ name: String) -> [UInt8]? {
        let bytes = name.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7f }.map { UInt8($0.value) }
        let trimmed = Array(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces).utf8.prefix(nameFieldSize - 1))
        return trimmed.isEmpty ? nil : trimmed
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Writes `cpuName` over the fallback literal of a stock `build` file. Throws if the literal
    /// isn't where the build recorded it.
    static func patched(_ data: Data, build: Build, cpuName: String) throws -> Data {
        var bytes = [UInt8](data)
        let range = build.nameOffset..<build.nameOffset + nameFieldSize
        guard range.upperBound <= bytes.count, Array(bytes[range]) == stockField else {
            throw PatchError("CrossOver ARM's xtajit64.dll has unexpected data at offset \(build.nameOffset).")
        }
        guard let name = fieldName(cpuName) else { return data }
        bytes.replaceSubrange(range, with: name + [UInt8](repeating: 0, count: nameFieldSize - name.count))
        return Data(bytes)
    }

    /// The known build `data` is an edited copy of: the same file once the literal is put back.
    static func editedBuild(of data: Data) -> Build? {
        builds.first { build in
            let range = build.nameOffset..<build.nameOffset + nameFieldSize
            guard range.upperBound <= data.count else { return false }
            var bytes = [UInt8](data)
            guard Array(bytes[range]) != stockField else { return false }
            bytes.replaceSubrange(range, with: stockField)
            return sha256Hex(Data(bytes)) == build.stockSHA256
        }
    }

    /// Edits the file at `url` if it is a known stock build. Returns whether the file now carries
    /// (or already carried) a CPU name; an unknown or missing file is left alone and reports `false`.
    @discardableResult
    static func apply(toFile url: URL, cpuName: String? = hostCPUName()) throws -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        if editedBuild(of: data) != nil { return true }
        guard let cpuName, fieldName(cpuName) != nil,
              let build = builds.first(where: { $0.stockSHA256 == sha256Hex(data) }) else { return false }
        try patched(data, build: build, cpuName: cpuName).write(to: url, options: .atomic)
        return true
    }

    @discardableResult
    static func apply(toCrossOverRoot cxr: URL) throws -> Bool {
        try apply(toFile: cxr.appendingPathComponent(appSubpath))
    }

    @discardableResult
    static func apply(toBottle bottle: URL) throws -> Bool {
        try apply(toFile: bottle.appendingPathComponent(bottleSubpath))
    }
}
