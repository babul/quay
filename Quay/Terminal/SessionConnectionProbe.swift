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

    /// The far end of an established connection, read from the client's own
    /// socket.
    ///
    /// This is the only trustworthy answer to "where is this session actually
    /// connected?". `ConnectionProfile.hostname` is not: it is an ssh_config
    /// alias for alias profiles, and even a real name can be rewritten by
    /// `HostName`, `Port`, `ProxyJump`, or `ProxyCommand` before ssh dials —
    /// in which case the profile's hostname is not the machine on the other
    /// end of the socket, and may not resolve or answer at all.
    struct Peer: Equatable {
        var host: String
        var port: Int
    }

    /// One look at the pty's foreground process group.
    struct Foreground: Equatable {
        /// The group itself, so callers comparing against a remembered pgid
        /// compare against the same sample these names came from.
        var pgid: pid_t?
        /// Executable names running in the group — enough to tell the session
        /// client from the host shell waiting behind it.
        var names: Set<String> = []
        var state: SessionState = .noClient
        /// Where the established connection goes, when there is one. Remembered
        /// by the tab so a later reachability check can probe the route the
        /// session actually took.
        var peer: Peer?
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

    /// Discards anything typed but not yet read by the terminal's foreground
    /// process.
    ///
    /// Writing to a pty is asynchronous: bytes meant for a remote session can
    /// still be sitting in the line discipline when that session dies, and the
    /// host shell then reads them and *runs* them locally. A login script's
    /// keystrokes arriving that way is how a local `htop` ends up owning a tab.
    static func flushInput(ttyPath: String) {
        let fd = open(ttyPath, O_RDONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = tcflush(fd, TCIFLUSH)
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
        guard !clients.isEmpty else { return Foreground(pgid: pgid, names: names, state: .noClient) }
        let peer = clients.lazy.compactMap { stableEstablishedPeer(pid: $0, pgid: pgid) }.first
            ?? establishedHelperPeer(of: clients)
        return Foreground(
            pgid: pgid,
            names: names,
            state: peer == nil ? .connecting : .connected,
            peer: peer
        )
    }

    /// Executable name, used to tell the session client apart from the host
    /// shell sharing its process group.
    static func processName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let read = proc_name(pid, &buffer, UInt32(buffer.count))
        guard read > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Some clients hand the transport to a helper rather than opening the
    /// connection themselves — `ssh` with `ProxyCommand`/`ProxyJump` spawns a
    /// child that holds the socket, and `lftp` spawns its own `ssh` in a
    /// separate session. Without this such a session reads as "connecting" for
    /// as long as it runs.
    static func establishedHelperPeer(of clients: [pid_t]) -> Peer? {
        for client in clients {
            for pid in childProcesses(of: client) {
                // The same pid-recycling bracket as `stableEstablishedPeer`,
                // on the parent link this time.
                guard let before = identity(of: pid), before.ppid == client else { continue }
                guard let peer = establishedPeer(pid: pid) else { continue }
                guard let after = identity(of: pid), after == before else { continue }
                return peer
            }
        }
        return nil
    }

    /// A pid is not an identity — the kernel recycles them. Bracket the socket
    /// read with the process's identity so a pid that died and was reused
    /// mid-read can't answer for the session it replaced.
    private static func stableEstablishedPeer(pid: pid_t, pgid: pid_t) -> Peer? {
        guard let before = identity(of: pid), before.pgid == pgid else { return nil }
        guard let peer = establishedPeer(pid: pid) else { return nil }
        guard let after = identity(of: pid), after == before else { return nil }
        return peer
    }

    /// Process group plus start time — enough to tell a recycled pid apart from
    /// the process we were looking at.
    private static func identity(of pid: pid_t) -> (ppid: pid_t, pgid: pid_t, startedAt: UInt64)? {
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
        return (pid_t(info.pbi_ppid), pid_t(info.pbi_pgid), startedAt)
    }

    /// Every process whose process group is `pgid` — the `login` wrapper and
    /// the ssh client it exec'd into. The kernel answers this directly, so
    /// there is no need to walk the process table.
    static func sessionProcesses(pgid: pid_t) -> [pid_t] {
        listPids(selector: PROC_PGRP_ONLY, value: pgid)
    }

    /// Those of `pids` still running as session clients, plus any client they
    /// have spawned since.
    ///
    /// This is what a disconnect escalation aims at. Re-reading the pty's
    /// foreground group instead would lose a client that answers SIGHUP by
    /// forking a detached copy and exiting — the group then holds only the host
    /// shell, the escalation stops, and a live session is left behind a
    /// disconnected tab.
    static func liveClients(among pids: [pid_t], clientNames: Set<String>) -> [pid_t] {
        pids.flatMap { pid -> [pid_t] in
            // A pid the kernel has recycled into some other program is not our
            // client, and must not be signalled.
            guard clientNames.contains(processName(of: pid) ?? "") else { return [] }
            return [pid] + childProcesses(of: pid).filter {
                clientNames.contains(processName(of: $0) ?? "")
            }
        }
    }

    /// Direct children of `pid` — the kernel indexes these, so finding a
    /// client's transport helper costs one syscall rather than a walk over
    /// every process on the machine.
    static func childProcesses(of pid: pid_t) -> [pid_t] {
        listPids(selector: PROC_PPID_ONLY, value: pid)
    }

    private static func listPids(selector: Int32, value: pid_t) -> [pid_t] {
        // A session is a wrapper plus its client, and a client has few
        // children; 64 slots is headroom for both.
        var pids = [pid_t](repeating: 0, count: 64)
        // Unlike `proc_listallpids`, this returns *bytes*, not a count.
        let bytes = proc_listpids(
            UInt32(selector),
            UInt32(value),
            &pids,
            Int32(pids.count * MemoryLayout<pid_t>.stride)
        )
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }
    }

    /// The far end of `pid`'s first `ESTABLISHED` TCP socket, or nil when it
    /// has none — which doubles as "this client is not connected yet".
    static func establishedPeer(pid: pid_t) -> Peer? {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return nil }

        var fds = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: Int(size) / MemoryLayout<proc_fdinfo>.stride
        )
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
        guard used > 0 else { return nil }

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
            guard info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_ESTABLISHED else { continue }
            if let peer = peer(from: info.psi.soi_proto.pri_tcp.tcpsi_ini) { return peer }
        }
        return nil
    }

    /// Formats a socket's foreign address and port.
    private static func peer(from socket: in_sockinfo) -> Peer? {
        let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: socket.insi_fport)))
        guard port > 0 else { return nil }

        // `INI_IPV4` / `INI_IPV6` from <sys/proc_info.h>, which are macros and
        // so do not reach Swift. v4 is checked first: a v4-mapped socket sets
        // both, and its address belongs in the v4 arm.
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let formatted: Bool
        if socket.insi_vflag & 0x1 != 0 {
            var address = socket.insi_faddr.ina_46.i46a_addr4
            formatted = inet_ntop(AF_INET, &address, &text, socklen_t(text.count)) != nil
        } else if socket.insi_vflag & 0x2 != 0 {
            var address = socket.insi_faddr.ina_6
            formatted = inet_ntop(AF_INET6, &address, &text, socklen_t(text.count)) != nil
        } else {
            return nil
        }
        guard formatted else { return nil }
        return Peer(host: String(cString: text), port: port)
    }
}
