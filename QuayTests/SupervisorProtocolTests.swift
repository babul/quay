import Foundation
import Testing
@testable import Quay

/// The wire format between Quay and `quay-supervisor`. Both ends compile the
/// same file, so what matters here is that a message survives the trip and
/// that the byte stream is cut into messages correctly.
@Suite("Supervisor protocol")
struct SupervisorProtocolTests {
    @Test("A spawn request round-trips with every field")
    func spawnRoundTrip() throws {
        let request = SupervisorProtocol.Request.spawn(
            .init(
                argv: ["/usr/bin/ssh", "-o", "BatchMode=no", "user@host"],
                environment: ["TERM": "xterm-256color", "SSH_ASKPASS": "/p/quay askpass"],
                workingDirectory: "/Users/me/Downloads",
                announce: "→ 2026-09-13 03:00:00  ssh user@host"
            )
        )
        let line = try SupervisorProtocol.encodeLine(request)
        #expect(line.last == UInt8(ascii: "\n"))
        let decoded: SupervisorProtocol.Request = try SupervisorProtocol.decode(line.dropLast())
        #expect(decoded == request)
    }

    @Test("Every event round-trips")
    func eventsRoundTrip() throws {
        let events: [SupervisorProtocol.Event] = [
            .ready,
            .spawned(pid: 4242),
            .exited(pid: 4242, status: 255, signal: nil),
            .exited(pid: 4243, status: nil, signal: 9),
            .error(message: "a session is already running"),
        ]
        for event in events {
            let line = try SupervisorProtocol.encodeLine(event)
            let decoded: SupervisorProtocol.Event = try SupervisorProtocol.decode(line.dropLast())
            #expect(decoded == event)
        }
    }

    @Test("Lines are cut at newlines, and a partial line waits for the rest")
    func framing() {
        var framer = LineFramer()
        #expect(framer.append(Data("{\"a\":1}\n{\"b\"".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["{\"a\":1}"])
        #expect(framer.append(Data(":2}".utf8)).isEmpty)
        #expect(framer.append(Data("\n\n".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["{\"b\":2}", ""])
    }
}
