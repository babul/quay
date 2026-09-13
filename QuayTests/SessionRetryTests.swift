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

    // MARK: Typing the session into the host shell

    /// Regression: this gate used to match the host shell by name, which never
    /// fired — `proc_name` reports the real executable, and `/bin/sh` on macOS
    /// *is* bash, so the shell shows up as "bash". The tab sat with an idle
    /// shell, a blank screen and no way to type into it.
    @Test("The host shell is ready whatever it is called")
    func readyWhateverTheShellIsCalled() {
        for name in ["bash", "sh", "zsh", "fish"] {
            #expect(
                TerminalTabItem.isReadyForCommand(
                    .init(names: [name], state: .noClient),
                    echoDisabled: true,
                    shellIsForeground: true
                ),
                "a host shell named \(name) should be typed into"
            )
        }
    }

    @Test("Nothing in the foreground group yet means not ready")
    func notReadyWhileGroupIsEmpty() {
        #expect(
            !TerminalTabItem.isReadyForCommand(
                .init(names: [], state: .noClient),
                echoDisabled: true,
                shellIsForeground: true
            )
        )
    }

    /// Regression: typing while the login shell is still sourcing the user's
    /// profile means the line discipline echoes the whole ssh invocation onto
    /// the screen, because `stty -echo` hasn't run yet.
    @Test("A shell that still echoes has not finished starting")
    func notReadyWhileTerminalStillEchoes() {
        #expect(
            !TerminalTabItem.isReadyForCommand(
                .init(names: ["bash"], state: .noClient),
                echoDisabled: false,
                shellIsForeground: true
            )
        )
        #expect(poll(.init(names: ["bash"], state: .noClient), pending: true, echoDisabled: false)
            == .wait)
    }

    @Test("A shell that never quiets is typed into anyway rather than hanging")
    func typesAnywayAfterGrace() {
        #expect(
            poll(
                .init(names: ["bash"], state: .noClient),
                pending: true,
                echoDisabled: false,
                sinceAttemptStart: TerminalTabItem.hostShellQuietGrace + 0.5
            ) == .typeCommand
        )
    }

    @Test("A running client is not something to type a command into")
    func notReadyWhileClientRuns() {
        #expect(
            !TerminalTabItem.isReadyForCommand(
                .init(names: ["ssh"], state: .connecting),
                echoDisabled: true,
                shellIsForeground: true
            )
        )
        #expect(
            !TerminalTabItem.isReadyForCommand(
                .init(names: ["ssh"], state: .connected),
                echoDisabled: true,
                shellIsForeground: true
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

    /// The grace exists so a slow host shell still gets its command typed. If
    /// the attempt could fail first, a shell slower than that bound would fail
    /// every attempt instead of connecting with an echoed line.
    @Test("The shell may take longer to quiet than the grace, and still connect")
    func shellBoundsAreOrdered() {
        #expect(TerminalTabItem.hostShellStartTimeout > TerminalTabItem.hostShellQuietGrace)
        #expect(
            poll(
                .init(names: ["bash"], state: .noClient),
                pending: true,
                echoDisabled: false,
                sinceAttemptStart: TerminalTabItem.hostShellQuietGrace + 0.5
            ) == .typeCommand
        )
        #expect(
            poll(
                .init(names: ["bash"], state: .noClient),
                pending: true,
                echoDisabled: false,
                sinceAttemptStart: TerminalTabItem.hostShellStartTimeout + 0.5
            ) == .typeCommand
        )
    }

    // MARK: What each poll of the foreground group means

    private func poll(
        _ snapshot: SessionConnectionProbe.Foreground,
        pending: Bool = false,
        echoDisabled: Bool = true,
        shellIsForeground: Bool = true,
        noClientStreak: Int = TerminalTabItem.sessionEndConfirmations,
        sinceAttemptStart: TimeInterval = 0,
        sinceCommand: TimeInterval? = nil,
        phase: TerminalTabItem.Phase = .running
    ) -> TerminalTabItem.PollOutcome {
        TerminalTabItem.pollOutcome(
            snapshot: snapshot,
            hasPendingCommand: pending,
            echoDisabled: echoDisabled,
            shellIsForeground: shellIsForeground,
            noClientStreak: noClientStreak,
            secondsSinceAttemptStart: sinceAttemptStart,
            secondsSinceCommand: sinceCommand,
            phase: phase
        )
    }

    /// Disconnect, then Space before the old client has finished dying: the
    /// client still in the terminal is the previous session, and marking the
    /// tab connected to it would also replay the login script into a session
    /// being torn down.
    @Test("A client still running before this attempt has typed is not adopted")
    func doesNotAdoptTheDyingClient() {
        #expect(poll(.init(names: ["ssh"], state: .connected), pending: true) == .wait)
        #expect(poll(.init(names: ["ssh"], state: .connecting), pending: true) == .wait)
        // Once the command is out, the client that appears is this attempt's.
        #expect(poll(.init(names: ["ssh"], state: .connected), pending: false) == .connected)
    }

    @Test("A waiting command is typed as soon as the host shell owns the pty")
    func typesWhenShellIsReady() {
        #expect(poll(.init(names: ["bash"], state: .noClient), pending: true) == .typeCommand)
        // Nothing has the pty yet — the wrapper chain is still exec'ing.
        #expect(poll(.init(names: [], state: .noClient), pending: true) == .wait)
    }

    @Test("A client that is up but not yet through is still connecting")
    func reportsConnecting() {
        #expect(poll(.init(names: ["ssh"], state: .connecting), phase: .starting) == .connecting)
        #expect(poll(.init(names: ["ssh"], state: .connected), phase: .starting) == .connected)
    }

    /// Regression: the session watch used to be cancelled the moment a session
    /// connected, so nothing ever noticed it ending. The tab stayed "running"
    /// with no retry, and Space was forwarded to a dead terminal instead of
    /// reconnecting.
    @Test("A live session whose client disappears has ended")
    func detectsSessionEnd() {
        #expect(poll(.init(names: ["bash"], state: .noClient), phase: .running) == .sessionEnded)
        #expect(
            poll(.init(names: ["bash"], state: .noClient), phase: .reconnecting(attempt: 2))
                == .sessionEnded
        )
    }

    /// Between the items of the host shell's command list the foreground group
    /// belongs to `stty` or `printf`. Calling that a disconnect puts a live
    /// session behind a "press Space to reconnect" pill.
    @Test("One poll without the client is not a session ending")
    func singleMissIsNotAnEnding() {
        #expect(
            poll(.init(names: ["stty"], state: .noClient), noClientStreak: 1, phase: .running)
                == .wait
        )
        #expect(
            poll(.init(names: ["bash"], state: .noClient), noClientStreak: 2, phase: .running)
                == .sessionEnded
        )
    }

    /// A local program can end up owning the tab's terminal — a login script's
    /// keystrokes landing in the host shell as the session dies will start one.
    /// Typing the next command into *that* feeds it keystrokes, so every
    /// attempt times out against it and the tab never reconnects.
    @Test("A foreign process on the terminal is waited out, not typed into")
    func foreignProcessIsNotTypedInto() {
        #expect(
            poll(
                .init(names: ["htop"], state: .noClient),
                pending: true,
                shellIsForeground: false
            ) == .wait
        )
        // Even long past the point where a missing shell would fail the attempt:
        // failing repeatedly against a program that will never answer is worse
        // than waiting for the prompt to come back.
        #expect(
            poll(
                .init(names: ["htop"], state: .noClient),
                pending: true,
                shellIsForeground: false,
                sinceAttemptStart: TerminalTabItem.clientStartTimeout + 30
            ) == .wait
        )
        // The same snapshot, with the shell back at its prompt, is typed into.
        #expect(
            poll(.init(names: ["bash"], state: .noClient), pending: true) == .typeCommand
        )
    }

    @Test("A command just typed is given time for its client to appear")
    func waitsForClientToStart() {
        #expect(poll(.init(names: ["bash"], state: .noClient), sinceCommand: 0.5) == .wait)
        #expect(
            poll(
                .init(names: ["bash"], state: .noClient),
                sinceCommand: TerminalTabItem.clientStartTimeout + 1
            ) == .sessionEnded
        )
    }

    /// An empty foreground group means the probe saw nothing — a surface still
    /// starting, or a failed enumeration. Reading that as "the client exited"
    /// would end a perfectly live session.
    @Test("An unreadable foreground group is not a session ending")
    func emptySnapshotIsNotAnEnding() {
        #expect(poll(.init(names: [], state: .noClient), phase: .running) == .wait)
        #expect(
            poll(.init(names: [], state: .noClient), phase: .reconnecting(attempt: 2)) == .wait
        )
    }

    @Test("Waiting for a host shell that never appears fails the attempt")
    func pendingCommandIsBounded() {
        #expect(poll(.init(names: [], state: .noClient), pending: true, sinceAttemptStart: 1) == .wait)
        #expect(
            poll(
                .init(names: [], state: .noClient),
                pending: true,
                sinceAttemptStart: TerminalTabItem.hostShellStartTimeout + 1
            ) == .sessionEnded
        )
    }

    @Test("With no session expected there is nothing to watch")
    func stopsWatchingWhenIdle() {
        #expect(poll(.init(names: ["bash"], state: .noClient), phase: .disconnected) == .stopWatching)
        #expect(
            poll(.init(names: ["bash"], state: .noClient), phase: .waitingToRetry(attempt: 1))
                == .stopWatching
        )
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
