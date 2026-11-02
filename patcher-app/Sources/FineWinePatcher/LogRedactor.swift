import Foundation

/// Removes user- and machine-identifying data from the logs the Automated Setup wizard reports.
///
/// Logs are inherently path-heavy, and launcher logs can contain account data, tokens and URLs.
/// Before anything is shown in the preview (or sent), every excerpt goes through this filter:
///
/// * the user's home folder, macOS/Windows user names and the host name become placeholders;
/// * the bottle name (chosen by the user and often containing their name) becomes `<bottle>`;
/// * e-mail addresses, IP/MAC addresses, UUIDs, JWTs/bearer tokens, `token=…`-style values and
///   long hexadecimal blobs become placeholders;
/// * other users' home folders, temporary folders and volume names are generalised.
///
/// It is intentionally conservative: keeping a useful log line matters less than not shipping an
/// identifier. The user still sees the exact redacted payload in the confirmation dialog.
struct LogRedactor {
    let homeDirectory: String
    let userNames: [String]
    let hostName: String
    let bottleNames: [String]

    init(homeDirectory: String, userNames: [String], hostName: String, bottleNames: [String]) {
        self.homeDirectory = homeDirectory
        self.userNames = userNames
        self.hostName = hostName
        self.bottleNames = bottleNames
    }

    /// The values for this machine and this run. `NSUserName()`/`NSFullUserName()` are empty in
    /// some contexts, so blanks are dropped.
    static func live(bottleNames: [String]) -> LogRedactor {
        LogRedactor(
            homeDirectory: NSHomeDirectory(),
            userNames: [NSUserName(), NSFullUserName()].filter { !$0.isEmpty },
            hostName: ProcessInfo.processInfo.hostName,
            bottleNames: bottleNames
        )
    }

    func redact(_ text: String) -> String {
        var result = text

        // Literal values first, so paths containing them become a single placeholder.
        if homeDirectory.count > 1 {
            result = result.replacingOccurrences(of: homeDirectory, with: "~")
        }
        if hostName.count >= 3 {
            // Also redact the usual "host.local"/"host.domain" forms.
            result = result.replacingOccurrences(
                of: NSRegularExpression.escapedPattern(for: hostName) + "(?:\\.[\\w.-]+)?",
                with: "<host>",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        for bottle in bottleNames where !bottle.isEmpty {
            result = result.replacingOccurrences(
                of: NSRegularExpression.escapedPattern(for: bottle),
                with: "<bottle>"
            )
        }

        for rule in Self.rules {
            result = rule.apply(to: result)
        }

        // User names last: e-mail addresses and Windows profiles have already been collapsed, so
        // this only catches names that appear on their own (e.g. a "Registered to" style line).
        for name in userNames where name.count >= 3 {
            result = result.replacingOccurrences(
                of: "(?<![\\w.-])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\w.-])",
                with: "<user>",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    /// A log excerpt is its tail (the newest lines, where failures are reported), capped so the
    /// preview and the request stay small.
    static func excerpt(_ text: String, maxCharacters: Int = 4_000) -> (text: String, truncated: Bool) {
        guard text.count > maxCharacters else { return (text, false) }
        return ("… [earlier output omitted]\n" + String(text.suffix(maxCharacters)), true)
    }

    /// Reads, redacts and bounds each log file. `maxTotalCharacters` is shared across all files, so
    /// a chatty installer log cannot crowd out the bottle log.
    static func excerpts(
        logs: [(name: String, url: URL)],
        redactor: LogRedactor,
        maxPerLog: Int = 4_000,
        maxTotalCharacters: Int = 12_000
    ) -> [String] {
        var remaining = maxTotalCharacters
        var omitted = false
        var result: [String] = []
        for log in logs {
            guard remaining > 80 else { omitted = true; break }
            guard let raw = try? String(contentsOf: log.url, encoding: .utf8) else { continue }
            let redacted = redactor.redact(raw)
            guard !redacted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let name = redactor.redact(log.name)
            let header = "== \(name) ==\n"
            let budget = min(maxPerLog, max(40, remaining - header.count - 1))
            let capped = excerpt(redacted, maxCharacters: budget)
            if capped.truncated { omitted = true }
            var entry = header + capped.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if entry.count > remaining {
                entry = String(entry.prefix(remaining))
                omitted = true
            }
            remaining -= entry.count
            result.append(entry)
        }
        if omitted {
            result.append("… [further log output omitted]")
        }
        return result
    }

    // MARK: - Patterns

    private struct Rule {
        let pattern: String
        let template: String
        let options: NSRegularExpression.Options

        func apply(to text: String) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
        }
    }

    private static let rules: [Rule] = [
        // Other users' home folders and Windows profiles.
        Rule(pattern: "/Users/[^/\\s\"']+", template: "/Users/<user>", options: []),
        Rule(pattern: "(?i)([A-Za-z]:[\\\\/]+users[\\\\/]+)[^\\\\/\\s\"']+", template: "$1<user>", options: []),
        Rule(pattern: "(?i)(drive_c[\\\\/]+users[\\\\/]+)[^\\\\/\\s\"']+", template: "$1<user>", options: []),
        // Random per-session temp folders and external volume names.
        Rule(pattern: "/private/var/folders/[^\\s\"']+", template: "<tmp>", options: []),
        Rule(pattern: "/var/folders/[^\\s\"']+", template: "<tmp>", options: []),
        Rule(pattern: "/Volumes/[^/\\s\"']+", template: "/Volumes/<volume>", options: []),
        // CrossOver's own "Registered to: …" license line, if a log ever includes it.
        Rule(pattern: "(?i)Registered to:.*", template: "Registered to: <redacted>", options: []),
        // Account / credential material.
        Rule(pattern: "eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}", template: "<token>", options: []),
        Rule(pattern: "(?i)Bearer\\s+[A-Za-z0-9._~+/=-]{8,}", template: "Bearer <token>", options: []),
        Rule(
            pattern: "(?i)\\b(token|access_token|refresh_token|authorization|password|passwd|secret|session|sid|uid|openid|account|email|username|user_name|auth)\\b\\s*[:=]\\s*\"?(?!(?:Bearer|<))[^\\s\"&,;]+",
            template: "$1=<redacted>",
            options: []
        ),
        Rule(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", template: "<email>", options: []),
        // Device / request identifiers.
        Rule(pattern: "\\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\b", template: "<uuid>", options: []),
        Rule(pattern: "\\b[0-9a-fA-F]{32,}\\b", template: "<hash>", options: []),
        Rule(pattern: "(?i)\\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\\b", template: "<mac>", options: []),
        Rule(pattern: "\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b", template: "<ip>", options: []),
        Rule(pattern: "(?i)\\b(?:[0-9a-f]{0,4}:){4,7}[0-9a-f]{0,4}\\b", template: "<ip>", options: []),
    ]
}
