import XCTest
@testable import FineWineCore

final class DiscordPresenceTests: XCTestCase {
    private func object(_ frame: DiscordPresence.Frame) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: frame.payload) as? [String: Any])
    }

    func testFramesAreAHeaderOfKindAndLengthThenJSON() throws {
        let frame = DiscordPresence.handshake(applicationID: "1234")
        let data = frame.encoded
        XCTAssertEqual(Array(data.prefix(4)), [0, 0, 0, 0])
        XCTAssertEqual(Int(data.le32(at: 4)), data.count - 8)
        XCTAssertEqual(try object(frame)["client_id"] as? String, "1234")
        XCTAssertEqual(try object(frame)["v"] as? Int, 1)

        // two messages arriving together, the second not whole yet
        let two = data + DiscordPresence.Frame(kind: .ping, payload: Data("{}".utf8)).encoded
        let first = try XCTUnwrap(DiscordPresence.Frame.decode(two.dropLast(1)))
        XCTAssertEqual(first.frame, frame)
        XCTAssertNil(DiscordPresence.Frame.decode(two.dropFirst(first.length).dropLast(1)))
        XCTAssertEqual(DiscordPresence.Frame.decode(two.dropFirst(first.length))?.frame.kind, .ping)
    }

    func testTheActivityNamesTheGameAndCanBeCleared() throws {
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let set = try object(DiscordPresence.setActivity(game: "Zenless Zone Zero", since: since, others: 1, processID: 77, nonce: "n"))
        XCTAssertEqual(set["cmd"] as? String, "SET_ACTIVITY")
        let arguments = try XCTUnwrap(set["args"] as? [String: Any])
        XCTAssertEqual(arguments["pid"] as? Int, 77)
        let activity = try XCTUnwrap(arguments["activity"] as? [String: Any])
        XCTAssertEqual(activity["details"] as? String, "Zenless Zone Zero")
        XCTAssertEqual(activity["status_display_type"] as? Int, 2)
        XCTAssertEqual((activity["timestamps"] as? [String: Any])?["start"] as? Int, 1_800_000_000)
        XCTAssertTrue((activity["state"] as? String ?? "").contains("1 more"))

        let plain = try object(DiscordPresence.setActivity(game: "G2", since: nil, processID: 1, nameAsStatus: false))
        XCTAssertNil(((plain["args"] as? [String: Any])?["activity"] as? [String: Any])?["status_display_type"])

        let cleared = try object(DiscordPresence.setActivity(game: nil, since: nil, processID: 77))
        XCTAssertTrue((cleared["args"] as? [String: Any])?["activity"] is NSNull)
    }

    func testTheGameIsWhatALauncherStartedWhenThereIsOne() {
        let listed = ["HoYoPlay", "Zenless Zone Zero"]
        XCTAssertEqual(DiscordPresence.game(started: "HoYoPlay", running: ["HYP", "Zenless Zone Zero"], listed: listed), "Zenless Zone Zero")
        XCTAssertEqual(DiscordPresence.game(started: "HoYoPlay", running: ["HYP"], listed: listed), "HoYoPlay")
        XCTAssertEqual(DiscordPresence.game(started: "Zenless Zone Zero", running: ["Zenless Zone Zero"], listed: listed), "Zenless Zone Zero")
        XCTAssertNil(DiscordPresence.game(started: "HoYoPlay", running: [], listed: listed))
    }

    func testSocketPathsStartInTheTemporaryFolder() {
        let paths = DiscordPresence.socketPaths(environment: ["TMPDIR": "/var/folders/x/T/"])
        XCTAssertEqual(paths.first, "/var/folders/x/T/discord-ipc-0")
        XCTAssertTrue(paths.contains("/tmp/discord-ipc-9"))
    }

    /// A stand-in for the Discord app: accepts one connection on a socket and answers each
    /// message, refusing an activity that has the newer status field in it once.
    private final class Server: @unchecked Sendable {
        let path: String
        private let listener: Int32
        private(set) var received: [[String: Any]] = []
        private let lock = NSLock()

        init?(refuseStatusField: Bool) {
            path = "/tmp/fw-discord-\(UUID().uuidString.prefix(8))"
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, listen(listener, 1) == 0 else { return nil }
            Thread.detachNewThread { [self] in
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                var buffer = Data()
                var chunk = [UInt8](repeating: 0, count: 4096)
                while true {
                    while let (frame, length) = DiscordPresence.Frame.decode(buffer) {
                        buffer.removeFirst(length)
                        let message = (try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any]) ?? [:]
                        lock.lock(); received.append(message); lock.unlock()
                        let activity = (message["args"] as? [String: Any])?["activity"] as? [String: Any]
                        let refuse = refuseStatusField && activity?["status_display_type"] != nil
                        let reply = refuse ? #"{"cmd":"SET_ACTIVITY","evt":"ERROR","data":{"code":4000}}"# : #"{"cmd":"DISPATCH","evt":"READY"}"#
                        let data = DiscordPresence.Frame(kind: .frame, payload: Data(reply.utf8)).encoded
                        _ = data.withUnsafeBytes { write(client, $0.baseAddress!, $0.count) }
                    }
                    let count = read(client, &chunk, chunk.count)
                    if count <= 0 { break }
                    buffer.append(contentsOf: chunk[0..<count])
                }
                close(client)
            }
        }

        deinit { close(listener); unlink(path) }

        var messages: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return received }
    }

    private final class States: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [DiscordConnection.State] = []
        func add(_ state: DiscordConnection.State) { lock.lock(); all.append(state); lock.unlock() }
        var last: DiscordConnection.State? { lock.lock(); defer { lock.unlock() }; return all.last }
    }

    func testAGameIsShownThroughTheSocket() throws {
        let server = try XCTUnwrap(Server(refuseStatusField: false))
        let states = States()
        let connection = DiscordConnection(paths: ["/tmp/fw-discord-nothing-here", server.path]) { states.add($0) }
        connection.show(game: "Cool Game", since: Date(), others: 0, applicationID: "42")
        connection.flush()
        XCTAssertEqual(states.last, .showing("Cool Game"))
        XCTAssertEqual(server.messages.first?["client_id"] as? String, "42")
        XCTAssertEqual(server.messages.last?["cmd"] as? String, "SET_ACTIVITY")
        connection.show(game: nil, since: nil, others: 0, applicationID: "")
        connection.flush()
        XCTAssertEqual(states.last, .idle)
    }

    func testAnOlderDiscordIsSentTheActivityWithoutTheNewerField() throws {
        let server = try XCTUnwrap(Server(refuseStatusField: true))
        let states = States()
        let connection = DiscordConnection(paths: [server.path]) { states.add($0) }
        connection.show(game: "Cool Game", since: nil, others: 0, applicationID: "42")
        connection.flush()
        XCTAssertEqual(states.last, .showing("Cool Game"))
        XCTAssertEqual(server.messages.count, 3)     // the introduction, the refused activity, the plain one
    }

    func testWithoutDiscordNothingHappens() {
        let states = States()
        let connection = DiscordConnection(paths: ["/tmp/fw-discord-nothing-here"]) { states.add($0) }
        connection.show(game: "Cool Game", since: nil, others: 0, applicationID: "42")
        connection.flush()
        XCTAssertEqual(states.last, .noDiscord)
    }
}
