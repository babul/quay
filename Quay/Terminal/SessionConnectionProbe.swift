import Darwin

/// Answers "is this session's ssh actually connected?" by reading the client's
/// TCP state from the kernel.
///
/// The terminal screen cannot answer it. macOS `login -flp` prints its own
/// `Last login:` banner into the pty before ssh is even exec'd, so "there is
/// text on screen" says nothing about the connection — and a connect that
/// stalls in `SYN_SENT` prints nothing at all, which is exactly the case the
/// UI most needs to distinguish.
///
/// libghostty's `foreground_pid` is `tcgetpgrp` — a process *group*, not a pid.
/// The group holds whatever currently owns the terminal: the tab's host shell
/// between sessions, and the session's client while one runs. So the client is
/// found by enumerating that group and matching executable names.
enum SessionConnectionProbe {
    /// What the pty's foreground process group is doing.
    enum SessionState: Equatable {
        /// No session client is running — the pty belongs to Quay's host shell,
        /// so nothing typed here should reach it.
        case noClient
        /// The client is running but has no established connection yet.
        case connecting
        /// The client's connection is up.
        case connected
    }

    /// One look at the pty's foreground process group.
    struct Foreground: Equatable {
        /// Executable names running in the group — enough to tell the session
        /// client from the host shell waiting behind it.
        var names: Set<String> = []
        var state: SessionState = .noClient
    }

    /// Classifies the foreground process group by looking for the session
    /// client (`ssh`, `sftp`, …) and, if it is there, whether its connection
    /// has been established.
    /// Is the session's client running at all?
    ///
    /// Deliberately cheaper than `foreground(pgid:clientNames:)`: the input gate
    /// asks this on every keystroke and only needs presence, never the socket
    /// state.
    static func clientIsRunning(pgid: pid_t, clientNames: Set<String>) -> Bool {
        sessionProcesses(pgid: pgid).contains { pid in
            guard let name = processName(of: pid) else { return false }
            return clientNames.contains(name)
        }
    }

    /// True once the host shell has turned the terminal's echo off — the last
    /// thing its startup does, so it doubles as "ready to be typed into".
    static func echoDisabled(ttyPath: String) -> Bool {
        // O_NONBLOCK so a tty with no session attached can't block the open,
        // O_NOCTTY so this never becomes our controlling terminal.
        let fd = open(ttyPath, O_RDONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var attributes = termios()
        guard tcgetattr(fd, &attributes) == 0 else { return false }
        return attributes.c_lflag & tcflag_t(ECHO) == 0
    }

    /// - Parameter pgid: the pty's foreground process *group*, which is what
    ///   libghostty's `foreground_pid` actually reports.
    static func foreground(pgid: pid_t, clientNames: Set<String>) -> Foreground {
        var names: Set<String> = []
        var clients: [pid_t] = []
        for member in sessionProcesses(pgid: pgid) {
            guard let name = processName(of: member) else { continue }
            names.insert(name)
            if clientNames.contains(name) { clients.append(member) }
        }
        guard !clients.isEmpty else { return Foreground(names: names, state: .noClient) }
        let connected = clients.contains { hasStableEstablishedTCP(pid: $0, pgid: pgid) }
        return Foreground(names: names, state: connected ? .connected : .connecting)
    }

    /// Executable name, used to tell the session client apart from the host
    /// shell sharing its process group.
    static func processName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let read = proc_name(pid, &buffer, UInt32(buffer.count))
        guard read > 0 else { return nil }
        return String(cString: buffer)
    }

    /// A pid is not an identity — the kernel recycles them. Bracket the socket
    /// read with the process's identity so a pid that died and was reused
    /// mid-read can't answer for the session it replaced.
    private static func hasStableEstablishedTCP(pid: pid_t, pgid: pid_t) -> Bool {
        guard let before = identity(of: pid), before.pgid == pgid else { return false }
        guard hasEstablishedTCP(pid: pid) else { return false }
        guard let after = identity(of: pid) else { return false }
        return after == before
    }

    /// Process group plus start time — enough to tell a recycled pid apart from
    /// the process we were looking at.
    private static func identity(of pid: pid_t) -> (pgid: pid_t, startedAt: UInt64)? {
        var info = proc_bsdinfo()
        let read = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard read > 0 else { return nil }
        let startedAt = UInt64(info.pbi_start_tvsec) << 32 | UInt64(info.pbi_start_tvusec)
        return (pid_t(info.pbi_pgid), startedAt)
    }

    /// Every process whose process group is `pgid` — the `login` wrapper and
    /// the ssh client it exec'd into. The kernel answers this directly, so
    /// there is no need to walk the process table.
    static func sessionProcesses(pgid: pid_t) -> [pid_t] {
        // A session is the wrapper plus its client; 64 slots is headroom.
        var pids = [pid_t](repeating: 0, count: 64)
        // Unlike `proc_listallpids`, this returns *bytes*, not a count.
        let bytes = proc_listpids(
            UInt32(PROC_PGRP_ONLY),
            UInt32(pgid),
            &pids,
            Int32(pids.count * MemoryLayout<pid_t>.stride)
        )
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }
    }

    /// True when `pid` owns at least one TCP socket in `ESTABLISHED`.
    static func hasEstablishedTCP(pid: pid_t) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }

        var fds = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: Int(size) / MemoryLayout<proc_fdinfo>.stride
        )
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
        guard used > 0 else { return false }

        for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride)
        where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let read = proc_pidfdinfo(
                pid,
                fd.proc_fd,
                PROC_PIDFDSOCKETINFO,
                &info,
                Int32(MemoryLayout<socket_fdinfo>.size)
            )
            guard read > 0, info.psi.soi_kind == SOCKINFO_TCP else { continue }
            if info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_ESTABLISHED { return true }
        }
        return false
    }
}
