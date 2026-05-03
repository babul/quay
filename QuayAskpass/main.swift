// QuayAskpass
//
// Tiny command-line helper that OpenSSH invokes via `SSH_ASKPASS` to obtain
// a password / passphrase. We connect to the parent app's per-connection
// Unix domain socket (path supplied via `QUAY_ASKPASS_SOCKET` env var),
// read the secret bytes, write them to stdout, and exit.
//
// Real implementation lands in Step 6 along with `AskpassServer.swift`.

import Foundation

guard let socketPath = ProcessInfo.processInfo.environment["QUAY_ASKPASS_SOCKET"] else {
    FileHandle.standardError.write(Data("quay-askpass: QUAY_ASKPASS_SOCKET not set\n".utf8))
    exit(2)
}

FileHandle.standardError.write(Data("quay-askpass: stub (socket=\(socketPath))\n".utf8))
exit(1)
