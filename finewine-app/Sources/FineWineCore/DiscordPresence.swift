import Foundation

/// Shows what is being played as the user's Discord activity ("Rich Presence").
///
/// The Discord app listens on a socket in the user's temporary folder (`discord-ipc-0` to
/// `-9`). A program introduces itself there with the id of a Discord application and then
/// sets an activity; the activity lasts for as long as the connection is open. Messages are a
/// header of two little-endian 32-bit numbers, the kind of message and its length, followed by
/// JSON.
///
/// The activity is filed under the Discord application whose id is used, so FineWine needs
/// one (made once at discord.com/developers, where its name and picture are also set). The
/// game's own name goes in the activity's first line, and Discord is asked to show that line as
/// the status ("Playing Zenless Zone Zero") in place of the application's name.
public enum DiscordPresence {
    /// One message on the socket.
    public struct Frame: Equatable, Sendable {
        public enum Kind: UInt32, Sendable { case handshake = 0, frame = 1, close = 2, ping = 3, pong = 4 }
        public var kind: Kind
        public var payload: Data

        public init(kind: Kind, payload: Data) {
            self.kind = kind
            self.payload = payload
        }

        public var encoded: Data {
            var data = Data()
            for value in [kind.rawValue, UInt32(payload.count)] {
                var little = value.littleEndian
                data.append(Data(bytes: &little, count: 4))
            }
            data.append(payload)
            return data
        }

        /// The first whole message in `buffer`, and how many bytes it took; nil when there is
        /// not a whole one yet.
        public static func decode(_ buffer: Data) -> (frame: Frame, length: Int)? {
            guard buffer.count >= 8 else { return nil }
            let length = Int(buffer.le32(at: 4))
            guard length <= 1 << 20, buffer.count >= 8 + length,
                  let kind = Kind(rawValue: buffer.le32(at: 0)) else { return nil }
            let start = buffer.startIndex + 8
            return (Frame(kind: kind, payload: Data(buffer[start..<(start + length)])), 8 + length)
        }
    }

    /// Where Discord may be listening, most likely first.
    public static func socketPaths(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var folders: [String] = []
        for name in ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"] {
            if let value = environment[name], !value.isEmpty, !folders.contains(value) { folders.append(value) }
        }
        if !folders.contains("/tmp") { folders.append("/tmp") }
        return folders.flatMap { folder in
            (0..<10).map { (folder.hasSuffix("/") ? folder : folder + "/") + "discord-ipc-\($0)" }
        }
    }

    public static func handshake(applicationID: String) -> Frame {
        Frame(kind: .handshake, payload: json(["v": 1, "client_id": applicationID]))
    }

    /// Sets the activity, or clears it when `game` is nil.
    /// - Parameters:
    ///   - others: how many more programs are running besides the one named.
    ///   - nameAsStatus: ask Discord to show the game's name as the status line. An older
    ///     Discord that does not know the field may refuse the message; the caller then sends
    ///     it again without.
    public static func setActivity(game: String?, since: Date?, others: Int = 0, processID: Int32,
                                   nonce: String = UUID().uuidString, nameAsStatus: Bool = true) -> Frame {
        var arguments: [String: Any] = ["pid": Int(processID)]
        if let game {
            var activity: [String: Any] = ["type": 0, "details": limited(game), "instance": false]
            activity["state"] = others > 0 ? "and \(others) more, with FineWine" : "with FineWine on a Mac"
            if let since { activity["timestamps"] = ["start": Int(since.timeIntervalSince1970)] }
            if nameAsStatus { activity["status_display_type"] = 2 }     // 2: the details line
            arguments["activity"] = activity
        } else {
            arguments["activity"] = NSNull()
        }
        return Frame(kind: .frame, payload: json(["cmd": "SET_ACTIVITY", "args": arguments, "nonce": nonce]))
    }

    /// True when a reply says the message was refused.
    public static func isError(_ frame: Frame) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any] else { return false }
        return (object["evt"] as? String) == "ERROR" || frame.kind == .close
    }

    /// Discord takes 2 to 128 characters in an activity's lines.
    static func limited(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 2 { return trimmed + " " + String(repeating: "\u{200B}", count: 1) }
        return String(trimmed.prefix(128))
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// Which of the programs running in a prefix is "what is being played": a program FineWine
    /// lists that is not the one the user started (a launcher started the game), else the one
    /// the user started while it or anything else is still running.
    public static func game(started: String, running: [String], listed: [String]) -> String? {
        guard !running.isEmpty else { return nil }
        if let game = running.last(where: { $0 != started && listed.contains($0) }) { return game }
        return started
    }
}

/// The connection to Discord: opened when there is something to show, closed when there is not.
/// Everything happens on its own queue; nothing here blocks the app.
public final class DiscordConnection: @unchecked Sendable {
    public enum State: Equatable, Sendable { case idle, noDiscord, refused, showing(String) }

    private let queue = DispatchQueue(label: "finewine.discord")
    private let paths: [String]
    private var descriptor: Int32 = -1
    private var connectedID = ""
    private var state: State = .idle
    private let onState: @Sendable (State) -> Void

    public init(paths: [String] = DiscordPresence.socketPaths(), onState: @escaping @Sendable (State) -> Void = { _ in }) {
        self.paths = paths
        self.onState = onState
    }

    deinit { if descriptor >= 0 { close(descriptor) } }

    /// Shows a game, or with nil clears the activity and lets the connection go.
    public func show(game: String?, since: Date?, others: Int, applicationID: String) {
        queue.async { [self] in
            guard let game, !applicationID.isEmpty else {
                disconnect()
                set(.idle)
                return
            }
            if descriptor >= 0, connectedID != applicationID { disconnect() }
            if descriptor < 0, !connect(applicationID: applicationID) { return }
            let pid = ProcessInfo.processInfo.processIdentifier
            var reply = send(DiscordPresence.setActivity(game: game, since: since, others: others, processID: pid))
            if let refused = reply, DiscordPresence.isError(refused), descriptor >= 0 {
                reply = send(DiscordPresence.setActivity(game: game, since: since, others: others, processID: pid, nameAsStatus: false))
            }
            if let reply, !DiscordPresence.isError(reply) { set(.showing(game)) }
            else { disconnect(); set(reply == nil ? .noDiscord : .refused) }
        }
    }

    /// Waits for what has been asked so far to be done. For tests and for quitting.
    public func flush() { queue.sync {} }

    private func set(_ new: State) {
        guard new != state else { return }
        state = new
        onState(new)
    }

    private func disconnect() {
        if descriptor >= 0 { close(descriptor) }
        descriptor = -1
        connectedID = ""
    }

    private func connect(applicationID: String) -> Bool {
        for path in paths {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); continue }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard connected == 0 else { close(fd); continue }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            descriptor = fd
            if let reply = send(DiscordPresence.handshake(applicationID: applicationID)), !DiscordPresence.isError(reply) {
                connectedID = applicationID
                return true
            }
            // Discord answered and said no: the application id is not one it knows.
            disconnect()
            set(.refused)
            return false
        }
        set(.noDiscord)
        return false
    }

    /// Sends a message and waits for the reply to it, answering pings meanwhile.
    private func send(_ frame: DiscordPresence.Frame) -> DiscordPresence.Frame? {
        guard write(frame.encoded) else { return nil }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let (reply, length) = DiscordPresence.Frame.decode(buffer) {
                buffer.removeFirst(length)
                if reply.kind == .ping { _ = write(DiscordPresence.Frame(kind: .pong, payload: reply.payload).encoded); continue }
                return reply
            }
            let count = read(descriptor, &chunk, chunk.count)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    private func write(_ data: Data) -> Bool {
        guard descriptor >= 0 else { return false }
        return data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress! + sent, raw.count - sent)
                if count <= 0 { return false }
                sent += count
            }
            return true
        }
    }
}
