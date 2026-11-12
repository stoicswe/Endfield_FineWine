import Foundation

/// Removes the black margin around the Gryphline launcher on CrossOver ARM.
///
/// On x64 this is patch 0009 in winemac.so. CrossOver ARM's winemac.so can't be rebuilt, so the
/// payload carries `fwalpha.dylib` (patches/ARM/winemac-shim), which applies the same behaviour at
/// runtime in the launcher's process, and this adds a load command for it to winemac.so. The
/// command fits in the padding after winemac.so's existing load commands, so nothing else in the
/// file moves; the file is then ad-hoc signed again. The loader has
/// `disable-library-validation`, so the ad-hoc signed library is allowed to load.
enum ArmLauncherAlpha {
    static let winemacSubpath = "lib/wine/aarch64-unix/winemac.so"
    static let libraryName = "@loader_path/fwalpha.dylib"

    private static let mhMagic64: UInt32 = 0xfeedfacf
    private static let lcLoadDylib: UInt32 = 0xc
    private static let lcSegment64: UInt32 = 0x19
    private static let lcCodeSignature: UInt32 = 0x1d

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[offset + $1]) }
    }

    private static func put32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
        for index in 0..<4 { bytes[offset + index] = UInt8((value >> (8 * UInt32(index))) & 0xff) }
    }

    private struct LoadCommand { let offset: Int, command: UInt32, size: Int }

    private static func loadCommands(_ bytes: [UInt8]) throws -> [LoadCommand] {
        guard bytes.count >= 32, u32(bytes, 0) == mhMagic64 else {
            throw PatchError("winemac.so isn't a 64-bit Mach-O file.")
        }
        var commands: [LoadCommand] = []
        var offset = 32
        for _ in 0..<Int(u32(bytes, 16)) {
            guard offset + 8 <= bytes.count else { throw PatchError("winemac.so's load commands are truncated.") }
            let size = Int(u32(bytes, offset + 4))
            guard size >= 8 else { throw PatchError("winemac.so has a malformed load command.") }
            commands.append(LoadCommand(offset: offset, command: u32(bytes, offset), size: size))
            offset += size
        }
        return commands
    }

    private static func dylibName(_ bytes: [UInt8], _ command: LoadCommand) -> String {
        let start = command.offset + Int(u32(bytes, command.offset + 8))
        let end = command.offset + command.size
        guard start < end, end <= bytes.count else { return "" }
        let raw = bytes[start..<end].prefix { $0 != 0 }
        return String(decoding: raw, as: UTF8.self)
    }

    static func hasLoadCommand(in data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard let commands = try? loadCommands(bytes) else { return false }
        return commands.contains { $0.command == lcLoadDylib && dylibName(bytes, $0) == libraryName }
    }

    /// Appends an LC_LOAD_DYLIB for `libraryName`. The file must not be signed, since the code
    /// signature covers the header.
    static func addLoadCommand(to data: Data) throws -> Data {
        var bytes = [UInt8](data)
        let commands = try loadCommands(bytes)
        if commands.contains(where: { $0.command == lcLoadDylib && dylibName(bytes, $0) == libraryName }) {
            return data
        }
        guard !commands.contains(where: { $0.command == lcCodeSignature }) else {
            throw PatchError("winemac.so must be unsigned before its load commands change.")
        }
        // The first section's file offset bounds the room the header may grow into.
        var firstSection = bytes.count
        for command in commands where command.command == lcSegment64 {
            let sections = Int(u32(bytes, command.offset + 64))
            for index in 0..<sections {
                let fileOffset = Int(u32(bytes, command.offset + 72 + index * 80 + 48))
                if fileOffset > 0 { firstSection = min(firstSection, fileOffset) }
            }
        }
        let name = Array(libraryName.utf8) + [0]
        let size = (24 + name.count + 7) & ~7
        let end = 32 + Int(u32(bytes, 20))
        guard end + size <= firstSection, bytes[end..<end + size].allSatisfy({ $0 == 0 }) else {
            throw PatchError("winemac.so has no room for another load command.")
        }
        put32(&bytes, end, lcLoadDylib)
        put32(&bytes, end + 4, UInt32(size))
        put32(&bytes, end + 8, 24)              // name offset
        put32(&bytes, end + 12, 2)              // timestamp
        put32(&bytes, end + 16, 0x10000)        // current version 1.0.0
        put32(&bytes, end + 20, 0x10000)        // compatibility version 1.0.0
        bytes.replaceSubrange(end + 24..<end + 24 + name.count, with: name)
        put32(&bytes, 16, u32(bytes, 16) + 1)
        put32(&bytes, 20, u32(bytes, 20) + UInt32(size))
        return Data(bytes)
    }

    /// Adds the load command to the CrossOver root's winemac.so and signs it again. The edited
    /// file replaces the original as a new file: rewriting a signed Mach-O in place leaves the
    /// kernel's cached signature for it stale, and it is then killed on load.
    static func apply(toCrossOverRoot cxr: URL, sign: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let url = cxr.appendingPathComponent(winemacSubpath)
        guard fm.fileExists(atPath: cxr.appendingPathComponent("lib/wine/aarch64-unix/fwalpha.dylib").path) else {
            throw PatchError("fwalpha.dylib is missing from the patched app.")
        }
        if hasLoadCommand(in: try Data(contentsOf: url)) { return }

        let staged = url.deletingLastPathComponent().appendingPathComponent(".winemac.so.fwalpha")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: url, to: staged)
        do {
            try removeSignature(staged)
            try addLoadCommand(to: try Data(contentsOf: staged)).write(to: staged)
            try sign(staged)
            _ = try fm.replaceItemAt(url, withItemAt: staged)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
    }

    static func isApplied(inCrossOverRoot cxr: URL) -> Bool {
        guard let data = try? Data(contentsOf: cxr.appendingPathComponent(winemacSubpath)) else { return false }
        return hasLoadCommand(in: data)
    }

    private static func removeSignature(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--remove-signature", url.path]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PatchError("codesign couldn't remove winemac.so's signature.")
        }
    }
}
