import Darwin
import Foundation
import Testing
@testable import Quay

/// Runs the bundled `quay-supervisor` on a real pty and drives it the way a
/// tab does. This is what proves the job control — handing the terminal to a
/// session and taking it back — before anything in the app depends on it.
@MainActor
@Suite("Supervisor on a pty", .serialized)
struct SupervisorIntegrationTests {
    @MainActor
    private final class Harness {
        let client: SupervisorClient
        let master: Int32
        let helper: pid_t
        private(set) var events: [SupervisorProtocol.Event] = []
        private var consumed = 0

        init() throws {
            client = try SupervisorClient()

            let masterFD = posix_openpt(O_RDWR | O_NOCTTY)
            try #require(masterFD >= 0)
            try #require(grantpt(masterFD) == 0 && unlockpt(masterFD) == 0)
            let slavePath = String(cString: try #require(ptsname(masterFD)))
            master = masterFD

            let helperPath = try #require(
                SessionBootstrap.bundledExecutable(named: SessionBootstrap.supervisorName),
                "quay-supervisor is not in the test host bundle"
            )

            // Its own session, holding the pty on fds 0-2. Note this does NOT
            // hand it a *controlling* terminal: on macOS that takes an explicit
            // `TIOCSCTTY`, which libghostty's spawn does for the real thing and
            // the helper does for itself when nothing else has.
            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, slavePath, O_RDWR, 0)
            posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO)

            var environment = ProcessInfo.processInfo.environment
            environment[SupervisorProtocol.socketEnvironmentKey] = client.socketPath
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup(helperPath), nil]
            var envp: [UnsafeMutablePointer<CChar>?] =
                environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer {
                argv.forEach { free($0) }
                envp.forEach { free($0) }
            }
            var pid: pid_t = 0
            try #require(posix_spawn(&pid, helperPath, &actions, &attributes, &argv, &envp) == 0)
            helper = pid

            client.onEvent = { [weak self] in self?.events.append($0) }
            client.start()
        }

        /// A helper on its own pty that has reported ready — which every test
        /// needs before it can ask for anything, and no test is about.
        static func ready(within timeout: TimeInterval = 5) async throws -> Harness {
            let harness = try Harness()
            let event = await harness.nextEvent(within: timeout)
            guard event == .ready else {
                harness.finish()
                throw UnexpectedEvent(expected: "ready", received: event)
            }
            return harness
        }

        /// The helper sent something other than what the test was waiting for.
        struct UnexpectedEvent: Error, CustomStringConvertible {
            var expected: String
            var received: SupervisorProtocol.Event?

            var description: String {
                let got = received.map(String.init(describing:)) ?? "nothing"
                return "expected \(expected), got \(got)"
            }
        }

        /// The pid of the session the helper reports having started.
        func spawnedPID(within timeout: TimeInterval = 5) async throws -> pid_t {
            let event = await nextEvent(within: timeout)
            guard case .spawned(let pid)? = event else {
                throw UnexpectedEvent(expected: "spawned", received: event)
            }
            return pid
        }

        /// The next event the helper sends, in order.
        func nextEvent(within timeout: TimeInterval = 5) async -> SupervisorProtocol.Event? {
            let deadline = Date().addingTimeInterval(timeout)
            while events.count <= consumed, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard events.count > consumed else { return nil }
            defer { consumed += 1 }
            return events[consumed]
        }

        /// Everything the pty has shown so far.
        func screen() -> String {
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            let flags = fcntl(master, F_GETFL, 0)
            _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
            defer { _ = fcntl(master, F_SETFL, flags) }
            while true {
                let read = Darwin.read(master, &buffer, buffer.count)
                guard read > 0 else { break }
                output.append(contentsOf: buffer[..<read])
            }
            return String(decoding: output, as: UTF8.self)
        }

        /// The terminal's foreground process group — which session, if any, the
        /// line discipline would send a Ctrl-C to.
        func foregroundProcessGroup() -> pid_t {
            tcgetpgrp(master)
        }

        /// What a keystroke or paste does: bytes into the pty's input.
        func type(_ text: String) {
            _ = text.withCString { Darwin.write(master, $0, strlen($0)) }
        }

        func spawn(
            _ argv: [String],
            workingDirectory: String? = nil,
            announce: String? = nil
        ) throws {
            try client.send(
                .spawn(.init(argv: argv, workingDirectory: workingDirectory, announce: announce))
            )
        }

        func finish() {
            client.stop()
            kill(helper, SIGKILL)
            // Before reaping, and this order matters: the helper holds the pty
            // as its controlling terminal, and a session leader's exit drains
            // the terminal's output — which cannot finish while the only
            // reader of the master is the thread about to call `waitpid`.
            // libghostty, which keeps reading, never puts the real one here.
            close(master)
            var status: Int32 = 0
            waitpid(helper, &status, 0)
        }
    }

    @Test("The helper reports ready, runs a session, and reports how it ended")
    func spawnsAndReportsExit() async throws {
        let h = try await Harness.ready()
        defer { h.finish() }

        try h.spawn(["/bin/sh", "-c", "echo hello from the session; exit 3"], announce: "→ marker")
        let pid = try await h.spawnedPID()
        #expect(await h.nextEvent() == .exited(pid: pid, status: 3, signal: nil))

        let screen = h.screen()
        #expect(screen.contains("→ marker"))
        #expect(screen.contains("hello from the session"))
        // The terminal is put back after the session — bracketed paste off is
        // the reset that matters most.
        #expect(screen.contains("\u{1B}[?2004l"))
    }

    /// A session is the terminal's foreground process group, so it can read
    /// the terminal — and a signal from Quay reaches it.
    @Test("A session owns the terminal, and a signal from Quay ends it")
    func sessionOwnsTerminalAndIsSignalled() async throws {
        let h = try await Harness.ready()
        defer { h.finish() }

        try h.spawn(["/bin/sh", "-c", "read line; echo got:$line; exec sleep 30"])
        let pid = try await h.spawnedPID()
        h.type("typed while running\n")
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.screen().contains("got:typed while running"))

        try h.client.send(.signal(number: SIGTERM, session: pid))
        #expect(await h.nextEvent() == .exited(pid: pid, status: nil, signal: SIGTERM))
    }

    /// The property the helper exists for: between sessions there is no
    /// interpreter behind the terminal. What arrives is dropped, not run, and
    /// not handed to the next session either.
    @Test("Input that lands between sessions reaches nothing")
    func idleInputIsDiscarded() async throws {
        let h = try await Harness.ready()
        defer { h.finish() }

        h.type("echo LEAKED\n")
        try await Task.sleep(for: .milliseconds(200))
        // Nothing echoed it, nothing ran it.
        #expect(!h.screen().contains("LEAKED"))

        // The next session must not see it either: a read with nothing
        // waiting times out and the script exits 0; anything read exits 42.
        try h.spawn(["/bin/sh", "-c", "if read -t 1 line; then exit 42; else exit 0; fi"])
        let pid = try await h.spawnedPID()
        #expect(await h.nextEvent() == .exited(pid: pid, status: 0, signal: nil))
    }

    /// An sftp session opens in the tab's local directory. The helper must
    /// place the child there without moving itself, or the next session would
    /// start wherever the last one was told to go.
    @Test("A session is placed in its working directory, and the helper stays put")
    func placesSessionWithoutMovingItself() async throws {
        let h = try await Harness.ready()
        defer { h.finish() }

        // Resolved, since $TMPDIR is a symlink under /private on macOS and pwd
        // reports where it lands.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        try h.spawn(["/bin/sh", "-c", "pwd"], workingDirectory: directory)
        let placed = try await h.spawnedPID()
        #expect(await h.nextEvent() == .exited(pid: placed, status: 0, signal: nil))
        #expect(h.screen().contains(directory))

        // A request with no directory of its own starts where the helper did.
        try h.spawn(["/bin/sh", "-c", "pwd"])
        let after = try await h.spawnedPID()
        #expect(await h.nextEvent() == .exited(pid: after, status: 0, signal: nil))
        let secondLine = h.screen().trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!secondLine.contains(directory))
    }

    /// Ctrl-C must reach the session — it is the foreground process group, so
    /// the line discipline sends it there and nowhere else. This is also the
    /// check that the terminal handover actually happened: with the foreground
    /// group unset, the signal would go to the helper, which ignores it.
    @Test("Ctrl-C reaches the session, and its death is reported as a signal")
    func interruptReachesTheSession() async throws {
        let h = try await Harness.ready()
        defer { h.finish() }

        try h.spawn(["/bin/cat"])
        let pid = try await h.spawnedPID()
        try await Task.sleep(for: .milliseconds(200))
        // The session must be the terminal's foreground group, or the line
        // discipline would send the signal to the helper instead.
        #expect(h.foregroundProcessGroup() == pid)
        h.type("\u{03}")

        let ended = await h.nextEvent()
        #expect(ended == .exited(pid: pid, status: nil, signal: SIGINT), "got \(String(describing: ended))")
    }

    /// Ctrl-Z would stop the session, and a *stopped* child fires no
    /// `NOTE_EXIT` — the tab would sit frozen, still claiming to be connected,
    /// holding a terminal nothing is reading. Suspend is disabled, so the byte
    /// reaches the session instead.
    @Test("Ctrl-Z cannot freeze a session")
    func suspendCannotFreezeTheSession() async throws {
        let h = try await Harness.ready()
        defer { h.finish() }

        // `cat` echoes what it reads, so the byte arriving proves it was
        // delivered rather than swallowed by the line discipline.
        try h.spawn(["/bin/cat"])
        let pid = try await h.spawnedPID()
        try await Task.sleep(for: .milliseconds(200))
        h.type("\u{1A}\n")
        try await Task.sleep(for: .milliseconds(400))

        #expect(h.screen().contains("\u{1A}"))
        // Still running, and still ours to end.
        try h.client.send(.signal(number: SIGKILL, session: pid))
        #expect(await h.nextEvent() == .exited(pid: pid, status: nil, signal: SIGKILL))
    }

    /// lftp answers a hangup by forking to finish its transfers and letting the
    /// original exit. The leader's death is therefore not the session's end,
    /// and signalling has to keep reaching what it left behind — otherwise a
    /// disconnected tab leaves a live session running.
    @Test("A session that outlives its leader can still be ended")
    func signalsReachWhatTheLeaderLeftBehind() async throws {
        let h = try await Harness.ready()
        defer { h.finish() }

        try h.spawn(["/bin/sh", "-c", "sleep 30 & echo LEFT:$!; exit 0"])
        let leader = try await h.spawnedPID()
        #expect(await h.nextEvent() == .exited(pid: leader, status: 0, signal: nil))

        let screen = h.screen()
        let reported = screen
            .components(separatedBy: "LEFT:").last?
            .prefix { $0.isNumber }
        let survivor = pid_t(reported.flatMap { Int32($0) } ?? 0)
        try #require(survivor > 0, "could not read the surviving pid from \(screen)")
        // Still there: the leader exiting did not take it with it.
        try #require(kill(survivor, 0) == 0)

        try h.client.send(.signal(number: SIGKILL, session: leader))
        var reached = false
        for _ in 0..<40 where !reached {
            try await Task.sleep(for: .milliseconds(50))
            reached = kill(survivor, 0) != 0
        }
        #expect(reached, "the survivor outlived a disconnect")
    }

    /// A local directory can be removed between the app validating it and the
    /// session starting. Running somewhere else instead would put an sftp
    /// download in a place the user never chose, so the spawn fails instead.
    @Test("A working directory that has gone away fails the session")
    func missingWorkingDirectoryFailsTheSpawn() async throws {
        let h = try await Harness.ready()
        defer { h.finish() }

        let gone = NSTemporaryDirectory() + "quay-not-here-\(UUID().uuidString)"
        try h.spawn(["/bin/sh", "-c", "pwd"], workingDirectory: gone)

        guard case .error(let message)? = await h.nextEvent() else {
            Issue.record("a missing directory did not fail the spawn")
            return
        }
        #expect(message.contains(gone))
        // Nothing ran, so the terminal is untouched and the next session is
        // still welcome.
        #expect(!h.screen().contains(gone))
        try h.spawn(["/usr/bin/true"])
        let pid = try await h.spawnedPID()
        #expect(await h.nextEvent() == .exited(pid: pid, status: 0, signal: nil))
    }

    /// A teardown is escalated over seconds, and a reconnect can start a
    /// replacement inside that window. A signal left over from the previous
    /// session must not land on the new one — which, with SIGKILL at the end of
    /// the escalation, would kill a session the user just asked for.
    @Test("A signal aimed at a finished session never reaches its replacement")
    func staleSignalsMissTheReplacement() async throws {
        let h = try await Harness.ready()
        defer { h.finish() }

        try h.spawn(["/usr/bin/true"])
        let first = try await h.spawnedPID()
        #expect(await h.nextEvent() == .exited(pid: first, status: 0, signal: nil))

        try h.spawn(["/bin/sh", "-c", "exec sleep 30"])
        let second = try await h.spawnedPID()

        // Aimed at the session that has already gone.
        try h.client.send(.signal(number: SIGKILL, session: first))
        try await Task.sleep(for: .milliseconds(400))
        #expect(kill(second, 0) == 0, "a stale signal killed the replacement")

        // Aimed correctly, it still works.
        try h.client.send(.signal(number: SIGKILL, session: second))
        #expect(await h.nextEvent() == .exited(pid: second, status: nil, signal: SIGKILL))
    }

    /// A spawn that fails has to retire the request it answered. Nothing else
    /// will: no session started, so no `spawned` or `exited` is coming, and a
    /// request left outstanding blocks every later session in the tab.
    @Test("A failed spawn does not block the next one")
    func failedSpawnDoesNotBlockTheNext() async throws {
        let h = try await Harness.ready()
        defer { h.finish() }

        try h.spawn(["/nonexistent/binary"])
        guard case .error? = await h.nextEvent() else {
            Issue.record("a missing binary did not fail the spawn")
            return
        }

        try h.spawn(["/usr/bin/true"])
        let pid = try await h.spawnedPID()
        #expect(await h.nextEvent() == .exited(pid: pid, status: 0, signal: nil))
    }

    @Test("A second spawn while one runs is refused, not queued")
    func refusesConcurrentSpawn() async throws {
        let h = try await Harness.ready()
        defer { h.finish() }

        try h.spawn(["/bin/sleep", "30"])
        _ = try await h.spawnedPID()

        try h.spawn(["/usr/bin/true"])
        let refusal = await h.nextEvent()
        guard case .error? = refusal else {
            Issue.record("second spawn was not refused, got \(String(describing: refusal))")
            return
        }
    }
}
