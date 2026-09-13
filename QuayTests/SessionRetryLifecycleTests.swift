import Foundation
import Testing
@testable import Quay

/// Drives the whole retry cycle — attempts, backoff, recovery, cancellation —
/// with a stub launcher and a clock the test owns, so no ssh is spawned and no
/// test waits on real time. The policy tests next door check single decisions;
/// these check that the decisions are wired together.
@MainActor
@Suite("Session retry lifecycle")
struct SessionRetryLifecycleTests {
    /// A tab whose attempts are recorded instead of spawned.
    @MainActor
    private final class Harness {
        let tab: TerminalTabItem
        private(set) var attempts = 0
        /// Every delay waited on, in order.
        private(set) var waits: [TimeInterval] = []

        /// Just the retry backoff: the cosmetic hold before a connected session
        /// reads as running goes through the same injected sleep.
        var backoffWaits: [TimeInterval] {
            waits.filter { $0 != TerminalTabItem.minimumConnectingDisplay }
        }
        private var clock = Date(timeIntervalSince1970: 1_000_000)

        init() {
            var recordAttempt: (@MainActor () -> Void)?
            var recordWait: (@MainActor (TimeInterval) -> Void)?
            var readClock: (@MainActor () -> Date)?

            tab = TerminalTabItem(
                profile: ConnectionProfile(name: "prod", hostname: "prod.example.com"),
                launchSession: { recordAttempt?() },
                sleepFor: { seconds in recordWait?(seconds) },
                now: { readClock?() ?? Date() }
            )
            recordAttempt = { [weak self] in self?.attempts += 1 }
            recordWait = { [weak self] seconds in self?.waits.append(seconds) }
            readClock = { [weak self] in self?.clock ?? Date() }
        }

        func advanceClock(by seconds: TimeInterval) {
            clock = clock.addingTimeInterval(seconds)
        }

        /// The client's connection comes up — but nothing yet proves it got
        /// past authentication.
        func connectSession() async {
            tab.markConnected()
            await tab.awaitConnectedHold()
        }

        /// The remote shell announces itself, which is what proves the session
        /// authenticated.
        func reachRemoteShell() async {
            tab.markRemoteShellReached()
            await tab.awaitConnectedHold()
        }

        /// A session that authenticated, worked for a while, then dropped.
        func dropWorkingSession() async {
            await reachRemoteShell()
            advanceClock(by: TerminalTabItem.minimumWorkingSession + 1)
            tab.markSessionEnded()
        }

        /// An attempt that never connected, failing.
        func failAttempt() async {
            tab.markSessionEnded()
        }
    }

    @Test("A working session that drops is retried, and the attempt is launched")
    func dropSchedulesAndLaunchesRetry() async {
        let h = Harness()
        h.tab.connect()
        #expect(h.attempts == 1)

        await h.dropWorkingSession()
        #expect(h.tab.phase == .waitingToRetry(attempt: 1))

        await h.tab.awaitPendingRetry()
        #expect(h.attempts == 2)
        #expect(h.tab.phase == .reconnecting(attempt: 1))
    }

    @Test("Failed attempts keep the cycle going, backing off as they go")
    func failedAttemptsAdvanceTheCycle() async {
        let h = Harness()
        h.tab.connect()
        await h.dropWorkingSession()
        await h.tab.awaitPendingRetry()

        for _ in 0..<3 {
            await h.failAttempt()
            await h.tab.awaitPendingRetry()
        }

        #expect(h.attempts == 5)  // first connect + four attempts
        #expect(h.backoffWaits == [2, 4, 8, 15])
        #expect(h.tab.phase == .reconnecting(attempt: 4))
    }

    @Test("The cycle gives up at the ceiling and waits for the user")
    func cycleStopsAtCeiling() async {
        let h = Harness()
        h.tab.connect()
        await h.dropWorkingSession()
        await h.tab.awaitPendingRetry()

        while case .reconnecting = h.tab.phase {
            await h.failAttempt()
            await h.tab.awaitPendingRetry()
        }

        #expect(h.tab.phase == .disconnected)
        #expect(h.attempts == TerminalTabItem.maximumRetryAttempts + 1)
    }

    /// Recovering late must not leave the next outage with a spent budget.
    @Test("A session recovered deep in a cycle resets the budget")
    func recoveryResetsBudget() async {
        let h = Harness()
        h.tab.connect()
        await h.dropWorkingSession()
        await h.tab.awaitPendingRetry()

        for _ in 0..<4 {
            await h.failAttempt()
            await h.tab.awaitPendingRetry()
        }
        #expect(h.tab.phase == .reconnecting(attempt: 5))

        await h.dropWorkingSession()
        #expect(h.tab.phase == .waitingToRetry(attempt: 1))
        await h.tab.awaitPendingRetry()
        #expect(h.backoffWaits.last == 2)  // backoff restarted, not capped
    }

    /// libghostty re-fires a close request for every key pressed into a dead
    /// surface, so typing during a backoff must not spend the budget.
    @Test("Repeated end-of-session reports during a backoff change nothing")
    func repeatedEndReportsAreIgnored() async {
        let h = Harness()
        h.tab.connect()
        await h.dropWorkingSession()
        #expect(h.tab.phase == .waitingToRetry(attempt: 1))

        for _ in 0..<10 { h.tab.markSessionEnded() }

        #expect(h.tab.phase == .waitingToRetry(attempt: 1))
        await h.tab.awaitPendingRetry()
        #expect(h.attempts == 2)
        #expect(h.backoffWaits == [2])
    }

    @Test("A rejected credential — connected, then gone a second later — is not retried")
    func rejectedCredentialIsNotRetried() async {
        let h = Harness()
        h.tab.connect()
        await h.connectSession()
        h.advanceClock(by: 1)
        h.tab.markSessionEnded()

        #expect(h.tab.phase == .disconnected)
        #expect(h.attempts == 1)
    }

    @Test("An attempt against a host that never answers is not retried on its own")
    func unprovenHostIsNotRetried() async {
        let h = Harness()
        h.tab.connect()
        await h.failAttempt()

        #expect(h.tab.phase == .disconnected)
        #expect(h.attempts == 1)
    }

    @Test("Disconnecting during a backoff ends the cycle for good")
    func disconnectStopsTheCycle() async {
        let h = Harness()
        h.tab.connect()
        await h.dropWorkingSession()

        h.tab.disconnect()
        #expect(h.tab.phase == .disconnected)

        await h.tab.awaitPendingRetry()
        #expect(h.attempts == 1)

        // And a later end-of-session report doesn't revive it.
        h.tab.markSessionEnded()
        #expect(h.tab.phase == .disconnected)
        #expect(h.attempts == 1)
    }

    @Test("Connecting by hand during a backoff attempts immediately and resets the cycle")
    func manualConnectSkipsTheBackoff() async {
        let h = Harness()
        h.tab.connect()
        await h.dropWorkingSession()
        #expect(h.tab.phase == .waitingToRetry(attempt: 1))

        h.tab.connect()
        #expect(h.attempts == 2)
        #expect(h.tab.phase == .starting)  // a fresh cycle, not attempt 2

        await h.tab.awaitPendingRetry()
        #expect(h.attempts == 2)  // the cancelled backoff launched nothing
    }

    @Test("A tab closed mid-cycle launches nothing more")
    func closeStopsTheCycle() async {
        let h = Harness()
        h.tab.connect()
        await h.dropWorkingSession()

        h.tab.close()
        await h.tab.awaitPendingRetry()

        #expect(h.attempts == 1)
        #expect(h.tab.phase == .idle)
    }
}
