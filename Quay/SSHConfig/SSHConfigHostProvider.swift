import Darwin
import Foundation

struct DiscoveredSSHHost: Identifiable, Equatable, Sendable {
    var id: UUID
    var alias: String
    var displayName: String
    var sourceFile: String
    var lineNumber: Int?

    init(
        alias: String,
        sourceFile: String,
        lineNumber: Int? = nil
    ) {
        self.id = Self.stableID(for: alias)
        self.alias = alias
        self.displayName = alias
        self.sourceFile = sourceFile
        self.lineNumber = lineNumber
    }

    private static func stableID(for alias: String) -> UUID {
        let bytes = Array("ssh-config:\(alias.lowercased())".utf8)
        let first = fnv64(bytes, seed: 0xcbf29ce484222325)
        let second = fnv64(bytes, seed: 0x84222325cbf29ce4)
        var uuid = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: first.bigEndian) { buffer in
            for index in 0..<8 { uuid[index] = buffer[index] }
        }
        withUnsafeBytes(of: second.bigEndian) { buffer in
            for index in 0..<8 { uuid[index + 8] = buffer[index] }
        }
        uuid[6] = (uuid[6] & 0x0f) | 0x50
        uuid[8] = (uuid[8] & 0x3f) | 0x80
        return UUID(uuid: (
            uuid[0], uuid[1], uuid[2], uuid[3],
            uuid[4], uuid[5], uuid[6], uuid[7],
            uuid[8], uuid[9], uuid[10], uuid[11],
            uuid[12], uuid[13], uuid[14], uuid[15]
        ))
    }

    private static func fnv64(_ bytes: [UInt8], seed: UInt64) -> UInt64 {
        var hash = seed
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x00000100000001b3
        }
        return hash
    }
}

enum SSHConfigHostProvider {
    static func loadHosts(
        rootConfigURL: URL = defaultConfigURL(),
        fileManager: FileManager = .default
    ) -> [DiscoveredSSHHost] {
        var parser = SSHConfigParser(fileManager: fileManager)
        return parser.parse(rootConfigURL)
    }

    private static func defaultConfigURL() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: ".ssh")
            .appending(path: "config")
    }
}

private struct SSHConfigParser {
    var fileManager: FileManager
    var visitedFiles: Set<String> = []
    var seenAliases: Set<String> = []
    var hosts: [DiscoveredSSHHost] = []

    mutating func parse(_ rootConfigURL: URL) -> [DiscoveredSSHHost] {
        parseFile(rootConfigURL)
        return hosts.sorted { lhs, rhs in
            lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    private mutating func parseFile(_ url: URL) {
        let standardized = url.standardizedFileURL
        let key = standardized.path
        guard !visitedFiles.contains(key),
              fileManager.isReadableFile(atPath: key),
              let contents = try? String(contentsOf: standardized, encoding: .utf8)
        else { return }

        visitedFiles.insert(key)
        let baseURL = standardized.deletingLastPathComponent()

        for (offset, rawLine) in contents.components(separatedBy: .newlines).enumerated() {
            let lineNumber = offset + 1
            let tokens = tokenize(stripComment(from: rawLine))
            guard let keyword = tokens.first?.lowercased() else { continue }

            switch keyword {
            case "host":
                for alias in tokens.dropFirst() where isConcreteHostAlias(alias) {
                    let normalized = alias.lowercased()
                    guard !seenAliases.contains(normalized) else { continue }
                    seenAliases.insert(normalized)
                    hosts.append(
                        DiscoveredSSHHost(
                            alias: alias,
                            sourceFile: key,
                            lineNumber: lineNumber
                        )
                    )
                }
            case "include":
                for pattern in tokens.dropFirst() {
                    for includeURL in resolveInclude(pattern, relativeTo: baseURL) {
                        parseFile(includeURL)
                    }
                }
            default:
                continue
            }
        }
    }

    private func resolveInclude(_ pattern: String, relativeTo baseURL: URL) -> [URL] {
        let expanded = expandTilde(pattern)
        let path: String
        if expanded.hasPrefix("/") {
            path = expanded
        } else {
            path = baseURL.appending(path: expanded).path
        }

        let matches = globPaths(path)
        if matches.isEmpty {
            return [URL(fileURLWithPath: path)]
        }
        return matches.map { URL(fileURLWithPath: $0) }
    }

    private func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let home = fileManager.homeDirectoryForCurrentUser.path
        if path == "~" { return home }
        return home + String(path.dropFirst())
    }

    private func globPaths(_ pattern: String) -> [String] {
        var results = glob_t()
        defer { globfree(&results) }
        guard glob(pattern, GLOB_TILDE, nil, &results) == 0,
              let glPathv = results.gl_pathv
        else { return [] }

        var paths: [String] = []
        for index in 0..<Int(results.gl_pathc) {
            guard let cPath = glPathv[index] else { continue }
            paths.append(String(cString: cPath))
        }
        return paths.sorted()
    }

    private func stripComment(from line: String) -> String {
        var output = ""
        var quote: Character?
        var previousWasEscape = false

        for character in line {
            if previousWasEscape {
                output.append(character)
                previousWasEscape = false
                continue
            }
            if character == "\\" {
                output.append(character)
                previousWasEscape = true
                continue
            }
            if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
                output.append(character)
                continue
            }
            if character == "#", quote == nil {
                break
            }
            output.append(character)
        }

        return output
    }

    private func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var previousWasEscape = false

        for character in line {
            if previousWasEscape {
                current.append(character)
                previousWasEscape = false
                continue
            }
            if character == "\\" {
                previousWasEscape = true
                continue
            }
            if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                } else {
                    current.append(character)
                }
                continue
            }
            if character.isWhitespace, quote == nil {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private func isConcreteHostAlias(_ alias: String) -> Bool {
        guard !alias.isEmpty, !alias.hasPrefix("!") else { return false }
        return !alias.contains("*") && !alias.contains("?")
    }
}
