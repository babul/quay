import Darwin
import Foundation

/// One-shot Unix-domain-socket server that hands a single secret to the
/// bundled `quay-askpass` helper, then shuts down.
///
/// Lifecycle:
///
///   1. `init` picks a fresh socket path under `$TMPDIR`.
///   2. `start()` binds + listens (mode 0600 — same-user only).
///   3. The first incoming connection is served: we resolve the configured
///      reference, write the plaintext bytes, close the socket, unlink.
///   4. After serving once, the listener is torn down.
///
/// One server per connection-attempt. Because `quay-askpass` may be
/// invoked multiple times by OpenSSH (e.g. retry after wrong password),
/// callers may opt to keep the server alive longer — currently we serve
/// exactly once.
final class AskpassServer: @unchecked Sendable {
    /// Closure that produces the bytes to hand to the helper. Async because
    /// real resolution may shell out (1Password) or hit Touch ID (Keychain).
    typealias Resolver = @Sendable () async throws -> SensitiveBytes

    let socketPath: String
    private let resolve: Resolver
    private var listenerFD: Int32 = -1

    /// General-purpose constructor — the resolution closure picks the secret.
    init(resolve: @escaping @Sendable () async throws -> SensitiveBytes) {
        self.resolve = resolve
        let tmpDir = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp/"
        let normalized = tmpDir.hasSuffix("/") ? tmpDir : tmpDir + "/"
        self.socketPath = "\(normalized)quay-askpass-\(UUID().uuidString).sock"
    }

    /// Convenience: serve the secret behind a `keychain://` / `op://` URI.
    convenience init(secretURI: String, resolver: ReferenceResolver = ReferenceResolver()) {
        self.init(resolve: { try await resolver.resolve(secretURI) })
    }

    deinit {
        teardown()
    }

    /// Bind + listen, then spawn a single accept-and-serve task. Returns
    /// after the listener is open; the actual serve happens asynchronously.
    func start() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IOError(errno: errno) }

        // sockaddr_un.sun_path is fixed-size; check before strcpy.
        let pathBytes = Array(socketPath.utf8) + [0]
        guard pathBytes.count <= 104 else {
            close(fd)
            throw IOError(message: "socket path too long: \(socketPath)")
        }

        // Make sure no stale socket file is in the way.
        unlink(socketPath)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBufferPointer { src in
                dst.copyBytes(from: UnsafeRawBufferPointer(src))
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(fd)
            throw IOError(errno: err)
        }

        // Same-user only — defense in depth even though the FS path is
        // already $TMPDIR which is per-user on macOS.
        chmod(socketPath, 0o600)

        guard listen(fd, 1) == 0 else {
            let err = errno
            close(fd); unlink(socketPath)
            throw IOError(errno: err)
        }

        listenerFD = fd

        Task.detached { [self] in
            await self.serveOnce()
        }
    }

    /// Stop the listener and clean up the socket file.
    func stop() {
        teardown()
    }

    private func teardown() {
        if listenerFD >= 0 {
            close(listenerFD)
            listenerFD = -1
        }
        unlink(socketPath)
    }

    private func serveOnce() async {
        guard listenerFD >= 0 else { return }
        let client = accept(listenerFD, nil, nil)
        defer { teardown() }
        guard client >= 0 else { return }

        // Resolve the secret on demand. Even if the helper connects faster
        // than expected, we do NOT precompute the secret — fewer windows
        // where plaintext sits in memory.
        let bytes: SensitiveBytes
        do {
            bytes = try await resolve()
        } catch {
            // Helper sees EOF on read => prints nothing => ssh treats it as
            // an empty password. That's fine: ssh will prompt or fail.
            close(client)
            return
        }

        bytes.withUnsafeBytes { buf in
            guard let base = buf.baseAddress, buf.count > 0 else { return }
            var written = 0
            while written < buf.count {
                let n = write(client, base.advanced(by: written), buf.count - written)
                if n <= 0 { break }
                written += n
            }
        }
        close(client)
    }
}

struct IOError: Error, CustomStringConvertible {
    let message: String

    init(message: String) {
        self.message = message
    }

    init(errno code: Int32) {
        self.message = String(cString: strerror(code)) + " (errno=\(code))"
    }

    var description: String { message }
}
