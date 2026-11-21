import Foundation

/// The compiled shaders kept on disk for the programs of a prefix, and their removal.
///
/// Three things keep them. Metal keeps what it compiled per program that draws, by the
/// identity of the program, which for everything a FineWine runtime starts is one of its
/// loaders: these caches are shared by every prefix. DXMT (Direct3D 10 and 11) keeps one per
/// executable name. DXVK (Direct3D 9 on Vulkan) keeps one per executable, in the prefix when
/// FineWine starts it and, as DXVK does by itself, next to the executable otherwise.
///
/// A cache is only ever a shortcut: removing one costs a recompilation the next time a game
/// runs (stutter while shaders are built again) and nothing else. They are cleared when a
/// prefix changes what Direct3D is drawn with, so that nothing built for the one path is
/// left for the other.
public struct ShaderCaches {
    /// macOS' per-user cache folder (`DARWIN_USER_CACHE_DIR`), where Metal and DXMT keep theirs.
    public var systemCacheDirectory: URL?

    public init(systemCacheDirectory: URL? = ShaderCaches.darwinUserCacheDirectory()) {
        self.systemCacheDirectory = systemCacheDirectory
    }

    /// The identities Metal knows a runtime's programs by: FineWine's two loaders (the one
    /// macOS takes for a game, and the plain one) and Wine's own.
    public static let loaderIdentifiers = ["org.finewine.game", "org.finewine.program", "org.winehq.wine"]
    /// What Metal keeps inside a program's cache folder.
    static let metalFolders = ["com.apple.metal", "com.apple.metalfe", "com.apple.gpuarchiver"]

    /// Where DXVK keeps its caches for a prefix (`DXVK_STATE_CACHE_PATH`): one folder deep, as
    /// DXVK creates the folder itself but not its parents.
    public static func dxvkDirectory(inPrefix prefix: URL) -> URL {
        prefix.appendingPathComponent(".finewine-dxvk-cache", isDirectory: true)
    }

    public static func darwinUserCacheDirectory() -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    /// Whether going from `old` to `new` changes what draws Direct3D in the prefix.
    public static func rendererChanged(from old: PrefixSettings?, to new: PrefixSettings) -> Bool {
        guard let old else { return false }     // a new prefix has nothing cached
        return old.graphicsBackend != new.graphicsBackend || old.legacyDirect3DOnVulkan != new.legacyDirect3DOnVulkan
    }

    /// Everything that would be removed for `prefix`, whether or not it exists.
    public func locations(for prefix: Prefix) -> [URL] {
        var out = [Self.dxvkDirectory(inPrefix: prefix.directory)]
        for program in prefix.metadata.programs {
            guard let exe = WindowsPath.macURL(for: program.windowsPath, inPrefix: prefix.directory) else { continue }
            // DXVK by itself: <name without .exe>.dxvk-cache beside the executable
            out.append(exe.deletingPathExtension().appendingPathExtension("dxvk-cache"))
            // DXMT: dxmt/<executable name>/
            if let system = systemCacheDirectory {
                out.append(system.appendingPathComponent("dxmt/\(exe.lastPathComponent)", isDirectory: true))
            }
        }
        if let system = systemCacheDirectory {
            for id in Self.loaderIdentifiers {
                for folder in Self.metalFolders {
                    out.append(system.appendingPathComponent("\(id)/\(folder)", isDirectory: true))
                }
            }
        }
        return out
    }

    /// Removes the caches of `prefix`'s programs, and Metal's, which every prefix shares.
    /// Returns what was there and is gone.
    @discardableResult
    public func clear(for prefix: Prefix) -> [URL] {
        let fm = FileManager.default
        var removed: [URL] = []
        for url in locations(for: prefix) where fm.fileExists(atPath: url.path) {
            if (try? fm.removeItem(at: url)) != nil { removed.append(url) }
        }
        return removed
    }
}
