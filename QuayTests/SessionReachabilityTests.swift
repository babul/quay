import Foundation
import Testing
@testable import Quay

/// A reachability check is destructive — a negative answer tears the session
/// down — so these cover the guards that stand between a slow probe and a
/// healthy tab. Reachability is scripted; no network is touched.
@MainActor
@Suite("Session reachability")
struct SessionReachabilityTests {
    @MainActor
    private final class Harness {
        let tab: TerminalTabItem
        /// Answers handed out in order; the last one repeats.
        var answers: [Bool] = [false, false]
        private(set) var probes = 0
        /// Runs just before each answer is given, to move the world while the
        /// probe is in flight.
        var beforeAnswer: (@MainActor (Int) -> Void)?

        init() {
            var probe: (@MainActor () async -> Bool)?
            tab = TerminalTabItem(
                profile: ConnectionProfile(name: "prod", hostname: "prod.example.com"),
                launchSession: {},
                sleepFor: { _ in },
                checkReachable: { _ in await probe?() ?? true }
            )
            probe = { [weak self] in
                guard let self else { return true }
                probes += 1
                beforeAnswer?(probes)
                return answers[min(probes - 1, answers.count - 1)]
            }
            tab.lastKnownPeer = .init(host: "203.0.113.7", port: 22)
        }

        /// A tab in `.running`, which is the only state a sibling's bad news is
        /// acted on from.
        func reachRunning() async {
            tab.connect()
            tab.markConnected()
            tab.markRemoteShellReached()
            await tab.awaitConnectedHold()
        }

        func settle() async {
            await tab.awaitReachabilityCheck()
        }
    }

    /// The point of the check: a client whose host is gone but which has not
    /// noticed is ended on its behalf, so the retry cycle can take over.
    @Test("A host that stops answering twice ends the session and retries")
    func confirmedLossEndsSession() async {
        let h = Harness()
        await h.reachRunning()

        h.tab.verifyHostReachable()
        await h.settle()
        await h.tab.awaitPendingRetry()

        #expect(h.probes == 2)
        #expect(h.tab.phase == .reconnecting(attempt: 1))
    }

    /// sshd restarting, or a connection-rate limit, refuses new connections
    /// while every existing one is fine. One refusal must not be enough.
    @Test("A single refusal is not enough to end a session")
    func singleRefusalIsNotEnough() async {
        let h = Harness()
        h.answers = [false, true]
        await h.reachRunning()

        h.tab.verifyHostReachable()
        await h.settle()

        #expect(h.probes == 2)
        #expect(h.tab.phase == .running)
    }

    /// The probe is slow. A tab the user disconnected, or one whose session
    /// already ended, must not be acted on by an answer that arrives late.
    @Test("A negative answer is dropped once the session is no longer live")
    func staleNegativeIsDropped() async {
        let h = Harness()
        await h.reachRunning()
        h.beforeAnswer = { [weak h] round in
            if round == 1 { h?.tab.disconnect() }
        }

        h.tab.verifyHostReachable()
        await h.settle()

        // Abandoned after the first round rather than confirmed.
        #expect(h.probes == 1)
    }

    @Test("A tab that is not running ignores a sibling's report")
    func onlyRunningTabsCheck() async {
        let h = Harness()
        h.tab.connect()  // .starting — an attempt of its own is already bounded

        h.tab.verifyHostReachable()
        await h.settle()

        #expect(h.probes == 0)
    }

    /// Without a peer there is nothing to probe: `profile.hostname` may be an
    /// ssh_config alias, or rewritten by `HostName`/`Port`/`ProxyJump` before
    /// ssh dials, and probing it would report a healthy session dead.
    @Test("A session never seen connected is not probed by guesswork")
    func noPeerMeansNoProbe() async {
        let h = Harness()
        h.tab.lastKnownPeer = nil
        await h.reachRunning()

        h.tab.verifyHostReachable()
        await h.settle()

        #expect(h.probes == 0)
        #expect(h.tab.phase == .running)
    }
}
