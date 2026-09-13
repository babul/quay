import Darwin
import Foundation

/// Quay's end of the conversation with a tab's `quay-supervisor`.
///
/// Listens on a per-tab Unix domain socket that only this user can reach,
/// accepts exactly one connection — the helper's — and then unlinks the path,
/// so nothing else can ever connect. Same trust boundary as `AskpassServer`.
@MainActor
final class SupervisorClient {
    enum Failure: Error, CustomStringConvertible {
        case socket(String)
        case notConnected

        var description: String {
            switch self {
            case .socket(let detail): return "supervisor socket: \(detail)"
            case .notConnected: return "the session supervisor is not connected"
            }
        }
    }

    let socketPath: String
    private var listener: Int32
    private var connection: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var readSource: DispatchSourceRead?
    private var framer = LineFramer()

    /// Delivered on the main actor, in the order the helper sent them.
    var onEvent: ((SupervisorProtocol.Event) -> Void)?

    init() throws {
        let directory = FileManager.default.temporaryDirectory
        let name = "quay-sv-\(UUID().uuidString.prefix(8)).sock"
        socketPath = directory.appending(path: name).path

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        listener = fd
        guard fd >= 0 else { throw Failure.socket("socket: \(UnixSocket.errnoText)") }

        // Mode 0600 from the moment the path exists: the socket is created
        // under a temporary umask rather than tightened afterwards.
        let previousMask = umask(0o077)
        let bound = UnixSocket.withAddress(ofPath: socketPath) { address, length in
            bind(fd, address, length)
        }
        umask(previousMask)
        guard let bound else {
            close(fd)
            throw Failure.socket("path too long: \(socketPath)")
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            let detail = UnixSocket.errnoText
            close(fd)
            unlink(socketPath)
            throw Failure.socket("bind: \(detail)")
        }
    }

    /// Starts waiting for the helper to connect. Events flow once it has.
    func start() {
        let fd = listener
        let path = socketPath
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.acceptHelper() }
        }
        // A source reads its descriptor asynchronously, so closing one out from
        // under it can land the read on whatever reused the number. Closing in
        // the cancel handler is the documented way to hand ownership over.
        source.setCancelHandler {
            close(fd)
            unlink(path)
        }
        acceptSource = source
        source.resume()
    }

    var isConnected: Bool { connection >= 0 }

    func send(_ request: SupervisorProtocol.Request) throws {
        guard isConnected else { throw Failure.notConnected }
        let data = try SupervisorProtocol.encodeLine(request)
        let written = data.withUnsafeBytes { Darwin.write(connection, $0.baseAddress, $0.count) }
        guard written == data.count else { throw Failure.socket("write: \(UnixSocket.errnoText)") }
    }

    /// Closes the socket. The helper hangs up its session and exits when it
    /// sees this.
    func stop() {
        closeListener()
        closeConnection()
    }

    /// Stops taking connections and removes the socket from the filesystem.
    /// The descriptor is closed by the source's cancel handler.
    private func closeListener() {
        listener = -1
        guard let source = acceptSource else { return }
        acceptSource = nil
        source.cancel()
    }

    /// The descriptor is closed by the source's cancel handler.
    private func closeConnection() {
        connection = -1
        guard let source = readSource else { return }
        readSource = nil
        source.cancel()
    }

    private func acceptHelper() {
        let accepted = accept(listener, nil, nil)
        guard accepted >= 0 else { return }
        connection = accepted

        // One connection, then the door is closed and the path removed.
        closeListener()

        let source = DispatchSource.makeReadSource(fileDescriptor: accepted, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readEvents() }
        }
        source.setCancelHandler { close(accepted) }
        readSource = source
        source.resume()
    }

    private func readEvents() {
        guard let lines = framer.readLines(from: connection) else {
            // The helper is gone. libghostty reports the same thing as its
            // child exiting, which is where the tab acts on it.
            closeConnection()
            return
        }
        for line in lines {
            guard let event = try? SupervisorProtocol.decode(line) as SupervisorProtocol.Event else { continue }
            onEvent?(event)
        }
    }
}
