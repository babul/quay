import Darwin
import Foundation
import Testing
@testable import Quay

/// This is what tells an sftp client that idle-closed its connection apart from
/// a host that has gone away — the two look identical from the process table,
/// and getting it wrong either strands a tab on a rebooted machine or declares
/// a working one dead.
@Suite("Host reachability")
struct HostReachabilityTests {
    /// A listening socket on loopback, closed when the test ends.
    private final class Listener {
        let fd: Int32
        let port: Int

        init?() {
            // Locals until the end: Swift forbids capturing stored properties
            // in a closure before every member is initialized.
            let listenFD = socket(AF_INET, SOCK_STREAM, 0)
            guard listenFD >= 0 else { return nil }

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, Darwin.listen(listenFD, 4) == 0 else {
                close(listenFD)
                return nil
            }

            var named = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let gotName = withUnsafeMutablePointer(to: &named) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(listenFD, $0, &length)
                }
            }
            guard gotName == 0 else {
                close(listenFD)
                return nil
            }

            fd = listenFD
            port = Int(UInt16(bigEndian: named.sin_port))
        }

        deinit { close(fd) }
    }

    @Test("A host that accepts connections is reachable")
    func reachableHostAnswers() throws {
        let listener = try #require(Listener())
        #expect(
            HostReachability.isReachable(host: "127.0.0.1", port: listener.port, timeout: 3)
        )
    }

    @Test("A closed port is not reachable, and says so immediately")
    func closedPortIsRefused() throws {
        // Bind and release, so the port is almost certainly free and refusing.
        let port = try #require(Listener()).port
        let started = Date()
        #expect(!HostReachability.isReachable(host: "127.0.0.1", port: port, timeout: 3))
        // A refusal is an answer, not a timeout: it must not burn the budget.
        #expect(Date().timeIntervalSince(started) < 2)
    }

    /// The case this exists for: a host that has gone away answers nothing at
    /// all, and the check has to give up on its own schedule rather than the
    /// kernel's minute-plus SYN retransmits.
    @Test("A host that never answers gives up within the timeout")
    func unansweredHostTimesOut() {
        let started = Date()
        // RFC 5737 documentation address: routable in form, answered by nobody.
        #expect(!HostReachability.isReachable(host: "192.0.2.1", port: 22, timeout: 1))
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test("A name that does not resolve is not reachable")
    func unresolvableHost() {
        #expect(!HostReachability.isReachable(host: "no-such-host.invalid", port: 22, timeout: 2))
    }
}
