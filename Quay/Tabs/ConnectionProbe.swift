import Foundation

/// One-shot, non-interactive SSH probe for the connection editor's
/// "Test connection" button.
///
/// Builds its own argv instead of calling `SSHCommandBuilder.build` because
/// the production builder hardcodes `-o BatchMode=no` first, and ssh's
/// "first value wins" rule makes it impossible to override via `extraOptions`.
enum ConnectionProbe {
    enum Outcome: Sendable, Equatable {
        case success
        case failure(message: String, exitCode: Int32?)
    }

    /// Pure, testable argv builder. argv[0] is `/usr/bin/ssh`; argv.last is `"exit 0"`.
    static func probeArgv(for target: SSHTarget) -> [String] {
        var argv: [String] = [SSHCommandBuilder.sshBinary]

        // Common options for all auth modes
        argv += ["-o", "ConnectTimeout=5"]
        argv += ["-o", "StrictHostKeyChecking=accept-new"]

        switch target.auth {
        case .sshAgent:
            argv += ["-o", "BatchMode=yes"]
            argv += ["-o", "NumberOfPasswordPrompts=0"]
            argv += hostFlags(target)

        case .privateKey(let path):
            argv += ["-o", "BatchMode=yes"]
            argv += ["-o", "NumberOfPasswordPrompts=0"]
            argv += ["-i", path, "-o", "IdentitiesOnly=yes"]
            argv += hostFlags(target)

        case .privateKeyWithPassphrase(let path, _):
            // No BatchMode=yes — passphrase prompt must reach askpass.
            argv += ["-o", "NumberOfPasswordPrompts=1"]
            argv += ["-i", path, "-o", "IdentitiesOnly=yes"]
            argv += hostFlags(target)

        case .password:
            argv += ["-o", "NumberOfPasswordPrompts=1"]
            argv += ["-o", "PreferredAuthentications=password,keyboard-interactive"]
            argv += ["-o", "PubkeyAuthentication=no"]
            argv += hostFlags(target)

        case .sshConfigAlias(let alias):
            // Alias may need agent/passphrase-less keys; can't deliver secrets.
            argv += ["-o", "NumberOfPasswordPrompts=0"]
            argv += ["-o", "BatchMode=yes"]
            argv.append(alias)
        }

        argv.append("exit 0")
        return argv
    }

    /// Environment to inject when askpass plumbing is needed; empty otherwise.
    static func probeEnv(askpass: SSHCommandBuilder.AskpassEnv?) -> [String: String] {
        guard let askpass else { return [:] }
        return [
            "SSH_ASKPASS": askpass.helperPath,
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": ":0",
            "QUAY_ASKPASS_SOCKET": askpass.socketPath,
        ]
    }

    /// Runs the probe. Respects Swift Task cancellation; wall-clock cap is 15s.
    ///
    /// @MainActor mirrors the real connection path (TerminalTabItem.connect →
    /// SessionBootstrap.start) so AskpassServer is created with the same actor
    /// context, allowing the Security framework to present 1Password's unlock
    /// dialog on the main thread when the Keychain item requires user interaction.
    @MainActor
    static func run(target: SSHTarget) async -> Outcome {
        var server: AskpassServer?
        var askpassEnv: SSHCommandBuilder.AskpassEnv?

        if let secretURI = SessionBootstrap.secretRef(for: target) {
            guard let helperPath = SessionBootstrap.bundledHelperPath() else {
                return .failure(message: "quay-askpass helper not found in bundle.", exitCode: nil)
            }
            let s = AskpassServer(secretURI: secretURI)
            do {
                try s.start()
            } catch {
                return .failure(message: "Askpass server failed to start: \(error)", exitCode: nil)
            }
            server = s
            askpassEnv = .init(helperPath: helperPath, socketPath: s.socketPath)
        }
        defer { server?.stop() }

        let argv = probeArgv(for: target)
        let env  = probeEnv(askpass: askpassEnv)
        let inner = argv.map(probeShellQuote).joined(separator: " ")
        let cmd   = SessionBootstrap.wrapInLoginShell(inner, askpassEnv: env)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", cmd]
        process.standardInput  = Pipe()
        process.standardOutput = Pipe()
        let errPipe = Pipe()
        process.standardError = errPipe

        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                let timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    guard !Task.isCancelled else { return }
                    process.terminate()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }

                process.terminationHandler = { p in
                    timeoutTask.cancel()
                    let stderr = String(
                        data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? ""
                    let outcome: Outcome
                    if p.terminationStatus == 0 {
                        outcome = .success
                    } else {
                        let msg = stderr
                            .components(separatedBy: .newlines)
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                            .joined(separator: "\n")
                        outcome = .failure(
                            message: msg.isEmpty ? "ssh exited \(p.terminationStatus)" : msg,
                            exitCode: p.terminationStatus
                        )
                    }
                    cont.resume(returning: outcome)
                }

                do {
                    try process.run()
                } catch {
                    timeoutTask.cancel()
                    cont.resume(returning: .failure(message: "Failed to launch ssh: \(error)", exitCode: nil))
                }
            }
        } onCancel: {
            process.terminate()
        }
    }

    private static func hostFlags(_ target: SSHTarget) -> [String] {
        var out: [String] = []
        if let port = target.port {
            out += ["-p", String(port)]
        }
        let userPrefix = target.username.map { "\($0)@" } ?? ""
        out.append("\(userPrefix)\(target.hostname)")
        return out
    }
}

@inline(__always)
private func probeShellQuote(_ arg: String) -> String {
    let safe = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyz" +
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ" +
        "0123456789" +
        "@%+=:,./-_"
    )
    if !arg.isEmpty, arg.unicodeScalars.allSatisfy({ safe.contains($0) }) {
        return arg
    }
    return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
