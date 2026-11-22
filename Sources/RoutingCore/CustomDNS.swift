import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum CustomDNSEntryKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case host
    case server

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .host: return "Host 映射"
        case .server: return "DNS 服务器"
        }
    }

    public var shortLabel: String {
        switch self {
        case .host: return "Host"
        case .server: return "Server"
        }
    }
}

public struct CustomDNSEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Exact domain or Mihomo wildcard pattern (e.g. `nas.local`, `*.corp.local`, `+.example.com`, `.internal`).
    public var pattern: String
    public var kind: CustomDNSEntryKind
    /// For `.host`: IP(s) or CNAME (comma-separated for multiple IPs).
    /// For `.server`: DNS server URL(s) / IP(s) (comma-separated, e.g. `10.0.0.53` or `https://dns.alidns.com/dns-query`).
    public var value: String
    /// Optional outbound network target for `.server` queries (appends `#<targetName>` when server has no explicit `#`).
    public var targetID: UUID?
    /// When TUN Fake-IP mode is active, append `pattern` to `dns.fake-ip-filter` so clients receive real IPs.
    public var bypassFakeIP: Bool
    public var note: String
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        pattern: String,
        kind: CustomDNSEntryKind,
        value: String,
        targetID: UUID? = nil,
        bypassFakeIP: Bool = false,
        note: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.pattern = pattern
        self.kind = kind
        self.value = value
        self.targetID = targetID
        self.bypassFakeIP = bypassFakeIP
        self.note = note
        self.isEnabled = isEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        pattern = try c.decode(String.self, forKey: .pattern)
        kind = try c.decode(CustomDNSEntryKind.self, forKey: .kind)
        value = try c.decode(String.self, forKey: .value)
        targetID = try c.decodeIfPresent(UUID.self, forKey: .targetID)
        bypassFakeIP = try c.decodeIfPresent(Bool.self, forKey: .bypassFakeIP) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    public var trimmedPattern: String {
        pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isWildcard: Bool {
        let p = trimmedPattern
        return p.contains("*") || p.hasPrefix("+.") || p.hasPrefix(".")
    }

    public var splitValues: [String] {
        value
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

public struct CustomDNSConfig: Codable, Equatable, Sendable {
    public var entries: [CustomDNSEntry]
    /// Optional custom direct upstream DNS servers (empty = automatic interface/system + domestic IP fallbacks).
    public var directServers: [String]
    /// Optional custom bootstrap DNS servers for `default-nameserver` and `proxy-server-nameserver` (empty = automatic).
    public var bootstrapServers: [String]

    public init(
        entries: [CustomDNSEntry] = [],
        directServers: [String] = [],
        bootstrapServers: [String] = []
    ) {
        self.entries = entries
        self.directServers = directServers
        self.bootstrapServers = bootstrapServers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([CustomDNSEntry].self, forKey: .entries) ?? []
        directServers = try c.decodeIfPresent([String].self, forKey: .directServers) ?? []
        bootstrapServers = try c.decodeIfPresent([String].self, forKey: .bootstrapServers) ?? []
    }

    public var isEmpty: Bool {
        entries.isEmpty && directServers.isEmpty && bootstrapServers.isEmpty
    }

    public var enabledEntries: [CustomDNSEntry] {
        entries.filter(\.isEnabled)
    }
}

public enum CustomDNSValidator {
    /// Validates a domain or Mihomo wildcard host pattern.
    /// Supports exact domains (`nas.local`), single-level wildcards (`*.example.com`, `time.*.com`),
    /// multi-level wildcards (`+.example.com`, `.example.com`), and for `allowPolicyPrefix` also `geosite:` / `rule-set:`.
    public static func isValidPattern(_ raw: String, allowPolicyPrefix: Bool = false) -> Bool {
        let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty,
              !pattern.contains(","),
              !pattern.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              !pattern.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return false
        }

        let lower = pattern.lowercased()
        if allowPolicyPrefix, (lower.hasPrefix("geosite:") || lower.hasPrefix("rule-set:")) {
            let suffix = pattern.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            return !suffix.isEmpty
        }

        // Reject bare wildcards without any domain label.
        if pattern == "*" || pattern == "+" || pattern == "." || pattern == "+." || pattern == "*." {
            return false
        }
        if pattern.hasPrefix("+.") {
            let rest = String(pattern.dropFirst(2))
            return !rest.isEmpty && !rest.hasPrefix(".") && !rest.hasSuffix(".")
        }
        if pattern.hasPrefix(".") {
            let rest = String(pattern.dropFirst())
            return !rest.isEmpty && !rest.hasPrefix(".") && !rest.hasSuffix(".")
        }
        return !pattern.hasSuffix(".")
    }

    /// Validates a single Mihomo DNS server specification.
    /// Accepts `system`, `dhcp://...`, `rcode://...`, IP / IP:port, or `udp://`, `tcp://`, `tls://`, `https://`, `quic://`, `h3://` URLs
    /// (with optional `#outbound` suffix).
    public static func isValidServer(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(","),
              !trimmed.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return false
        }

        let base = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? trimmed
        guard !base.isEmpty else { return false }

        let lower = base.lowercased()
        if lower == "system" {
            return true
        }
        let allowedSchemes = ["udp://", "tcp://", "tls://", "https://", "http://", "quic://", "h3://", "dhcp://", "rcode://"]
        if let scheme = allowedSchemes.first(where: { lower.hasPrefix($0) }) {
            let rest = String(base.dropFirst(scheme.count))
            return !rest.isEmpty
        }
        if base.contains("://") {
            return false
        }
        return isValidIPOrHostPort(base)
    }

    /// Validates a single Host target value (IPv4, IPv6, or CNAME hostname).
    public static func isValidHostTarget(_ raw: String, forPattern pattern: String) -> Bool {
        let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty,
              !target.contains(","),
              !target.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              !target.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              target.caseInsensitiveCompare(pattern.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame else {
            return false
        }
        return true
    }

    public static func isIPAddress(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return false }
        var addr4 = in_addr()
        if s.withCString({ inet_pton(AF_INET, $0, &addr4) }) == 1 {
            return true
        }
        var addr6 = in6_addr()
        if s.withCString({ inet_pton(AF_INET6, $0, &addr6) }) == 1 {
            return true
        }
        return false
    }

    private static func isValidIPOrHostPort(_ value: String) -> Bool {
        // Bracketed IPv6 with optional port: `[2001:4860:4860::8888]:53`
        if value.hasPrefix("[") {
            guard let closeIdx = value.firstIndex(of: "]") else { return false }
            let ipPart = String(value[value.index(after: value.startIndex)..<closeIdx])
            guard !ipPart.isEmpty, ipPart.contains(":") else { return false }
            let remainder = value[value.index(after: closeIdx)...]
            if remainder.isEmpty { return true }
            guard remainder.hasPrefix(":"),
                  let port = Int(remainder.dropFirst()),
                  (1...65535).contains(port) else { return false }
            return true
        }
        // Bare IPv6 address (contains multiple colons)
        let colonCount = value.filter { $0 == ":" }.count
        if colonCount >= 2 {
            return value.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }
        // IPv4 / hostname with optional :port
        if colonCount == 1 {
            let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  !parts[0].isEmpty,
                  let port = Int(parts[1]),
                  (1...65535).contains(port) else { return false }
            return true
        }
        return !value.isEmpty
    }
}

public enum CustomDNSParser {
    /// Parses bulk text into `CustomDNSEntry` items.
    /// Supports:
    /// - Surge `[Host]` style:
    ///   - `*.corp.local = server:10.0.0.53`
    ///   - `+.company.com = server:https://dns.corp.com/dns-query`
    ///   - `*.dev.local = 127.0.0.1`
    ///   - `multi.local = 10.0.0.1, 10.0.0.2`
    /// - Standard `/etc/hosts` style:
    ///   - `192.168.1.10 nas.local *.nas.local`
    public static func parseBulk(_ text: String) -> [CustomDNSEntry] {
        var entries: [CustomDNSEntry] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("#"),
                  !trimmed.hasPrefix(";"),
                  !trimmed.hasPrefix("//"),
                  !(trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) else {
                continue
            }

            // Strip inline `# comment` when preceded by whitespace
            let line: String
            if let range = trimmed.range(of: " #") {
                line = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                line = trimmed
            }
            guard !line.isEmpty else { continue }

            if let eqIndex = line.firstIndex(of: "=") {
                let lhs = line[..<eqIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                let rhs = line[line.index(after: eqIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !lhs.isEmpty, !rhs.isEmpty else { continue }

                let lowerRHS = rhs.lowercased()
                if lowerRHS.hasPrefix("script:") {
                    continue
                }
                if lowerRHS.hasPrefix("server:") {
                    let serverSpec = String(rhs.dropFirst("server:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard CustomDNSValidator.isValidPattern(lhs, allowPolicyPrefix: true),
                          !serverSpec.isEmpty else { continue }
                    let servers = serverSpec
                        .split(separator: ",", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    guard !servers.isEmpty, servers.allSatisfy(CustomDNSValidator.isValidServer) else { continue }
                    entries.append(
                        CustomDNSEntry(
                            pattern: lhs,
                            kind: .server,
                            value: servers.joined(separator: ", ")
                        )
                    )
                } else if lowerRHS == "system" {
                    guard CustomDNSValidator.isValidPattern(lhs, allowPolicyPrefix: true) else { continue }
                    entries.append(
                        CustomDNSEntry(
                            pattern: lhs,
                            kind: .server,
                            value: "system"
                        )
                    )
                } else {
                    guard CustomDNSValidator.isValidPattern(lhs, allowPolicyPrefix: false) else { continue }
                    let targets = rhs
                        .split(separator: ",", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    guard !targets.isEmpty,
                          targets.allSatisfy({ CustomDNSValidator.isValidHostTarget($0, forPattern: lhs) }) else {
                        continue
                    }
                    entries.append(
                        CustomDNSEntry(
                            pattern: lhs,
                            kind: .host,
                            value: targets.joined(separator: ", ")
                        )
                    )
                }
            } else {
                // Whitespace-separated formats:
                // 1) Standard `/etc/hosts`: `<ip> <host1> [host2 ...]`
                // 2) Host-first shorthand:  `<host> <ip/cname/server:...>` (e.g. `media.home.arpa 192.168.1.20`)
                let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard tokens.count >= 2 else { continue }
                if CustomDNSValidator.isIPAddress(tokens[0]) {
                    let targetIP = tokens[0]
                    for hostToken in tokens.dropFirst() {
                        guard CustomDNSValidator.isValidPattern(hostToken, allowPolicyPrefix: false),
                              CustomDNSValidator.isValidHostTarget(targetIP, forPattern: hostToken) else {
                            continue
                        }
                        entries.append(
                            CustomDNSEntry(
                                pattern: hostToken,
                                kind: .host,
                                value: targetIP
                            )
                        )
                    }
                } else {
                    let lhs = tokens[0].hasSuffix(":") ? String(tokens[0].dropLast()) : tokens[0]
                    let rhsJoined = tokens.dropFirst().joined(separator: " ")
                    let lowerRHS = rhsJoined.lowercased()
                    if lowerRHS.hasPrefix("script:") {
                        continue
                    }
                    if lowerRHS.hasPrefix("server:") {
                        let serverSpec = String(rhsJoined.dropFirst("server:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard CustomDNSValidator.isValidPattern(lhs, allowPolicyPrefix: true),
                              !serverSpec.isEmpty else { continue }
                        let servers = serverSpec
                            .split { $0 == "," || $0.isWhitespace }
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        guard !servers.isEmpty, servers.allSatisfy(CustomDNSValidator.isValidServer) else { continue }
                        entries.append(
                            CustomDNSEntry(
                                pattern: lhs,
                                kind: .server,
                                value: servers.joined(separator: ", ")
                            )
                        )
                    } else if lowerRHS == "system" {
                        guard CustomDNSValidator.isValidPattern(lhs, allowPolicyPrefix: true) else { continue }
                        entries.append(
                            CustomDNSEntry(
                                pattern: lhs,
                                kind: .server,
                                value: "system"
                            )
                        )
                    } else {
                        guard CustomDNSValidator.isValidPattern(lhs, allowPolicyPrefix: false) else { continue }
                        let targets = rhsJoined
                            .split { $0 == "," || $0.isWhitespace }
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        guard !targets.isEmpty,
                              targets.allSatisfy({ CustomDNSValidator.isValidHostTarget($0, forPattern: lhs) }) else {
                            continue
                        }
                        entries.append(
                            CustomDNSEntry(
                                pattern: lhs,
                                kind: .host,
                                value: targets.joined(separator: ", ")
                            )
                        )
                    }
                }
            }
        }

        return entries
    }

    /// Splits a comma- or newline-separated list of DNS servers.
    public static func parseServerList(_ text: String) -> [String] {
        text
            .split { $0 == "," || $0.isNewline }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
