import XCTest
@testable import FineWineCore

final class AppUpdateTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func asset(_ name: String, size: Int64 = 1) -> ReleaseInfo.Asset {
        ReleaseInfo.Asset(name: name, size: size, downloadURL: URL(string: "https://example.invalid/\(name)")!)
    }

    /// The releases the project had on 2026-11-19, in short: betas carry the app, the nightly
    /// and the release of that day carry only the patcher.
    private var releases: [ReleaseInfo] {
        [
            ReleaseInfo(tag: "nightly_26.3.0.20261119_453b18c3", name: "Nightly", isPrerelease: true,
                        publishedAt: date("2026-11-19T14:11:31Z"),
                        assets: [asset("finewine-patcher-26.3.0-453b18c3.zip"), asset("SHA256SUMS.txt")]),
            ReleaseInfo(tag: "beta_20261119.5", name: "Beta 5", isPrerelease: true, publishedAt: date("2026-11-19T05:37:15Z"),
                        assets: [asset("FineWine-0.1.0-453b18c3.zip", size: 162_943_484), asset("finewine-patcher-26.3.0-453b18c3.zip"),
                                 asset("SHA256SUMS.txt")]),
            ReleaseInfo(tag: "beta_20261119.4", name: "Beta 4", isPrerelease: true, publishedAt: date("2026-11-19T00:04:26Z"),
                        assets: [asset("FineWine-0.1.0-aaaaaaaa.zip"), asset("SHA256SUMS.txt")]),
            ReleaseInfo(tag: "2.0.0", name: "Endfield FineWine 2.0.0", publishedAt: date("2026-11-13T18:38:18Z"),
                        assets: [asset("FineWine.Patcher.app.zip"), asset("endfield-wine-modules.tar.gz")]),
        ]
    }

    private func build(commit: String, built: String, channel: String = "beta") -> BuildIdentity {
        BuildIdentity(version: "0.1.0", commit: commit, builtAt: date(built), channel: channel)
    }

    func testKindsAndChannels() {
        XCTAssertEqual(releases.map(\.kind), [.nightly, .beta, .beta, .release])
        XCTAssertEqual(ReleaseInfo(tag: "v3.0.0-rc1", name: "rc", isPrerelease: true).kind, .beta)
        XCTAssertTrue(UpdateChannel.release.includes(.release))
        XCTAssertFalse(UpdateChannel.release.includes(.beta))
        XCTAssertTrue(UpdateChannel.beta.includes(.release))
        XCTAssertFalse(UpdateChannel.beta.includes(.nightly))
        XCTAssertTrue(UpdateChannel.nightly.includes(.beta))
        XCTAssertEqual(UpdateChannel.natural(for: "nightly"), .nightly)
        XCTAssertEqual(UpdateChannel.natural(for: "Release"), .release)
        XCTAssertEqual(UpdateChannel.natural(for: "dev"), .beta)
    }

    func testTheAppsZipIsFoundAndThePatchersIsNot() {
        XCTAssertNil(releases[0].appAsset)
        XCTAssertEqual(releases[1].appAsset?.name, "FineWine-0.1.0-453b18c3.zip")
        XCTAssertEqual(releases[1].appCommitPrefix, "453b18c3")
        XCTAssertNil(releases[3].appAsset)
        XCTAssertEqual(releases[1].checksumsAsset?.name, "SHA256SUMS.txt")
        XCTAssertNil(ReleaseInfo(tag: "x", name: "x", assets: [asset("FineWine-Patcher-1.0-abcdef12.zip")]).appAsset)
    }

    func testOfferIsTheNewestReleaseOfTheChannelThatCarriesTheApp() {
        let old = build(commit: "0000000011111111", built: "2026-11-18T10:00:00Z")
        // on betas: Beta 5, although the nightly is newer (it has no app in it, and is a nightly)
        XCTAssertEqual(UpdateChecker.offer(from: releases, channel: .beta, current: old)?.release.tag, "beta_20261119.5")
        XCTAssertEqual(UpdateChecker.offer(from: releases, channel: .nightly, current: old)?.release.tag, "beta_20261119.5")
        // on releases: nothing, no release carries the app yet
        XCTAssertNil(UpdateChecker.offer(from: releases, channel: .release, current: old))
        // the order the releases come in does not matter
        XCTAssertEqual(UpdateChecker.offer(from: releases.reversed(), channel: .beta, current: old)?.release.tag, "beta_20261119.5")
        // drafts are not offered
        var withDraft = releases
        withDraft.insert(ReleaseInfo(tag: "beta_20261120.6", name: "Beta 6", isPrerelease: true, isDraft: true,
                                     publishedAt: date("2026-11-20T01:00:00Z"), assets: [asset("FineWine-0.1.0-bbbbbbbb.zip")]), at: 0)
        XCTAssertEqual(UpdateChecker.offer(from: withDraft, channel: .beta, current: old)?.release.tag, "beta_20261119.5")
    }

    func testABuildIsNotOfferedToItselfNorAnOlderOne() {
        // Beta 5's own build: made before the release was published, from the same commit
        let beta5 = build(commit: "453b18c3bbcb370f54eb84dac145462b03d2eb50", built: "2026-11-19T04:50:00Z")
        XCTAssertNil(UpdateChecker.offer(from: releases, channel: .beta, current: beta5))
        // a build made after everything published
        let newer = build(commit: "ffffffff", built: "2026-11-20T00:00:00Z")
        XCTAssertNil(UpdateChecker.offer(from: releases, channel: .nightly, current: newer))
        // a build with no commit recorded goes by the date alone
        let unstamped = build(commit: "", built: "2026-11-19T01:00:00Z")
        XCTAssertEqual(UpdateChecker.offer(from: releases, channel: .beta, current: unstamped)?.release.tag, "beta_20261119.5")
    }

    func testASkippedReleaseComesBackOnlyWhenAsked() {
        let old = build(commit: "00000000", built: "2026-11-18T10:00:00Z")
        XCTAssertNil(UpdateChecker.offer(from: releases, channel: .beta, current: old, skippedTag: "beta_20261119.5"))
        XCTAssertEqual(UpdateChecker.offer(from: releases, channel: .beta, current: old, skippedTag: "beta_20261119.5",
                                           includingSkipped: true)?.release.tag, "beta_20261119.5")
        // skipping one does not hide the next
        var later = releases
        later.insert(ReleaseInfo(tag: "beta_20261120.6", name: "Beta 6", isPrerelease: true, publishedAt: date("2026-11-20T01:00:00Z"),
                                 assets: [asset("FineWine-0.1.0-bbbbbbbb.zip")]), at: 0)
        XCTAssertEqual(UpdateChecker.offer(from: later, channel: .beta, current: old, skippedTag: "beta_20261119.5")?.release.tag,
                       "beta_20261120.6")
    }

    func testReleasesAreReadFromGitHubsJSON() throws {
        let json = """
        [{"tag_name":"beta_20261119.5","name":"Endfield FW 20261119 Beta 5","body":"## Notes\\n\\n- one","prerelease":true,"draft":false,
          "published_at":"2026-11-19T05:37:15Z","html_url":"https://github.com/stoicswe/Endfield_FineWine/releases/tag/beta_20261119.5",
          "assets":[{"name":"FineWine-0.1.0-453b18c3.zip","size":162943484,
                     "browser_download_url":"https://github.com/stoicswe/Endfield_FineWine/releases/download/beta_20261119.5/FineWine-0.1.0-453b18c3.zip"}]},
         {"tag_name":"2.0.0","name":null,"body":null,"published_at":null,"assets":[]}]
        """
        let list = try ReleaseInfo.list(fromJSON: Data(json.utf8))
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].name, "Endfield FW 20261119 Beta 5")
        XCTAssertEqual(list[0].publishedAt, date("2026-11-19T05:37:15Z"))
        XCTAssertEqual(list[0].appAsset?.size, 162_943_484)
        XCTAssertEqual(list[0].notes, "## Notes\n\n- one")
        XCTAssertEqual(list[1].name, "2.0.0")          // a release with no name goes by its tag
        XCTAssertEqual(list[1].kind, .release)
    }

    func testChecksumIsFoundInSHA256SUMS() {
        let sums = """
        1111111111111111111111111111111111111111111111111111111111111111  ./finewine-patcher-26.3.0-453b18c3.zip
        ABCDEFabcdef0123456789abcdef0123456789abcdef0123456789abcdef0123  ./FineWine-0.1.0-453b18c3.zip
        2222222222222222222222222222222222222222222222222222222222222222 *other.zip
        not a checksum line
        """
        XCTAssertEqual(UpdateChecker.checksum(for: "FineWine-0.1.0-453b18c3.zip", inSums: sums),
                       "abcdefabcdef0123456789abcdef0123456789abcdef0123456789abcdef0123")
        XCTAssertEqual(UpdateChecker.checksum(for: "other.zip", inSums: sums), String(repeating: "2", count: 64))
        XCTAssertNil(UpdateChecker.checksum(for: "missing.zip", inSums: sums))
    }

    /// Asks GitHub for real. Only with FINEWINE_LIVE_UPDATE_TEST=1: tests do not go on line
    /// otherwise.
    func testLiveFeedIsReadable() async throws {
        guard ProcessInfo.processInfo.environment["FINEWINE_LIVE_UPDATE_TEST"] == "1" else {
            throw XCTSkip("set FINEWINE_LIVE_UPDATE_TEST=1 to ask GitHub")
        }
        let releases = try await UpdateChecker.fetchReleases()
        XCTAssertFalse(releases.isEmpty)
        let old = BuildIdentity(version: "0", commit: "", builtAt: .distantPast, channel: "beta")
        for channel in UpdateChannel.allCases {
            let offer = UpdateChecker.offer(from: releases, channel: channel, current: old)
            print("live \(channel.rawValue): \(offer?.release.tag ?? "nothing") \(offer?.asset.name ?? "") \(offer?.asset.size ?? 0)")
        }
        if let offer = UpdateChecker.offer(from: releases, channel: .nightly, current: old), let sums = offer.checksums {
            let text = try await UpdateChecker.fetchText(sums.downloadURL)
            XCTAssertNotNil(UpdateChecker.checksum(for: offer.asset.name, inSums: text))
            print("live notes blocks: \(MarkdownBlocks.parse(offer.release.notes).count)")
        }
    }

    // MARK: Installing

    /// A stand-in for FineWine.app: FineWine's bundle identifier, an executable, ad-hoc signed.
    private func makeApp(at url: URL, version: String, identifier: String = UpdateInstaller.bundleIdentifier) throws {
        let fm = FileManager.default
        let macOS = url.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "FineWine", "CFBundleName": "FineWine",
                                    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version,
                                    "LSMinimumSystemVersion": "11.0", "FineWineCommit": "0123456789abcdef"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        let executable = macOS.appendingPathComponent("FineWine")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", url.path]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0)
    }

    private func zip(_ app: URL, to zip: URL) throws {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)
    }

    private func version(of app: URL) -> String? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }

    func testAnUpdateIsVerifiedUnpackedAndPutInPlace() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("fw-update-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let installed = home.appendingPathComponent("Applications/FineWine.app")
        try makeApp(at: installed, version: "1.0")
        let staging = home.appendingPathComponent("staging/FineWine.app")
        try makeApp(at: staging, version: "2.0")
        let archive = home.appendingPathComponent("FineWine-2.0-01234567.zip")
        try zip(staging, to: archive)

        var log: [String] = []
        let sum = try UpdateInstaller.sha256(of: archive)
        XCTAssertEqual(sum.count, 64)
        // the right checksum passes, a wrong one stops the installation, none is said so
        XCTAssertNoThrow(try UpdateInstaller.verify(zip: archive, expectedSHA256: sum.uppercased()) { log.append($0) })
        XCTAssertThrowsError(try UpdateInstaller.verify(zip: archive, expectedSHA256: String(repeating: "0", count: 64)) { log.append($0) })
        XCTAssertNoThrow(try UpdateInstaller.verify(zip: archive, expectedSHA256: nil) { log.append($0) })

        let unpacked = try UpdateInstaller.unpack(zip: archive, into: home.appendingPathComponent("work")) { log.append($0) }
        XCTAssertEqual(version(of: unpacked), "2.0")
        try UpdateInstaller.replace(installed: installed, with: unpacked) { log.append($0) }
        XCTAssertEqual(version(of: installed), "2.0")
        XCTAssertFalse(fm.fileExists(atPath: unpacked.path))
        // nothing of the previous version is left beside the app
        let beside = try fm.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)
        XCTAssertEqual(beside, ["FineWine.app"])
        XCTAssertFalse(log.isEmpty)
    }

    func testADownloadThatIsNotFineWineOrIsDamagedIsRefused() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("fw-update-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }

        // another app under FineWine's name
        let other = home.appendingPathComponent("other/FineWine.app")
        try makeApp(at: other, version: "9.9", identifier: "com.example.NotFineWine")
        let otherZip = home.appendingPathComponent("other.zip")
        try zip(other, to: otherZip)
        XCTAssertThrowsError(try UpdateInstaller.unpack(zip: otherZip, into: home.appendingPathComponent("w1")) { _ in })

        // FineWine with a file changed after it was signed
        let broken = home.appendingPathComponent("broken/FineWine.app")
        try makeApp(at: broken, version: "2.0")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: broken.appendingPathComponent("Contents/MacOS/FineWine"))
        let brokenZip = home.appendingPathComponent("broken.zip")
        try zip(broken, to: brokenZip)
        XCTAssertThrowsError(try UpdateInstaller.unpack(zip: brokenZip, into: home.appendingPathComponent("w2")) { _ in })

        // not a zip at all
        let junk = home.appendingPathComponent("junk.zip")
        try Data("not a zip".utf8).write(to: junk)
        XCTAssertThrowsError(try UpdateInstaller.unpack(zip: junk, into: home.appendingPathComponent("w3")) { _ in })
    }

    // MARK: Release notes

    func testReleaseNotesAreSplitIntoBlocks() {
        let notes = """
        ## Endfield FW 20261119 Beta 5

        > 🧪 **Beta 5**, built from the `beta/3.0.0-Beta` branch
        > by [run #6](https://example.invalid/run).

        ### What's inside

        | Asset | What it is |
        |---|---|
        | `FineWine-…zip` | **FineWine.app** |
        | `SHA256SUMS.txt` | checksums |

        - Added ARM fixes
          continued on the next line
          - nested item
        1. first
        2) second

        ---
        ```
        swift build
        ```
        Last paragraph,
        on two lines.
        """
        let blocks = MarkdownBlocks.parse(notes)
        XCTAssertEqual(blocks.count, 8)
        XCTAssertEqual(blocks[0], .heading(level: 2, text: "Endfield FW 20261119 Beta 5"))
        XCTAssertEqual(blocks[1], .quote([.paragraph("🧪 **Beta 5**, built from the `beta/3.0.0-Beta` branch by [run #6](https://example.invalid/run).")]))
        XCTAssertEqual(blocks[2], .heading(level: 3, text: "What's inside"))
        XCTAssertEqual(blocks[3], .table(header: ["Asset", "What it is"],
                                         rows: [["`FineWine-…zip`", "**FineWine.app**"], ["`SHA256SUMS.txt`", "checksums"]]))
        XCTAssertEqual(blocks[4], .list([
            .init(depth: 0, marker: "•", text: "Added ARM fixes continued on the next line"),
            .init(depth: 1, marker: "•", text: "nested item"),
            .init(depth: 0, marker: "1.", text: "first"),
            .init(depth: 0, marker: "2.", text: "second"),
        ]))
        XCTAssertEqual(blocks[5], .rule)
        XCTAssertEqual(blocks[6], .code("swift build"))
        XCTAssertEqual(blocks[7], .paragraph("Last paragraph, on two lines."))
        XCTAssertEqual(MarkdownBlocks.parse(""), [])
        XCTAssertEqual(MarkdownBlocks.parse("#hashtag is not a heading"), [.paragraph("#hashtag is not a heading")])
    }
}
