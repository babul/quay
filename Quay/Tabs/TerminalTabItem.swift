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
/// The pty runs `quay-supervisor` for the tab's whole life and sessions are
/// spawned through it, so the surface — and the screen it holds — survive a
/// reconnect. A new surface is built only when that supervisor dies. See
/// `SessionBootstrap.supervisorConfig(socketPath:)`.
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

    /// The tab's surface. `nil` before the first connect, and after the
    /// supervisor dies or the tab closes.
    private(set) var surfaceView: GhosttySurfaceView?

    /// The surface's observable state, held here because `surfaceView.bridge`
    /// is a plain property: a view that reads through it before the bridge
    /// exists would never see the bridge arrive, and stays stale.
    private(set) var surfaceState: GhosttySurfaceState?

    /// `AskpassServer` owned for the tab's lifetime, stopped only on tab close.
    private var askpassServer: AskpassServer?
    /// The tab's end of its `quay-supervisor`, for the surface's lifetime.
    private var supervisor: SupervisorClient?
    private var supervisorIsReady = false
    /// The attempt waiting to be spawned — for the supervisor to come up, or
    /// for the previous session to finish leaving.
    private var pendingSpawn: SupervisorProtocol.Spawn?
    /// Which attempt each session belongs to.
    ///
    /// A spawn is asked for and acknowledged as two separate events, and the
    /// user can disconnect or reconnect in between. Without this, the `spawned`
    /// meant for an abandoned attempt is adopted by whatever replaced it — and
    /// a disconnect issued in that window signals nothing, because there is no
    /// pid yet to signal.
    private var attemptGeneration = 0
    /// The generation whose spawn has been sent but not yet acknowledged.
    private var spawnInFlight: Int?
    /// Fails an attempt whose supervisor never reports ready.
    private var spawnDeadlineTask: Task<Void, Never>?
    /// The session the supervisor reports running, whoever started it.
    private var livePID: pid_t?
    /// The session this attempt started. Differs from `livePID` only while a
    /// previous session is still on its way out.
    private var attemptPID: pid_t?
    private var loginScriptRunner: LoginScriptRunner?
    /// Polls the running client's TCP state: it is what turns an attempt into
    /// a connection, and what keeps `transportIsLive` honest.
    private var sessionWatch: Task<Void, Never>?
    /// Holds the indicator on screen long enough to be read — purely cosmetic,
    /// kept apart from the watch so cancelling one never means the other.
    private var connectedHoldTask: Task<Void, Never>?
    private var connectStartedAt: Date
    /// When the current session's connection came up, or `nil` if it never did.
    private var connectedAt: Date?
    /// See `SessionBootstrap.Session.connectedWhenClientRuns`.
    private var connectedWhenClientRuns = false
    /// Escalates a disconnect that the client ignored. See `hangUpClient`.
    private var disconnectTask: Task<Void, Never>?
    /// Whether the session's client currently holds a connection.
    ///
    /// Only ever *stays* false for a client that outlives its transport
    /// (lftp): it keeps its prompt when the connection drops or idles out, and
    /// reopens one on the next command, so the session is still `.running` —
    /// the indicator just stops claiming a transport that isn't there. Every
    /// other client exits with its transport, and the session ends with it.
    private(set) var transportIsLive = true
    /// Whether this attempt's login script has been started yet.
    private var didStartLoginScript = false
    /// The screen as it was when this attempt was spawned. Everything in it
    /// belongs to the previous session, so the login script matches only
    /// against what this one adds.
    private var loginScriptBaseline = ""

    /// How long to wait for the supervisor to report ready before failing the
    /// attempt. It is reached through libghostty's `login -flp` (PAM, utmp)
    /// and a login shell sourcing the user's profile, which together can take
    /// several seconds on a real machine.
    static let supervisorStartTimeout: TimeInterval = 20
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

    /// Starts one attempt. Spawning the session is the production behaviour;
    /// tests substitute a launcher so the retry cycle can be driven without a
    /// host.
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
        // A session still running belongs to the attempt before this one. Hang
        // it up; the supervisor spawns the new one once it has gone.
        hangUpClient()
        attemptPID = nil
        attemptGeneration += 1
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
            connectedWhenClientRuns = session.connectedWhenClientRuns

            var spawn = session.spawn
            spawn.announce = SessionBootstrap.announcement(
                SessionBootstrap.sessionMarker(
                    target: session.displayTarget,
                    attempt: retryAttempt,
                    // A manual reconnect resets the count, so this only ever
                    // reports a backoff that was actually waited out.
                    backoff: retryAttempt > 0 ? Self.retryDelay(attempt: retryAttempt) : 0,
                    at: now()
                )
            )
            pendingSpawn = spawn

            if surfaceView?.hasLiveSupervisor != true {
                try startSupervisor()
            }
            sendPendingSpawn()
        } catch {
            failAttempt("\(error)")
        }
    }

    /// A fresh supervisor and the surface that hosts it. The socket is listening
    /// before the surface exists, so the helper can never connect to nothing.
    private func startSupervisor() throws {
        supervisor?.stop()
        supervisorIsReady = false
        livePID = nil
        let client = try SupervisorClient()
        client.onEvent = { [weak self] event in self?.handleSupervisorEvent(event) }
        client.start()
        supervisor = client
        surfaceView = makeSurfaceView(
            config: try SessionBootstrap.supervisorConfig(socketPath: client.socketPath)
        )
    }

    private func handleSupervisorEvent(_ event: SupervisorProtocol.Event) {
        switch event {
        case .ready:
            supervisorIsReady = true
            sendPendingSpawn()

        case .spawned(let pid):
            let generation = spawnInFlight
            spawnInFlight = nil
            livePID = pid
            guard Self.adoptsSession(
                spawnGeneration: generation,
                attemptGeneration: attemptGeneration,
                userDisconnected: userDisconnected
            ) else {
                hangUpClient()
                return
            }
            attemptPID = pid
            // The connect clock starts when the client does, not when the
            // supervisor was asked for.
            connectStartedAt = now()
            startSessionWatch()

        case .exited(let pid, _, _):
            guard pid == livePID else { return }
            livePID = nil
            spawnInFlight = nil
            if pid == attemptPID {
                attemptPID = nil
                markSessionEnded()
            }
            // A previous session finishing is what a waiting attempt was
            // waiting for.
            sendPendingSpawn()

        case .error(let message):
            // The request is over, however it ended. Leaving it outstanding
            // would block every later spawn in this tab behind a deadline that
            // nothing can now satisfy — no session was started, so no
            // `spawned` or `exited` is coming to clear it.
            spawnInFlight = nil
            failAttempt(message)
        }
    }

    /// Whether a session the supervisor has just reported belongs to the
    /// attempt still in progress.
    ///
    /// A spawn is asked for and acknowledged as two separate events, and the
    /// user can disconnect or reconnect in between. A session that arrives for
    /// an abandoned attempt is not ignored — it is running, so the caller hangs
    /// it up.
    static func adoptsSession(
        spawnGeneration: Int?,
        attemptGeneration: Int,
        userDisconnected: Bool
    ) -> Bool {
        guard !userDisconnected else { return false }
        return spawnGeneration == attemptGeneration
    }

    /// Spawns the waiting attempt once the supervisor is ready and nothing
    /// else is running. Bounded, so a supervisor that never comes up fails
    /// the attempt instead of leaving the tab in "Connecting…" forever.
    private func sendPendingSpawn() {
        guard let spawn = pendingSpawn else { return }
        // `spawnInFlight` as well as `livePID`: between asking for a session and
        // hearing about it there is no pid, and asking twice would start two.
        guard supervisorIsReady, livePID == nil, spawnInFlight == nil, let supervisor else {
            armSpawnDeadline()
            return
        }
        pendingSpawn = nil
        spawnDeadlineTask?.cancel()
        spawnDeadlineTask = nil
        // Captured before the client starts: a prompt printed before the next
        // poll would otherwise land in the baseline and never match.
        loginScriptBaseline = surfaceView?.bridge?.visibleText() ?? ""
        do {
            try supervisor.send(.spawn(spawn))
            spawnInFlight = attemptGeneration
        } catch {
            failAttempt("\(error)")
        }
    }

    private func armSpawnDeadline() {
        guard spawnDeadlineTask == nil else { return }
        spawnDeadlineTask = Task { [weak self] in
            await self?.sleep(Self.supervisorStartTimeout)
            guard !Task.isCancelled, let self, self.pendingSpawn != nil else { return }
            self.failAttempt("The session supervisor did not start.")
        }
    }

    /// An attempt that cannot be made at all — the helper is missing, the
    /// client's binary is not there — is a configuration problem, not a drop,
    /// so it stops the cycle rather than burning retries on it.
    private func failAttempt(_ message: String) {
        stopRetrying()
        stopSessionTasks()
        pendingSpawn = nil
        phase = .failed(message)
    }

    private func makeSurfaceView(config: GhosttySurfaceConfig) -> GhosttySurfaceView {
        let view = GhosttySurfaceView(runtime: .shared, config: config)
        view.sessionIsEstablished = { [weak self] in self?.phase == .running }
        view.sessionOwnsTerminal = { [weak self] in self?.livePID != nil }
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
            self.surfaceState = bridge.state
            bridge.onCloseRequest = { [weak self] in
                self?.supervisorEnded()
            }
            bridge.onTitleChange = { [weak self] title in
                guard let self else { return }
                self.updateFromTerminalTitle(title)
                if !title.isEmpty { self.markRemoteShellReached() }
            }
            bridge.onChildExited = { [weak self] _ in
                // The supervisor itself died — the surface is spent.
                self?.supervisorEnded()
                self?.onChildExited?()
            }
        }
        return view
    }

    /// Records what the poll saw of the client's transport. Loss is not acted
    /// on: the client's own keepalives (`ServerAlive*`) end a dead connection
    /// in-band, and a client that outlives its transport reconnects itself.
    func noteTransport(present: Bool) {
        transportIsLive = present
    }

    /// Started only once the session is established: the screen still holds
    /// the *previous* session's text until then, so a retained prompt would
    /// match immediately, and a step typed at a password prompt is wrong.
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
            sendText: { [weak view] text in
                view?.sendAutomatedInput(text, appendReturn: true)
            }
        )
        loginScriptRunner = runner
        runner.start()
    }

    /// Drops the tab's end of the supervisor and the surface that hosted it.
    /// Nothing spawned through it can still be running, so the session pids go
    /// with it.
    private func releaseSupervisor() {
        supervisor?.stop()
        supervisor = nil
        supervisorIsReady = false
        pendingSpawn = nil
        // Nothing outstanding survives the supervisor that was asked: a request
        // it died before acknowledging is never answered, and holding it would
        // stall the replacement.
        spawnInFlight = nil
        livePID = nil
        attemptPID = nil
        surfaceView = nil
        surfaceState = nil
    }

    /// The pty's own child is gone, so the screen can't be reused: the next
    /// attempt builds a fresh surface.
    private func supervisorEnded() {
        releaseSupervisor()
        markSessionEnded()
    }

    func reconnect() {
        connect()
    }

    /// Polled while a session is being established, where latency is visible.
    static let attemptingPollInterval: Duration = .milliseconds(150)
    /// Polled once connected, where the only thing left to notice is a
    /// transport coming or going — a second of latency there is imperceptible,
    /// and a tab can sit connected for hours.
    static let connectedPollInterval: Duration = .milliseconds(1500)

    private func startSessionWatch() {
        sessionWatch?.cancel()
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

    /// One look at the client's sockets. Returns `false` when there is no
    /// client left to watch.
    private func pollSession() -> Bool {
        guard let pid = attemptPID, pid == livePID else { return false }
        let connected = SessionConnectionProbe.connection(of: pid) != nil
        noteTransport(present: connected)
        // A client still alive past the connect timeout counts as connected
        // even without a socket of its own — see `assumeConnectedAfter`.
        let pastTimeout = now().timeIntervalSince(connectStartedAt) >= Self.assumeConnectedAfter
        if phase.isAttemptingConnection, connected || connectedWhenClientRuns || pastTimeout {
            markConnected()
        }
        return true
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
        // Note the session watch keeps running: it is what keeps the transport
        // indicator honest. Only the cosmetic hold is replaced here — the
        // probe and a remote title can both land, and the loser must not leave
        // a sleeping task behind that wakes onto a later attempt.
        connectedHoldTask?.cancel()
        connectedHoldTask = nil
        guard phase.isAttemptingConnection else { return }
        connectedAt = now()

        let remaining = Self.minimumConnectingDisplay
            - now().timeIntervalSince(connectStartedAt)
        guard remaining > 0 else {
            phase = .running
            startLoginScriptOnce()
            return
        }
        connectedHoldTask = Task { [weak self] in
            await self?.sleep(remaining)
            guard !Task.isCancelled, let self, self.phase.isAttemptingConnection else { return }
            self.phase = .running
            self.startLoginScriptOnce()
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

    /// Hang up, then insist.
    ///
    /// A hangup is the polite ask, and ssh takes it — but lftp ignores SIGHUP
    /// by design, backgrounding itself to finish transfers. Disconnecting one
    /// of those left a live session sitting behind a "press Space to
    /// reconnect" pill, so each signal is given a moment to work before the
    /// next one.
    static let hangupSignal: Int32 = SIGHUP
    /// Applied in turn while the client is still there. SIGKILL cannot be
    /// caught, so the sequence always ends.
    static let escalationSignals: [Int32] = [SIGTERM, SIGKILL]
    static let disconnectEscalationDelay: TimeInterval = 0.8

    func disconnect() {
        userDisconnected = true
        stopRetrying()
        stopSessionTasks()
        pendingSpawn = nil
        phase = .disconnected
        hangUpClient()
    }

    /// Hangs the client up, and keeps asking until it goes.
    ///
    /// Signals go to the session's whole process group, which is what reaches a
    /// client that forks to background itself — lftp does exactly that on
    /// SIGHUP, to finish transfers. The escalation deliberately outlives the
    /// leader's exit for the same reason: the leader going away is what such a
    /// client does *instead* of ending the session, so stopping there is how a
    /// disconnected tab used to leave a live session behind.
    ///
    /// Every signal names the session it is aimed at, because outliving the
    /// leader means outliving the attempt too: a reconnect can start a
    /// replacement while this is still counting down, and the supervisor drops
    /// anything aimed at the session before it. Tying it to the attempt instead
    /// would do both the wrong things — a hangup issued *by* a reconnect is
    /// already a generation behind and would never escalate, while one issued
    /// just before it would escalate onto the new session.
    private func hangUpClient() {
        guard let target = livePID, let supervisor else { return }
        try? supervisor.send(.signal(number: Self.hangupSignal, session: target))

        disconnectTask?.cancel()
        disconnectTask = Task { [weak self] in
            for signal in Self.escalationSignals {
                await self?.sleep(Self.disconnectEscalationDelay)
                guard !Task.isCancelled, let self else { return }
                try? self.supervisor?.send(.signal(number: signal, session: target))
            }
        }
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
        transportIsLive = true
        sessionWatch?.cancel()
        sessionWatch = nil
        spawnDeadlineTask?.cancel()
        spawnDeadlineTask = nil
        connectedHoldTask?.cancel()
        connectedHoldTask = nil
        loginScriptRunner?.stop()
        loginScriptRunner = nil
    }

    /// Called when the tab is permanently closed. Stops the askpass server and
    /// the supervisor, which hangs up whatever it was running.
    func close() {
        disconnectTask?.cancel()
        disconnectTask = nil
        stopRetrying()
        stopSessionTasks()
        releaseSupervisor()
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

    // MARK: Scrollback

    /// `nil` until the surface reports a scrollback position.
    var scrollbar: TerminalScrollbar? {
        surfaceState?.scrollbar
    }

    func scrollToTop() {
        _ = surfaceView?.performBindingAction("scroll_to_top")
    }

    /// Also hands the keyboard back to the terminal, since the jump-to-bottom
    /// button takes focus when clicked.
    func scrollToBottom() {
        guard let view = surfaceView else { return }
        _ = view.performBindingAction("scroll_to_bottom")
        view.window?.makeFirstResponder(view)
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
