import Darwin
import Foundation

/// What Quay and the bundled `quay-supervisor` say to each other, one JSON
/// object per line over a Unix domain socket.
///
/// Compiled into both the app and the helper, so the two can only ever
/// disagree about a message by failing to build.
enum SupervisorProtocol {
    /// Environment variable carrying the socket path to the helper.
    static let socketEnvironmentKey = "QUAY_SUPERVISOR_SOCKET"

    /// A session to run as the terminal's foreground process.
    struct Spawn: Codable, Equatable, Sendable {
        /// `argv[0]` is the executable's absolute path.
        var argv: [String]
        /// Applied over the helper's own environment, which is the user's
        /// login environment.
        var environment: [String: String] = [:]
        var workingDirectory: String?
        /// Written to the terminal, followed by a newline, just before the
        /// session starts — the marker line.
        var announce: String?
    }

    enum Request: Codable, Equatable, Sendable {
        case spawn(Spawn)
        /// Delivered to `session`'s whole process group, and only while that is
        /// still the session the helper has.
        ///
        /// The pid is named rather than implied because a teardown outlives the
        /// session it is tearing down: signals are escalated over seconds, and
        /// a reconnect in that window can start a replacement. Aiming at a pid
        /// lets the helper drop a signal meant for the session before it.
        case signal(number: Int32, session: Int32)
    }

    enum Event: Codable, Equatable, Sendable {
        /// Sent once, after the helper owns the terminal. Nothing may be
        /// spawned before it.
        case ready
        case spawned(pid: Int32)
        /// Exactly one of `status` and `signal` is set.
        case exited(pid: Int32, status: Int32?, signal: Int32?)
        /// A request that could not be carried out. The helper is still alive.
        case error(message: String)
    }

    static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    static func decode<T: Decodable>(_ line: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: line)
    }
}

/// Splits a byte stream into newline-terminated lines, holding a partial line
/// until the rest arrives.
struct LineFramer {
    private var pending = Data()

    /// Returns each complete line in `data`, without its newline.
    mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(pending[pending.startIndex..<newline])
            pending = Data(pending[pending.index(after: newline)...])
        }
        return lines
    }

    /// Reads whatever is waiting on `fd` and returns the complete lines it
    /// finished. `nil` means end of stream: the peer hung up.
    mutating func readLines(from fd: Int32) -> [Data]? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(fd, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return append(Data(buffer[..<count]))
    }
}

/// The socket plumbing both ends share. Compiled into the app and the helper,
/// so the address Quay binds and the one the helper connects to can only ever
/// differ by failing to build.
enum UnixSocket {
    /// Calls `body` with `path` as a `sockaddr_un`, or returns `nil` when the
    /// path does not fit `sun_path`'s fixed size.
    static func withAddress<T>(
        ofPath path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) -> T? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static var errnoText: String { String(cString: strerror(errno)) }
}
