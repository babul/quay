import Darwin

/// Answers "is this session's client actually connected?" by reading its TCP
/// state from the kernel.
///
/// The terminal screen cannot answer it. macOS `login -flp` prints its own
/// `Last login:` banner into the pty before the client is even exec'd, so
/// "there is text on screen" says nothing about the connection — and a connect
/// that stalls in `SYN_SENT` prints nothing at all, which is exactly the case
/// the UI most needs to distinguish.
///
/// Which process to look at is never in doubt: the tab's supervisor reports the
/// pid it spawned. It is reaped there before the exit reaches the tab, so a
/// probe issued in that gap can in principle read a recycled pid — the tab
/// stops polling as soon as it processes the exit, so the worst of it is one
/// stale reading of an indicator, which is why there is no identity bracket
/// here. Note the transport helpers below get one, because their pids are
/// reaped by the client and nothing coordinates that at all.
enum SessionConnectionProbe {
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

    /// The client's established connection, held by the client itself or by
    /// a transport helper it spawned.
    static func connection(of client: pid_t) -> Peer? {
        establishedPeer(pid: client) ?? establishedHelperPeer(of: [client])
    }

    /// Some clients hand the transport to a helper rather than opening the
    /// connection themselves — `ssh` with `ProxyCommand`/`ProxyJump` spawns a
    /// child that holds the socket, and `lftp` spawns its own `ssh` in a
    /// separate session. Without this such a session reads as "connecting" for
    /// as long as it runs.
    static func establishedHelperPeer(of clients: [pid_t]) -> Peer? {
        for client in clients {
            for pid in childProcesses(of: client) {
                // A helper's pid is not held for us the way the client's is:
                // the client reaps it, so it can be recycled mid-read. Bracket
                // the socket read with the process's identity so a pid that
                // died and was reused can't answer for the session.
                guard let before = identity(of: pid), before.ppid == client else { continue }
                guard let peer = establishedPeer(pid: pid) else { continue }
                guard let after = identity(of: pid), after == before else { continue }
                return peer
            }
        }
        return nil
    }

    /// Parent plus start time — enough to tell a recycled pid apart from the
    /// process we were looking at.
    private static func identity(of pid: pid_t) -> (ppid: pid_t, startedAt: UInt64)? {
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
        return (pid_t(info.pbi_ppid), startedAt)
    }

    /// Direct children of `pid` — the kernel indexes these, so finding a
    /// client's transport helper costs one syscall rather than a walk over
    /// every process on the machine.
    static func childProcesses(of pid: pid_t) -> [pid_t] {
        // A client has few children; 64 slots is headroom.
        var pids = [pid_t](repeating: 0, count: 64)
        // Unlike `proc_listallpids`, this returns *bytes*, not a count.
        let bytes = proc_listpids(
            UInt32(PROC_PPID_ONLY),
            UInt32(pid),
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
