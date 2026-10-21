import Foundation

/// User-confirmed, per-patch anonymous usage reporting.
///
/// Nothing is queued or sent automatically: after a patch run finishes the app shows a dialog
/// with the exact payload, and only the user's explicit "Send Statistics" action posts it.
enum UsageTelemetry {
    private static let endpoint = URL(string: "https://endfield-fine-wine.lovable.app/api/statistics")!

    /// Only completed runs are reported: a patch run, or an Automated Setup run.
    static let allowedEvents: Set<String> = [
        "patch_succeeded", "patch_failed", "setup_succeeded", "setup_failed",
    ]

    /// Metadata is an allowlist, not a free-form dictionary: a future call site must not be able
    /// to leak a path, bottle name or identifier by adding a new key.
    static let allowedMetadataKeys: Set<String> = [
        "gptk", "duration_seconds", "failed_step", "cross_over_build",
        "setup_backend", "setup_msync", "setup_upscaling", "installer_status",
    ]

    private struct Event: Encodable {
        let app = "endfield-finewine-patcher"
        let event: String
        let count = 1
        let appVersion: String
        let osMajor: Int
        let metadata: [String: String]
        /// Redacted log excerpts. Only Automated Setup reports carry these; a patch report omits
        /// the field entirely (nil optionals are not encoded).
        let logs: [String]?
    }

    /// A local, unsent report for one run. Showing it never sends anything.
    struct Prompt: Identifiable {
        let id = UUID()
        let event: String
        let metadata: [String: String]
        let logs: [String]

        init(event: String, metadata: [String: String], logs: [String] = []) {
            self.event = event
            self.metadata = metadata
            self.logs = logs
        }

        var isSuccess: Bool { event.hasSuffix("_succeeded") }
        var isSetup: Bool { event.hasPrefix("setup_") }

        /// Pretty-printed JSON exactly matching what `send(_:)` would post.
        var json: String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(UsageTelemetry.makeEvent(event, metadata: metadata, logs: logs)) else {
                return "{}"
            }
            return String(data: data, encoding: .utf8) ?? "{}"
        }
    }

    static func makePatchPrompt(succeeded: Bool, gptk: Bool, failedStep: Int?,
                                durationSeconds: Int, crossOverBuild: String? = nil) -> Prompt {
        var metadata = [
            "gptk": gptk ? "true" : "false",
            "duration_seconds": String(durationSeconds),
        ]
        if let failedStep { metadata["failed_step"] = String(failedStep) }
        // The source CrossOver's build, not a path or a user identifier: "26.3" alone cannot tell
        // two Wine-ABI-incompatible builds apart (see CrossOverInfo.build).
        if let crossOverBuild, !crossOverBuild.isEmpty { metadata["cross_over_build"] = crossOverBuild }
        return Prompt(
            event: succeeded ? "patch_succeeded" : "patch_failed",
            metadata: safeMetadata(metadata)
        )
    }

    /// The Automated Setup report: the same allowlisted settings, plus redacted excerpts of the
    /// bottle/installer/menu logs so failures (and the successful path) can be diagnosed.
    static func makeSetupPrompt(
        succeeded: Bool,
        failedStep: Int?,
        durationSeconds: Int,
        settings: BottleSettings,
        installerStarted: Bool,
        installerExit: Int32?,
        bottleName: String,
        logs: [(name: String, url: URL)]
    ) -> Prompt {
        var metadata = [
            "duration_seconds": String(durationSeconds),
            "setup_backend": settings.backend.rawValue,
            "setup_msync": settings.msync ? "true" : "false",
            "setup_upscaling": settings.upscaling ? "true" : "false",
            "installer_status": installerExit.map { "exited:\($0)" } ?? (installerStarted ? "started" : "not_started"),
        ]
        if let failedStep { metadata["failed_step"] = String(failedStep) }

        // Redact before the excerpt is built, so a line is only ever held in memory in its
        // redacted form once it reaches the preview/send path.
        let redactor = LogRedactor.live(bottleNames: [bottleName, settings.trimmedName])
        let excerpts = LogRedactor.excerpts(logs: logs, redactor: redactor)
        return Prompt(
            event: succeeded ? "setup_succeeded" : "setup_failed",
            metadata: safeMetadata(metadata),
            logs: excerpts
        )
    }

    /// Drops any metadata key that was not explicitly approved for collection.
    static func safeMetadata(_ metadata: [String: String]) -> [String: String] {
        metadata.filter { allowedMetadataKeys.contains($0.key) }
    }

    /// Called only from the user's "Send Statistics" button in the run prompt.
    static func send(_ prompt: Prompt) {
        guard allowedEvents.contains(prompt.event) else { return }
        // Re-sanitise here as well, so a hand-built Prompt cannot bypass the allowlist.
        let event = makeEvent(prompt.event, metadata: prompt.metadata, logs: prompt.logs)
        Task {
            await post(event)
        }
    }

    private static func makeEvent(_ name: String, metadata: [String: String], logs: [String] = []) -> Event {
        Event(
            event: name,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            metadata: safeMetadata(metadata),
            logs: logs.isEmpty ? nil : logs
        )
    }

    private static func post(_ event: Event) async {
        guard let body = try? JSONEncoder().encode(event) else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        _ = try? await URLSession.shared.data(for: request)
    }
}
