import Foundation

/// Where a Wine runtime is stored: on this Mac (standard Application Support), on an external
/// or secondary drive (e.g. `<Volume>/FineWine/Runtimes/<id>`), or in an arbitrary custom folder.
public enum RuntimePlace: Hashable, Sendable {
    /// Standard location: `~/Library/Application Support/FineWine/Runtimes`.
    case thisMac
    /// A mounted volume by its UUID. Stored under `<volumeRoot>/FineWine/Runtimes/<id>`.
    case drive(String)
    /// An arbitrary custom folder selected by the user.
    case customFolder(URL)
}

extension RuntimeStore {
    /// The folder FineWine owns on a drive for runtimes.
    public static let runtimesFolderName = "Runtimes"
    public static let rootFolderName = "FineWine"

    /// The runtimes directory on a mounted volume.
    public static func runtimesFolder(on volume: VolumeInfo) -> URL {
        volume.root.appendingPathComponent(rootFolderName, isDirectory: true)
            .appendingPathComponent(runtimesFolderName, isDirectory: true)
    }

    /// Resolves the destination directory for a runtime with `id` given a `RuntimePlace`.
    public func targetDirectory(for place: RuntimePlace, runtimeID: String,
                                volumes: VolumeProviding = SystemVolumes()) -> URL? {
        switch place {
        case .thisMac:
            return paths.runtimes.appendingPathComponent(runtimeID, isDirectory: true)
        case .drive(let uuid):
            guard let vol = volumes.mounted().first(where: { $0.uuid == uuid }) else { return nil }
            return Self.runtimesFolder(on: vol).appendingPathComponent(runtimeID, isDirectory: true)
        case .customFolder(let url):
            return url.appendingPathComponent(runtimeID, isDirectory: true)
        }
    }
}
