import Foundation

/// Pulls the icon out of a Windows executable so its shortcut app can wear it.
public enum PEIcon {
    private struct Reader {
        let bytes: [UInt8]
        func u8(_ o: Int) -> Int? { o >= 0 && o < bytes.count ? Int(bytes[o]) : nil }
        func u16(_ o: Int) -> Int? {
            guard o >= 0, o + 2 <= bytes.count else { return nil }
            return Int(bytes[o]) | Int(bytes[o + 1]) << 8
        }
        func u32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= bytes.count else { return nil }
            return Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24
        }
        func slice(_ o: Int, _ count: Int) -> [UInt8]? {
            guard o >= 0, count >= 0, o + count <= bytes.count else { return nil }
            return Array(bytes[o..<o + count])
        }
    }

    private struct Section { let virtualAddress, virtualSize, rawOffset, rawSize: Int }

    private static let typeIcon = 3
    private static let typeGroupIcon = 14

    /// The executable's first icon group as `.ico` file data, or `nil` if it has none.
    public static func icoData(fromExecutable data: Data) -> Data? {
        let r = Reader(bytes: [UInt8](data))
        guard r.u16(0) == 0x5A4D, let pe = r.u32(0x3C), r.u32(pe) == 0x0000_4550,
              let sectionCount = r.u16(pe + 6), let optionalSize = r.u16(pe + 20) else { return nil }
        let optional = pe + 24
        let directories: Int
        switch r.u16(optional) {
        case 0x10B: directories = optional + 96     // PE32
        case 0x20B: directories = optional + 112    // PE32+
        default: return nil
        }
        // Data directory 2 is the resource table.
        guard let resourceRVA = r.u32(directories + 2 * 8), resourceRVA != 0 else { return nil }

        var sections: [Section] = []
        let table = optional + optionalSize
        for i in 0..<sectionCount {
            let s = table + i * 40
            guard let vsize = r.u32(s + 8), let va = r.u32(s + 12),
                  let rawSize = r.u32(s + 16), let raw = r.u32(s + 20) else { return nil }
            sections.append(Section(virtualAddress: va, virtualSize: vsize, rawOffset: raw, rawSize: rawSize))
        }
        func fileOffset(rva: Int) -> Int? {
            for s in sections where rva >= s.virtualAddress && rva < s.virtualAddress + max(s.virtualSize, s.rawSize) {
                return s.rawOffset + (rva - s.virtualAddress)
            }
            return nil
        }
        guard let root = fileOffset(rva: resourceRVA) else { return nil }

        /// The entries of a resource directory: (id, or nil for a named entry; offset; is a subdirectory).
        func entries(at directory: Int) -> [(id: Int?, offset: Int, isDirectory: Bool)] {
            guard let named = r.u16(directory + 12), let ids = r.u16(directory + 14) else { return [] }
            var out: [(Int?, Int, Bool)] = []
            for i in 0..<(named + ids) {
                let e = directory + 16 + i * 8
                guard let name = r.u32(e), let target = r.u32(e + 4) else { break }
                out.append((name & 0x8000_0000 != 0 ? nil : name, root + (target & 0x7FFF_FFFF),
                            target & 0x8000_0000 != 0))
            }
            return out
        }
        /// The bytes of the first language's data under a name/id entry.
        func resourceData(_ entry: (id: Int?, offset: Int, isDirectory: Bool)) -> [UInt8]? {
            var leaf = entry
            if leaf.isDirectory {
                guard let first = entries(at: leaf.offset).first, !first.isDirectory else { return nil }
                leaf = first
            }
            guard let rva = r.u32(leaf.offset), let size = r.u32(leaf.offset + 4),
                  let offset = fileOffset(rva: rva) else { return nil }
            return r.slice(offset, size)
        }

        let types = entries(at: root)
        guard let groupType = types.first(where: { $0.id == typeGroupIcon && $0.isDirectory }),
              let iconType = types.first(where: { $0.id == typeIcon && $0.isDirectory }),
              let firstGroup = entries(at: groupType.offset).first,
              let group = resourceData(firstGroup) else { return nil }
        let icons = entries(at: iconType.offset)

        // GRPICONDIR: reserved, type (1 = icon), count, then 14-byte entries ending in an icon id.
        let g = Reader(bytes: group)
        guard g.u16(2) == 1, let count = g.u16(4), count > 0 else { return nil }
        var images: [(header: [UInt8], data: [UInt8])] = []
        for i in 0..<count {
            let e = 6 + i * 14
            guard let header = g.slice(e, 12), let id = g.u16(e + 12),
                  let icon = icons.first(where: { $0.id == id }),
                  let image = resourceData(icon) else { continue }
            images.append((header, image))
        }
        guard !images.isEmpty else { return nil }

        // An .ico file is the same directory with file offsets in place of resource ids.
        var ico: [UInt8] = [0, 0, 1, 0, UInt8(images.count & 0xFF), UInt8(images.count >> 8)]
        var offset = 6 + images.count * 16
        for image in images {
            ico += image.header.prefix(8)
            ico += le32(image.data.count)
            ico += le32(offset)
            offset += image.data.count
        }
        for image in images { ico += image.data }
        return Data(ico)
    }

    static func le32(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }
}
