// quay-supervisor
//
// Runs as the pty's child for a Quay tab. Quay connects the socket named by
// QUAY_SUPERVISOR_SOCKET and asks for sessions to be spawned; this process
// runs them as the terminal's foreground process group and reports when they
// exit. See `Supervisor` for what it deliberately does not do.

import Darwin
import Foundation

guard let socketPath = ProcessInfo.processInfo.environment[SupervisorProtocol.socketEnvironmentKey] else {
    FileHandle.standardError.write(Data("quay-supervisor: \(SupervisorProtocol.socketEnvironmentKey) not set\n".utf8))
    exit(2)
}

do {
    try Supervisor(socketPath: socketPath).run()
} catch {
    FileHandle.standardError.write(Data("quay-supervisor: \(error)\n".utf8))
    exit(1)
}
