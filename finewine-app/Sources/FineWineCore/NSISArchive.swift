import Foundation
import Compression

/// Reads an NSIS installer (Nullsoft Scriptable Install System) without running it.
///
/// An NSIS installer is a small 32-bit Windows program followed by its data: a header holding
/// the install script (instructions, strings, sections) and then the files, compressed either
/// each on their own or all as one stream ("solid"). FineWine's runtime cannot run 32-bit
/// programs, so the installer's own code never runs here: this type gets at the script and
/// the files, and `NSISScript` carries the script out.
///
/// Supported: NSIS 3 Unicode installers compressed with zlib (deflate) or LZMA, solid or not.
/// Not supported, and reported as such: ANSI installers (NSIS 2 and ANSI builds of NSIS 3) and
/// bzip2 compression.
public final class NSISArchive {
    public enum Compression: String, Sendable { case none, deflate, lzma, bzip2 }

    public struct Unsupported: Error, LocalizedError, Sendable {
        public let reason: String
        public var errorDescription: String? { reason }
    }

    /// The uncompressed header: script and strings.
    public let header: Data
    public let compression: Compression
    public let isSolid: Bool

    private let file: FileHandle
    /// Where the files' data starts: in the installer itself, or in `unpacked` when solid.
    private let dataBase: UInt64
    /// The whole solid stream, decompressed to a temporary file once.
    private let unpacked: FileHandle?
    private let unpackedURL: URL?
    private let lzmaHasFilterByte: Bool

    // MARK: Recognising

    /// The offset of the NSIS data in a file, or nil when it is not an NSIS installer.
    /// The data starts on a 512-byte boundary with a 28-byte "first header".
    static func firstHeaderOffset(in file: FileHandle, size: UInt64) -> UInt64? {
        var offset: UInt64 = 0
        let signature = Data([0xEF, 0xBE, 0xAD, 0xDE]) + Data("NullsoftInst".utf8)
        // Installer programs are small; the data follows within the first megabytes.
        while offset + 28 <= size, offset < 64 << 20 {
            try? file.seek(toOffset: offset + 4)
            if let chunk = try? file.read(upToCount: 16), chunk == signature { return offset }
            offset += 512
        }
        return nil
    }

    /// True when the file is an NSIS installer.
    public static func isNSISInstaller(_ url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        let size = (try? file.seekToEnd()) ?? 0
        return firstHeaderOffset(in: file, size: size) != nil
    }

    // MARK: Opening

    /// Opens the installer and reads its header. For a solid installer this decompresses
    /// everything to a temporary file, which takes as long as unpacking it does; `progress`
    /// is called with the fraction done.
    public init(url: URL, temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                progress: ((Double) -> Void)? = nil) throws {
        file = try FileHandle(forReadingFrom: url)
        let size = try file.seekToEnd()
        guard let start = Self.firstHeaderOffset(in: file, size: size) else {
            throw Unsupported(reason: "This is not an NSIS installer.")
        }
        try file.seek(toOffset: start)
        guard let first = try file.read(upToCount: 28), first.count == 28 else {
            throw Unsupported(reason: "The installer's data is cut short.")
        }
        let headerLength = Int(first.le32(at: 20))
        let body = start + 28
        try file.seek(toOffset: body)
        guard let probe = try file.read(upToCount: 16), probe.count == 16,
              headerLength > 0, headerLength < 64 << 20 else {
            throw Unsupported(reason: "The installer's data is cut short.")
        }

        func looksLikeLZMA(_ d: Data, _ at: Int) -> Bool {
            d[d.startIndex + at] == 0x5D && d[d.startIndex + at + 1] == 0 && d[d.startIndex + at + 2] == 0
                && d[d.startIndex + at + 5] == 0
        }
        func looksLikeBZip2(_ d: Data, _ at: Int) -> Bool {
            d[d.startIndex + at] == 0x31 && d[d.startIndex + at + 1] < 14
        }

        let firstWord = probe.le32(at: 0)
        var method: Compression
        var solid = true
        var filterByte = false
        if Int(firstWord) == headerLength {
            method = .none; solid = false
        } else if looksLikeLZMA(probe, 0) {
            method = .lzma
        } else if probe[probe.startIndex + 3] == 0x80 {
            solid = false
            if looksLikeLZMA(probe, 4) { method = .lzma }
            else if probe[probe.startIndex + 4] <= 1, looksLikeLZMA(probe, 5) { method = .lzma; filterByte = true }
            else if looksLikeBZip2(probe, 4) { method = .bzip2 }
            else { method = .deflate }
        } else if looksLikeBZip2(probe, 0) {
            method = .bzip2
        } else {
            method = .deflate
        }
        guard method != .bzip2 else {
            throw Unsupported(reason: "This installer is compressed with bzip2, which FineWine cannot unpack yet.")
        }
        compression = method
        isSolid = solid
        lzmaHasFilterByte = filterByte

        if solid {
            // One stream holds a length, the header, then every file with its length in front.
            let target = temporaryDirectory.appendingPathComponent("finewine-nsis-\(UUID().uuidString).bin")
            FileManager.default.createFile(atPath: target.path, contents: nil)
            let out = try FileHandle(forWritingTo: target)
            let total = Double(max(1, size - body))
            try file.seek(toOffset: body)
            let input = file
            var consumed = 0.0
            do {
                try Self.decode(method, filterByte: false, read: {
                    let chunk = (try? input.read(upToCount: 1 << 20)) ?? Data()
                    consumed += Double(chunk.count)
                    progress?(min(1, consumed / total))
                    return chunk
                }, write: { try out.write(contentsOf: $0) })
            } catch {
                try? out.close()
                try? FileManager.default.removeItem(at: target)
                throw error
            }
            try out.close()
            let reader = try FileHandle(forReadingFrom: target)
            unpacked = reader
            unpackedURL = target
            try reader.seek(toOffset: 0)
            guard let lengthField = try reader.read(upToCount: 4), lengthField.count == 4,
                  Int(lengthField.le32(at: 0)) == headerLength,
                  let data = try reader.read(upToCount: headerLength), data.count == headerLength else {
                try? reader.close()
                try? FileManager.default.removeItem(at: target)
                throw Unsupported(reason: "The installer's header could not be read.")
            }
            header = data
            dataBase = UInt64(4 + headerLength)
        } else {
            unpacked = nil
            unpackedURL = nil
            let stored = Int(firstWord & 0x7FFF_FFFF)
            try file.seek(toOffset: body + 4)
            guard let raw = try file.read(upToCount: stored), raw.count == stored else {
                throw Unsupported(reason: "The installer's header is cut short.")
            }
            if firstWord & 0x8000_0000 != 0 {
                header = try Self.decode(method, filterByte: filterByte, data: raw, limit: headerLength)
            } else {
                header = raw
            }
            guard header.count == headerLength else {
                throw Unsupported(reason: "The installer's header could not be read.")
            }
            dataBase = body + 4 + UInt64(stored)
        }
    }

    deinit {
        try? file.close()
        try? unpacked?.close()
        if let unpackedURL { try? FileManager.default.removeItem(at: unpackedURL) }
    }

    // MARK: Files

    /// Writes the file stored at `offset` (an instruction's data offset) to `destination`.
    public func extract(dataOffset offset: Int, to destination: URL) throws {
        guard offset >= 0 else { throw Unsupported(reason: "The installer refers to data that is not there.") }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        if let unpacked {
            try unpacked.seek(toOffset: dataBase + UInt64(offset))
            guard let field = try unpacked.read(upToCount: 4), field.count == 4 else {
                throw Unsupported(reason: "The installer's data is cut short.")
            }
            var left = Int(field.le32(at: 0) & 0x7FFF_FFFF)
            while left > 0 {
                guard let chunk = try unpacked.read(upToCount: min(left, 4 << 20)), !chunk.isEmpty else {
                    throw Unsupported(reason: "The installer's data is cut short.")
                }
                try out.write(contentsOf: chunk)
                left -= chunk.count
            }
            return
        }
        try file.seek(toOffset: dataBase + UInt64(offset))
        guard let field = try file.read(upToCount: 4), field.count == 4 else {
            throw Unsupported(reason: "The installer's data is cut short.")
        }
        let word = field.le32(at: 0)
        var left = Int(word & 0x7FFF_FFFF)
        let input = file
        let next: () -> Data = {
            guard left > 0 else { return Data() }
            let chunk = (try? input.read(upToCount: min(left, 1 << 20))) ?? Data()
            left -= chunk.count
            return chunk
        }
        if word & 0x8000_0000 != 0, compression != .none {
            try Self.decode(compression, filterByte: lzmaHasFilterByte, read: next, write: { try out.write(contentsOf: $0) })
        } else {
            while true {
                let chunk = next()
                if chunk.isEmpty { break }
                try out.write(contentsOf: chunk)
            }
        }
    }

    // MARK: Decompression

    private static func decode(_ method: Compression, filterByte: Bool, data: Data, limit: Int) throws -> Data {
        var out = Data()
        var sent = false
        try decode(method, filterByte: filterByte, read: {
            if sent { return Data() }
            sent = true
            return data
        }, write: { out.append($0) })
        return out.count > limit ? out.prefix(limit) : out
    }

    /// Decompresses a stream. `read` returns the next piece of input, empty at the end.
    private static func decode(_ method: Compression, filterByte: Bool,
                               read: () -> Data, write: (Data) throws -> Void) throws {
        switch method {
        case .none:
            while true {
                let chunk = read()
                if chunk.isEmpty { return }
                try write(chunk)
            }
        case .deflate:
            try inflate(read: read, write: write)
        case .lzma:
            try LZMADecoder.decode(skipFilterByte: filterByte, read: read, write: write)
        case .bzip2:
            throw Unsupported(reason: "This installer is compressed with bzip2, which FineWine cannot unpack yet.")
        }
    }

    /// Raw deflate, which is what NSIS calls zlib compression.
    private static func inflate(read: () -> Data, write: (Data) throws -> Void) throws {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Unsupported(reason: "The decompressor could not be started.")
        }
        defer { compression_stream_destroy(stream) }
        let capacity = 1 << 20
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        var input = read()
        var finished = false
        while !finished {
            if input.isEmpty { return }   // the stream has no end marker of its own
            let atEnd = false
            try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                stream.pointee.src_ptr = base
                stream.pointee.src_size = raw.count
                while stream.pointee.src_size > 0 {
                    stream.pointee.dst_ptr = buffer
                    stream.pointee.dst_size = capacity
                    let status = compression_stream_process(stream, atEnd ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    let produced = capacity - stream.pointee.dst_size
                    if produced > 0 { try write(Data(bytes: buffer, count: produced)) }
                    if status == COMPRESSION_STATUS_END { finished = true; return }
                    if status == COMPRESSION_STATUS_ERROR {
                        throw Unsupported(reason: "The installer's data is damaged or compressed in a way FineWine does not know.")
                    }
                }
                // drain what is still buffered inside the decoder
                while true {
                    stream.pointee.dst_ptr = buffer
                    stream.pointee.dst_size = capacity
                    let status = compression_stream_process(stream, 0)
                    let produced = capacity - stream.pointee.dst_size
                    if produced > 0 { try write(Data(bytes: buffer, count: produced)) }
                    if status == COMPRESSION_STATUS_END { finished = true; return }
                    if status == COMPRESSION_STATUS_ERROR {
                        throw Unsupported(reason: "The installer's data is damaged or compressed in a way FineWine does not know.")
                    }
                    if produced < capacity { break }
                }
            }
            if !finished { input = read() }
        }
    }
}

/// LZMA as NSIS stores it: five property bytes and then the stream, with no length and no end
/// marker. macOS has liblzma but no header for it, so the few calls needed are looked up by
/// name. The stream is given the 13-byte header of the ".lzma" format with "length unknown".
enum LZMADecoder {
    private typealias AloneDecoder = @convention(c) (UnsafeMutableRawPointer, UInt64) -> Int32
    private typealias Code = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    private typealias End = @convention(c) (UnsafeMutableRawPointer) -> Void

    private static let library: UnsafeMutableRawPointer? = dlopen("/usr/lib/liblzma.5.dylib", RTLD_NOW)

    static func decode(skipFilterByte: Bool, read: () -> Data, write: (Data) throws -> Void) throws {
        guard let library,
              let initSymbol = dlsym(library, "lzma_alone_decoder"),
              let codeSymbol = dlsym(library, "lzma_code"),
              let endSymbol = dlsym(library, "lzma_end") else {
            throw NSISArchive.Unsupported(reason: "This installer is compressed with LZMA, and this Mac's LZMA library could not be loaded.")
        }
        let start = unsafeBitCast(initSymbol, to: AloneDecoder.self)
        let code = unsafeBitCast(codeSymbol, to: Code.self)
        let end = unsafeBitCast(endSymbol, to: End.self)

        // lzma_stream: next_in, avail_in, total_in, next_out, avail_out, total_out, then
        // private fields. 136 bytes; more is allocated than that.
        let stream = UnsafeMutableRawPointer.allocate(byteCount: 256, alignment: 16)
        stream.initializeMemory(as: UInt8.self, repeating: 0, count: 256)
        defer { stream.deallocate() }
        guard start(stream, UInt64.max) == 0 else {
            throw NSISArchive.Unsupported(reason: "The LZMA decompressor could not be started.")
        }
        defer { end(stream) }

        var first = read()
        if skipFilterByte, !first.isEmpty { first = first.dropFirst() }
        while first.count < 5 {
            let more = read()
            if more.isEmpty { throw NSISArchive.Unsupported(reason: "The installer's data is cut short.") }
            first.append(more)
        }
        var pending = Data(first.prefix(5)) + Data(repeating: 0xFF, count: 8) + first.dropFirst(5)

        let capacity = 1 << 20
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        while true {
            if pending.isEmpty {
                pending = read()
                if pending.isEmpty { return }
            }
            var done = false
            try pending.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                stream.storeBytes(of: raw.baseAddress, toByteOffset: 0, as: UnsafeRawPointer?.self)
                stream.storeBytes(of: raw.count, toByteOffset: 8, as: Int.self)
                while true {
                    stream.storeBytes(of: UnsafeMutableRawPointer(buffer), toByteOffset: 24, as: UnsafeMutableRawPointer?.self)
                    stream.storeBytes(of: capacity, toByteOffset: 32, as: Int.self)
                    let status = code(stream, 0)
                    let produced = capacity - stream.load(fromByteOffset: 32, as: Int.self)
                    if produced > 0 { try write(Data(bytes: buffer, count: produced)) }
                    if status == 1 { done = true; return }          // LZMA_STREAM_END
                    // LZMA_BUF_ERROR (10) only says that nothing more can be done with this input
                    if status != 0 && status != 10 {
                        throw NSISArchive.Unsupported(reason: "The installer's LZMA data is damaged.")
                    }
                    if stream.load(fromByteOffset: 8, as: Int.self) == 0 && produced < capacity { return }
                }
            }
            if done { return }
            pending = Data()
        }
    }
}

extension Data {
    func le32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    func le16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func leInt32(at offset: Int) -> Int { Int(Int32(bitPattern: le32(at: offset))) }
}
