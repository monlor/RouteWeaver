import Darwin
import Foundation

public enum RuleType: String, Codable, CaseIterable, Identifiable, Sendable {
    case domainSuffix = "DOMAIN-SUFFIX"
    case domain = "DOMAIN"
    case domainKeyword = "DOMAIN-KEYWORD"
    case processName = "PROCESS-NAME"
    case processPath = "PROCESS-PATH"
    case srcIPCIDR = "SRC-IP-CIDR"
    case ipCIDR = "IP-CIDR"
    case ipCIDR6 = "IP-CIDR6"
    case dstPort = "DST-PORT"
    case geosite = "GEOSITE"
    case geoip = "GEOIP"
    case ruleSet = "RULE-SET"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .domainSuffix: return "域名后缀 (DOMAIN-SUFFIX)"
        case .domain: return "完整域名 (DOMAIN)"
        case .domainKeyword: return "域名关键词 (DOMAIN-KEYWORD)"
        case .processName: return "应用 / 进程名 (PROCESS-NAME)"
        case .processPath: return "进程路径 (PROCESS-PATH)"
        case .srcIPCIDR: return "源设备 IP / 网段 (SRC-IP-CIDR)"
        case .ipCIDR: return "IPv4 网段 (IP-CIDR)"
        case .ipCIDR6: return "IPv6 网段 (IP-CIDR6)"
        case .dstPort: return "目标端口 (DST-PORT)"
        case .geosite: return "GeoSite 集合 (GEOSITE)"
        case .geoip: return "GeoIP 地区 (GEOIP)"
        case .ruleSet: return "远程规则集 (RULE-SET)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .domainSuffix: return "域名后缀"
        case .domain: return "精确域名"
        case .domainKeyword: return "关键词"
        case .processName: return "进程/应用"
        case .processPath: return "进程路径"
        case .srcIPCIDR: return "源设备"
        case .ipCIDR: return "IPv4"
        case .ipCIDR6: return "IPv6"
        case .dstPort: return "端口"
        case .geosite: return "GeoSite"
        case .geoip: return "GeoIP"
        case .ruleSet: return "规则集"
        }
    }

    public var placeholder: String {
        switch self {
        case .domainSuffix: return "例如 openai.com"
        case .domain: return "例如 api.example.com"
        case .domainKeyword: return "例如 claude"
        case .processName: return "例如 Claude 或 curl"
        case .processPath: return "例如 /Applications/Claude.app/Contents/MacOS/Claude"
        case .srcIPCIDR: return "例如 192.168.1.55 或 192.168.1.0/24"
        case .ipCIDR: return "例如 192.168.1.0/24"
        case .ipCIDR6: return "例如 fc00::/7"
        case .dstPort: return "例如 22"
        case .geosite: return "例如 google"
        case .geoip: return "例如 CN"
        case .ruleSet: return "https://.../*.list 或 *.yaml"
        }
    }

    public var needsNoResolve: Bool {
        self == .ipCIDR || self == .ipCIDR6
    }

    public var isProcessRule: Bool {
        self == .processName || self == .processPath
    }

    public var allowsSpaces: Bool {
        isProcessRule
    }
}

public enum ClientAddressValidator {
    /// Validates and normalizes an IPv4/IPv6 address or CIDR prefix into Mihomo `SRC-IP-CIDR` format.
    /// Examples: `192.168.1.55` -> `192.168.1.55/32`, `192.168.1.0/24` -> `192.168.1.0/24`, `fd00::1` -> `fd00::1/128`.
    public static func normalizedCIDR(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(","),
              !trimmed.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }

        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        let ipPart = String(parts[0])
        let prefixPart = parts.count == 2 ? String(parts[1]) : nil

        var ipv4Addr = in_addr()
        if inet_pton(AF_INET, ipPart, &ipv4Addr) == 1 {
            if let prefixPart {
                guard let prefix = Int(prefixPart), (0...32).contains(prefix), String(prefix) == prefixPart else {
                    return nil
                }
                return "\(ipPart)/\(prefix)"
            }
            return "\(ipPart)/32"
        }

        var ipv6Addr = in6_addr()
        if inet_pton(AF_INET6, ipPart, &ipv6Addr) == 1 {
            if let prefixPart {
                guard let prefix = Int(prefixPart), (0...128).contains(prefix), String(prefix) == prefixPart else {
                    return nil
                }
                return "\(ipPart)/\(prefix)"
            }
            return "\(ipPart)/128"
        }

        return nil
    }
}

public enum RuleSetFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case text
    case yaml
    case mrs

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "自动识别"
        case .text: return "Text (.list / .ini / .txt)"
        case .yaml: return "YAML (.yaml / .yml)"
        case .mrs: return "MRS 二进制 (.mrs)"
        }
    }
}

public enum RuleSetBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case classical
    case domain
    case ipcidr

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "自动识别"
        case .classical: return "Classical（混合规则）"
        case .domain: return "Domain（纯域名）"
        case .ipcidr: return "IP-CIDR（纯 IP 段）"
        }
    }
}

public struct ResolvedRuleSetMetadata: Equatable, Sendable {
    public let format: String
    public let behavior: String
    public let fileExt: String
    public let isAmbiguous: Bool
    public let hint: String?
}

public enum RuleSetResolver {
    private static let ipTokens: Set<String> = [
        "ip", "ips", "geoip", "ipcidr", "cidr", "ipv4", "ipv6", "cnip", "cncidr", "asn"
    ]
    private static let domainTokens: Set<String> = [
        "domain", "domains", "geosite", "site", "sites"
    ]

    public static func resolve(
        url: String,
        format explicitFormat: RuleSetFormat?,
        behavior explicitBehavior: RuleSetBehavior?
    ) throws -> ResolvedRuleSetMetadata {
        let lowerPath = URLComponents(string: url)?.path.lowercased() ?? url.lowercased()
        let fileName = (lowerPath as NSString).lastPathComponent
        let stem = (fileName as NSString).deletingPathExtension
        let pathSegments = Set(lowerPath.split(separator: "/").map(String.init))
        let stemTokens = Set(stem.split { $0 == "-" || $0 == "_" || $0 == "." }.map(String.init))

        // 1. Resolve format
        let effectiveFormat: RuleSetFormat
        if let explicitFormat, explicitFormat != .auto {
            effectiveFormat = explicitFormat
        } else if lowerPath.hasSuffix(".mrs") {
            effectiveFormat = .mrs
        } else if lowerPath.hasSuffix(".yaml") || lowerPath.hasSuffix(".yml") {
            effectiveFormat = .yaml
        } else {
            effectiveFormat = .text
        }

        let formatStr: String
        let fileExt: String
        switch effectiveFormat {
        case .mrs:
            formatStr = "mrs"
            fileExt = "mrs"
        case .yaml:
            formatStr = "yaml"
            fileExt = "yaml"
        case .text, .auto:
            formatStr = "text"
            fileExt = "list"
        }

        // 2. Reject invalid MRS + classical combination explicitly
        if effectiveFormat == .mrs && explicitBehavior == .classical {
            throw RoutingConfigurationError.invalidRule("MRS 规则集仅支持 domain 或 ipcidr，不能设为 classical。")
        }

        // 3. Resolve behavior
        if let explicitBehavior, explicitBehavior != .auto {
            return ResolvedRuleSetMetadata(
                format: formatStr,
                behavior: explicitBehavior.rawValue,
                fileExt: fileExt,
                isAmbiguous: false,
                hint: nil
            )
        }

        let hasIPCue = !pathSegments.isDisjoint(with: ["geoip", "ipcidr", "ip"])
            || !stemTokens.isDisjoint(with: ipTokens)
        let hasDomainCue = !pathSegments.isDisjoint(with: ["geosite", "domain", "domains"])
            || !stemTokens.isDisjoint(with: domainTokens)

        switch effectiveFormat {
        case .mrs:
            if hasIPCue && !hasDomainCue {
                return ResolvedRuleSetMetadata(format: "mrs", behavior: "ipcidr", fileExt: "mrs", isAmbiguous: false, hint: nil)
            }
            if hasDomainCue && !hasIPCue {
                return ResolvedRuleSetMetadata(format: "mrs", behavior: "domain", fileExt: "mrs", isAmbiguous: false, hint: nil)
            }
            return ResolvedRuleSetMetadata(
                format: "mrs",
                behavior: "domain",
                fileExt: "mrs",
                isAmbiguous: true,
                hint: "无法从文件名确定 .mrs 是 domain 还是 ipcidr，当前默认按 domain 处理，如有误请在「高级设置」手动指定。"
            )

        case .yaml:
            if hasIPCue && !hasDomainCue {
                return ResolvedRuleSetMetadata(format: "yaml", behavior: "ipcidr", fileExt: "yaml", isAmbiguous: false, hint: nil)
            }
            if hasDomainCue && !hasIPCue {
                return ResolvedRuleSetMetadata(format: "yaml", behavior: "domain", fileExt: "yaml", isAmbiguous: false, hint: nil)
            }
            return ResolvedRuleSetMetadata(
                format: "yaml",
                behavior: "classical",
                fileExt: "yaml",
                isAmbiguous: true,
                hint: "YAML 规则集可能是 classical、domain 或 ipcidr，当前默认按 classical 处理，若不匹配请在「高级设置」手动指定。"
            )

        case .text, .auto:
            if hasIPCue && !hasDomainCue && !lowerPath.hasSuffix(".list") && !lowerPath.hasSuffix(".ini") {
                return ResolvedRuleSetMetadata(format: "text", behavior: "ipcidr", fileExt: "list", isAmbiguous: false, hint: nil)
            }
            if hasDomainCue && !hasIPCue && !lowerPath.hasSuffix(".list") && !lowerPath.hasSuffix(".ini") {
                return ResolvedRuleSetMetadata(format: "text", behavior: "domain", fileExt: "list", isAmbiguous: false, hint: nil)
            }
            return ResolvedRuleSetMetadata(format: "text", behavior: "classical", fileExt: "list", isAmbiguous: false, hint: nil)
        }
    }
}

public struct RuleItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var type: RuleType
    public var value: String
    public var note: String
    public var isEnabled: Bool
    /// Optional explicit metadata for `.ruleSet` rules (nil or `.auto` means auto-detect).
    public var ruleSetFormat: RuleSetFormat?
    public var ruleSetBehavior: RuleSetBehavior?
    public var ruleSetNoResolve: Bool?

    public init(
        id: UUID = UUID(),
        type: RuleType,
        value: String,
        note: String = "",
        isEnabled: Bool = true,
        ruleSetFormat: RuleSetFormat? = nil,
        ruleSetBehavior: RuleSetBehavior? = nil,
        ruleSetNoResolve: Bool? = nil
    ) {
        self.id = id
        self.type = type
        self.value = value
        self.note = note
        self.isEnabled = isEnabled
        self.ruleSetFormat = ruleSetFormat
        self.ruleSetBehavior = ruleSetBehavior
        self.ruleSetNoResolve = ruleSetNoResolve
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = try c.decode(RuleType.self, forKey: .type)
        value = try c.decode(String.self, forKey: .value)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        ruleSetFormat = try c.decodeIfPresent(RuleSetFormat.self, forKey: .ruleSetFormat)
        ruleSetBehavior = try c.decodeIfPresent(RuleSetBehavior.self, forKey: .ruleSetBehavior)
        ruleSetNoResolve = try c.decodeIfPresent(Bool.self, forKey: .ruleSetNoResolve)
    }

    public func formatted(target: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if type == .srcIPCIDR {
            let normalized = ClientAddressValidator.normalizedCIDR(clean) ?? clean
            return "\(type.rawValue),\(normalized),\(target)"
        }
        if type.needsNoResolve {
            return "\(type.rawValue),\(clean),\(target),no-resolve"
        }
        return "\(type.rawValue),\(clean),\(target)"
    }
}

public enum RuleGroupClientScopeMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case all
    case include
    case exclude

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "全部设备"
        case .include: return "仅指定设备"
        case .exclude: return "排除指定设备"
        }
    }

    public var shortLabel: String {
        switch self {
        case .all: return "全部设备"
        case .include: return "仅限设备"
        case .exclude: return "排除设备"
        }
    }
}

public struct RuleGroupClientEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var address: String
    public var name: String
    public var macAddress: String?
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        address: String,
        name: String = "",
        macAddress: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.address = address
        self.name = name
        self.macAddress = macAddress
        self.isEnabled = isEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        address = try c.decode(String.self, forKey: .address)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    public var normalizedCIDR: String? {
        ClientAddressValidator.normalizedCIDR(address)
    }

    public var displayTitle: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty && trimmedName != trimmedAddress {
            return "\(trimmedName) (\(trimmedAddress))"
        }
        return trimmedAddress
    }
}

public enum TargetReference: Codable, Equatable, Hashable, Sendable {
    case target(UUID)
    case reject

    private enum CodingKeys: String, CodingKey {
        case kind, id
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        if kind == "reject" {
            self = .reject
        } else {
            self = .target(try c.decode(UUID.self, forKey: .id))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .reject:
            try c.encode("reject", forKey: .kind)
        case .target(let id):
            try c.encode("target", forKey: .kind)
            try c.encode(id, forKey: .id)
        }
    }
}

public struct RuleGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var icon: String
    public var target: TargetReference
    public var isEnabled: Bool
    public var rules: [RuleItem]
    public var clientScopeMode: RuleGroupClientScopeMode
    public var clientEntries: [RuleGroupClientEntry]

    public init(
        id: UUID = UUID(),
        name: String,
        icon: String = "list.bullet.rectangle",
        target: TargetReference,
        isEnabled: Bool = true,
        rules: [RuleItem] = [],
        clientScopeMode: RuleGroupClientScopeMode = .all,
        clientEntries: [RuleGroupClientEntry] = []
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.target = target
        self.isEnabled = isEnabled
        self.rules = rules
        self.clientScopeMode = clientScopeMode
        self.clientEntries = clientEntries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "list.bullet.rectangle"
        target = try c.decode(TargetReference.self, forKey: .target)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        rules = try c.decodeIfPresent([RuleItem].self, forKey: .rules) ?? []
        clientScopeMode = try c.decodeIfPresent(RuleGroupClientScopeMode.self, forKey: .clientScopeMode) ?? .all
        clientEntries = try c.decodeIfPresent([RuleGroupClientEntry].self, forKey: .clientEntries) ?? []
    }

    public var enabledClientEntries: [RuleGroupClientEntry] {
        clientEntries.filter(\.isEnabled)
    }

    public var isEffectivelyActive: Bool {
        guard isEnabled, rules.contains(where: \.isEnabled) else { return false }
        if clientScopeMode == .include && enabledClientEntries.isEmpty {
            return false
        }
        return true
    }

    public var hasActiveClientScopeFilter: Bool {
        clientScopeMode != .all && !enabledClientEntries.isEmpty
    }
}

// MARK: - Subconverter / ACL4SSR / monlor-subconverter-rules Catalog

public enum SubconverterMirror: String, CaseIterable, Identifiable, Sendable {
    case jsdelivr
    case monlorProxy
    case githubRaw

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .jsdelivr: return "jsDelivr 加速"
        case .monlorProxy: return "gh.monlor.com"
        case .githubRaw: return "GitHub Raw"
        }
    }

    public func githubFileURL(owner: String, repo: String, branch: String, path: String) -> String {
        switch self {
        case .jsdelivr:
            return "https://fastly.jsdelivr.net/gh/\(owner)/\(repo)@\(branch)/\(path)"
        case .monlorProxy:
            return "https://gh.monlor.com/https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(path)"
        case .githubRaw:
            return "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(path)"
        }
    }

    public func acl4ssrURL(file: String) -> String {
        githubFileURL(owner: "ACL4SSR", repo: "ACL4SSR", branch: "master", path: "Clash/\(file)")
    }

    public func monlorRuleURL(file: String) -> String {
        githubFileURL(owner: "monlor", repo: "subconverter-rules", branch: "main", path: "rules/\(file)")
    }
}

public struct SubconverterRuleSet: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let owner: String
    public let repo: String
    public let branch: String
    public let path: String
    public let sourceLabel: String
    public let format: RuleSetFormat
    public let behavior: RuleSetBehavior
    public let noResolve: Bool

    public init(
        id: String,
        name: String,
        file: String,
        format: RuleSetFormat = .text,
        behavior: RuleSetBehavior = .classical,
        noResolve: Bool = false
    ) {
        self.id = id
        self.name = name
        self.owner = "ACL4SSR"
        self.repo = "ACL4SSR"
        self.branch = "master"
        self.path = "Clash/\(file)"
        self.sourceLabel = "ACL4SSR"
        self.format = format
        self.behavior = behavior
        self.noResolve = noResolve
    }

    public init(
        id: String,
        name: String,
        owner: String,
        repo: String,
        branch: String,
        path: String,
        sourceLabel: String,
        format: RuleSetFormat = .text,
        behavior: RuleSetBehavior = .classical,
        noResolve: Bool = false
    ) {
        self.id = id
        self.name = name
        self.owner = owner
        self.repo = repo
        self.branch = branch
        self.path = path
        self.sourceLabel = sourceLabel
        self.format = format
        self.behavior = behavior
        self.noResolve = noResolve
    }

    public var file: String { path }

    public func url(mirror: SubconverterMirror) -> String {
        mirror.githubFileURL(owner: owner, repo: repo, branch: branch, path: path)
    }
}

public struct SubconverterRuleGroupPreset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let subtitle: String
    public let icon: String
    public let suggestReject: Bool
    public let suggestDirect: Bool
    public let ruleSets: [SubconverterRuleSet]
    public let extraRules: [RuleItem]

    public init(
        id: String,
        name: String,
        subtitle: String,
        icon: String,
        suggestReject: Bool = false,
        suggestDirect: Bool = false,
        ruleSets: [SubconverterRuleSet],
        extraRules: [RuleItem] = []
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.icon = icon
        self.suggestReject = suggestReject
        self.suggestDirect = suggestDirect
        self.ruleSets = ruleSets
        self.extraRules = extraRules
    }

    public func makeRules(mirror: SubconverterMirror) -> [RuleItem] {
        ruleSets.map { rs in
            RuleItem(
                type: .ruleSet,
                value: rs.url(mirror: mirror),
                note: "\(rs.sourceLabel) · \(rs.name)",
                ruleSetFormat: rs.format,
                ruleSetBehavior: rs.behavior,
                ruleSetNoResolve: rs.noResolve ? true : nil
            )
        } + extraRules
    }
}

public enum SubconverterCatalog {
    public static let presets: [SubconverterRuleGroupPreset] = [
        SubconverterRuleGroupPreset(
            id: "ai",
            name: "AI 服务 (OpenAI / Claude / Gemini)",
            subtitle: "ACL4SSR OpenAi、Claude、ClaudeAI、Gemini 与 AI 规则集",
            icon: "sparkles",
            suggestReject: false,
            ruleSets: [
                SubconverterRuleSet(id: "rs-openai", name: "OpenAi", file: "Ruleset/OpenAi.list"),
                SubconverterRuleSet(id: "rs-claude", name: "Claude", file: "Ruleset/Claude.list"),
                SubconverterRuleSet(id: "rs-claudeai", name: "ClaudeAI", file: "Ruleset/ClaudeAI.list"),
                SubconverterRuleSet(id: "rs-gemini", name: "Gemini", file: "Ruleset/Gemini.list"),
                SubconverterRuleSet(id: "rs-ai", name: "AI", file: "Ruleset/AI.list"),
            ]
        ),
        SubconverterRuleGroupPreset(
            id: "google",
            name: "Google / YouTube",
            subtitle: "Google、YouTube、YouTubeMusic 与 GoogleFCM",
            icon: "magnifyingglass.circle",
            suggestReject: false,
            ruleSets: [
                SubconverterRuleSet(id: "rs-google", name: "Google", file: "Ruleset/Google.list"),
                SubconverterRuleSet(id: "rs-youtube", name: "YouTube", file: "Ruleset/YouTube.list"),
                SubconverterRuleSet(id: "rs-ytmusic", name: "YouTubeMusic", file: "Ruleset/YouTubeMusic.list"),
            ]
        ),
        SubconverterRuleGroupPreset(
            id: "telegram",
            name: "Telegram 电报",
            subtitle: "ACL4SSR Telegram 域名与官方 IP 段",
            icon: "paperplane",
            suggestReject: false,
            ruleSets: [
                SubconverterRuleSet(id: "rs-telegram", name: "Telegram", file: "Ruleset/Telegram.list"),
            ]
        ),
        SubconverterRuleGroupPreset(
            id: "social",
            name: "海外社交 (X / Discord / Meta / Reddit / TikTok)",
            subtitle: "Twitter、Discord、Facebook、Instagram、Reddit、TikTok、WhatsApp",
            icon: "bubble.left.and.bubble.right",
            suggestReject: false,
            ruleSets: [
                SubconverterRuleSet(id: "rs-twitter", name: "Twitter", file: "Ruleset/Twitter.list"),
                SubconverterRuleSet(id: "rs-discord", name: "Discord", file: "Ruleset/Discord.list"),
                SubconverterRuleSet(id: "rs-facebook", name: "Facebook", file: "Ruleset/Facebook.list"),
                SubconverterRuleSet(id: "rs-instagram", name: "Instagram", file: "Ruleset/Instagram.list"),
                SubconverterRuleSet(id: "rs-reddit", name: "Reddit", file: "Ruleset/Reddit.list"),
                SubconverterRuleSet(id: "rs-tiktok", name: "TikTok", file: "Ruleset/TikTok.list"),
                SubconverterRuleSet(id: "rs-whatsapp", name: "Whatsapp", file: "Ruleset/Whatsapp.list"),
            ]
        ),
        SubconverterRuleGroupPreset(
            id: "github",
            name: "开发者与 GitHub",
            subtitle: "GitHub、Developer、Docker、JetBrains",
            icon: "chevron.left.forwardslash.chevron.right",
            suggestReject: false,
            ruleSets: [
                SubconverterRuleSet(id: "rs-github", name: "Github", file: "Ruleset/Github.list"),
                SubconverterRuleSet(id: "rs-developer", name: "Developer", file: "Ruleset/Developer.list"),
                SubconverterRuleSet(id: "rs-docker", name: "Docker", file: "Ruleset/Docker.list"),
                SubconverterRuleSet(id: "rs-jetbrains", name: "JetBrains", file: "Ruleset/JetBrains.list"),
            ]
        ),
        SubconverterRuleGroupPreset(
            id: "media",
            name: "国外流媒体 (Netflix / Disney+ / Spotify)",
            subtitle: "Netflix、Disney+、Spotify、HBO、Hulu、Bahamut 与 ProxyMedia",
            icon: "play.tv",
            suggestReject: false,
            ruleSets: [
                SubconverterRuleSet(id: "rs-netflix", name: "Netflix", file: "Ruleset/Netflix.list"),
                SubconverterRuleSet(id: "rs-disney", name: "DisneyPlus", file: "Ruleset/DisneyPlus.list"),
                SubconverterRuleSet(id: "rs-spotify", name: "Spotify", file: "Ruleset/Spotify.list"),
                SubconverterRuleSet(id: "rs-hbo", name: "HBO", file: "Ruleset/HBO.list"),
                SubconverterRuleSet(id: "rs-hulu", name: "Hulu", file: "Ruleset/Hulu.list"),
                SubconverterRuleSet(id: "rs-bahamut", name: "Bahamut", file: "Ruleset/Bahamut.list"),
                SubconverterRuleSet(id: "root-proxymedia", name: "ProxyMedia", file: "ProxyMedia.list"),
            ]
        ),
        SubconverterRuleGroupPreset(
            id: "apple",
            name: "苹果服务 (Apple)",
            subtitle: "App Store、iCloud、AppleTV 与 Apple 服务",
            icon: "apple.logo",
            suggestReject: false,
            ruleSets: [
                SubconverterRuleSet(id: "root-apple", name: "Apple", file: "Apple.list"),
                SubconverterRuleSet(id: "rs-appletv", name: "AppleTV", file: "Ruleset/AppleTV.list"),
            ]
        ),
        SubconverterRuleGroupPreset(
            id: "microsoft",
            name: "微软服务 (Microsoft / OneDrive / Bing)",
            subtitle: "Microsoft、OneDrive 与 Bing",
            icon: "window.ceiling",
            suggestReject: false,
            ruleSets: [
                SubconverterRuleSet(id: "root-microsoft", name: "Microsoft", file: "Microsoft.list"),
                SubconverterRuleSet(id: "root-onedrive", name: "OneDrive", file: "OneDrive.list"),
                SubconverterRuleSet(id: "root-bing", name: "Bing", file: "Bing.list"),
            ]
        ),
        SubconverterRuleGroupPreset(
            id: "gaming",
            name: "游戏平台 (Steam / Epic / Sony / Nintendo)",
            subtitle: "Steam、Epic、Sony、Nintendo、Xbox、Blizzard",
            icon: "gamecontroller",
            suggestReject: false,
            ruleSets: [
                SubconverterRuleSet(id: "rs-steam", name: "Steam", file: "Ruleset/Steam.list"),
                SubconverterRuleSet(id: "rs-epic", name: "Epic", file: "Ruleset/Epic.list"),
                SubconverterRuleSet(id: "rs-sony", name: "Sony", file: "Ruleset/Sony.list"),
                SubconverterRuleSet(id: "rs-nintendo", name: "Nintendo", file: "Ruleset/Nintendo.list"),
                SubconverterRuleSet(id: "rs-xbox", name: "Xbox", file: "Ruleset/Xbox.list"),
                SubconverterRuleSet(id: "rs-blizzard", name: "Blizzard", file: "Ruleset/Blizzard.list"),
            ]
        ),
        SubconverterRuleGroupPreset(
            id: "crypto",
            name: "加密货币与交易所",
            subtitle: "Binance 与 Crypto 相关站点",
            icon: "bitcoinsign.circle",
            suggestReject: false,
            ruleSets: [
                SubconverterRuleSet(id: "rs-binance", name: "Binance", file: "Ruleset/Binance.list"),
                SubconverterRuleSet(id: "rs-crypto", name: "Crypto", file: "Ruleset/Crypto.list"),
            ]
        ),
        SubconverterRuleGroupPreset(
            id: "scholar",
            name: "学术与维基百科",
            subtitle: "Scholar 学术站点与 Wikipedia",
            icon: "book",
            suggestReject: false,
            ruleSets: [
                SubconverterRuleSet(id: "rs-scholar", name: "Scholar", file: "Ruleset/Scholar.list"),
                SubconverterRuleSet(id: "rs-wikipedia", name: "Wikipedia", file: "Ruleset/Wikipedia.list"),
            ]
        ),
        SubconverterRuleGroupPreset(
            id: "proxyGFW",
            name: "国外代理列表 (ProxyGFWlist)",
            subtitle: "ACL4SSR 常见受限海外域名集合",
            icon: "globe",
            suggestReject: false,
            ruleSets: [
                SubconverterRuleSet(id: "root-gfw", name: "ProxyGFWlist", file: "ProxyGFWlist.list"),
            ]
        ),
        SubconverterRuleGroupPreset(
            id: "adblock",
            name: "广告与隐私拦截 (BanAD)",
            subtitle: "BanAD、BanProgramAD 与 BanEasyPrivacy",
            icon: "hand.raised",
            suggestReject: true,
            ruleSets: [
                SubconverterRuleSet(id: "root-banad", name: "BanAD", file: "BanAD.list"),
                SubconverterRuleSet(id: "root-banprogramad", name: "BanProgramAD", file: "BanProgramAD.list"),
                SubconverterRuleSet(id: "root-banprivacy", name: "BanEasyPrivacy", file: "BanEasyPrivacy.list"),
            ]
        ),
        SubconverterRuleGroupPreset(
            id: "chinaDirect",
            name: "全球直连与国内局域网 (ChinaDomain)",
            subtitle: "LocalAreaNetwork、UnBan、GoogleCN、SteamCN、ChinaDomain、ChinaCompanyIp",
            icon: "house",
            suggestReject: false,
            ruleSets: [
                SubconverterRuleSet(id: "root-lan", name: "LocalAreaNetwork", file: "LocalAreaNetwork.list"),
                SubconverterRuleSet(id: "root-unban", name: "UnBan", file: "UnBan.list"),
                SubconverterRuleSet(id: "root-googlecn", name: "GoogleCN", file: "GoogleCN.list"),
                SubconverterRuleSet(id: "rs-steamcn", name: "SteamCN", file: "Ruleset/SteamCN.list"),
                SubconverterRuleSet(id: "root-chinaDomain", name: "ChinaDomain", file: "ChinaDomain.list"),
                SubconverterRuleSet(id: "root-chinaIP", name: "ChinaCompanyIp", file: "ChinaCompanyIp.list"),
            ]
        ),
    ]

    /// Complete official ACL4SSR Clash root rulesets (`Clash/*.list`).
    public static let rootListFiles: [String] = [
        "Apple.list", "BanAD.list", "BanEasyList.list", "BanEasyListChina.list",
        "BanEasyPrivacy.list", "BanProgramAD.list", "Bing.list", "ChinaCompanyIp.list",
        "ChinaDomain.list", "ChinaIp.list", "ChinaIpV6.list", "ChinaMedia.list",
        "Download.list", "GoogleCN.list", "LocalAreaNetwork.list", "Microsoft.list",
        "Netflix.list", "OneDrive.list", "ProxyGFWlist.list", "ProxyLite.list",
        "ProxyMedia.list", "Telegram.list", "UnBan.list", "Xbox.list",
    ]

    /// Complete official ACL4SSR Clash sub-rulesets (`Clash/Ruleset/*.list`).
    public static let rulesetFiles: [String] = [
        "360.list", "4399.list", "58.list", "ABC.list", "AI.list", "AbemaTV.list",
        "AccelerateDirectSites.list", "Adobe.list", "Alibaba.list", "All4.list",
        "Amazon.list", "AmazonIp.list", "Apple.list", "AppleNews.list", "AppleTV.list",
        "BBC.list", "BBCiPlayer.list", "Bahamut.list", "Baidu.list", "Bilibili.list",
        "BilibiliHMT.list", "Binance.list", "Bing.list", "Blizzard.list", "ByteDance.list",
        "CCTV.list", "CN.list", "ChinaDNS.list", "ChinaNet.list", "ChinaOneKeyLogin.list",
        "Claude.list", "ClaudeAI.list", "Crypto.list", "DAZN.list", "Deezer.list",
        "Developer.list", "DiDi.list", "Discord.list", "DiscoveryPlus.list", "DisneyPlus.list",
        "Dmm.list", "Docker.list", "Douyu.list", "Download.list", "Dubox.list",
        "EHGallery.list", "EncoreTVB.list", "Epic.list", "F1.list", "Facebook.list",
        "FoxNow.list", "GameDownload.list", "Gemini.list", "Github.list", "Google.list",
        "GoogleCN.list", "GoogleCNProxyIP.list", "GoogleEarth.list", "GoogleFCM.list",
        "HBO.list", "HBO_GO_HKG.list", "HWTV.list", "Heytap.list", "HuaWei.list",
        "Hulu.list", "HuluJapan.list", "ITV.list", "Iflytek.list", "Instagram.list",
        "Iqiyi.list", "IqiyiHMT.list", "Iwara.list", "JD.list", "JOOX.list", "Japonx.list",
        "JetBrains.list", "KKBOX.list", "KKTV.list", "KakaoTalk.list", "Kingsoft.list",
        "Kuaishou.list", "LeTV.list", "LiTV.list", "Line.list", "LineTV.list", "MGTVTV.list",
        "MI.list", "MIUIPrivacy.list", "MOO.list", "Marketing.list", "Meitu.list",
        "Microsoft.list", "My5.list", "MyTVSuper.list", "NaSDDNS.list", "NetEase.list",
        "NetEaseMusic.list", "Netflix.list", "NetflixIP.list", "Niconico.list", "Nintendo.list",
        "NivodTV.list", "Olevod.list", "OneDrive.list", "OpenAi.list", "Origin.list",
        "PBS.list", "PDD.list", "PPTVPPLive.list", "Pandora.list", "Pixiv.list", "Porn.list",
        "Pornhub.list", "PrivateTracker.list", "ProxyGFWlist.list", "PublicDirectCDN.list",
        "Qobuz.list", "Reddit.list", "RemoteDesktop.list", "Samsung.list", "Scholar.list",
        "Sina.list", "SohuSogo.list", "Sony.list", "SoundCloud.list", "Spark.list",
        "Spotify.list", "Steam.list", "SteamCN.list", "SteamRegionCheck.list", "TIDAL.list",
        "TaiWanGood.list", "TapTap.list", "TeamViewer.list", "Telegram.list", "Tencent.list",
        "TencentLolm.list", "TencentVideo.list", "TeraBox.list", "TikTok.list",
        "TopBlockedSites.list", "Twitch.list", "Twitter.list", "UnBan.list", "VikACG.list",
        "Vip.list", "ViuTV.list", "Wechat.list", "Whatsapp.list", "Wikipedia.list",
        "Xbox.list", "Ximalaya.list", "Xunlei.list", "YYeTs.list", "YouTube.list",
        "YouTubeMusic.list", "Youku.list", "Zoom.list",
    ]

    public static var allRuleSets: [SubconverterRuleSet] {
        let root = rootListFiles.map { file in
            let name = file.replacingOccurrences(of: ".list", with: "")
            return SubconverterRuleSet(id: "root-\(name)", name: "\(name)（主规则）", file: file)
        }
        let sub = rulesetFiles.map { file in
            let name = file.replacingOccurrences(of: ".list", with: "")
            return SubconverterRuleSet(id: "ruleset-\(name)", name: name, file: "Ruleset/\(file)")
        }
        return root + sub
    }

    // MARK: - monlor/subconverter-rules

    private static func monlorRS(_ id: String, _ name: String, _ file: String) -> SubconverterRuleSet {
        SubconverterRuleSet(
            id: "monlor-\(id)",
            name: name,
            owner: "monlor",
            repo: "subconverter-rules",
            branch: "main",
            path: "rules/\(file)",
            sourceLabel: "monlor"
        )
    }

    private static let appleAIRS = SubconverterRuleSet(
        id: "rocm301-apple-ai",
        name: "Apple-AI",
        owner: "RocM301",
        repo: "Apple-Rule",
        branch: "main",
        path: "Apple-AI.list",
        sourceLabel: "RocM301"
    )

    /// Complete files from `monlor/subconverter-rules/rules/`.
    public static let monlorRuleSets: [SubconverterRuleSet] = [
        monlorRS("ban", "隐私广告 (ban)", "ban.ini"),
        monlorRS("whitelist", "中国直连白名单 (whitelist)", "whitelist.ini"),
        monlorRS("blacklist", "GFW 黑名单 (blacklist)", "blacklist.ini"),
        monlorRS("ai", "AI 服务 (ai)", "ai.ini"),
        monlorRS("kiro", "Kiro IDE (kiro)", "kiro.ini"),
        monlorRS("icloud", "iCloud 同步优先 (icloud)", "icloud.ini"),
        monlorRS("apple-region", "苹果区域 (AppleRegion)", "AppleRegion.ini"),
        monlorRS("apple-push", "苹果推送 APNs (ApplePush)", "ApplePush.ini"),
        monlorRS("tcpports", "常见端口 (tcpports)", "tcpports.ini"),
        monlorRS("ssh", "SSH 端口 (ssh)", "ssh.ini"),
        monlorRS("vowifi", "VoWiFi 汇总 (vowifi)", "vowifi.ini"),
        monlorRS("vowifi-us", "VoWiFi · 美国", "vowifi/us.ini"),
        monlorRS("vowifi-hk", "VoWiFi · 香港", "vowifi/hk.ini"),
        monlorRS("vowifi-uk", "VoWiFi · 英国", "vowifi/uk.ini"),
        monlorRS("vowifi-au", "VoWiFi · 澳洲", "vowifi/au.ini"),
        monlorRS("vowifi-nz", "VoWiFi · 新西兰", "vowifi/nz.ini"),
        monlorRS("vowifi-ch", "VoWiFi · 瑞士", "vowifi/ch.ini"),
        monlorRS("vowifi-fr", "VoWiFi · 法国", "vowifi/fr.ini"),
        monlorRS("vowifi-nl", "VoWiFi · 荷兰", "vowifi/nl.ini"),
        monlorRS("vowifi-my", "VoWiFi · 马来西亚", "vowifi/my.ini"),
        monlorRS("vowifi-ph", "VoWiFi · 菲律宾", "vowifi/ph.ini"),
        monlorRS("us", "美国服务 (unitedstates)", "unitedstates.ini"),
        monlorRS("hk", "香港服务 (hongkong)", "hongkong.ini"),
        monlorRS("jp", "日本服务 (japan)", "japan.ini"),
        monlorRS("uk", "英国服务 (unitedkingdom)", "unitedkingdom.ini"),
        monlorRS("de", "德国服务 (germany)", "germany.ini"),
        monlorRS("ng", "尼日利亚服务 (nigeria)", "nigeria.ini"),
        monlorRS("paypal", "PayPal (paypal)", "paypal.ini"),
        monlorRS("wallet", "银行与钱包 (wallet)", "wallet.ini"),
        monlorRS("globalmedia", "流媒体汇总 (globalmedia)", "globalmedia.ini"),
        monlorRS("hbomax", "HBO Max (hbomax)", "hbomax.ini"),
        monlorRS("socialmedia", "社交媒体汇总 (socialmedia)", "socialmedia.ini"),
        monlorRS("adspower", "AdsPower (adspower)", "adspower.ini"),
        monlorRS("jegotrip", "无忧行 (jegotrip)", "jegotrip.ini"),
    ]

    /// Rule groups mirroring `monlor/subconverter-rules/full.ini`.
    public static let monlorFullPresets: [SubconverterRuleGroupPreset] = [
        SubconverterRuleGroupPreset(
            id: "monlor-ban",
            name: "隐私广告",
            subtitle: "monlor/ban.ini + ACL4SSR BanAD / BanProgramAD / BanEasyListChina / BanEasyPrivacy",
            icon: "hand.raised",
            suggestReject: true,
            ruleSets: [
                monlorRS("ban", "ban.ini", "ban.ini"),
                SubconverterRuleSet(id: "m-banad", name: "BanAD", file: "BanAD.list"),
                SubconverterRuleSet(id: "m-banprog", name: "BanProgramAD", file: "BanProgramAD.list"),
                SubconverterRuleSet(id: "m-banelc", name: "BanEasyListChina", file: "BanEasyListChina.list"),
                SubconverterRuleSet(id: "m-banpriv", name: "BanEasyPrivacy", file: "BanEasyPrivacy.list"),
            ]
        ),
        SubconverterRuleGroupPreset(
            id: "monlor-ai",
            name: "AI 服务 (monlor)",
            subtitle: "ACL4SSR AI / OpenAi / Claude + RocM301 Apple-AI + monlor/kiro.ini",
            icon: "sparkles",
            ruleSets: [
                SubconverterRuleSet(id: "m-ai", name: "AI", file: "Ruleset/AI.list"),
                SubconverterRuleSet(id: "m-openai", name: "OpenAi", file: "Ruleset/OpenAi.list"),
                SubconverterRuleSet(id: "m-claude", name: "Claude", file: "Ruleset/Claude.list"),
                appleAIRS,
                monlorRS("kiro", "kiro.ini", "kiro.ini"),
            ]
        ),
        SubconverterRuleGroupPreset(
            id: "monlor-wallet",
            name: "银行钱包",
            subtitle: "monlor/paypal.ini + monlor/wallet.ini",
            icon: "creditcard",
            ruleSets: [
                monlorRS("paypal", "paypal.ini", "paypal.ini"),
                monlorRS("wallet", "wallet.ini", "wallet.ini"),
            ]
        ),
        SubconverterRuleGroupPreset(
            id: "monlor-us",
            name: "美国服务",
            subtitle: "monlor/unitedstates.ini",
            icon: "flag",
            ruleSets: [monlorRS("us", "unitedstates.ini", "unitedstates.ini")]
        ),
        SubconverterRuleGroupPreset(
            id: "monlor-social",
            name: "社交媒体 (monlor)",
            subtitle: "monlor/socialmedia.ini",
            icon: "bubble.left.and.bubble.right",
            ruleSets: [monlorRS("social", "socialmedia.ini", "socialmedia.ini")]
        ),
        SubconverterRuleGroupPreset(
            id: "monlor-google",
            name: "谷歌服务",
            subtitle: "ACL4SSR GoogleFCM / Google / YouTube",
            icon: "magnifyingglass.circle",
            ruleSets: [
                SubconverterRuleSet(id: "m-gfcm", name: "GoogleFCM", file: "Ruleset/GoogleFCM.list"),
                SubconverterRuleSet(id: "m-google", name: "Google", file: "Ruleset/Google.list"),
                SubconverterRuleSet(id: "m-youtube", name: "YouTube", file: "Ruleset/YouTube.list"),
            ]
        ),
        SubconverterRuleGroupPreset(
            id: "monlor-media",
            name: "流媒体服务 (monlor)",
            subtitle: "monlor/globalmedia.ini + Bahamut",
            icon: "play.tv",
            ruleSets: [
                SubconverterRuleSet(id: "m-bahamut", name: "Bahamut", file: "Ruleset/Bahamut.list"),
                monlorRS("globalmedia", "globalmedia.ini", "globalmedia.ini"),
            ]
        ),
        SubconverterRuleGroupPreset(
            id: "monlor-apple-region",
            name: "苹果区域",
            subtitle: "monlor/AppleRegion.ini",
            icon: "map",
            ruleSets: [monlorRS("apple-region", "AppleRegion.ini", "AppleRegion.ini")]
        ),
        SubconverterRuleGroupPreset(
            id: "monlor-apple-push",
            name: "苹果推送",
            subtitle: "monlor/ApplePush.ini",
            icon: "bell.badge",
            suggestDirect: true,
            ruleSets: [monlorRS("apple-push", "ApplePush.ini", "ApplePush.ini")]
        ),
        SubconverterRuleGroupPreset(
            id: "monlor-apple",
            name: "苹果服务 (monlor)",
            subtitle: "monlor/icloud.ini + ACL4SSR Apple.list",
            icon: "apple.logo",
            suggestDirect: true,
            ruleSets: [
                monlorRS("icloud", "icloud.ini", "icloud.ini"),
                SubconverterRuleSet(id: "m-apple", name: "Apple", file: "Apple.list"),
            ]
        ),
        SubconverterRuleGroupPreset(
            id: "monlor-microsoft",
            name: "微软服务 (monlor)",
            subtitle: "ACL4SSR Bing / OneDrive / Microsoft",
            icon: "window.ceiling",
            suggestDirect: true,
            ruleSets: [
                SubconverterRuleSet(id: "m-bing", name: "Bing", file: "Bing.list"),
                SubconverterRuleSet(id: "m-onedrive", name: "OneDrive", file: "OneDrive.list"),
                SubconverterRuleSet(id: "m-ms", name: "Microsoft", file: "Microsoft.list"),
            ]
        ),
        SubconverterRuleGroupPreset(
            id: "monlor-gaming",
            name: "游戏平台 (monlor)",
            subtitle: "ACL4SSR Epic / Origin / Sony / Steam / Nintendo",
            icon: "gamecontroller",
            ruleSets: [
                SubconverterRuleSet(id: "m-epic", name: "Epic", file: "Ruleset/Epic.list"),
                SubconverterRuleSet(id: "m-origin", name: "Origin", file: "Ruleset/Origin.list"),
                SubconverterRuleSet(id: "m-sony", name: "Sony", file: "Ruleset/Sony.list"),
                SubconverterRuleSet(id: "m-steam", name: "Steam", file: "Ruleset/Steam.list"),
                SubconverterRuleSet(id: "m-nintendo", name: "Nintendo", file: "Ruleset/Nintendo.list"),
            ]
        ),
        SubconverterRuleGroupPreset(
            id: "monlor-tcpports",
            name: "常见端口",
            subtitle: "monlor/tcpports.ini",
            icon: "cable.connector",
            suggestDirect: true,
            ruleSets: [monlorRS("tcpports", "tcpports.ini", "tcpports.ini")]
        ),
        SubconverterRuleGroupPreset(
            id: "monlor-vowifi",
            name: "VoWiFi",
            subtitle: "monlor/vowifi.ini",
            icon: "antenna.radiowaves.left.and.right",
            suggestDirect: true,
            ruleSets: [monlorRS("vowifi", "vowifi.ini", "vowifi.ini")]
        ),
        SubconverterRuleGroupPreset(
            id: "monlor-gfw",
            name: "GFW 列表 (monlor)",
            subtitle: "monlor/blacklist.ini + ACL4SSR ProxyGFWlist",
            icon: "globe",
            ruleSets: [
                monlorRS("blacklist", "blacklist.ini", "blacklist.ini"),
                SubconverterRuleSet(id: "m-gfw", name: "ProxyGFWlist", file: "ProxyGFWlist.list"),
            ]
        ),
        SubconverterRuleGroupPreset(
            id: "monlor-cn",
            name: "中国直连 (monlor)",
            subtitle: "whitelist.ini + LocalAreaNetwork / UnBan / SteamCN / GoogleCN / ChinaDomain / ChinaCompanyIp / Download / GEOIP,CN",
            icon: "house",
            suggestDirect: true,
            ruleSets: [
                monlorRS("whitelist", "whitelist.ini", "whitelist.ini"),
                SubconverterRuleSet(id: "m-lan", name: "LocalAreaNetwork", file: "LocalAreaNetwork.list"),
                SubconverterRuleSet(id: "m-unban", name: "UnBan", file: "UnBan.list"),
                SubconverterRuleSet(id: "m-steamcn", name: "SteamCN", file: "Ruleset/SteamCN.list"),
                SubconverterRuleSet(id: "m-googlecn", name: "GoogleCN", file: "GoogleCN.list"),
                SubconverterRuleSet(id: "m-cndomain", name: "ChinaDomain", file: "ChinaDomain.list"),
                SubconverterRuleSet(id: "m-cnip", name: "ChinaCompanyIp", file: "ChinaCompanyIp.list"),
                SubconverterRuleSet(id: "m-download", name: "Download", file: "Download.list"),
            ],
            extraRules: [RuleItem(type: .geoip, value: "CN")]
        ),
    ]
}

public enum StarterRules {
    public static let ai: [RuleItem] = [
        RuleItem(type: .domainSuffix, value: "claude.ai"),
        RuleItem(type: .domainSuffix, value: "claude.com"),
        RuleItem(type: .domainSuffix, value: "anthropic.com"),
        RuleItem(type: .domainSuffix, value: "claudeusercontent.com"),
        RuleItem(type: .domainSuffix, value: "openai.com"),
        RuleItem(type: .domainSuffix, value: "chatgpt.com"),
        RuleItem(type: .domainSuffix, value: "oaistatic.com"),
        RuleItem(type: .domainSuffix, value: "oaiusercontent.com"),
        RuleItem(type: .domainSuffix, value: "gemini.google.com"),
        RuleItem(type: .domainSuffix, value: "aistudio.google.com"),
        RuleItem(type: .domainSuffix, value: "perplexity.ai"),
        RuleItem(type: .domain, value: "copilot.microsoft.com"),
        RuleItem(type: .domainSuffix, value: "kiro.dev"),
    ]

    public static let google: [RuleItem] = [
        RuleItem(type: .geosite, value: "google"),
        RuleItem(type: .geosite, value: "youtube"),
    ]

    public static let telegram: [RuleItem] = [
        RuleItem(type: .domainSuffix, value: "telegram.org"),
        RuleItem(type: .domainSuffix, value: "t.me"),
        RuleItem(type: .domainSuffix, value: "telegra.ph"),
        RuleItem(type: .ipCIDR, value: "91.108.4.0/22"),
        RuleItem(type: .ipCIDR, value: "91.108.8.0/22"),
        RuleItem(type: .ipCIDR, value: "91.108.56.0/22"),
        RuleItem(type: .ipCIDR, value: "149.154.160.0/20"),
    ]

    public static let social: [RuleItem] = [
        RuleItem(type: .domainSuffix, value: "x.com"),
        RuleItem(type: .domainSuffix, value: "twitter.com"),
        RuleItem(type: .domainSuffix, value: "t.co"),
        RuleItem(type: .domainSuffix, value: "discord.com"),
        RuleItem(type: .domainSuffix, value: "discord.gg"),
        RuleItem(type: .domainSuffix, value: "reddit.com"),
        RuleItem(type: .domainSuffix, value: "instagram.com"),
        RuleItem(type: .domainSuffix, value: "facebook.com"),
        RuleItem(type: .domainSuffix, value: "whatsapp.com"),
    ]

    public static let dev: [RuleItem] = [
        RuleItem(type: .geosite, value: "github"),
        RuleItem(type: .domainSuffix, value: "github.com"),
        RuleItem(type: .domainSuffix, value: "githubusercontent.com"),
        RuleItem(type: .domainSuffix, value: "gitlab.com"),
        RuleItem(type: .domainSuffix, value: "brew.sh"),
        RuleItem(type: .domainSuffix, value: "npmjs.org"),
        RuleItem(type: .domainSuffix, value: "docker.io"),
    ]

    public static let media: [RuleItem] = [
        RuleItem(type: .geosite, value: "netflix"),
        RuleItem(type: .geosite, value: "disney"),
        RuleItem(type: .geosite, value: "spotify"),
    ]

    public static let apple: [RuleItem] = [
        RuleItem(type: .geosite, value: "apple"),
    ]

    public static let microsoft: [RuleItem] = [
        RuleItem(type: .geosite, value: "microsoft"),
        RuleItem(type: .geosite, value: "onedrive"),
    ]

    public static let adblock: [RuleItem] = [
        RuleItem(type: .geosite, value: "category-ads-all"),
    ]

    public static let domestic: [RuleItem] = [
        RuleItem(type: .domain, value: "localhost"),
        RuleItem(type: .domainSuffix, value: "local"),
        RuleItem(type: .ipCIDR, value: "127.0.0.0/8"),
        RuleItem(type: .ipCIDR, value: "10.0.0.0/8"),
        RuleItem(type: .ipCIDR, value: "172.16.0.0/12"),
        RuleItem(type: .ipCIDR, value: "192.168.0.0/16"),
        RuleItem(type: .ipCIDR, value: "169.254.0.0/16"),
        RuleItem(type: .ipCIDR6, value: "::1/128"),
        RuleItem(type: .ipCIDR6, value: "fc00::/7"),
        RuleItem(type: .ipCIDR6, value: "fe80::/10"),
        RuleItem(type: .geosite, value: "cn"),
        RuleItem(type: .domainSuffix, value: "cn"),
        RuleItem(type: .geoip, value: "CN"),
    ]
}
