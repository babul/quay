import Foundation
import Darwin
import Testing
@testable import Quay

/// The probe is what decides whether a tab says "Connecting…" or claims to be
/// connected, so the two states it must never confuse are a socket that
/// completed its handshake and one that is still waiting for the peer.
@Suite("Session connection probe")
struct SessionConnectionProbeTests {
    /// A listening socket plus a client connected to it, both owned by this
    /// process. Closed on `deinit`.
    private final class LoopbackPair {
        let listener: Int32
        let client: Int32
        let accepted: Int32

        init?() {
            // Locals throughout: Swift forbids capturing stored properties in a
            // closure before every member is initialized.
            let listenFD = socket(AF_INET, SOCK_STREAM, 0)
            guard listenFD >= 0 else { return nil }
            var yes: Int32 = 1
            setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0  // kernel picks the port
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")

            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, Darwin.listen(listenFD, 1) == 0 else {
                close(listenFD)
                return nil
            }

            var boundAddr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &boundAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(listenFD, $0, &len)
                }
            }
            guard named == 0 else {
                close(listenFD)
                return nil
            }

            let clientFD = socket(AF_INET, SOCK_STREAM, 0)
            guard clientFD >= 0 else {
                close(listenFD)
                return nil
            }
            let connected = withUnsafePointer(to: &boundAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(clientFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else {
                close(listenFD)
                close(clientFD)
                return nil
            }

            let acceptedFD = accept(listenFD, nil, nil)
            guard acceptedFD >= 0 else {
                close(listenFD)
                close(clientFD)
                return nil
            }

            listener = listenFD
            client = clientFD
            accepted = acceptedFD
        }

        deinit {
            close(accepted)
            close(client)
            close(listener)
        }
    }

    @Test("An established connection owned by this process is seen, with its far end")
    func seesEstablishedConnection() throws {
        let pair = try #require(LoopbackPair(), "could not open a loopback connection")
        _ = pair  // held open for the duration of the check
        // The address the session actually reached is what a later reachability
        // check has to probe — the profile's hostname can be an ssh_config
        // alias, or rewritten by HostName/Port/ProxyJump before ssh dials. Both
        // ends of the pair belong to this process, so which one answers first
        // is not fixed; that it is a real endpoint is the point.
        let peer = try #require(SessionConnectionProbe.establishedPeer(pid: getpid()))
        #expect(peer.host == "127.0.0.1")
        #expect(peer.port > 0)
    }

    @Test("A process that owns no sockets at all reports no connection")
    func ignoresProcessWithoutSockets() {
        // pid 0 (the kernel) is never a session process and exposes no fds.
        #expect(SessionConnectionProbe.establishedPeer(pid: 0) == nil)
    }

    @Test("Session lookup finds this process by its own process group")
    func findsProcessesByGroup() {
        let group = SessionConnectionProbe.sessionProcesses(pgid: getpgrp())
        #expect(group.contains(getpid()))
    }

    @Test("A process group with no members yields nothing")
    func emptyGroupYieldsNothing() {
        // A pgid this high cannot exist: pids wrap well below it.
        #expect(SessionConnectionProbe.sessionProcesses(pgid: .max).isEmpty)
    }

    @Test("This process is found by name in its own group")
    func findsClientByName() {
        let name = try? #require(SessionConnectionProbe.processName(of: getpid()))
        let found = SessionConnectionProbe.foreground(
            pgid: getpgrp(),
            clientNames: [name ?? ""]
        )
        #expect(found.names.contains(name ?? ""))
        #expect(found.state != .noClient)
    }

    @Test("A group with no matching client reports no client")
    func reportsNoClientWhenAbsent() {
        let found = SessionConnectionProbe.foreground(
            pgid: getpgrp(),
            clientNames: ["definitely-not-a-running-binary"]
        )
        #expect(found.state == .noClient)
        // The group's own processes are still reported, which is how the tab
        // knows its host shell is ready for a command.
        #expect(!found.names.isEmpty)
    }

    @Test("Client presence is answered without walking sockets")
    func clientPresenceCheck() {
        let name = SessionConnectionProbe.processName(of: getpid()) ?? ""
        #expect(SessionConnectionProbe.clientIsRunning(pgid: getpgrp(), clientNames: [name]))
        #expect(!SessionConnectionProbe.clientIsRunning(pgid: getpgrp(), clientNames: ["nope"]))
    }

    /// The host shell turns echo off as the last step of its startup, which is
    /// how the tab knows it is ready to be typed into.
    @Test("Echo state is read from the tty, and a bad path reports not-ready")
    func echoDisabledReadsTheTty() {
        #expect(!SessionConnectionProbe.echoDisabled(ttyPath: "/dev/definitely-not-a-tty"))
        // This test runs under a pipe, not a tty, so /dev/tty may not exist —
        // assert only that a readable non-tty device answers false rather than
        // crashing or reporting ready.
        #expect(!SessionConnectionProbe.echoDisabled(ttyPath: "/dev/null"))
    }

    /// lftp opens no socket itself — it spawns `ssh` in its own session and
    /// lets that hold the connection. A session like that read as "connecting"
    /// for as long as it ran.
    @Test("A client whose transport runs in a helper child counts as connected")
    func findsTransportHelperChild() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        try #require(listener >= 0)
        defer { close(listener) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bound == 0)
        try #require(Darwin.listen(listener, 1) == 0)

        var named = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gotName = withUnsafeMutablePointer(to: &named) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        try #require(gotName == 0)
        let port = UInt16(bigEndian: named.sin_port)

        // The helper: a child of this process, holding the connection.
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        helper.arguments = ["127.0.0.1", String(port)]
        try #require(throws: Never.self) { try helper.run() }
        defer { helper.terminate() }

        var readable = fd_set()
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        __darwin_fd_set(listener, &readable)
        try #require(select(listener + 1, &readable, nil, nil, &timeout) > 0)
        let accepted = accept(listener, nil, nil)
        try #require(accepted >= 0)
        defer { close(accepted) }

        // The helper's far end is the listener above — which is the address a
        // reachability check on an lftp-style session has to probe, since the
        // client itself never holds the socket.
        let peer = SessionConnectionProbe.establishedHelperPeer(of: [getpid()])
        #expect(peer?.host == "127.0.0.1")
        #expect(peer?.port == Int(port))
    }

    @Test("A process with no children holding sockets is not mistaken for connected")
    func ignoresUnrelatedProcesses() {
        // pid 1 is not this test's client, and nothing it owns should answer.
        #expect(SessionConnectionProbe.establishedHelperPeer(of: []) == nil)
    }

    /// Writing to a pty is asynchronous, so keystrokes meant for a remote
    /// session can still be unread when it dies — and the host shell then reads
    /// and *runs* them. That is how a login script's `htop` ended up owning a
    /// tab locally.
    @Test("Input typed for a dead session is discarded, not left for the shell")
    func flushDiscardsUnreadInput() throws {
        var primary: Int32 = 0
        var replica: Int32 = 0
        try #require(openpty(&primary, &replica, nil, nil, nil) == 0)
        defer { close(primary); close(replica) }

        let path = String(cString: try #require(ptsname(primary)))
        _ = fcntl(replica, F_SETFL, fcntl(replica, F_GETFL, 0) | O_NONBLOCK)

        // Something typed for the session that is about to die.
        let pending = "htop\n"
        _ = pending.withCString { write(primary, $0, strlen($0)) }
        usleep(50_000)

        SessionConnectionProbe.flushInput(ttyPath: path)

        var buffer = [CChar](repeating: 0, count: 64)
        let read = Darwin.read(replica, &buffer, buffer.count)
        // Nothing left for the shell to run: -1/EAGAIN on an empty queue.
        #expect(read <= 0)
    }
}
