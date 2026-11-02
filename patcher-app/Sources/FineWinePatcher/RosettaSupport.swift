import Foundation

enum RosettaSupport {
    /// Ensures x86_64 Wine can run before any CrossOver copy is created.
    /// On Apple Silicon, softwareupdate may present macOS's administrator prompt.
    nonisolated static func ensureInstalled(
        archPath: String = "/usr/bin/arch",
        softwareUpdatePath: String = "/usr/sbin/softwareupdate",
        appleSilicon: Bool? = nil
    ) throws {
        let needsRosetta = appleSilicon ?? isAppleSilicon()
        guard needsRosetta else { return }

        let probe = run(archPath, ["-x86_64", "/usr/bin/true"])
        guard probe.status != 0 else { return }

        let install = run(softwareUpdatePath, ["--install-rosetta", "--agree-to-license"])
        guard install.status == 0 else {
            throw PatchError("Rosetta 2 installation failed (exit \(install.status)). \(install.output)")
        }

        let verify = run(archPath, ["-x86_64", "/usr/bin/true"])
        guard verify.status == 0 else {
            throw PatchError("Rosetta 2 was not available after installation. \(verify.output)")
        }
    }

    private nonisolated static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    private nonisolated static func isAppleSilicon() -> Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
}
