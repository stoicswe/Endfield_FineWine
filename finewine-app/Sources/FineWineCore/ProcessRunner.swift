import Foundation

public struct ProcessResult: Equatable, Sendable {
    public var status: Int32
    public var output: String
    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

/// Runs launch plans. The real implementation starts processes; tests substitute a recorder.
public protocol ProcessRunning {
    /// Runs to completion and returns the exit status with combined stdout and stderr.
    func run(_ plan: LaunchPlan) throws -> ProcessResult
    /// Starts the process and returns its pid straight away. Output goes to `logFile`;
    /// `onExit` is called (on an arbitrary thread) with the exit status.
    func start(_ plan: LaunchPlan, logFile: URL?, onExit: @escaping @Sendable (Int32) -> Void) throws -> Int32
}

public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    private func process(for plan: LaunchPlan) -> Process {
        let process = Process()
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        process.environment = plan.environment
        process.currentDirectoryURL = plan.workingDirectory
        process.standardInput = FileHandle.nullDevice
        // Whatever thread FineWine happens to launch from, the program runs at the priority of
        // something the user is looking at. A process started at a background priority is kept
        // on the efficiency cores, where it runs about three times slower.
        process.qualityOfService = .userInteractive
        return process
    }

    public func run(_ plan: LaunchPlan) throws -> ProcessResult {
        let process = process(for: plan)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Read before waiting: a full pipe would otherwise block the child forever.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    public func start(_ plan: LaunchPlan, logFile: URL?, onExit: @escaping @Sendable (Int32) -> Void) throws -> Int32 {
        let process = process(for: plan)
        var handle: FileHandle?
        if let logFile {
            try FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
            handle = try FileHandle(forWritingTo: logFile)
        }
        process.standardOutput = handle ?? FileHandle.nullDevice
        process.standardError = handle ?? FileHandle.nullDevice
        process.terminationHandler = { finished in
            try? handle?.close()
            onExit(finished.terminationStatus)
        }
        try process.run()
        return process.processIdentifier
    }
}
