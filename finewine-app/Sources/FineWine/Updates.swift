import SwiftUI
import AppKit
import FineWineCore

/// Looking for, showing and installing updates of FineWine itself.
///
/// Releases are read from the project's GitHub page. Which ones count is the user's choice of
/// channel (release, beta, nightly). A check is made a little after FineWine starts and every
/// few hours after that, unless that is turned off, and whenever the user asks for one. An
/// update the user skipped is not shown again by the checks FineWine makes by itself; a check
/// the user asks for shows it.
@MainActor
final class UpdateModel: ObservableObject {
    static let shared = UpdateModel()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading
        case installing
        case failed(String)
    }

    struct LogLine: Identifiable, Equatable {
        let id = UUID()
        let time: Date
        let text: String
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var offer: UpdateOffer?
    @Published private(set) var received: Int64 = 0
    @Published private(set) var expected: Int64 = 0
    /// What is being done right now, for the line above the progress bar.
    @Published private(set) var stage: String = ""
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var lastChecked: Date?

    let current = BuildIdentity.of()

    /// Set by the menu bar label, which is the one view that always exists.
    var openUpdateWindow: () -> Void = {}

    private static let channelKey = "UpdateChannel"
    private static let automaticKey = "UpdateChecksAutomatically"
    private static let skippedKey = "UpdateSkippedTag"
    private static let lastCheckedKey = "UpdateLastChecked"
    /// How often FineWine looks by itself.
    private static let interval: TimeInterval = 6 * 60 * 60

    private var timer: Timer?
    private var download: UpdateDownload?

    private init() {
        lastChecked = UserDefaults.standard.object(forKey: Self.lastCheckedKey) as? Date
    }

    // MARK: Settings

    var channel: UpdateChannel {
        get {
            UserDefaults.standard.string(forKey: Self.channelKey).flatMap(UpdateChannel.init)
                ?? UpdateChannel.natural(for: current.channel)
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.channelKey)
            // what was found, or skipped, on another channel says nothing about this one
            if phase == .available || phase == .upToDate { phase = .idle; offer = nil }
        }
    }

    var checksAutomatically: Bool {
        get { UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.automaticKey)
            schedule()
        }
    }

    private var skippedTag: String? {
        get { UserDefaults.standard.string(forKey: Self.skippedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.skippedKey) }
    }

    var isBusy: Bool { phase == .checking || phase == .downloading || phase == .installing }

    /// Where the running app is, when it is an app that can be replaced.
    var installedApp: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    // MARK: Checking

    /// Called once when FineWine starts.
    func start() {
        schedule()
        guard checksAutomatically else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [self] in
            if lastChecked.map({ Date().timeIntervalSince($0) >= 15 * 60 }) ?? true {
                Task { await check(manual: false) }
            }
        }
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard checksAutomatically else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor in await UpdateModel.shared.check(manual: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Looks for an update. A check the user asked for (`manual`) also shows an update they
    /// skipped, opens the window with whatever the answer is, and reports a failure; a check
    /// FineWine makes by itself only speaks up when there is something new.
    func check(manual: Bool) async {
        guard !isBusy else {
            if manual { openUpdateWindow() }
            return
        }
        let previous = phase
        phase = .checking
        if manual { openUpdateWindow() }
        do {
            let releases = try await UpdateChecker.fetchReleases()
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: Self.lastCheckedKey)
            let found = UpdateChecker.offer(from: releases, channel: channel, current: current,
                                            skippedTag: skippedTag, includingSkipped: manual)
            if let found {
                let isNews = found != offer || previous != .available
                offer = found
                phase = .available
                if manual || isNews { openUpdateWindow() }
            } else {
                // An update found earlier and left for later is still there to be had.
                let stillThere = offer.map { UpdateChecker.offer(from: releases, channel: channel, current: current,
                                                                 includingSkipped: true)?.release.tag == $0.release.tag } ?? false
                if !manual, stillThere, previous == .available {
                    phase = .available
                } else {
                    offer = nil
                    phase = manual ? .upToDate : .idle
                }
            }
        } catch {
            phase = manual ? .failed(error.localizedDescription) : previous
        }
    }

    /// Not this one: FineWine's own checks leave it alone from now on.
    func skip() {
        guard let offer else { return }
        skippedTag = offer.release.tag
        self.offer = nil
        phase = .idle
    }

    func dismissResult() {
        if phase == .upToDate { phase = .idle }
        if case .failed = phase { phase = offer == nil ? .idle : .available }
    }

    // MARK: Installing

    private func note(_ text: String) {
        log.append(LogLine(time: Date(), text: text))
        stage = text
    }

    func cancelDownload() {
        download?.cancel()
    }

    /// Downloads the update, checks it, puts it in place of the running app and starts it.
    /// Programs still running in a prefix are closed first when `closingPrograms` is set; the
    /// caller asks the user before passing that.
    func install(closingPrograms: Bool) async {
        guard let offer, !isBusy else { return }
        log = []
        received = 0
        expected = offer.asset.size
        phase = .downloading
        openUpdateWindow()

        do {
            guard let installed = installedApp else { throw FineWineError(tr("update.err_not_an_app")) }
            if installed.path.contains("/AppTranslocation/") { throw FineWineError(tr("update.err_translocated")) }

            let size = ByteCountFormatter.string(fromByteCount: offer.asset.size, countStyle: .file)
            note(tr("update.log_downloading", offer.asset.name, size))
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FineWine/Updates", isDirectory: true)
            let zip = caches.appendingPathComponent(offer.asset.name)
            let download = UpdateDownload(destination: zip, expectedSize: offer.asset.size) { received, expected in
                Task { @MainActor in
                    UpdateModel.shared.received = received
                    UpdateModel.shared.expected = expected
                }
            }
            self.download = download
            _ = try await download.run(offer.asset.downloadURL)
            self.download = nil
            received = expected
            note(tr("update.log_downloaded"))

            phase = .installing
            var checksum: String?
            if let sums = offer.checksums {
                note(tr("update.log_fetching_checksums"))
                let text = try await UpdateChecker.fetchText(sums.downloadURL)
                checksum = UpdateChecker.checksum(for: offer.asset.name, inSums: text)
            }
            note(tr("update.log_verifying"))
            let logger = LogRelay()
            let unpacked: URL = try await Task.detached(priority: .userInitiated) {
                try UpdateInstaller.verify(zip: zip, expectedSHA256: checksum) { logger.say($0) }
                let workspace = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                            appropriateFor: installed, create: true)
                return try UpdateInstaller.unpack(zip: zip, into: workspace.appendingPathComponent("unpacked")) { logger.say($0) }
            }.value

            if AppModel.shared.hasRunningPrograms {
                guard closingPrograms else { throw FineWineError(tr("update.err_programs_running")) }
                note(tr("update.log_closing_programs"))
                await AppModel.shared.closeEverythingForUpdate()
            }

            try await Task.detached(priority: .userInitiated) {
                try UpdateInstaller.replace(installed: installed, with: unpacked) { logger.say($0) }
            }.value
            try? FileManager.default.removeItem(at: zip)
            note(tr("update.log_relaunching"))
            try UpdateInstaller.relaunch(installed, afterExitOf: ProcessInfo.processInfo.processIdentifier)
            // long enough for the last lines to be read
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            // Not from here: this code is a job on the main queue, and a quit that waits for an
            // answer (see applicationShouldTerminate) would wait for another job on that queue,
            // which cannot start before this one ends. The run loop calls it instead.
            AppModel.shared.quittingForUpdate = true
            RunLoop.main.perform(inModes: [.common]) { NSApp.terminate(nil) }
        } catch {
            download = nil
            let cancelled = (error as? URLError)?.code == .cancelled
            if cancelled {
                note(tr("update.log_cancelled"))
                phase = .available
            } else {
                note(tr("update.log_failed", error.localizedDescription))
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Lets work that is off the main thread add lines to the log.
    private final class LogRelay: @unchecked Sendable {
        func say(_ text: String) {
            Task { @MainActor in UpdateModel.shared.note(text) }
        }
    }
}

// MARK: - The update window

struct UpdateWindow: View {
    @ObservedObject private var updates = UpdateModel.shared
    @ObservedObject private var l10n = LanguageManager.shared
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch updates.phase {
            case .available:
                if let offer = updates.offer { available(offer) } else { quiet(l10n.tr("update.up_to_date_title")) }
            case .downloading, .installing:
                progress
            case .failed(let message):
                failed(message)
            case .checking:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(l10n.tr("update.checking"))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .upToDate, .idle:
                quiet(l10n.tr("update.up_to_date_title"))
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 560)
        .background { Backdrop() }
    }

    private func header(_ title: String, symbol: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(Look.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                Text(l10n.tr("update.current_build", updates.current.summary))
                    .font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
        }
    }

    private func kindName(_ kind: ReleaseKind) -> String {
        switch kind {
        case .release: return l10n.tr("update.channel_release")
        case .beta: return l10n.tr("update.channel_beta")
        case .nightly: return l10n.tr("update.channel_nightly")
        }
    }

    @ViewBuilder private func available(_ offer: UpdateOffer) -> some View {
        header(l10n.tr("update.available_title"), symbol: "arrow.down.circle")
        HStack(spacing: 6) {
            Text(offer.release.name).font(.headline).lineLimit(2)
            Spacer()
            Pill(text: kindName(offer.release.kind), symbol: "tag")
            if let date = offer.release.publishedAt {
                Pill(text: date.formatted(date: .abbreviated, time: .shortened), symbol: "calendar")
            }
            Pill(text: ByteCountFormatter.string(fromByteCount: offer.asset.size, countStyle: .file), symbol: "arrow.down")
        }
        ScrollView {
            MarkdownView(markdown: offer.release.notes.isEmpty ? l10n.tr("update.no_notes") : offer.release.notes)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .glassCard()
        if model.hasRunningPrograms {
            Label(l10n.tr("update.programs_running_note"), systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Button(l10n.tr("update.skip")) { updates.skip(); dismiss() }
                .fwButton().help(l10n.tr("update.skip_help"))
            if let page = offer.release.pageURL {
                Button(l10n.tr("update.open_page")) { NSWorkspace.shared.open(page) }.fwButton()
            }
            Spacer()
            Button(l10n.tr("update.later")) { dismiss() }.fwButton()
            Button(model.hasRunningPrograms ? l10n.tr("update.install_closing") : l10n.tr("update.install")) {
                Task { await updates.install(closingPrograms: true) }
            }
            .fwProminentButton()
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private var progress: some View {
        header(updates.phase == .downloading ? l10n.tr("update.downloading_title") : l10n.tr("update.installing_title"),
               symbol: updates.phase == .downloading ? "arrow.down.circle" : "shippingbox")
        if let offer = updates.offer { Text(offer.release.name).font(.headline).lineLimit(2) }
        VStack(alignment: .leading, spacing: 6) {
            if updates.phase == .downloading, updates.expected > 0 {
                ProgressView(value: Double(min(updates.received, updates.expected)), total: Double(updates.expected))
                Text(l10n.tr("update.download_progress",
                             ByteCountFormatter.string(fromByteCount: updates.received, countStyle: .file),
                             ByteCountFormatter.string(fromByteCount: updates.expected, countStyle: .file),
                             Int(Double(updates.received) / Double(updates.expected) * 100)))
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                ProgressView().progressViewStyle(.linear)
                Text(updates.stage).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        logView
        HStack {
            Spacer()
            if updates.phase == .downloading {
                Button(l10n.tr("app.cancel")) { updates.cancelDownload() }.fwButton()
            }
        }
    }

    @ViewBuilder private func failed(_ message: String) -> some View {
        header(l10n.tr("update.failed_title"), symbol: "exclamationmark.triangle")
        Text(message).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        if !updates.log.isEmpty { logView } else { Spacer() }
        HStack {
            Button(l10n.tr("update.open_releases")) { NSWorkspace.shared.open(UpdateChecker.releasesPageURL) }.fwButton()
            Spacer()
            Button(l10n.tr("app.close")) { updates.dismissResult(); dismiss() }.fwButton()
            if updates.offer != nil {
                Button(l10n.tr("update.try_again")) { Task { await updates.install(closingPrograms: true) } }.fwProminentButton()
            } else {
                Button(l10n.tr("update.check_now")) { Task { await updates.check(manual: true) } }.fwProminentButton()
            }
        }
    }

    @ViewBuilder private func quiet(_ title: String) -> some View {
        header(title, symbol: "checkmark.circle")
        Text(l10n.tr("update.up_to_date_detail", channelName(updates.channel)))
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let last = updates.lastChecked {
            Text(l10n.tr("update.last_checked", last.formatted(date: .abbreviated, time: .shortened)))
                .font(.footnote).foregroundStyle(.secondary)
        }
        Spacer()
        HStack {
            Button(l10n.tr("update.open_releases")) { NSWorkspace.shared.open(UpdateChecker.releasesPageURL) }.fwButton()
            Spacer()
            Button(l10n.tr("update.check_now")) { Task { await updates.check(manual: true) } }.fwButton()
            Button(l10n.tr("app.close")) { updates.dismissResult(); dismiss() }.fwProminentButton()
                .keyboardShortcut(.defaultAction)
        }
    }

    private func channelName(_ channel: UpdateChannel) -> String {
        switch channel {
        case .release: return l10n.tr("update.channel_release")
        case .beta: return l10n.tr("update.channel_beta")
        case .nightly: return l10n.tr("update.channel_nightly")
        }
    }

    /// What has been done so far, newest at the bottom and kept in view.
    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(updates.log) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(line.time.formatted(date: .omitted, time: .standard))
                                .foregroundStyle(.tertiary)
                            Text(line.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.caption.monospaced())
                        .id(line.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .glassCard()
            .onChange(of: updates.log.count) { _, _ in
                if let last = updates.log.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }
}

// MARK: - Settings

struct UpdatesCard: View {
    @ObservedObject private var updates = UpdateModel.shared
    @ObservedObject private var l10n = LanguageManager.shared

    private var status: String {
        switch updates.phase {
        case .checking: return l10n.tr("update.checking")
        case .available: return l10n.tr("update.status_available", updates.offer?.release.name ?? "")
        case .downloading: return l10n.tr("update.downloading_title")
        case .installing: return l10n.tr("update.installing_title")
        case .failed(let message): return message
        case .upToDate, .idle:
            if let last = updates.lastChecked {
                return l10n.tr("update.last_checked", last.formatted(date: .abbreviated, time: .shortened))
            }
            return l10n.tr("update.never_checked")
        }
    }

    var body: some View {
        Card(title: l10n.tr("update.card"), symbol: "arrow.triangle.2.circlepath", footnote: l10n.tr("update.card_footnote")) {
            Row(label: l10n.tr("update.channel_label"), detail: l10n.tr("update.channel_detail")) {
                Picker(l10n.tr("update.channel_label"), selection: Binding(get: { updates.channel }, set: { updates.channel = $0 })) {
                    Text(l10n.tr("update.channel_release")).tag(UpdateChannel.release)
                    Text(l10n.tr("update.channel_beta")).tag(UpdateChannel.beta)
                    Text(l10n.tr("update.channel_nightly")).tag(UpdateChannel.nightly)
                }
                .labelsHidden().fixedSize()
            }
            Divider()
            Toggle(isOn: Binding(get: { updates.checksAutomatically }, set: { updates.checksAutomatically = $0 })) {
                Text(l10n.tr("update.automatic_title"))
                Text(l10n.tr("update.automatic_desc"))
            }
            Divider()
            Row(label: l10n.tr("update.current_build", updates.current.summary), detail: status) {
                if updates.phase == .available {
                    Button(l10n.tr("update.view")) { updates.openUpdateWindow() }.fwProminentButton()
                }
                Button(l10n.tr("update.check_now")) { Task { await updates.check(manual: true) } }
                    .fwButton()
                    .disabled(updates.isBusy)
            }
        }
    }
}

// MARK: - Release notes

/// Release notes as GitHub shows them, near enough: headings, paragraphs, lists, quotes, code,
/// tables and rules, with bold, links and `code` inside them.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    init(markdown: String) { blocks = MarkdownBlocks.parse(markdown) }
    init(blocks: [MarkdownBlock]) { self.blocks = blocks }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level <= 1 ? .title2.weight(.bold) : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, level <= 2 ? 4 : 0)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker).foregroundStyle(.secondary).monospacedDigit()
                        Text(Self.inline(item.text)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 18)
                }
            }
        case .quote(let inner):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Look.accent.opacity(0.6)).frame(width: 3)
                MarkdownView(blocks: inner).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.callout.monospaced()).padding(10)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .table(let header, let rows):
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(Self.inline(cell)).fontWeight(.semibold)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(Self.inline(cell)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        case .rule:
            Divider()
        }
    }
}
