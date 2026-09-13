import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
final class LoginScriptRunner {
    private let steps: [LoginScriptStep]
    private let resolver: ReferenceResolver
    private let readVisibleText: () -> String
    private let sendText: (String) -> Void
    private let pollInterval: TimeInterval
    private let stepTimeout: TimeInterval

    private var task: Task<Void, Never>?

    init(
        steps: [LoginScriptStep],
        resolver: ReferenceResolver = ReferenceResolver(),
        pollInterval: TimeInterval = 0.25,
        stepTimeout: TimeInterval = 30,
        readVisibleText: @escaping () -> String,
        sendText: @escaping (String) -> Void
    ) {
        self.steps = steps.normalizedLoginScriptSteps
        self.resolver = resolver
        self.pollInterval = pollInterval
        self.stepTimeout = stepTimeout
        self.readVisibleText = readVisibleText
        self.sendText = sendText
    }

    func start() {
        stop()
        guard !steps.isEmpty else { return }
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func run() async {
        // Resolve any Keychain-backed steps before entering the match loop so
        // Touch ID (if required) appears as a single burst at connect time.
        var resolvedSends: [UUID: String] = [:]
        for step in steps where step.sendRef != nil {
            guard let uri = step.sendRef else { continue }
            do {
                let bytes = try await resolver.resolve(uri)
                resolvedSends[step.id] = bytes.unsafeUTF8String() ?? ""
            } catch {
                return  // Touch ID cancelled or item missing — abort the script
            }
        }

        for step in steps {
            let send = resolvedSends[step.id] ?? step.send
            let deadline = Date().addingTimeInterval(stepTimeout)
            while !Task.isCancelled {
                if readVisibleText().contains(step.match) {
                    sendText(Self.terminalText(for: send))
                    break
                }

                guard Date() < deadline else { return }
                let nanoseconds = UInt64(max(0.001, pollInterval) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
        }
    }

    static func terminalText(for text: String) -> String {
        if text.hasSuffix("\r") || text.hasSuffix("\n") {
            return String(text.dropLast())
        }
        return text
    }
}

/// A single SSH tab.
///
/// The pty runs a host shell for the tab's whole life and sessions are *typed
/// into it*, so the surface — and the screen it holds — survive a reconnect.
/// A new surface is built only when that host shell dies. See
/// `SessionBootstrap.hostShellCommand()`.
///
/// - The `AskpassServer` lives for the duration of the tab (not just one surface
///   lifetime) so re-auth on reconnect still works.
/// - `phase` is the per-tab session lifecycle; the view observes it to decide
///   what to show.
@Observable
@MainActor
final class TerminalTabItem: Identifiable {
    let id: UUID
    let profile: ConnectionProfile
    let kind: TerminalSessionKind
    let localDirectoryOverride: String?

    enum Phase: Equatable {
        case idle
        /// First attempt for this tab, started by the user.
        case starting
        case running
        case disconnected
        /// An automatic attempt is in flight — a live child process, exactly
        /// like `.starting` but numbered.
        case reconnecting(attempt: Int)
        /// Waiting out the backoff before the next automatic attempt. No child
        /// process is alive, so the keyboard belongs to the app here.
        case waitingToRetry(attempt: Int)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var displayedTitle: String
    private(set) var displayedUsername: String?
    private var reachedRemoteShell = false

    /// The tab's surface. `nil` before the first connect, and after the host
    /// shell dies or the tab closes.
    private(set) var surfaceView: GhosttySurfaceView?

    /// `AskpassServer` owned for the tab's lifetime, stopped only on tab close.
    private var askpassServer: AskpassServer?
    private var loginScriptRunner: LoginScriptRunner?
    /// Watches the pty's foreground process group for the tab's whole life:
    /// it types the session in, sees it connect, and sees it end. libghostty
    /// has no callback for any of that once a host shell owns the pty.
    private var sessionWatch: Task<Void, Never>?
    /// Holds the indicator on screen long enough to be read — purely cosmetic,
    /// kept apart from `connectWatch` so cancelling one never means the other.
    private var connectedHoldTask: Task<Void, Never>?
    private var connectStartedAt: Date
    /// When the current session's connection came up, or `nil` if it never did.
    private var connectedAt: Date?
    /// Executable names that count as this session's client.
    private var clientNames: Set<String> = ["ssh"]
    /// When the attempt's command was typed, to bound the wait for its client
    /// to appear.
    private var commandSentAt: Date?
    /// Whether this attempt's login script has been started yet.
    private var didStartLoginScript = false
    /// The screen as it was when this attempt's command was typed. Everything
    /// in it belongs to the previous session, so the login script matches only
    /// against what this one adds.
    private var loginScriptBaseline = ""
    /// The attempt's command line, waiting for the host shell to be ready for
    /// it. Typing before the shell takes over the pty makes it echo twice.
    private var pendingCommandLine: String?

    /// The host shell is ready for a command once something owns the pty's
    /// foreground group and it isn't the session client.
    ///
    /// Deliberately not matched by name: `proc_name` reports the real
    /// executable, and `/bin/sh` on macOS *is* bash, so the host shell shows up
    /// as "bash". What matters is only that the client isn't running yet.
    static func isReadyForCommand(
        _ snapshot: SessionConnectionProbe.Foreground,
        echoDisabled: Bool
    ) -> Bool {
        snapshot.state == .noClient && !snapshot.names.isEmpty && echoDisabled
    }

    /// How long to wait for the host shell to quiet the terminal before typing
    /// anyway. If `stty` never ran, an echoed command line is a blemish; never
    /// typing at all would be a dead tab.
    static let hostShellQuietGrace: TimeInterval = 2
    /// Sleeps out the backoff between automatic attempts.
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0
    /// When the pending automatic attempt fires, so the indicator can count
    /// down to it without the model ticking once a second.
    private(set) var nextRetryAt: Date?
    /// Set when the user disconnects on purpose, so the tab stays down.
    private var userDisconnected = false
    /// Called when the child process exits. Set by external observers (e.g.,
    /// `TerminalClient`) to receive cross-feature child-exit events.
    var onChildExited: (() -> Void)?

    /// Starts one attempt. Spawning ssh is the production behaviour; tests
    /// substitute a launcher so the retry cycle can be driven without a host.
    private let launchSession: (@MainActor () -> Void)?
    /// Waits out a delay. Tests substitute an instant one.
    private let sleepFor: (@MainActor (TimeInterval) async -> Void)?
    /// Reads the wall clock, so tests can age a session without waiting.
    private let now: @MainActor () -> Date

    init(
        profile: ConnectionProfile,
        kind: TerminalSessionKind = .ssh,
        localDirectoryOverride: String? = nil,
        launchSession: (@MainActor () -> Void)? = nil,
        sleepFor: (@MainActor (TimeInterval) async -> Void)? = nil,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.id = UUID()
        self.profile = profile
        self.kind = kind
        self.localDirectoryOverride = localDirectoryOverride
        self.displayedTitle = kind == .sftp ? "\(profile.name) SFTP" : profile.name
        self.displayedUsername = profile.username
        self.launchSession = launchSession
        self.sleepFor = sleepFor
        self.now = now
        self.connectStartedAt = now()
    }

    private func sleep(_ seconds: TimeInterval) async {
        if let sleepFor {
            await sleepFor(seconds)
        } else {
            try? await Task.sleep(for: .seconds(seconds))
        }
    }

    /// Awaits a pending backoff (and the attempt it launches), so tests need no
    /// timing guesses.
    func awaitPendingRetry() async {
        await retryTask?.value
    }

    /// Awaits the cosmetic hold before a connected session reads as running.
    func awaitConnectedHold() async {
        await connectedHoldTask?.value
    }

    // MARK: Lifecycle

    /// Connect at the user's request: cancels any retry cycle and starts over.
    func connect() {
        stopRetrying()
        retryAttempt = 0
        userDisconnected = false
        attemptConnect()
    }

    private func attemptConnect() {
        // Stop the previous attempt's tasks but keep the surface: reusing it is
        // what lets the new session continue on the screen already there.
        stopSessionTasks()
        reachedRemoteShell = false
        didStartLoginScript = false
        connectStartedAt = now()
        connectedAt = nil
        nextRetryAt = nil
        phase = retryAttempt > 0 ? .reconnecting(attempt: retryAttempt) : .starting

        if let launchSession { launchSession() } else { startSSHSession() }
    }

    private func startSSHSession() {
        do {
            let session = try SessionBootstrap.start(
                for: profile,
                kind: kind,
                localDirectoryOverride: localDirectoryOverride
            )
            if askpassServer == nil {
                askpassServer = session.askpass
            } else if let askpass = session.askpass {
                // Reconnecting: old server is still live; replace with fresh one.
                askpassServer?.stop()
                askpassServer = askpass
            }
            clientNames = session.clientNames

            // Typed by the watch once the host shell is ready for it — the
            // same path whether the shell is new or left over from the last
            // session, which is what keeps the screen.
            let marker = SessionBootstrap.sessionMarker(
                target: session.displayTarget,
                attempt: retryAttempt,
                // A manual reconnect resets the count, so this only ever
                // reports a backoff that was actually waited out.
                backoff: retryAttempt > 0 ? Self.retryDelay(attempt: retryAttempt) : 0,
                at: now()
            )
            pendingCommandLine = SessionBootstrap.announced(session.commandLine, marker: marker)
            if surfaceView?.hasLiveHostShell != true {
                surfaceView = makeSurfaceView(config: session.config)
            }
            startSessionWatch()
        } catch {
            phase = .failed("\(error)")
        }
    }

    private func makeSurfaceView(config: GhosttySurfaceConfig) -> GhosttySurfaceView {
        let view = GhosttySurfaceView(runtime: .shared, config: config)
        view.sessionOwnsTerminal = { [weak self, weak view] in
            guard let self, let view else { return false }
            // Asked at write time rather than read from the poll: a session that
            // exited since the last poll would otherwise leave input reaching
            // the host shell for the rest of the interval.
            return view.hasRunningClient(clientNames: self.clientNames)
        }
        view.onDeadSessionKey = { [weak self] key in
            guard let self else { return false }
            switch key {
            case .reconnect:
                guard self.phase.isReconnectable else { return false }
                self.reconnect()
                return true
            case .cancel:
                // Only meaningful while a retry is pending; otherwise Escape is
                // the terminal's. Stopping is deliberate, so the cycle does not
                // restart on its own.
                guard case .waitingToRetry = self.phase else { return false }
                self.userDisconnected = true
                self.stopRetrying()
                return true
            }
        }
        view.onBridgeCreated = { [weak self] bridge in
            guard let self else { return }
            bridge.onCloseRequest = { [weak self] in
                self?.hostShellEnded()
            }
            bridge.onTitleChange = { [weak self] title in
                guard let self else { return }
                self.updateFromTerminalTitle(title)
                if !title.isEmpty { self.markRemoteShellReached() }
            }
            bridge.onChildExited = { [weak self] _ in
                // The host shell itself died — the surface is spent.
                self?.hostShellEnded()
                self?.onChildExited?()
            }
        }
        return view
    }

    /// Started only once the session's client owns the terminal.
    ///
    /// Starting it earlier is unsafe on two counts: the screen still holds the
    /// *previous* session's text, so a retained prompt matches immediately; and
    /// the pty still belongs to the host shell, so the step's value — which may
    /// be a resolved secret — would be typed into a local shell.
    private func startLoginScriptOnce() {
        guard !didStartLoginScript else { return }
        didStartLoginScript = true
        guard !profile.loginScriptSteps.isEmpty,
              let view = surfaceView,
              let bridge = view.bridge
        else { return }

        let baseline = loginScriptBaseline
        let runner = LoginScriptRunner(
            steps: profile.loginScriptSteps,
            readVisibleText: { [weak bridge] in
                let current = bridge?.visibleText() ?? ""
                guard current.hasPrefix(baseline) else { return current }
                return String(current.dropFirst(baseline.count))
            },
            // Same gate as user input: if the session went away mid-script,
            // these bytes — possibly a resolved secret — would run locally.
            sendText: { [weak view] text in
                view?.sendUserInput(text, appendReturn: true)
            }
        )
        loginScriptRunner = runner
        runner.start()
    }

    /// The pty's own child is gone, so the screen can't be reused: the next
    /// attempt builds a fresh surface.
    private func hostShellEnded() {
        pendingCommandLine = nil
        surfaceView = nil
        markSessionEnded()
    }

    func reconnect() {
        connect()
    }

    /// How long to wait for a typed command to show up as a running client
    /// before calling the attempt failed.
    static let clientStartTimeout: TimeInterval = 5

    /// Watches the pty's foreground process group for this tab's whole life.
    ///
    /// With the session running inside a long-lived host shell, the pty's child
    /// no longer exits when a session ends — so the client appearing and
    /// disappearing in that group *is* the session lifecycle, and it is also
    /// what decides whether keystrokes may reach the terminal.
    /// Polled while a session is being established, where latency is visible:
    /// the command is typed on the first poll that finds the shell ready.
    static let attemptingPollInterval: Duration = .milliseconds(150)
    /// Polled once connected, where the only event left is the session ending —
    /// a second of latency there is imperceptible, and a tab can sit connected
    /// for hours.
    static let connectedPollInterval: Duration = .milliseconds(1500)

    private func startSessionWatch() {
        sessionWatch?.cancel()
        commandSentAt = nil
        sessionWatch = Task { [weak self] in
            while !Task.isCancelled {
                // Poll first: sleeping first adds latency to the very thing the
                // short interval is for.
                guard let self, self.pollSession() else { return }
                let interval = self.phase == .running
                    ? Self.connectedPollInterval
                    : Self.attemptingPollInterval
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// What one look at the foreground process group means.
    enum PollOutcome: Equatable {
        /// Nothing to do yet — the host shell hasn't taken the pty, or the
        /// command's client hasn't appeared.
        case wait
        /// The host shell is ready; type the session into it.
        case typeCommand
        /// The client is up but its connection isn't established.
        case connecting
        case connected
        /// The client is gone and a session was expected — it ended.
        case sessionEnded
        /// No session is expected; stop watching until the user asks for one.
        case stopWatching
    }

    static func pollOutcome(
        snapshot: SessionConnectionProbe.Foreground,
        hasPendingCommand: Bool,
        echoDisabled: Bool,
        secondsSinceAttemptStart: TimeInterval,
        secondsSinceCommand: TimeInterval?,
        phase: Phase
    ) -> PollOutcome {
        switch snapshot.state {
        case .connected:
            return .connected
        case .connecting:
            return .connecting
        case .noClient:
            // An empty group is "we can't see anything" — a surface that hasn't
            // started, or a probe that failed — not "the client is gone". It
            // must never be read as a session ending.
            let sawProcesses = !snapshot.names.isEmpty

            if hasPendingCommand {
                // Ready, or past the grace — a shell whose `stty` never ran
                // still gets its command, just with an echoed line.
                if sawProcesses,
                   echoDisabled || secondsSinceAttemptStart >= hostShellQuietGrace {
                    return .typeCommand
                }
                // Bounded, so a shell that never appears fails the attempt
                // instead of hanging the tab in "Connecting…" forever.
                return secondsSinceAttemptStart >= clientStartTimeout ? .sessionEnded : .wait
            }

            // The command was typed but its client hasn't shown up yet.
            if let secondsSinceCommand, secondsSinceCommand < clientStartTimeout {
                return .wait
            }
            guard sawProcesses else { return .wait }
            return phase.hasLiveSession ? .sessionEnded : .stopWatching
        }
    }

    /// One poll. Returns `false` when the watch has nothing left to do.
    private func pollSession() -> Bool {
        guard let view = surfaceView else { return false }

        let snapshot = view.foregroundSnapshot(clientNames: clientNames)
        let outcome = Self.pollOutcome(
            snapshot: snapshot,
            hasPendingCommand: pendingCommandLine != nil,
            // Only consulted while a command is pending; cheap enough to read
            // unconditionally rather than thread laziness through.
            echoDisabled: pendingCommandLine == nil || view.hostShellHasQuietedTerminal,
            secondsSinceAttemptStart: now().timeIntervalSince(connectStartedAt),
            secondsSinceCommand: commandSentAt.map { now().timeIntervalSince($0) },
            phase: phase
        )

        switch outcome {
        case .wait:
            return true

        case .typeCommand:
            let command = pendingCommandLine
            pendingCommandLine = nil
            commandSentAt = now()
            // Captured before the command is sent: a prompt printed before the
            // next poll would otherwise land in the baseline and never match.
            loginScriptBaseline = view.bridge?.visibleText() ?? ""
            // No control-character prefix to clear the line editor: ghostty's
            // paste path replaces VKILL and friends with spaces
            // (vendor/ghostty/src/input/paste.zig), so it would only insert one.
            if let command { view.bridge?.sendText(command + "\n") }
            return true

        case .connecting, .connected:
            commandSentAt = nil
            startLoginScriptOnce()
            // A client still alive past the connect timeout counts as connected
            // even without a socket of its own — see `assumeConnectedAfter`.
            let pastTimeout = now().timeIntervalSince(connectStartedAt) >= Self.assumeConnectedAfter
            if phase.isAttemptingConnection, outcome == .connected || pastTimeout {
                markConnected()
            }
            return true

        case .sessionEnded:
            commandSentAt = nil
            markSessionEnded()
            return false

        case .stopWatching:
            return false
        }
    }

    /// ssh abandons an unanswered SYN at `ConnectTimeout`, so a client still
    /// alive past that bound is connected by some route the probe cannot see —
    /// a session multiplexed over an existing `ControlMaster` owns no TCP
    /// socket of its own. Assume connected rather than spin forever.
    /// Tracks the *default* connect timeout. A profile that overrides
    /// `ConnectTimeout` via `extraOptions` connects on its own schedule, and
    /// this bound stops matching it — the cost is only that a multiplexed
    /// session is assumed connected early, so it is not worth plumbing
    /// through.
    static let assumeConnectedAfter =
        TimeInterval(SSHCommandBuilder.connectTimeoutSeconds) + 3

    /// A local host answers in well under the time it takes to read a status
    /// pill, so the indicator is held briefly rather than flashed for a frame
    /// or two. `.starting` is treated as an active session everywhere else, so
    /// holding it costs nothing.
    static let minimumConnectingDisplay: TimeInterval = 0.6

    /// The remote shell announced itself by setting a title — the only signal
    /// that proves the session got past authentication, which is what earns a
    /// fresh retry budget.
    func markRemoteShellReached() {
        guard !reachedRemoteShell else { return }
        reachedRemoteShell = true
        markConnected()
        NotificationCenter.default.post(name: .connectionConnected, object: id)
    }

    func markConnected() {
        // Note the session watch keeps running: it is what later notices the
        // session ending. Only the cosmetic hold is replaced here — the probe
        // and a remote title can both land, and the loser must not leave a
        // sleeping task behind that wakes onto a later attempt.
        connectedHoldTask?.cancel()
        connectedHoldTask = nil
        guard phase.isAttemptingConnection else { return }
        connectedAt = now()

        let remaining = Self.minimumConnectingDisplay
            - now().timeIntervalSince(connectStartedAt)
        guard remaining > 0 else {
            phase = .running
            return
        }
        connectedHoldTask = Task { [weak self] in
            await self?.sleep(remaining)
            guard !Task.isCancelled, let self, self.phase.isAttemptingConnection else { return }
            self.phase = .running
        }
    }

    // MARK: Automatic retry

    /// Backoff between automatic attempts: 2s, 4s, 8s, then every 15s. A host
    /// coming back from a reboot can take minutes, so attempts continue until
    /// the session is back or the user stops them.
    static let maximumRetryDelay: TimeInterval = 15

    static func retryDelay(attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        return min(maximumRetryDelay, 2 * pow(2, Double(attempt - 1)))
    }

    /// How long a session has to last to count as real. TCP establishes before
    /// authentication, so a rejected credential produces a connection that dies
    /// a second later — retrying that replays the rejection forever, and
    /// re-prompts Touch ID on every cycle.
    static let minimumWorkingSession: TimeInterval = 5

    /// Ceiling on one retry cycle. At the capped delay this is a few minutes of
    /// trying, after which the tab waits for the user rather than looping on
    /// unattended.
    static let maximumRetryAttempts = 20

    /// A dropped session starts a retry cycle when it looked like a working
    /// session — it reached the remote shell, or stayed up longer than a
    /// rejected handshake could — and the user didn't put it down on purpose.
    static func shouldAutoRetry(
        reachedRemoteShell: Bool,
        sessionDuration: TimeInterval?,
        userDisconnected: Bool
    ) -> Bool {
        guard !userDisconnected else { return false }
        if reachedRemoteShell { return true }
        guard let sessionDuration else { return false }
        return sessionDuration >= minimumWorkingSession
    }

    /// What ending a session should do to the retry cycle.
    enum SessionEndOutcome: Equatable {
        /// Nothing was running — ignore it.
        case ignore
        /// Stay down until the user acts.
        case stop
        /// Try again, as this numbered attempt.
        case retry(attempt: Int)
    }

    static func sessionEndOutcome(
        phase: Phase,
        reachedRemoteShell: Bool,
        sessionDuration: TimeInterval?,
        userDisconnected: Bool,
        retryAttempt: Int
    ) -> SessionEndOutcome {
        // libghostty re-fires a close request whenever a key is pressed into a
        // dead surface, so ending an already-ended session must not restart the
        // backoff or spend the budget.
        guard !phase.hasEndedSession else { return .ignore }
        guard !userDisconnected else { return .stop }

        // Reaching the remote shell is the only proof of an authenticated
        // session, and only that earns a fresh budget. Elapsed time doesn't
        // prove it: a password prompt can sit unanswered for longer than
        // `minimumWorkingSession` and still be refused, which would otherwise
        // reset the cycle on every failure and never reach the ceiling.
        if reachedRemoteShell { return .retry(attempt: 1) }

        // An attempt inside a running cycle failing again.
        if retryAttempt > 0 {
            return retryAttempt < maximumRetryAttempts ? .retry(attempt: retryAttempt + 1) : .stop
        }

        // No cycle yet: a session that stayed up long enough starts one.
        return shouldAutoRetry(
            reachedRemoteShell: false,
            sessionDuration: sessionDuration,
            userDisconnected: userDisconnected
        ) ? .retry(attempt: 1) : .stop
    }

    /// Stops the retry cycle, leaving the tab disconnected until the user acts.
    private func stopRetrying() {
        retryTask?.cancel()
        retryTask = nil
        nextRetryAt = nil
        if case .waitingToRetry = phase { phase = .disconnected }
    }

    private func scheduleRetry(attempt: Int) {
        retryTask?.cancel()
        retryAttempt = attempt
        let delay = Self.retryDelay(attempt: attempt)
        nextRetryAt = now().addingTimeInterval(delay)
        phase = .waitingToRetry(attempt: attempt)
        retryTask = Task { [weak self] in
            await self?.sleep(delay)
            guard !Task.isCancelled, let self else { return }
            guard case .waitingToRetry = self.phase else { return }
            self.attemptConnect()
        }
    }

    func disconnect() {
        userDisconnected = true
        stopRetrying()
        stopSessionTasks()
        surfaceView?.disconnectSessionClient(clientNames: clientNames)
        phase = .disconnected
    }

    func markSessionEnded() {
        let outcome = Self.sessionEndOutcome(
            phase: phase,
            reachedRemoteShell: reachedRemoteShell,
            sessionDuration: connectedAt.map { now().timeIntervalSince($0) },
            userDisconnected: userDisconnected,
            retryAttempt: retryAttempt
        )
        guard outcome != .ignore else { return }

        stopSessionTasks()
        connectedAt = nil

        if case .retry(let attempt) = outcome {
            scheduleRetry(attempt: attempt)
        } else {
            // `.ignore` returned above, so the session was live: this is always
            // a transition into `.disconnected`.
            stopRetrying()
            phase = .disconnected
        }
    }

    /// Stops everything tied to one attempt. Leaves the surface in place — a
    /// dead session keeps its last output on screen.
    private func stopSessionTasks() {
        sessionWatch?.cancel()
        sessionWatch = nil
        connectedHoldTask?.cancel()
        connectedHoldTask = nil
        loginScriptRunner?.stop()
        loginScriptRunner = nil
    }

    /// Called when the tab is permanently closed. Stops the askpass server.
    func close() {
        stopRetrying()
        stopSessionTasks()
        pendingCommandLine = nil
        surfaceView = nil
        askpassServer?.stop()
        askpassServer = nil
        phase = .idle
    }

    // MARK: Display

    var displayTitle: String {
        kind == .sftp ? "\(profile.name) SFTP" : profile.name
    }

    var terminalBackgroundColor: NSColor {
        surfaceView?.bridge?.state.backgroundColor
            ?? GhosttyResolvedAppearance.backgroundColor(from: GhosttyRuntime.shared.config)
    }

    var terminalBackgroundOpacity: Double {
        surfaceView?.bridge?.state.backgroundOpacity
            ?? GhosttyResolvedAppearance.backgroundOpacity(from: GhosttyRuntime.shared.config)
    }

    var currentWorkingDirectory: String? {
        surfaceView?.bridge?.state.pwd?.path
    }

    func updateFromTerminalTitle(_ terminalTitle: String) {
        guard !terminalTitle.isEmpty else {
            displayedUsername = profile.username
            return
        }

        let promptPrefix = terminalTitle.split(separator: ":", maxSplits: 1).first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let promptPrefix, !promptPrefix.isEmpty else { return }

        if let atIndex = promptPrefix.firstIndex(of: "@") {
            let username = String(promptPrefix[..<atIndex])
            displayedUsername = username.isEmpty ? profile.username : username
        }
    }
}

extension TerminalTabItem.Phase {
    /// A connection attempt is in flight — a live child process.
    var isAttemptingConnection: Bool {
        switch self {
        case .starting, .reconnecting: return true
        case .idle, .running, .disconnected, .waitingToRetry, .failed: return false
        }
    }

    /// A child process is alive: an attempt in flight, or a running session.
    var hasLiveSession: Bool {
        switch self {
        case .starting, .running, .reconnecting: return true
        case .idle, .disconnected, .waitingToRetry, .failed: return false
        }
    }

    /// The session is already over — any further "it ended" report is a repeat.
    /// `.idle` is neither this nor `hasLiveSession`: a tab that never started
    /// has no session to end, but reporting one is not a repeat either.
    var hasEndedSession: Bool {
        self != .idle && !hasLiveSession
    }

    /// Can the user ask for a connection right now? Which is the same question
    /// as whether the last session is over.
    var isReconnectable: Bool { hasEndedSession }
}
