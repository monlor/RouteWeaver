import Foundation

public enum RoutingConfigurationError: LocalizedError, Equatable {
    case invalidInterface(String)
    case duplicateUplink
    case invalidSubscription(String)
    case invalidPattern(String)
    case ambiguousEntryPattern
    case invalidPort(String)
    case invalidController

    public var errorDescription: String? {
        switch self {
        case .invalidInterface(let field):
            return "\(field)：请选择有效的 macOS 网络接口（例如 en0）。"
        case .duplicateUplink:
            return "双网卡配置必须选择两个不同的接口；如要共用一个接口，请选择单网卡模板。"
        case .invalidSubscription(let field):
            return "\(field)：请输入 HTTPS 的 Mihomo 节点订阅地址。"
        case .invalidPattern(let field):
            return "\(field)：正则表达式无效，或包含不支持的反引号、控制字符。"
        case .ambiguousEntryPattern:
            return "入口 L 与 A/B 共用订阅时，请为 L 设置专用的非空正则，不能与 A 或 B 的正则完全相同。"
        case .invalidPort(let field):
            return "\(field)：请输入 1024–65535 范围内、不与其他端口重复的端口。"
        case .invalidController:
            return "控制接口必须同时提供端口和非空密钥。"
        }
    }
}

public enum MihomoConfig {
    public static let minimumVersion = "1.19.27"
    public static let claudeOutbound = "Claude-Interface"
    public static let domesticOutbound = "Domestic-Interface"
    public static let entryGroup = "Entry-L"
    public static let groupA = "Group-A"
    public static let groupB = "Group-B"
    public static let providerL = "entry-l"
    public static let providerA = "exit-a"
    public static let providerB = "exit-b"
    public static let healthCheckURL = "https://www.gstatic.com/generate_204"

    /// Older engines ignore the fail-closed `empty-fallback` policy.
    public static func supportsVersionOutput(_ output: String) -> Bool {
        for line in output.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace)
            guard words.count > 2, words[0] == "Mihomo", words[1] == "Meta" else { continue }
            let token = words[2]
            let clean = token.hasPrefix("v") ? token.dropFirst() : token
            let pieces = clean.split(separator: ".", omittingEmptySubsequences: false)
            guard pieces.count == 3,
                  pieces.allSatisfy({ piece in
                      !piece.isEmpty && piece.utf8.allSatisfy { (48...57).contains($0) }
                  }) else { return false }
            let version = pieces.compactMap { Int($0) }
            return version.count == 3 && !version.lexicographicallyPrecedes([1, 19, 27])
        }
        return false
    }

    /// JSON uses YAML 1.2 flow syntax. The core's own config check is authoritative
    /// for its supported syntax and data files.
    public static func render(
        _ profile: RoutingProfile,
        controllerPort: Int? = nil,
        secret: String? = nil
    ) throws -> Data {
        let claudeInterface = try checkedInterface(profile.effectiveClaudeInterface, field: "Claude 出口")
        let domesticInterface = try checkedInterface(profile.domesticInterface, field: "国内出口")
        if !profile.useDomesticInterfaceForClaude, claudeInterface == domesticInterface {
            throw RoutingConfigurationError.duplicateUplink
        }
        let exitURL = try checkedURL(profile.exitProviderURL, field: "出口 A/B 订阅")
        let sharesExitProvider = profile.entryProviderURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let entryURL = sharesExitProvider
            ? exitURL
            : try checkedURL(profile.entryProviderURL, field: "入口 L 订阅")
        let entryPattern = try checkedPattern(profile.entryPattern, field: "入口 L")
        let groupAPattern = try checkedPattern(profile.groupAPattern, field: "节点组 A")
        let groupBPattern = try checkedPattern(profile.groupBPattern, field: "节点组 B")
        if entryURL == exitURL, entryPattern.isEmpty || entryPattern == groupAPattern || entryPattern == groupBPattern {
            throw RoutingConfigurationError.ambiguousEntryPattern
        }
        guard (1024...65535).contains(profile.mixedPort) else {
            throw RoutingConfigurationError.invalidPort("本地代理端口")
        }

        var config: [String: Any] = [
            "mode": "rule",
            "mixed-port": profile.mixedPort,
            "allow-lan": false,
            "bind-address": "127.0.0.1",
            "log-level": "warning",
            "ipv6": true,
            "find-process-mode": "off",
            "tun": ["enable": false],
            "profile": ["store-selected": true],
            "proxies": [
                direct(claudeOutbound, interface: claudeInterface),
                direct(domesticOutbound, interface: domesticInterface),
            ],
            "proxy-providers": [
                providerL: provider(
                    url: entryURL, key: providerL, pattern: entryPattern, prefix: "L · ",
                    dialer: "", interface: domesticInterface, automatic: profile.entryAutoTest
                ),
                providerA: provider(
                    url: exitURL, key: providerA, pattern: groupAPattern, prefix: "A · ",
                    dialer: entryGroup, automatic: profile.groupAAutoTest
                ),
                providerB: provider(
                    url: exitURL, key: providerB, pattern: groupBPattern, prefix: "B · ",
                    dialer: entryGroup, automatic: profile.groupBAutoTest
                ),
            ],
            "proxy-groups": [
                group(entryGroup, provider: providerL, automatic: profile.entryAutoTest),
                group(groupA, provider: providerA, automatic: profile.groupAAutoTest),
                group(groupB, provider: providerB, automatic: profile.groupBAutoTest),
            ],
            "rules": rules(socialGroup: profile.socialUsesGroupB ? groupB : groupA),
        ]

        switch (controllerPort, secret) {
        case (nil, nil): break
        case let (.some(port), .some(key)):
            guard (1024...65535).contains(port), port != profile.mixedPort else {
                throw RoutingConfigurationError.invalidPort("控制端口")
            }
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw RoutingConfigurationError.invalidController
            }
            config["external-controller"] = "127.0.0.1:\(port)"
            config["secret"] = key
        default: throw RoutingConfigurationError.invalidController
        }

        return try JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func checkedInterface(_ raw: String, field: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Darwin interface names fit IFNAMSIZ (16 bytes including the terminator).
        guard let range = value.range(of: #"^[A-Za-z][A-Za-z0-9_.-]{0,14}$"#, options: .regularExpression),
              range == value.startIndex..<value.endIndex, value != "lo0", !value.hasPrefix("utun") else {
            throw RoutingConfigurationError.invalidInterface(field)
        }
        return value
    }

    private static func checkedURL(_ raw: String, field: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.fragment == nil, parts.port.map({ (1...65535).contains($0) }) ?? true,
              let url = parts.url else {
            throw RoutingConfigurationError.invalidSubscription(field)
        }
        return url.absoluteString
    }

    private static func checkedPattern(_ raw: String, field: String) throws -> String {
        let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pattern.utf8.count <= 1_024, !pattern.contains("`"),
              !pattern.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              pattern.isEmpty || (try? NSRegularExpression(pattern: pattern)) != nil else {
            throw RoutingConfigurationError.invalidPattern(field)
        }
        return pattern
    }

    private static func direct(_ name: String, interface: String) -> [String: Any] {
        ["name": name, "type": "direct", "udp": true, "interface-name": interface]
    }

    private static func provider(
        url: String, key: String, pattern: String, prefix: String, dialer: String,
        interface: String? = nil, automatic: Bool
    ) -> [String: Any] {
        var override = ["dialer-proxy": dialer, "additional-prefix": prefix]
        if let interface { override["interface-name"] = interface }
        var data: [String: Any] = [
            "type": "http",
            "url": url,
            "path": "./providers/\(key)-\(cacheIdentifier(url, pattern)).yaml",
            "interval": 3600,
            "proxy": domesticOutbound,
            "size-limit": 5_242_880,
            "exclude-type": "direct|reject|reject-drop|pass|compatible",
            "override": override,
            "health-check": [
                "enable": automatic,
                "url": healthCheckURL,
                "interval": 300,
                "timeout": 5_000,
                "lazy": false,
                "expected-status": "204",
            ],
        ]
        if !pattern.isEmpty { data["filter"] = pattern }
        return data
    }

    // The stable, private cache key partitions different subscriptions and regex edits.
    // This is a non-secret identifier, not a credential hash or an authorization boundary.
    private static func cacheIdentifier(_ url: String, _ pattern: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in (url + "\u{0}" + pattern).utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private static func group(_ name: String, provider: String, automatic: Bool) -> [String: Any] {
        var data: [String: Any] = [
            "name": name,
            "type": automatic ? "url-test" : "select",
            "use": [provider],
            "empty-fallback": "REJECT",
        ]
        if automatic {
            data["url"] = healthCheckURL
            data["interval"] = 300
            data["tolerance"] = 50
            data["lazy"] = false
            data["expected-status"] = "204"
        }
        return data
    }

    private static func rules(socialGroup: String) -> [String] {
        let claude = [
            "claude.ai", "claude.com", "anthropic.com", "anthropic.ai",
            "claudeusercontent.com",
        ]
        let social = [
            "x.com", "twitter.com", "t.co", "twimg.com",
            "facebook.com", "facebook.net", "fbcdn.net", "fb.com", "messenger.com", "m.me",
            "instagram.com", "cdninstagram.com", "threads.net", "threads.com",
            "whatsapp.com", "whatsapp.net", "wa.me",
            "telegram.org", "telegram.me", "t.me", "telegra.ph", "telesco.pe",
            "reddit.com", "redd.it", "redditmedia.com", "redditstatic.com",
            "discord.com", "discord.gg", "discordapp.com", "discordapp.net",
            "linkedin.com", "licdn.com", "tiktok.com", "tiktokcdn.com", "tiktokv.com", "byteoversea.com",
            "bsky.app", "bsky.network", "bsky.social",
        ]
        let local = [
            "IP-CIDR,127.0.0.0/8", "IP-CIDR,10.0.0.0/8", "IP-CIDR,172.16.0.0/12",
            "IP-CIDR,192.168.0.0/16", "IP-CIDR,169.254.0.0/16", "IP-CIDR6,::1/128",
            "IP-CIDR6,fc00::/7", "IP-CIDR6,fe80::/10",
        ]
        return claude.map { "DOMAIN-SUFFIX,\($0),\(claudeOutbound)" }
            + ["GEOSITE,google,\(groupA)", "GEOSITE,youtube,\(groupA)"]
            + social.map { "DOMAIN-SUFFIX,\($0),\(socialGroup)" }
            + ["DOMAIN,localhost,\(domesticOutbound)", "DOMAIN-SUFFIX,local,\(domesticOutbound)"]
            + local.map { "\($0),\(domesticOutbound),no-resolve" }
            + ["GEOSITE,cn,\(domesticOutbound)", "DOMAIN-SUFFIX,cn,\(domesticOutbound)",
               "GEOIP,CN,\(domesticOutbound)", "MATCH,\(groupB)"]
    }
}
