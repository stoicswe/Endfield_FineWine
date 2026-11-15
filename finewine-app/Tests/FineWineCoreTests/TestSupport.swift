import XCTest
@testable import FineWineCore

/// The temporary directory with symlinks resolved (`/private/var/…`), which is the form
/// directory listings and `pwd` report.
func realTemporaryDirectory() -> URL {
    let path = FileManager.default.temporaryDirectory.path
    guard let real = realpath(path, nil) else { return URL(fileURLWithPath: path, isDirectory: true) }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

/// A scratch FineWine data folder that is deleted when the test ends.
final class Sandbox {
    let root: URL
    let paths: FineWinePaths

    init() {
        root = realTemporaryDirectory()
            .appendingPathComponent("finewine-tests-\(UUID().uuidString)", isDirectory: true)
        paths = FineWinePaths(root: root.appendingPathComponent("Support", isDirectory: true),
                              shortcuts: root.appendingPathComponent("Shortcuts", isDirectory: true))
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// A folder laid out like a Wine runtime, with stand-in executables.
    @discardableResult
    func makeRuntime(at dir: URL? = nil, manifest: RuntimeManifest? = nil,
                     wine: Bool = true, server: Bool = true) -> URL {
        let dir = dir ?? root.appendingPathComponent("runtime-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try! fm.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try! fm.createDirectory(at: dir.appendingPathComponent("lib/wine"), withIntermediateDirectories: true)
        for (name, wanted) in [("wine", wine), ("wineserver", server)] where wanted {
            let file = dir.appendingPathComponent("bin/\(name)")
            try! Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        if let manifest {
            try! JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent(RuntimeStore.manifestName))
        }
        return dir
    }

    func write(_ text: String, to url: URL) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: url)
    }

    func write(_ data: Data, to url: URL) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: url)
    }
}

/// Records the plans it is asked to run instead of starting anything.
final class RecordingRunner: ProcessRunning, @unchecked Sendable {
    var ran: [LaunchPlan] = []
    var started: [(plan: LaunchPlan, logFile: URL?)] = []
    /// Exit status for `run`, chosen per plan.
    var status: (LaunchPlan) -> Int32 = { _ in 0 }
    /// Called for every `run`, e.g. to fake what Wine would write.
    var onRun: (LaunchPlan) -> Void = { _ in }

    func run(_ plan: LaunchPlan) throws -> ProcessResult {
        ran.append(plan)
        onRun(plan)
        return ProcessResult(status: status(plan), output: "line one\nline two\n")
    }

    func start(_ plan: LaunchPlan, logFile: URL?, onExit: @escaping @Sendable (Int32) -> Void) throws -> Int32 {
        started.append((plan, logFile))
        return 4242
    }
}

enum Bytes {
    static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    static func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16((v >> 16) & 0xFFFF) }
    static func utf16(_ s: String) -> [UInt8] { s.utf16.flatMap { le16(Int($0)) } }
}

/// Builds `.lnk` data the way Windows lays it out.
enum LinkBuilder {
    static func make(target: String, name: String? = nil, workingDirectory: String? = nil,
                     arguments: String? = nil, unicode: Bool = true, withIDList: Bool = true,
                     unicodeLinkInfo: Bool = false) -> Data {
        var flags = 0x02   // HasLinkInfo
        if withIDList { flags |= 0x01 }
        if name != nil { flags |= 0x04 }
        if workingDirectory != nil { flags |= 0x10 }
        if arguments != nil { flags |= 0x20 }
        if unicode { flags |= 0x80 }

        var out: [UInt8] = Bytes.le32(0x4C)
        out += [0x01, 0x14, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46]
        out += Bytes.le32(flags)
        out += [UInt8](repeating: 0, count: 0x4C - out.count)
        if withIDList {
            let idList: [UInt8] = [5, 0, 1, 2, 3, 0, 0]   // one item and the terminator
            out += Bytes.le16(idList.count) + idList
        }

        let ansi = Array(target.utf8) + [0]
        if unicodeLinkInfo {
            let headerSize = 0x24
            let wide = Bytes.utf16(target) + [0, 0]
            let ansiOffset = headerSize
            let suffixOffset = ansiOffset + ansi.count
            let wideOffset = suffixOffset + 1
            let wideSuffixOffset = wideOffset + wide.count
            let size = wideSuffixOffset + 2
            out += Bytes.le32(size) + Bytes.le32(headerSize) + Bytes.le32(1) + Bytes.le32(0)
            out += Bytes.le32(ansiOffset) + Bytes.le32(0) + Bytes.le32(suffixOffset)
            out += Bytes.le32(wideOffset) + Bytes.le32(wideSuffixOffset)
            out += ansi + [0] + wide + [0, 0]
        } else {
            let headerSize = 0x1C
            let size = headerSize + ansi.count + 1
            out += Bytes.le32(size) + Bytes.le32(headerSize) + Bytes.le32(1) + Bytes.le32(0)
            out += Bytes.le32(headerSize) + Bytes.le32(0) + Bytes.le32(headerSize + ansi.count)
            out += ansi + [0]
        }

        for string in [name, workingDirectory, arguments].compactMap({ $0 }) {
            if unicode {
                out += Bytes.le16(string.utf16.count) + Bytes.utf16(string)
            } else {
                out += Bytes.le16(string.utf8.count) + Array(string.utf8)
            }
        }
        return Data(out)
    }
}

/// Builds a minimal PE file whose only section is a resource table with one icon group.
enum PEBuilder {
    /// `images` are (width, height, bytes) of each icon image in the group.
    static func make(images: [(width: Int, height: Int, data: [UInt8])], pe32Plus: Bool = true,
                     includeResources: Bool = true) -> Data {
        let peOffset = 0x80
        let optionalSize = pe32Plus ? 240 : 224
        let sectionTable = peOffset + 24 + optionalSize
        let rawOffset = 0x400
        let rva = 0x2000

        // Resource section, laid out by hand: directories first, then data entries, then data.
        var rsrc: [UInt8] = []
        func directory(_ ids: [Int], _ targets: [Int], subdirectory: Bool) -> [UInt8] {
            var d = [UInt8](repeating: 0, count: 12) + Bytes.le16(0) + Bytes.le16(ids.count)
            for (id, target) in zip(ids, targets) {
                d += Bytes.le32(id) + Bytes.le32(subdirectory ? target | 0x8000_0000 : target)
            }
            return d
        }
        let n = images.count
        // Offsets within the section.
        let rootSize = 16 + 2 * 8
        let iconDir = rootSize
        let iconDirSize = 16 + n * 8
        let iconLang = iconDir + iconDirSize                // n language directories, 24 bytes each
        let groupDir = iconLang + n * 24
        let groupLang = groupDir + 24
        let dataEntries = groupLang + 24                    // n icon entries, then the group entry
        let blobs = dataEntries + (n + 1) * 16

        var group: [UInt8] = Bytes.le16(0) + Bytes.le16(1) + Bytes.le16(n)
        for (i, image) in images.enumerated() {
            group += [UInt8(image.width & 0xFF), UInt8(image.height & 0xFF), 0, 0]
            group += Bytes.le16(1) + Bytes.le16(32) + Bytes.le32(image.data.count) + Bytes.le16(i + 1)
        }
        var blobOffsets: [Int] = []
        var blobData: [UInt8] = []
        for image in images {
            blobOffsets.append(blobs + blobData.count)
            blobData += image.data
        }
        let groupOffset = blobs + blobData.count
        blobData += group

        rsrc += directory([3, 14], [iconDir, groupDir], subdirectory: true)
        rsrc += directory(Array(1...max(n, 1)).prefix(n).map { $0 }, (0..<n).map { iconLang + $0 * 24 }, subdirectory: true)
        for i in 0..<n { rsrc += directory([1033], [dataEntries + i * 16], subdirectory: false) }
        rsrc += directory([1], [groupLang], subdirectory: true)
        rsrc += directory([1033], [dataEntries + n * 16], subdirectory: false)
        for (i, image) in images.enumerated() {
            rsrc += Bytes.le32(rva + blobOffsets[i]) + Bytes.le32(image.data.count) + Bytes.le32(0) + Bytes.le32(0)
        }
        rsrc += Bytes.le32(rva + groupOffset) + Bytes.le32(group.count) + Bytes.le32(0) + Bytes.le32(0)
        rsrc += blobData

        var file = [UInt8](repeating: 0, count: rawOffset)
        func put(_ bytes: [UInt8], at offset: Int) { file.replaceSubrange(offset..<offset + bytes.count, with: bytes) }
        put([0x4D, 0x5A], at: 0)
        put(Bytes.le32(peOffset), at: 0x3C)
        put([0x50, 0x45, 0, 0], at: peOffset)
        put(Bytes.le16(1), at: peOffset + 6)                 // one section
        put(Bytes.le16(optionalSize), at: peOffset + 20)
        let optional = peOffset + 24
        put(Bytes.le16(pe32Plus ? 0x20B : 0x10B), at: optional)
        let directories = optional + (pe32Plus ? 112 : 96)
        if includeResources {
            put(Bytes.le32(rva) + Bytes.le32(rsrc.count), at: directories + 2 * 8)
        }
        put(Array(".rsrc\0\0\0".utf8), at: sectionTable)
        put(Bytes.le32(rsrc.count) + Bytes.le32(rva) + Bytes.le32(rsrc.count) + Bytes.le32(rawOffset), at: sectionTable + 8)
        return Data(file + rsrc)
    }
}
