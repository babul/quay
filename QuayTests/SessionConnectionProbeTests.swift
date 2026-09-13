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

    @Test("An established connection owned by this process is seen")
    func seesEstablishedConnection() throws {
        let pair = try #require(LoopbackPair(), "could not open a loopback connection")
        _ = pair  // held open for the duration of the check
        #expect(SessionConnectionProbe.hasEstablishedTCP(pid: getpid()))
    }

    @Test("A process that owns no sockets at all reports no connection")
    func ignoresProcessWithoutSockets() {
        // pid 0 (the kernel) is never a session process and exposes no fds.
        #expect(!SessionConnectionProbe.hasEstablishedTCP(pid: 0))
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
}
