import Foundation

public enum SubscriptionRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case exit
    case relay
    case general

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .exit: return "出口代理订阅"
        case .relay: return "链式代理订阅"
        case .general: return "通用订阅"
        }
    }
}

public struct ProxySubscription: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var url: String
    public var role: SubscriptionRole

    public init(
        id: UUID = UUID(),
        name: String,
        url: String,
        role: SubscriptionRole = .general
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.role = role
    }
}

public struct HostModule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var url: String
    public var isEnabled: Bool
    public var cachedHosts: [String: String]
    public var lastUpdated: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        url: String,
        isEnabled: Bool = true,
        cachedHosts: [String: String] = [:],
        lastUpdated: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
        self.cachedHosts = cachedHosts
        self.lastUpdated = lastUpdated
    }
}

public enum HostModuleParser {
    /// Parses a Surge `.sgmodule` `[Host]` section (or plain `host = target` lines),
    /// filtering out identity decoy entries (`a = a`) and unsupported Surge `server:`/`script:` directives.
    public static func parse(_ text: String) -> (name: String?, hosts: [String: String]) {
        var moduleName: String?
        var hosts: [String: String] = [:]
        var hasSectionHeaders = false
        var inHostSection = false

        let lines = text.split(whereSeparator: \.isNewline)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                hasSectionHeaders = true
                break
            }
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#!name=") {
                let value = String(line.dropFirst("#!name=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { moduleName = value }
                continue
            }
            if line.hasPrefix("#") || line.hasPrefix(";") || line.hasPrefix("//") {
                continue
            }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inHostSection = line.lowercased() == "[host]"
                continue
            }
            if hasSectionHeaders && !inHostSection {
                continue
            }
            guard let eqIndex = line.firstIndex(of: "=") else { continue }
            let lhs = line[..<eqIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let rhs = line[line.index(after: eqIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lhs.isEmpty, !rhs.isEmpty else { continue }
            let lowerRHS = rhs.lowercased()
            if lowerRHS.hasPrefix("server:") || lowerRHS.hasPrefix("script:") || lowerRHS == "system" {
                continue
            }
            // Skip decoy identity entries like `www.qq.com = www.qq.com` to avoid CNAME loops.
            if lhs.caseInsensitiveCompare(rhs) == .orderedSame {
                continue
            }
            guard !lhs.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
                  !lhs.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !rhs.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                continue
            }
            if rhs.contains(",") {
                let items = rhs.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard !items.isEmpty,
                      items.allSatisfy({ item in
                          !item.isEmpty
                              && item.caseInsensitiveCompare(lhs) != .orderedSame
                              && !item.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains)
                      }) else {
                    continue
                }
                hosts[lhs] = items.joined(separator: ",")
            } else {
                guard !rhs.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) else {
                    continue
                }
                hosts[lhs] = rhs
            }
        }

        return (moduleName, hosts)
    }
}

public enum NodeGroupKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case exit
    case relay

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .exit: return "出口节点组"
        case .relay: return "链式代理节点组"
        }
    }

    public var shortLabel: String {
        switch self {
        case .exit: return "出口"
        case .relay: return "链式"
        }
    }
}

public struct NodeGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: NodeGroupKind
    public var subscriptionID: UUID?
    public var filterPattern: String
    public var excludeFilterPattern: String
    public var autoTest: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        kind: NodeGroupKind,
        subscriptionID: UUID? = nil,
        filterPattern: String = "",
        excludeFilterPattern: String = "",
        autoTest: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.subscriptionID = subscriptionID
        self.filterPattern = filterPattern
        self.excludeFilterPattern = excludeFilterPattern
        self.autoTest = autoTest
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(NodeGroupKind.self, forKey: .kind)
        subscriptionID = try c.decodeIfPresent(UUID.self, forKey: .subscriptionID)
        filterPattern = try c.decodeIfPresent(String.self, forKey: .filterPattern) ?? ""
        excludeFilterPattern = try c.decodeIfPresent(String.self, forKey: .excludeFilterPattern) ?? ""
        autoTest = try c.decodeIfPresent(Bool.self, forKey: .autoTest) ?? true
    }
}

public struct RegexPreset: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let pattern: String

    public static let regions: [RegexPreset] = [
        RegexPreset(id: "hk", title: "香港", pattern: #"(?i)(🇭🇰|香港|Hong[ -]?Kong|\bHK\b)"#),
        RegexPreset(id: "jp", title: "日本", pattern: #"(?i)(🇯🇵|日本|Japan|Tokyo|Osaka|\bJP\b)"#),
        RegexPreset(id: "sg", title: "新加坡", pattern: #"(?i)(🇸🇬|新加坡|狮城|Singapore|\bSG\b)"#),
        RegexPreset(id: "tw", title: "台湾", pattern: #"(?i)(🇹🇼|台湾|台灣|Taiwan|Taipei|\bTW\b)"#),
        RegexPreset(id: "us", title: "美国", pattern: #"(?i)(🇺🇸|美国|美國|United States|\b(?:US|USA)\b|Los Angeles|San Jose|Seattle|New York|Silicon Valley)"#),
        RegexPreset(id: "au", title: "澳洲", pattern: #"(?i)(🇦🇺|澳洲|澳大利亚|澳大利亞|Australia|Sydney|Melbourne|\bAU\b)"#),
        RegexPreset(id: "nz", title: "新西兰", pattern: #"(?i)(🇳🇿|新西兰|新西蘭|紐西蘭|New Zealand|Auckland|\bNZ\b)"#),
        RegexPreset(id: "uk", title: "英国", pattern: #"(?i)(🇬🇧|英国|英國|United Kingdom|Britain|London|\b(?:UK|GB)\b)"#),
        RegexPreset(id: "de", title: "德国", pattern: #"(?i)(🇩🇪|德国|德國|Germany|Frankfurt|\bDE\b)"#),
    ]

    public static let common: [RegexPreset] = regions + [
        RegexPreset(id: "relay", title: "中转/专线", pattern: #"(?i)(中转|专线|IEPL|IPLC|relay|入口)"#),
        RegexPreset(id: "all", title: "全部节点", pattern: ""),
    ]
}

public enum NetworkTargetMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case proxy
    case direct

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .proxy: return "代理出口"
        case .direct: return "网卡直连"
        }
    }
}

/// A reusable network target that rule groups point to.
/// Examples:
/// - `香港出口节点组 => 香港链式代理节点组 => 有线网卡 (en0)`
/// - `美国出口节点组 => 有线网卡 (en0)` (without chain)
/// - `美国出口节点组 => 系统默认网卡` (no chain, no bound interface)
/// - `直连 => USB 网卡 (en5)`
public struct NetworkTarget: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var mode: NetworkTargetMode
    public var exitGroupID: UUID?
    public var relayGroupID: UUID?
    /// Optional BSD interface name (e.g. `en0`, `en5`). Nil or empty means system default route.
    public var interfaceName: String?

    public init(
        id: UUID = UUID(),
        name: String,
        mode: NetworkTargetMode,
        exitGroupID: UUID? = nil,
        relayGroupID: UUID? = nil,
        interfaceName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.exitGroupID = exitGroupID
        self.relayGroupID = relayGroupID
        self.interfaceName = interfaceName
    }

    public var normalizedInterface: String? {
        guard let raw = interfaceName?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }
}

public enum RuleProviderProxyMode: Codable, Equatable, Hashable, Sendable {
    case auto
    case direct
    case target(UUID)

    private enum CodingKeys: String, CodingKey {
        case kind, id
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "direct":
            self = .direct
        case "target":
            self = .target(try c.decode(UUID.self, forKey: .id))
        default:
            self = .auto
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auto:
            try c.encode("auto", forKey: .kind)
        case .direct:
            try c.encode("direct", forKey: .kind)
        case .target(let id):
            try c.encode("target", forKey: .kind)
            try c.encode(id, forKey: .id)
        }
    }
}

public enum TunStack: String, Codable, CaseIterable, Identifiable, Sendable {
    case mixed
    case system
    case gvisor

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mixed: return "Mixed（推荐）"
        case .system: return "System（高性能）"
        case .gvisor: return "gVisor（兼容性强）"
        }
    }

    public var subtitle: String {
        switch self {
        case .mixed: return "TCP 使用系统协议栈，UDP 使用 gVisor，兼顾性能与兼容性"
        case .system: return "TCP 与 UDP 均使用系统协议栈，延迟最低、吞吐最高"
        case .gvisor: return "全用户态协议栈，在复杂网络环境下兼容性最好"
        }
    }
}

public enum TunDNSMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case fakeIP = "fake-ip"
    case redirHost = "redir-host"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fakeIP: return "Fake-IP（推荐）"
        case .redirHost: return "Redir-Host（真实 IP）"
        }
    }

    public var subtitle: String {
        switch self {
        case .fakeIP: return "返回虚拟保留段 IP（198.18.0.0/16），零本地 DNS 泄漏且域名分流最精准"
        case .redirHost: return "返回真实 IP 并结合 SNI 嗅探分流，适合需要查看真实解析 IP 的开发工具"
        }
    }
}

public enum MihomoLogLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case debug
    case info
    case warning
    case error

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .debug: return "Debug（含 DNS 解析）"
        case .info: return "Info（推荐）"
        case .warning: return "Warning（仅警告）"
        case .error: return "Error（仅错误）"
        }
    }
}

public struct RoutingProfile: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 2
    public var name: String

    // Listener & LAN exposure
    public var mixedPort: Int = 7890
    public var httpPort: Int? = nil
    public var socksPort: Int? = nil
    public var allowLAN: Bool = false
    /// Transparent system-wide TUN mode settings.
    public var tunEnabled: Bool = false
    /// Act as a transparent LAN gateway (requires TUN + root helper; enables DNS 0.0.0.0:53, allow-lan, and kernel IP forwarding).
    public var gatewayModeEnabled: Bool = false
    public var tunStack: TunStack = .mixed
    public var tunStrictRoute: Bool = true
    public var tunDNSMode: TunDNSMode = .fakeIP
    /// Mihomo core log verbosity (`info` by default; `debug` includes `[DNS]` query logs).
    public var logLevel: MihomoLogLevel = .info
    /// Automatic update interval (in hours) for online RULE-SET providers.
    public var ruleSetUpdateIntervalHours: Int = 24
    /// Download network strategy for online RULE-SET providers (`auto`, `direct`, or specific target).
    public var ruleProviderProxyMode: RuleProviderProxyMode = .auto

    // Core building blocks
    public var subscriptions: [ProxySubscription] = []
    public var hostModules: [HostModule] = []
    public var customDNS: CustomDNSConfig = CustomDNSConfig()
    public var nodeGroups: [NodeGroup] = []
    public var targets: [NetworkTarget] = []
    public var ruleGroups: [RuleGroup] = []
    public var fallbackTarget: TargetReference

    public init(
        name: String = "默认方案",
        mixedPort: Int = 7890,
        httpPort: Int? = nil,
        socksPort: Int? = nil,
        allowLAN: Bool = false,
        tunEnabled: Bool = false,
        gatewayModeEnabled: Bool = false,
        tunStack: TunStack = .mixed,
        tunStrictRoute: Bool = true,
        tunDNSMode: TunDNSMode = .fakeIP,
        logLevel: MihomoLogLevel = .info,
        ruleSetUpdateIntervalHours: Int = 24,
        ruleProviderProxyMode: RuleProviderProxyMode = .auto,
        subscriptions: [ProxySubscription] = [],
        hostModules: [HostModule] = [],
        customDNS: CustomDNSConfig = CustomDNSConfig(),
        nodeGroups: [NodeGroup] = [],
        targets: [NetworkTarget] = [],
        ruleGroups: [RuleGroup] = [],
        fallbackTarget: TargetReference = .reject
    ) {
        self.name = name
        self.mixedPort = mixedPort
        self.httpPort = httpPort
        self.socksPort = socksPort
        self.allowLAN = allowLAN
        self.tunEnabled = tunEnabled
        self.gatewayModeEnabled = gatewayModeEnabled
        self.tunStack = tunStack
        self.tunStrictRoute = tunStrictRoute
        self.tunDNSMode = tunDNSMode
        self.logLevel = logLevel
        self.ruleSetUpdateIntervalHours = ruleSetUpdateIntervalHours
        self.ruleProviderProxyMode = ruleProviderProxyMode
        self.subscriptions = subscriptions
        self.hostModules = hostModules
        self.customDNS = customDNS
        self.nodeGroups = nodeGroups
        self.targets = targets
        self.ruleGroups = ruleGroups
        self.fallbackTarget = fallbackTarget
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "默认方案"
        mixedPort = try c.decodeIfPresent(Int.self, forKey: .mixedPort) ?? 7890
        httpPort = try c.decodeIfPresent(Int.self, forKey: .httpPort)
        socksPort = try c.decodeIfPresent(Int.self, forKey: .socksPort)
        allowLAN = try c.decodeIfPresent(Bool.self, forKey: .allowLAN) ?? false
        tunEnabled = try c.decodeIfPresent(Bool.self, forKey: .tunEnabled) ?? false
        gatewayModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .gatewayModeEnabled) ?? false
        tunStack = try c.decodeIfPresent(TunStack.self, forKey: .tunStack) ?? .mixed
        tunStrictRoute = try c.decodeIfPresent(Bool.self, forKey: .tunStrictRoute) ?? true
        tunDNSMode = try c.decodeIfPresent(TunDNSMode.self, forKey: .tunDNSMode) ?? .fakeIP
        logLevel = try c.decodeIfPresent(MihomoLogLevel.self, forKey: .logLevel) ?? .info
        ruleSetUpdateIntervalHours = try c.decodeIfPresent(Int.self, forKey: .ruleSetUpdateIntervalHours) ?? 24
        ruleProviderProxyMode = try c.decodeIfPresent(RuleProviderProxyMode.self, forKey: .ruleProviderProxyMode) ?? .auto
        subscriptions = try c.decodeIfPresent([ProxySubscription].self, forKey: .subscriptions) ?? []
        hostModules = try c.decodeIfPresent([HostModule].self, forKey: .hostModules) ?? []
        customDNS = try c.decodeIfPresent(CustomDNSConfig.self, forKey: .customDNS) ?? CustomDNSConfig()
        nodeGroups = try c.decodeIfPresent([NodeGroup].self, forKey: .nodeGroups) ?? []
        targets = try c.decodeIfPresent([NetworkTarget].self, forKey: .targets) ?? []
        ruleGroups = try c.decodeIfPresent([RuleGroup].self, forKey: .ruleGroups) ?? []
        fallbackTarget = try c.decodeIfPresent(TargetReference.self, forKey: .fallbackTarget) ?? .reject
    }

    public func subscription(id: UUID?) -> ProxySubscription? {
        guard let id else { return nil }
        return subscriptions.first { $0.id == id }
    }

    public func nodeGroup(id: UUID?) -> NodeGroup? {
        guard let id else { return nil }
        return nodeGroups.first { $0.id == id }
    }

    public func target(id: UUID?) -> NetworkTarget? {
        guard let id else { return nil }
        return targets.first { $0.id == id }
    }

    public func targetTitle(for ref: TargetReference) -> String {
        switch ref {
        case .reject:
            return "拦截 (REJECT)"
        case .target(let id):
            return target(id: id)?.name ?? "未指定目标"
        }
    }

    /// Targets actively referenced by enabled rule groups, fallback target, or explicit rule-provider proxy target.
    public var activeTargetIDs: Set<UUID> {
        var ids = Set<UUID>()
        for group in ruleGroups where group.isEnabled && !group.rules.filter(\.isEnabled).isEmpty {
            if case .target(let id) = group.target {
                ids.insert(id)
            }
        }
        if case .target(let id) = fallbackTarget {
            ids.insert(id)
        }
        if case .target(let id) = ruleProviderProxyMode,
           ruleGroups.contains(where: { $0.isEnabled && $0.rules.contains(where: { $0.isEnabled && $0.type == .ruleSet }) }) {
            ids.insert(id)
        }
        for entry in customDNS.entries where entry.isEnabled && entry.kind == .server {
            if let targetID = entry.targetID {
                ids.insert(targetID)
            }
        }
        return ids
    }

    /// Bound interfaces required by actively referenced targets.
    public var requiredInterfaces: Set<String> {
        let active = activeTargetIDs
        var result = Set<String>()
        for target in targets where active.contains(target.id) {
            if let iface = target.normalizedInterface {
                result.insert(iface)
            }
        }
        return result
    }

    public var effectiveTunEnabled: Bool {
        tunEnabled || gatewayModeEnabled
    }

    public var effectiveAllowLAN: Bool {
        allowLAN || gatewayModeEnabled
    }

    public var hasActiveProcessRules: Bool {
        ruleGroups.contains { group in
            group.isEnabled && group.rules.contains { $0.isEnabled && $0.type.isProcessRule }
        }
    }

    /// Clean, ready-to-customize starter profile with regional exit & relay node groups.
    public static func starter() -> RoutingProfile {
        var exitGroupByRegion: [String: UUID] = [:]
        var nodeGroups: [NodeGroup] = []

        for region in RegexPreset.regions {
            let exitID = UUID()
            exitGroupByRegion[region.id] = exitID
            nodeGroups.append(
                NodeGroup(
                    id: exitID,
                    name: "\(region.title)出口节点组",
                    kind: .exit,
                    subscriptionID: nil,
                    filterPattern: region.pattern,
                    autoTest: true
                )
            )
        }

        for region in RegexPreset.regions {
            nodeGroups.append(
                NodeGroup(
                    name: "\(region.title)链式节点组",
                    kind: .relay,
                    subscriptionID: nil,
                    filterPattern: region.pattern,
                    autoTest: false
                )
            )
        }

        let directTargetID = UUID()
        let hkTargetID = UUID()
        let usTargetID = UUID()
        let jpTargetID = UUID()
        let sgTargetID = UUID()

        let targets: [NetworkTarget] = [
            NetworkTarget(
                id: directTargetID,
                name: "国内直连",
                mode: .direct,
                interfaceName: nil
            ),
            NetworkTarget(
                id: hkTargetID,
                name: "香港",
                mode: .proxy,
                exitGroupID: exitGroupByRegion["hk"],
                relayGroupID: nil,
                interfaceName: nil
            ),
            NetworkTarget(
                id: usTargetID,
                name: "美国",
                mode: .proxy,
                exitGroupID: exitGroupByRegion["us"],
                relayGroupID: nil,
                interfaceName: nil
            ),
            NetworkTarget(
                id: jpTargetID,
                name: "日本",
                mode: .proxy,
                exitGroupID: exitGroupByRegion["jp"],
                relayGroupID: nil,
                interfaceName: nil
            ),
            NetworkTarget(
                id: sgTargetID,
                name: "新加坡",
                mode: .proxy,
                exitGroupID: exitGroupByRegion["sg"],
                relayGroupID: nil,
                interfaceName: nil
            ),
        ]

        let ruleGroups: [RuleGroup] = [
            RuleGroup(name: "AI 服务", icon: "sparkles", target: .target(usTargetID), isEnabled: true, rules: StarterRules.ai),
            RuleGroup(name: "Google / YouTube", icon: "magnifyingglass.circle", target: .target(usTargetID), isEnabled: true, rules: StarterRules.google),
            RuleGroup(name: "Telegram 电报", icon: "paperplane", target: .target(hkTargetID), isEnabled: true, rules: StarterRules.telegram),
            RuleGroup(name: "社交媒体", icon: "bubble.left.and.bubble.right", target: .target(hkTargetID), isEnabled: true, rules: StarterRules.social),
            RuleGroup(name: "开发与 GitHub", icon: "chevron.left.forwardslash.chevron.right", target: .target(hkTargetID), isEnabled: true, rules: StarterRules.dev),
            RuleGroup(name: "国外流媒体", icon: "play.tv", target: .target(hkTargetID), isEnabled: false, rules: StarterRules.media),
            RuleGroup(name: "苹果服务", icon: "apple.logo", target: .target(directTargetID), isEnabled: false, rules: StarterRules.apple),
            RuleGroup(name: "微软服务", icon: "window.ceiling", target: .target(directTargetID), isEnabled: false, rules: StarterRules.microsoft),
            RuleGroup(name: "广告拦截", icon: "hand.raised", target: .reject, isEnabled: false, rules: StarterRules.adblock),
            RuleGroup(name: "国内与局域网", icon: "house", target: .target(directTargetID), isEnabled: true, rules: StarterRules.domestic),
        ]

        return RoutingProfile(
            name: "默认方案",
            mixedPort: 7890,
            httpPort: nil,
            socksPort: nil,
            allowLAN: false,
            subscriptions: [],
            nodeGroups: nodeGroups,
            targets: targets,
            ruleGroups: ruleGroups,
            fallbackTarget: .target(hkTargetID)
        )
    }

    /// Attempts to migrate a v1 profile JSON (from earlier RouteWeaver builds) into v2.
    public static func decodeOrMigrate(from data: Data) throws -> RoutingProfile {
        if let v2 = try? JSONDecoder().decode(RoutingProfile.self, from: data) {
            return v2
        }

        struct LegacyV1: Decodable {
            var name: String?
            var claudeInterface: String?
            var domesticInterface: String?
            var entryProviderURL: String?
            var exitProviderURL: String?
            var entryPattern: String?
            var groupAPattern: String?
            var groupBPattern: String?
            var mixedPort: Int?
        }

        let legacy = try JSONDecoder().decode(LegacyV1.self, from: data)
        var migrated = RoutingProfile.starter()
        if let name = legacy.name, !name.isEmpty { migrated.name = name }
        if let port = legacy.mixedPort, (1024...65535).contains(port) { migrated.mixedPort = port }

        let exitURL = (legacy.exitProviderURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let entryURL = (legacy.entryProviderURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        var exitSubID: UUID?
        var relaySubID: UUID?
        if !exitURL.isEmpty {
            let sub = ProxySubscription(name: "出口订阅", url: exitURL, role: .exit)
            migrated.subscriptions.append(sub)
            exitSubID = sub.id
        }
        if !entryURL.isEmpty && entryURL != exitURL {
            let sub = ProxySubscription(name: "链式订阅", url: entryURL, role: .relay)
            migrated.subscriptions.append(sub)
            relaySubID = sub.id
        } else {
            relaySubID = exitSubID
        }

        for idx in migrated.nodeGroups.indices {
            if migrated.nodeGroups[idx].kind == .exit {
                migrated.nodeGroups[idx].subscriptionID = exitSubID
            } else {
                migrated.nodeGroups[idx].subscriptionID = relaySubID
            }
        }
        if let dom = legacy.domesticInterface?.trimmingCharacters(in: .whitespacesAndNewlines), !dom.isEmpty {
            if let directIdx = migrated.targets.firstIndex(where: { $0.mode == .direct }) {
                migrated.targets[directIdx].interfaceName = dom
            }
        }
        return migrated
    }
}
