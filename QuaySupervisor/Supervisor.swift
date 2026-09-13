import Darwin
import Foundation

/// The pty's child for a tab's whole life. Runs sessions as the terminal's
/// foreground process on request, and reports when they end.
///
/// The point of this process is what it does *not* do: it never interprets a
/// byte from the terminal. While no session runs it owns the terminal, reads
/// whatever arrives and discards it, so a keystroke or a login-script step
/// that lands after a session died runs nothing on this machine. That is the
/// property a host shell in this position could only approximate.
final class Supervisor {
    enum Failure: Error, CustomStringConvertible {
        case notATerminal
        case noControllingTerminal
        case socket(String)

        var description: String {
            switch self {
            case .notATerminal: return "stdin is not a terminal"
            case .noControllingTerminal:
                return "this terminal cannot be controlled (not a session leader?)"
            case .socket(let detail): return "socket: \(detail)"
            }
        }
    }

    private let tty = STDIN_FILENO
    private let socket: Int32
    private let queue: Int32
    /// The terminal as it was handed to us: what every session starts with.
    private var sane = termios()
    /// The terminal between sessions: no echo, no line editing, no signals —
    /// a stray byte is neither shown nor acted on, just read and dropped.
    private var idle = termios()
    private var framer = LineFramer()
    private var child: pid_t?
    /// The last session's process group, kept after its leader is reaped.
    ///
    /// A client that forks to keep a transfer alive and then exits leaves the
    /// group populated but `child` nil, and every further signal would be a
    /// no-op — which is how a disconnected tab used to leave a live lftp
    /// behind. Replaced when the next session starts.
    private var lastGroup: pid_t?

    init(socketPath: String) throws {
        guard isatty(tty) == 1 else { throw Failure.notATerminal }

        // Owning the terminal is the job, so make sure we do. Without a
        // *controlling* terminal `tcsetpgrp` fails and a session never becomes
        // the foreground process group — which is silent, and shows up only as
        // Ctrl-C doing nothing. On macOS a terminal is not adopted by opening
        // it; it takes this ioctl, which is what `login_tty(3)` does. The spawn
        // that starts us normally has already done it, in which case there is
        // nothing to claim and this is a no-op.
        if tcgetpgrp(tty) < 0 { _ = ioctl(tty, TIOCSCTTY, 0) }
        guard tcgetpgrp(tty) >= 0 else { throw Failure.noControllingTerminal }

        tcgetattr(tty, &sane)
        // Suspend is disabled for the tab's whole life, session included.
        // Ctrl-Z stops the foreground process group, and a *stopped* child
        // fires no `NOTE_EXIT` — so the session would sit frozen holding the
        // terminal while the tab still claimed to be connected, recoverable
        // only by disconnecting. A terminal that suspends its foreground job
        // is offering to hand you the shell behind it; there is no shell
        // behind this one. Ctrl-Z reaches the session as a plain byte
        // instead, which is what a remote full-screen program expects anyway.
        // `_POSIX_VDISABLE` is a macro, so it does not reach Swift.
        let disabled: UInt8 = 0xFF
        withUnsafeMutableBytes(of: &sane.c_cc) { cc in
            cc[Int(VSUSP)] = disabled
            cc[Int(VDSUSP)] = disabled
        }
        idle = sane
        idle.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG | IEXTEN)
        withUnsafeMutableBytes(of: &idle.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }

        // Job-control and tty-generated signals are the child's business, not
        // ours: `tcsetpgrp`/`tcsetattr` from the background need SIGTTOU
        // ignored to proceed, and a Ctrl-C that reaches an idle terminal must
        // not kill the tab. SIGHUP is left alone — the pty closing is how the
        // helper learns the tab is gone.
        for sig in [SIGTTOU, SIGTTIN, SIGINT, SIGQUIT, SIGTSTP, SIGPIPE] {
            signal(sig, SIG_IGN)
        }

        socket = try Self.connect(to: socketPath)
        queue = kqueue()
        guard queue >= 0 else { throw Failure.socket("kqueue: \(UnixSocket.errnoText)") }
    }

    func run() -> Never {
        watch(ident: UInt(socket), filter: EVFILT_READ)
        setIdleTerminal()
        send(.ready)

        while true {
            var event = kevent()
            let count = kevent(queue, nil, 0, &event, 1, nil)
            guard count > 0 else {
                if errno == EINTR { continue }
                exitNow()
            }
            switch Int32(event.filter) {
            case EVFILT_READ where event.ident == UInt(socket):
                readSocket()
            case EVFILT_READ where event.ident == UInt(tty):
                drainTerminal()
            case EVFILT_PROC:
                reap(pid_t(event.ident))
            default:
                break
            }
        }
    }

    // MARK: Requests

    private func readSocket() {
        // Quay closed its end: the tab is gone.
        guard let lines = framer.readLines(from: socket) else { exitNow() }
        for line in lines {
            do {
                handle(try SupervisorProtocol.decode(line) as SupervisorProtocol.Request)
            } catch {
                send(.error(message: "unreadable request: \(error)"))
            }
        }
    }

    private func handle(_ request: SupervisorProtocol.Request) {
        switch request {
        case .spawn(let spawn):
            guard child == nil else {
                send(.error(message: "a session is already running"))
                return
            }
            self.spawn(spawn)
        case .signal(let number, let session):
            // The running session, or whatever the last one left behind — and
            // only if it is the one the signal was aimed at. A teardown is
            // escalated over seconds and a reconnect can land inside that
            // window, so an unaimed signal would fall on the replacement.
            guard let group = child ?? lastGroup, group == session else { return }
            kill(-group, number)
        }
    }

    // MARK: Sessions

    private func spawn(_ request: SupervisorProtocol.Spawn) {
        guard let path = request.argv.first else {
            send(.error(message: "nothing to run"))
            return
        }

        handOverTerminal(announcing: request.announce)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own process group, so it can be made the terminal's foreground
        // group and signalled as a unit. Started suspended so the terminal is
        // handed over before it can touch it — a read from the background
        // would stop it with SIGTTIN. Signals reset to defaults, since ours are
        // ignored. Every descriptor but the terminal closed on exec.
        posix_spawnattr_setflags(
            &attributes,
            Int16(
                POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_START_SUSPENDED
                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                    | POSIX_SPAWN_CLOEXEC_DEFAULT
            )
        )
        posix_spawnattr_setpgroup(&attributes, 0)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addinherit_np(&actions, fd)
        }
        // The child changes directory, not the helper: `chdir` here would move
        // this process for good, so a later session with no directory of its
        // own would start wherever the last one was sent. The kernel does it
        // between fork and exec instead, and a directory that has gone away
        // since the app checked it fails the spawn rather than quietly running
        // the session somewhere else — which for sftp is a download landing in
        // the wrong place.
        //
        // The `_np` spelling because the standard one is macOS 26+; this one
        // reaches back to 10.15, and its deprecation starts above our
        // deployment target, so it warns nowhere we build.
        if let directory = request.workingDirectory {
            posix_spawn_file_actions_addchdir_np(&actions, directory)
        }

        let argv = CStringArray(request.argv)
        let envp = CStringArray(Self.environmentStrings(for: request))
        var pid: pid_t = 0
        let status = posix_spawn(&pid, path, &actions, &attributes, argv.pointers, envp.pointers)
        guard status == 0 else {
            // The directory is named too: it is applied by the spawn, so its
            // errno arrives here looking like the executable's.
            let what = request.workingDirectory.map { "\(path) in \($0)" } ?? path
            abandonSpawn(nil, because: "\(what): \(String(cString: strerror(status)))")
            return
        }

        // The session becomes the terminal's foreground process group, which is
        // what routes Ctrl-C to it rather than to nobody. If that cannot be
        // done the session is abandoned rather than run half-attached: it is
        // still suspended here, so nothing of it has reached the screen, and a
        // spawn that reports success has to mean a session the user can
        // actually interact with.
        guard tcsetpgrp(tty, pid) == 0 else {
            abandonSpawn(
                pid,
                because: "could not hand the terminal to the session: \(UnixSocket.errnoText)"
            )
            return
        }

        // Armed before the child is released, so its exit cannot be missed —
        // and checked, because nothing else reaps: an unwatched child would
        // become a zombie the helper waits on forever, refusing every later
        // session as "already running".
        guard watch(ident: UInt(pid), filter: EVFILT_PROC, fflags: UInt32(NOTE_EXIT), oneShot: true) else {
            abandonSpawn(pid, because: "cannot watch the session for exit: \(UnixSocket.errnoText)")
            return
        }

        child = pid
        lastGroup = pid
        kill(pid, SIGCONT)
        send(.spawned(pid: pid))
    }

    /// Undoes a spawn that cannot be completed, and says why.
    ///
    /// `pid` is the child if one was started — killed and reaped here, since
    /// nothing else will, and the terminal taken back from it. It is still
    /// suspended at this point, so nothing of it has reached the screen. Pass
    /// `nil` when the spawn itself failed and there is no child to undo.
    private func abandonSpawn(_ pid: pid_t?, because message: String) {
        if let pid {
            kill(pid, SIGKILL)
            var discarded: Int32 = 0
            waitpid(pid, &discarded, 0)
            tcsetpgrp(tty, getpgrp())
        }
        setIdleTerminal()
        send(.error(message: message))
    }

    private func reap(_ pid: pid_t) {
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        child = nil

        tcsetpgrp(tty, getpgrp())
        setIdleTerminal()
        write(Self.terminalReset)

        let terminatingSignal = status & 0x7f
        if terminatingSignal == 0 {
            send(.exited(pid: pid, status: (status >> 8) & 0xff, signal: nil))
        } else {
            send(.exited(pid: pid, status: nil, signal: terminatingSignal))
        }
    }

    /// The session's environment: the helper's own — the user's login
    /// environment — with the request's overrides, less the socket path, which
    /// is the helper's business alone.
    private static func environmentStrings(for request: SupervisorProtocol.Spawn) -> [String] {
        var environment = ProcessInfo.processInfo.environment
        environment.merge(request.environment) { _, new in new }
        environment[SupervisorProtocol.socketEnvironmentKey] = nil
        return environment.map { "\($0.key)=\($0.value)" }
    }

    /// Hands the terminal to a session that is about to start: back to the
    /// modes it came with, with the marker line as the first thing on it.
    private func handOverTerminal(announcing announce: String?) {
        // Whatever was typed at the idle terminal is not this session's.
        tcflush(tty, TCIFLUSH)
        unwatch(ident: UInt(tty), filter: EVFILT_READ)
        tcsetattr(tty, TCSANOW, &sane)
        if let announce {
            write(announce + "\n")
        }
    }

    /// Takes the terminal back between sessions: quiet, and read-and-discard.
    private func setIdleTerminal() {
        tcsetattr(tty, TCSANOW, &idle)
        // Bytes written to the dying session are not the next one's.
        tcflush(tty, TCIFLUSH)
        watch(ident: UInt(tty), filter: EVFILT_READ)
    }

    private func drainTerminal() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        _ = Darwin.read(tty, &buffer, buffer.count)
    }

    /// Puts the terminal back to a state the next session can work in.
    ///
    /// A remote that enabled bracketed paste (mode 2004) and died without
    /// disabling it leaves the emulator wrapping the next session's input in
    /// `ESC[200~ … ESC[201~`; an editor killed mid-session leaves mouse
    /// reporting on, turning scrolls into stray bytes.
    ///
    /// The alt-screen reset is `1047`, never `1049`. Both return to the primary
    /// screen, but `1049` *restores a saved cursor* — on a terminal that was
    /// never in the alt screen that sends the cursor home and the next session
    /// overwrites the scrollback this whole design exists to keep. `1047` only
    /// touches the cursor when the screen actually changed, so it is a no-op
    /// unless a full-screen program died in there — in which case its frozen
    /// display is exactly what needs clearing before the next marker.
    static let terminalReset =
        "\u{1B}[?1047l"   // leave the alternate screen, cursor untouched
        + "\u{1B}[?2004l"   // bracketed paste off
        + "\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l"  // mouse reporting off
        + "\u{1B}[?1007l"  // wheel scrolls, rather than sending arrow keys
        + "\u{1B}[?1l"     // normal cursor keys
        + "\u{1B}[?25h"    // cursor visible
        + "\u{1B}[0m"      // no leftover colours

    // MARK: Plumbing

    private func send(_ event: SupervisorProtocol.Event) {
        guard let data = try? SupervisorProtocol.encodeLine(event) else { return }
        let written = data.withUnsafeBytes { Darwin.write(socket, $0.baseAddress, $0.count) }
        // Quay is gone; there is no one left to run sessions for.
        if written != data.count { exitNow() }
    }

    private func write(_ text: String) {
        var data = Data(text.utf8)
        while !data.isEmpty {
            let written = data.withUnsafeBytes { Darwin.write(tty, $0.baseAddress, $0.count) }
            guard written > 0 else { return }
            data.removeFirst(written)
        }
    }

    /// Hangs up the session, if any, and leaves. Called when Quay's end of the
    /// socket closes — the tab is gone.
    private func exitNow() -> Never {
        // `lastGroup` as well: a client that answers a hangup by forking and
        // letting its leader exit has no `child` left, and closing the tab on
        // one of those would otherwise leave it running.
        if let group = child ?? lastGroup { kill(-group, SIGHUP) }
        exit(0)
    }

    @discardableResult
    private func watch(ident: UInt, filter: Int32, fflags: UInt32 = 0, oneShot: Bool = false) -> Bool {
        var change = kevent(
            ident: ident,
            filter: Int16(filter),
            flags: UInt16(EV_ADD | EV_ENABLE | (oneShot ? EV_ONESHOT : 0)),
            fflags: fflags,
            data: 0,
            udata: nil
        )
        return kevent(queue, &change, 1, nil, 0, nil) != -1
    }

    private func unwatch(ident: UInt, filter: Int32) {
        var change = kevent(ident: ident, filter: Int16(filter), flags: UInt16(EV_DELETE), fflags: 0, data: 0, udata: nil)
        kevent(queue, &change, 1, nil, 0, nil)
    }

    private static func connect(to path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket("socket: \(UnixSocket.errnoText)") }

        let connected = UnixSocket.withAddress(ofPath: path) { address, length in
            Darwin.connect(fd, address, length)
        }
        guard let connected else {
            close(fd)
            throw Failure.socket("path too long")
        }
        guard connected == 0 else {
            let detail = UnixSocket.errnoText
            close(fd)
            throw Failure.socket("connect: \(detail)")
        }
        return fd
    }
}

/// A null-terminated `char *[]` for `posix_spawn`, freed with the wrapper.
private final class CStringArray {
    let pointers: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>

    init(_ strings: [String]) {
        pointers = .allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() {
            pointers[index] = strdup(string)
        }
        pointers[strings.count] = nil
    }

    deinit {
        var index = 0
        while let pointer = pointers[index] {
            free(pointer)
            index += 1
        }
        pointers.deallocate()
    }
}
