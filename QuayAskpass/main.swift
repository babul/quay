// QuayAskpass
//
// SSH_ASKPASS helper. OpenSSH execs us when it needs a password or
// passphrase; we connect to the parent app's per-connection Unix domain
// socket (path supplied via QUAY_ASKPASS_SOCKET), pipe the bytes the
// parent sends to stdout, and exit 0.
//
// No retries, no logging, no buffering. Failure is silent: ssh sees
// either zero bytes or EOF and treats that as an empty password, which
// fails authentication cleanly.

import Darwin
import Foundation

guard let socketPath = ProcessInfo.processInfo.environment["QUAY_ASKPASS_SOCKET"] else {
    FileHandle.standardError.write(Data("quay-askpass: QUAY_ASKPASS_SOCKET not set\n".utf8))
    exit(2)
}

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else {
    FileHandle.standardError.write(Data("quay-askpass: socket() failed (errno=\(errno))\n".utf8))
    exit(3)
}

let pathBytes = Array(socketPath.utf8) + [0]
guard pathBytes.count <= 104 else {
    FileHandle.standardError.write(Data("quay-askpass: socket path too long\n".utf8))
    exit(4)
}

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
withUnsafeMutableBytes(of: &addr.sun_path) { dst in
    pathBytes.withUnsafeBufferPointer { src in
        dst.copyBytes(from: UnsafeRawBufferPointer(src))
    }
}

let connectResult = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
        connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connectResult == 0 else {
    FileHandle.standardError.write(Data("quay-askpass: connect() failed (errno=\(errno))\n".utf8))
    close(fd)
    exit(5)
}

// Pipe bytes from the socket to stdout until EOF. We don't append a
// trailing newline — the server sends exactly the bytes ssh should see.
var buf = [UInt8](repeating: 0, count: 4096)
buf.withUnsafeMutableBufferPointer { ptr in
    let base = ptr.baseAddress!
    while true {
        let n = read(fd, base, ptr.count)
        if n <= 0 { break }
        var written = 0
        while written < n {
            let w = write(1, base.advanced(by: written), n - written)
            if w <= 0 { break }
            written += w
        }
    }
}
close(fd)
exit(0)
