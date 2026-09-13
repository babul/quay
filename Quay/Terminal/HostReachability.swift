import Darwin
import Foundation

/// Answers "is this host still there?" with a short TCP connect.
///
/// It exists to tell two situations apart that look identical from the process
/// table: an sftp client that closed an idle connection (lftp does this by
/// design, and reopens one on the next command), and a host that has gone away.
/// Without it, a tab either claims to be connected to a rebooted machine or
/// claims to be disconnected from a perfectly good one.
enum HostReachability {
    /// Connects, then hangs up immediately — nothing is sent and nothing is
    /// read, so this never disturbs the server beyond an accept and a close.
    ///
    /// Runs synchronously and blocks for up to `timeout` in total — the budget
    /// covers every address the name resolves to, not each one in turn. Call it
    /// off the main actor.
    ///
    /// `host` is expected to be a numeric address (Quay probes a session's own
    /// socket peer), so resolution is a parse rather than a DNS round trip and
    /// the deadline governs the connect. A name would resolve first, outside
    /// the budget.
    nonisolated static func isReachable(
        host: String,
        port: Int,
        timeout: TimeInterval
    ) -> Bool {
        var hints = addrinfo(
            // The port is always numeric, so there is no /etc/services lookup.
            ai_flags: AI_NUMERICSERV,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else {
            // Name resolution failing is itself an answer: nothing to reach.
            return false
        }
        defer { freeaddrinfo(list) }

        let deadline = Date().addingTimeInterval(timeout)
        for candidate in sequence(first: first, next: { $0.pointee.ai_next }) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            if connects(to: candidate.pointee, timeout: remaining) { return true }
        }
        return false
    }

    private static func connects(to address: addrinfo, timeout: TimeInterval) -> Bool {
        let fd = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        // Non-blocking, so the timeout is ours rather than the kernel's — an
        // unanswered SYN would otherwise hold this for over a minute.
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return false }

        if connect(fd, address.ai_addr, address.ai_addrlen) == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var writable = fd_set()
        __darwin_fd_set(fd, &writable)
        var deadline = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000)
        )
        guard select(fd + 1, nil, &writable, nil, &deadline) > 0 else { return false }

        // Writable also means "failed"; the pending error says which.
        var pending: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &pending, &size) == 0 else { return false }
        return pending == 0
    }
}
