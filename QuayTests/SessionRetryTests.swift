import AppKit
import Testing
@testable import Quay

/// The retry cycle runs unattended after a host drops, so the rules that decide
/// *whether* to retry and *how long* to wait are the ones worth pinning down: a
/// tab that never connected must not hammer a bad host, and a user who
/// disconnected on purpose must not be dragged back online.
@MainActor
@Suite("Session retry")
struct SessionRetryTests {
    @Test("Backoff grows 2s, 4s, 8s then holds at the cap")
    func backoffSchedule() {
        #expect(TerminalTabItem.retryDelay(attempt: 1) == 2)
        #expect(TerminalTabItem.retryDelay(attempt: 2) == 4)
        #expect(TerminalTabItem.retryDelay(attempt: 3) == 8)
        #expect(TerminalTabItem.retryDelay(attempt: 4) == TerminalTabItem.maximumRetryDelay)
        #expect(TerminalTabItem.retryDelay(attempt: 99) == TerminalTabItem.maximumRetryDelay)
    }

    @Test("A session that reached the remote shell is retried")
    func retriesRealSession() {
        #expect(
            TerminalTabItem.shouldAutoRetry(
                reachedRemoteShell: true,
                sessionDuration: 0.5,
                userDisconnected: false
            )
        )
    }

    @Test("A session that stayed up long enough is retried even without a title")
    func retriesLongEnoughSession() {
        #expect(
            TerminalTabItem.shouldAutoRetry(
                reachedRemoteShell: false,
                sessionDuration: TerminalTabItem.minimumWorkingSession + 1,
                userDisconnected: false
            )
        )
    }

    /// TCP establishes before authentication, so a rejected credential looks
    /// briefly "connected". Retrying it replays the rejection forever and
    /// re-prompts Touch ID every cycle.
    @Test("A connection rejected moments after it opened is not retried")
    func doesNotRetryRejectedCredential() {
        #expect(
            !TerminalTabItem.shouldAutoRetry(
                reachedRemoteShell: false,
                sessionDuration: 1,
                userDisconnected: false
            )
        )
    }

    @Test("A session the user disconnected stays down")
    func respectsDeliberateDisconnect() {
        #expect(
            !TerminalTabItem.shouldAutoRetry(
                reachedRemoteShell: true,
                sessionDuration: 600,
                userDisconnected: true
            )
        )
    }

    @Test("An attempt that never connected is not retried")
    func doesNotRetryUnprovenHost() {
        #expect(
            !TerminalTabItem.shouldAutoRetry(
                reachedRemoteShell: false,
                sessionDuration: nil,
                userDisconnected: false
            )
        )
    }

    @Test("An attempt in flight behaves like the first attempt")
    func reconnectingPhaseSemantics() {
        let attempting = TerminalTabItem.Phase.reconnecting(attempt: 3)
        // A live child process: same answers as `.starting` everywhere.
        #expect(attempting.isAttemptingConnection)
        #expect(attempting.isAttemptingConnection == TerminalTabItem.Phase.starting.isAttemptingConnection)
        #expect(attempting.isReconnectable == TerminalTabItem.Phase.starting.isReconnectable)
    }

    @Test("Waiting out the backoff invites an immediate retry instead")
    func waitingPhaseSemantics() {
        let waiting = TerminalTabItem.Phase.waitingToRetry(attempt: 3)
        // Nothing is running, so Space or Cmd-R skips the wait...
        #expect(waiting.isReconnectable)
        // ...and no probe should be polling.
        #expect(!waiting.isAttemptingConnection)
    }

    @Test("A live session is neither attempting nor reconnectable")
    func runningPhaseSemantics() {
        #expect(!TerminalTabItem.Phase.running.isAttemptingConnection)
        #expect(!TerminalTabItem.Phase.running.isReconnectable)
    }

    /// lftp keeps its prompt through a dropped or idled-out connection and
    /// reopens one on the next command. The session is genuinely alive, so
    /// losing the transport must not end it — only the indicator changes.
    @Test("Losing the transport is noted, not acted on")
    func transportLossIsOnlyNoted() async {
        let tab = TerminalTabItem(
            profile: ConnectionProfile(name: "files", hostname: "prod.example.com"),
            kind: .sftp,
            launchSession: {},
            sleepFor: { _ in }
        )
        tab.connect()
        tab.markRemoteShellReached()
        await tab.awaitConnectedHold()

        tab.noteTransport(present: false)
        #expect(tab.phase == .running)
        #expect(!tab.transportIsLive)

        tab.noteTransport(present: true)
        #expect(tab.transportIsLive)

        // A session that ends leaves nothing for the flag to describe.
        tab.noteTransport(present: false)
        tab.disconnect()
        #expect(tab.transportIsLive)
    }

    @Test("Closing during a backoff wait needs no confirmation — nothing is live")
    func waitingTabClosesWithoutPrompt() {
        #expect(
            !TerminalTabManager.shouldConfirmClose(
                phase: .waitingToRetry(attempt: 2),
                confirmActiveSessions: true
            )
        )
    }

    @Test("Closing during an in-flight attempt confirms, like the first attempt")
    func attemptingTabConfirmsClose() {
        for phase: TerminalTabItem.Phase in [.starting, .reconnecting(attempt: 2), .running] {
            #expect(TerminalTabManager.shouldConfirmClose(phase: phase, confirmActiveSessions: true))
        }
    }

    /// A spawn is asked for and acknowledged separately, and the user can act
    /// in between. A session that comes back for an attempt that no longer
    /// exists must not be adopted by whatever replaced it.
    @Test("A session is adopted only by the attempt that asked for it")
    func adoptsOnlyItsOwnSession() {
        // The attempt that asked is still the current one.
        #expect(
            TerminalTabItem.adoptsSession(
                spawnGeneration: 4,
                attemptGeneration: 4,
                userDisconnected: false
            )
        )
        // Reconnected while the request was in flight.
        #expect(
            !TerminalTabItem.adoptsSession(
                spawnGeneration: 4,
                attemptGeneration: 5,
                userDisconnected: false
            )
        )
        // Disconnected while the request was in flight — there was no pid to
        // signal at the time, so the session arrives already unwanted.
        #expect(
            !TerminalTabItem.adoptsSession(
                spawnGeneration: 4,
                attemptGeneration: 4,
                userDisconnected: true
            )
        )
        // Nothing was asked for, so nothing is ours to adopt.
        #expect(
            !TerminalTabItem.adoptsSession(
                spawnGeneration: nil,
                attemptGeneration: 4,
                userDisconnected: false
            )
        )
    }

    /// lftp ignores SIGHUP by design — it backgrounds itself to finish
    /// transfers — so a disconnect that only hangs up leaves a live session
    /// behind a "press Space to reconnect" pill.
    @Test("Disconnect escalates from a polite hangup to a kill")
    func disconnectEscalates() {
        #expect(TerminalTabItem.hangupSignal == SIGHUP)
        #expect(TerminalTabItem.escalationSignals.contains(SIGTERM))
        // SIGKILL cannot be caught, so the sequence always terminates.
        #expect(TerminalTabItem.escalationSignals.last == SIGKILL)
        #expect(TerminalTabItem.disconnectEscalationDelay > 0)
    }

    // MARK: Session-end decisions

    /// The one place that decides what a dropped session does to the cycle.
    private func outcome(
        phase: TerminalTabItem.Phase = .running,
        reachedRemoteShell: Bool = true,
        sessionDuration: TimeInterval? = 600,
        userDisconnected: Bool = false,
        retryAttempt: Int = 0
    ) -> TerminalTabItem.SessionEndOutcome {
        TerminalTabItem.sessionEndOutcome(
            phase: phase,
            reachedRemoteShell: reachedRemoteShell,
            sessionDuration: sessionDuration,
            userDisconnected: userDisconnected,
            retryAttempt: retryAttempt
        )
    }

    @Test("A working session that drops starts the cycle at attempt 1")
    func realSessionStartsCycle() {
        #expect(outcome() == .retry(attempt: 1))
    }

    @Test("A failed attempt inside a cycle advances it")
    func failedAttemptAdvancesCycle() {
        #expect(
            outcome(
                phase: .reconnecting(attempt: 4),
                reachedRemoteShell: false,
                sessionDuration: nil,
                retryAttempt: 4
            ) == .retry(attempt: 5)
        )
    }

    /// Recovering on attempt 19 must not leave the next outage with one attempt
    /// of budget and a capped backoff.
    @Test("Recovery resets the budget, however long it took to get back")
    func recoveryResetsBudget() {
        #expect(
            outcome(retryAttempt: TerminalTabItem.maximumRetryAttempts - 1)
                == .retry(attempt: 1)
        )
    }

    /// A password prompt can sit unanswered for longer than a "working
    /// session" and still be refused. If that reset the budget, a wrong
    /// credential would retry forever and never reach the ceiling.
    @Test("Time alone does not reset the budget mid-cycle")
    func durationDoesNotResetBudget() {
        #expect(
            outcome(
                phase: .reconnecting(attempt: 4),
                reachedRemoteShell: false,
                sessionDuration: TerminalTabItem.minimumWorkingSession + 10,
                retryAttempt: 4
            ) == .retry(attempt: 5)
        )
    }

    @Test("The cycle stops at the ceiling")
    func cycleStopsAtCeiling() {
        #expect(
            outcome(
                phase: .reconnecting(attempt: TerminalTabItem.maximumRetryAttempts),
                reachedRemoteShell: false,
                sessionDuration: nil,
                retryAttempt: TerminalTabItem.maximumRetryAttempts
            ) == .stop
        )
    }

    /// libghostty re-fires a close request on every key pressed into a dead
    /// surface. Typing during a backoff must not spend the budget or restart
    /// the delay.
    @Test("Ending an already-ended session is ignored")
    func repeatEndIsIgnored() {
        for phase: TerminalTabItem.Phase in [
            .disconnected, .waitingToRetry(attempt: 2), .failed("boom"),
        ] {
            #expect(outcome(phase: phase, retryAttempt: 2) == .ignore)
        }
    }

    @Test("A tab that never started stays down rather than being ignored")
    func idleTabEndsDisconnected() {
        #expect(
            outcome(phase: .idle, reachedRemoteShell: false, sessionDuration: nil) == .stop
        )
    }

    @Test("A deliberate disconnect stops the cycle rather than advancing it")
    func userDisconnectStops() {
        #expect(outcome(userDisconnected: true, retryAttempt: 3) == .stop)
    }

    @Test("An attempt that never connected, with no cycle running, stays down")
    func unprovenAttemptStays() {
        #expect(
            outcome(phase: .starting, reachedRemoteShell: false, sessionDuration: nil) == .stop
        )
    }

    @Test("Backoff is capped, and the ceiling is a real limit")
    func retryCycleIsBounded() {
        #expect(TerminalTabItem.maximumRetryAttempts > 0)
        #expect(
            TerminalTabItem.retryDelay(attempt: TerminalTabItem.maximumRetryAttempts)
                == TerminalTabItem.maximumRetryDelay
        )
    }
}


/// The waiting pill counts down to the next attempt, so the text has to stay
/// sensible at both ends: no negative seconds as the attempt fires, and no
/// silent zero while the user is still reading it.
@MainActor
@Suite("Retry countdown text")
struct RetryCountdownTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("Seconds remaining are rounded up, so the last second still shows")
    func roundsUp() {
        #expect(
            ContentView.countdown(to: now.addingTimeInterval(4.2), now: now)
                == "next try in 5s · Esc to stop"
        )
        #expect(
            ContentView.countdown(to: now.addingTimeInterval(0.3), now: now)
                == "next try in 1s · Esc to stop"
        )
    }

    @Test("The attempt number rides along with the countdown")
    func countdownCarriesDetail() {
        #expect(
            ContentView.countdown(to: now.addingTimeInterval(4), now: now, detail: "attempt 3")
                == "attempt 3 · next try in 4s · Esc to stop"
        )
    }

    @Test("A deadline that has passed reads as imminent, never negative")
    func clampsAtZero() {
        #expect(ContentView.countdown(to: now, now: now) == "next try now · Esc to stop")
        #expect(
            ContentView.countdown(to: now.addingTimeInterval(-5), now: now)
                == "next try now · Esc to stop"
        )
    }
}
