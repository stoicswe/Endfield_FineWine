import Foundation

/// Reads which DLLs a Windows executable imports, to tell whether it renders with Direct3D,
/// Vulkan or OpenGL. FineWine uses that to decide, before a program has ever run, whether to
/// start it as a game (see `LaunchPlanner.isGame`).
public enum PEImports {
    /// The DLLs whose presence in an import table means the program draws with a GPU API.
    public static let renderingDLLs: Set<String> = [
        "d3d8.dll", "d3d9.dll", "d3d10.dll", "d3d10_1.dll", "d3d10core.dll", "d3d11.dll", "d3d12.dll",
        "dxgi.dll", "ddraw.dll", "vulkan-1.dll", "opengl32.dll",
    ]

    /// The names of the DLLs in the executable's import and delay-import tables, lower-cased.
    /// Empty if the data is not a Windows executable or its tables cannot be read.
    public static func importedDLLs(in data: Data) -> [String] {
        func u16(_ o: Int) -> Int? { o >= 0 && o + 2 <= data.count ? Int(data[data.startIndex + o]) | Int(data[data.startIndex + o + 1]) << 8 : nil }
        func u32(_ o: Int) -> Int? {
            guard let lo = u16(o), let hi = u16(o + 2) else { return nil }
            return lo | hi << 16
        }
        guard u16(0) == 0x5A4D, let pe = u32(0x3C), u32(pe) == 0x0000_4550,
              let sectionCount = u16(pe + 6), let optionalSize = u16(pe + 20), let magic = u16(pe + 24) else { return [] }
        let optional = pe + 24
        let directories: Int
        switch magic {
        case 0x10B: directories = optional + 96      // 32-bit
        case 0x20B: directories = optional + 112     // 64-bit
        default: return []
        }
        let sections = optional + optionalSize
        // Where a relative virtual address is in the file.
        func offset(ofRVA rva: Int) -> Int? {
            for i in 0..<min(sectionCount, 96) {
                let s = sections + i * 40
                guard let vsize = u32(s + 8), let va = u32(s + 12), let rawSize = u32(s + 16), let raw = u32(s + 20) else { return nil }
                if rva >= va, rva < va + max(vsize, rawSize) { return raw + (rva - va) }
            }
            return nil
        }
        func name(atRVA rva: Int) -> String? {
            guard rva != 0, let start = offset(ofRVA: rva), start < data.count else { return nil }
            var bytes: [UInt8] = []
            var i = start
            while i < data.count, bytes.count < 260, data[data.startIndex + i] != 0 {
                bytes.append(data[data.startIndex + i]); i += 1
            }
            return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self).lowercased()
        }
        var names: [String] = []
        // (index of the data directory, size of one entry, where the name's address is in it)
        for (index, entrySize, nameField) in [(1, 20, 12), (13, 32, 4)] {
            guard directories + index * 8 + 8 <= optional + optionalSize,
                  let rva = u32(directories + index * 8), rva != 0, var entry = offset(ofRVA: rva) else { continue }
            for _ in 0..<4096 {
                guard let nameRVA = u32(entry + nameField), nameRVA != 0, let n = name(atRVA: nameRVA) else { break }
                if !names.contains(n) { names.append(n) }
                entry += entrySize
            }
        }
        return names
    }

    /// The same for a file. The file is mapped, not read, so a large game executable costs nothing.
    public static func importedDLLs(at url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        return importedDLLs(in: data)
    }

    public static func usesRenderingAPI(at url: URL) -> Bool {
        !renderingDLLs.isDisjoint(with: importedDLLs(at: url))
    }
}
