import XCTest
@testable import FineWineCore

/// Runs the NSIS reader on a real installer, when one is named: `FINEWINE_NSIS_SAMPLE=<file>`
/// and `FINEWINE_NSIS_OUT=<folder to use as drive_c>`. Prints what it did.
final class NSISSampleTests: XCTestCase {
    func testSampleInstaller() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sample = environment["FINEWINE_NSIS_SAMPLE"], let out = environment["FINEWINE_NSIS_OUT"] else {
            throw XCTSkip("no sample installer named")
        }
        let started = Date()
        let archive = try NSISArchive(url: URL(fileURLWithPath: sample))
        print("archive: \(archive.compression) solid=\(archive.isSolid) header=\(archive.header.count) in \(Date().timeIntervalSince(started)) s")
        let script = try NSISScript(archive: archive, driveC: URL(fileURLWithPath: out), userName: "tester",
                                    installer: URL(fileURLWithPath: sample), productName: "Sample")
        let report = try script.install()
        print("install directory: \(report.installDirectory)")
        print("files: \(report.filesWritten), by search: \(report.foundInstallRoutineBySearch)")
        print("programs: \(report.programs)")
        print("repaired: \(report.repairedFiles)")
        print("skipped add-on calls: \(report.skippedPluginCalls.sorted { $0.key < $1.key })")
        print("skipped commands: \(report.skippedCommands)")
        print("registry:\n\(report.registryFile)")
        print("total \(Date().timeIntervalSince(started)) s")
    }
}
