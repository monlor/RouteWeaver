import Foundation

public enum RoutingConfigurationError: LocalizedError, Equatable {
    case invalidInterface(String)
    case invalidSubscription(String)
    case invalidPattern(String)
    case invalidTarget(String)
    case ambiguousRelayPattern(String)
    case duplicateTargetName(String)
    case invalidPort(String)
    case invalidController
    case invalidRule(String)
    case invalidDNS(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInterface(let field):
            return "\(field)：请选择有效的 macOS 网络接口（例如 en0，不能为 lo0 或 utun）。"
        case .invalidSubscription(let field):
            return "\(field)：请输入有效的 HTTPS 订阅地址。"
        case .invalidPattern(let field):
            return "\(field)：正则表达式无效，或包含不支持的反引号、控制字符。"
        case .invalidTarget(let detail):
            return "网络目标配置不完整：\(detail)"
        case .ambiguousRelayPattern(let targetName):
            return "网络目标「\(targetName)」的出口节点组与链式节点组共用同一订阅时，链式节点组必须设置非空且不同于出口组的正则，避免循环代理。"
        case .duplicateTargetName(let name):
            return "网络目标名称「\(name)」重复，请确保每个网络目标名称唯一。"
        case .invalidPort(let field):
            return "\(field)：请输入 1024–65535 范围内、且不与其他端口重复的端口。"
        case .invalidController:
            return "控制接口必须同时提供端口和非空密钥。"
        case .invalidRule(let detail):
            return "规则无效：\(detail)"
        case .invalidDNS(let detail):
            return "自定义 DNS 无效：\(detail)"
        }
    }
}

public struct PreloadResourceItem: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case proxyProvider
        case ruleProvider
    }

    public let key: String
    public let url: String
    public let relativePath: String
    public let kind: Kind

    public init(key: String, url: String, relativePath: String, kind: Kind) {
        self.key = key
        self.url = url
        self.relativePath = relativePath
        self.kind = kind
    }
}

public struct RenderedMihomoConfig: Sendable {
    public let data: Data
    public let activeProxyGroupNames: [String]
    public let requiredInterfaces: [String]
    public let tunEnabled: Bool
    public let gatewayModeEnabled: Bool
    public let preloadResources: [PreloadResourceItem]
}

public enum MihomoConfig {
    public static func relayGroupName(for outboundName: String) -> String {
        "\(outboundName)·链式"
    }
    public static let minimumVersion = "1.19.27"
    public static let healthCheckURL = "https://www.gstatic.com/generate_204"
    public static let defaultFakeIPRange = "198.18.0.1/16"
    public static let defaultFakeIPFilter: [String] = [
        "*.lan",
        "*.local",
        "*.localdomain",
        "*.example",
        "*.invalid",
        "*.localhost",
        "*.test",
        "*.home.arpa",
        "localhost.ptlogin2.qq.com",
        "localhost.sec.qq.com",
        "+.msftconnecttest.com",
        "+.msftncsi.com",
        "time.*.com",
        "time.*.gov",
        "time.*.edu.cn",
        "time.*.apple.com",
        "ntp.*.com",
        "*.ntp.org.cn",
        "+.pool.ntp.org",
        "time1.cloud.tencent.com",
        "stun.*.*",
        "stun.*.*.*",
    ]

    /// Older engines ignore the fail-closed `empty-fallback` policy.
    public static func supportsVersionOutput(_ output: String) -> Bool {
        guard let versionString = parseVersion(from: output) else { return false }
        return compareVersions(versionString, minimumVersion) != .orderedAscending
    }

    /// Extracts the semantic version (e.g. `v1.19.27`) from `mihomo -v` output.
    public static func parseVersion(from output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace)
            guard words.count > 2, words[0] == "Mihomo", words[1] == "Meta" else { continue }
            let token = String(words[2])
            let clean = token.hasPrefix("v") ? String(token.dropFirst()) : token
            let pieces = clean.split(separator: ".", omittingEmptySubsequences: false)
            guard pieces.count == 3,
                  pieces.allSatisfy({ piece in
                      !piece.isEmpty && piece.utf8.allSatisfy { (48...57).contains($0) }
                  }) else { return nil }
            return token.hasPrefix("v") ? token : "v\(clean)"
        }
        return nil
    }

    /// Compares two semantic version strings (with or without leading `v`).
    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let clean = trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
            return clean.split(separator: ".").compactMap { Int($0) }
        }
        let a = parts(lhs)
        let b = parts(rhs)
        let count = max(a.count, b.count)
        for idx in 0..<count {
            let av = idx < a.count ? a[idx] : 0
            let bv = idx < b.count ? b[idx] : 0
            if av < bv { return .orderedAscending }
            if av > bv { return .orderedDescending }
        }
        return .orderedSame
    }

    public static func render(
        _ profile: RoutingProfile,
        controllerPort: Int? = nil,
        secret: String? = nil,
        interfaceDNS: [String: [String]] = [:]
    ) throws -> Data {
        try renderDetailed(profile, controllerPort: controllerPort, secret: secret, interfaceDNS: interfaceDNS).data
    }

    /// Renders a self-contained Mihomo JSON (valid YAML 1.2) configuration.
    public static func renderDetailed(
        _ profile: RoutingProfile,
        controllerPort: Int? = nil,
        secret: String? = nil,
        interfaceDNS: [String: [String]] = [:]
    ) throws -> RenderedMihomoConfig {
        // 1. Validate listener ports
        var usedPorts = Set<Int>()
        guard (1024...65535).contains(profile.mixedPort) else {
            throw RoutingConfigurationError.invalidPort("混合代理端口")
        }
        usedPorts.insert(profile.mixedPort)

        if let httpPort = profile.httpPort {
            guard (1024...65535).contains(httpPort), usedPorts.insert(httpPort).inserted else {
                throw RoutingConfigurationError.invalidPort("独立 HTTP 端口")
            }
        }
        if let socksPort = profile.socksPort {
            guard (1024...65535).contains(socksPort), usedPorts.insert(socksPort).inserted else {
                throw RoutingConfigurationError.invalidPort("独立 SOCKS5 端口")
            }
        }

        // 2. Collect all referenced targets (expanding any `.alias` targets to their concrete leaf targets)
        let activeTargetIDs = profile.activeTargetIDs
        var targetNameSet = Set<String>()
        var leafOutboundNameByID: [UUID: String] = [:]
        var resolvedLeafByTargetID: [UUID: NetworkTarget] = [:]

        for target in profile.targets where activeTargetIDs.contains(target.id) {
            let cleanName = try checkedTargetName(target.name)
            guard targetNameSet.insert(cleanName).inserted else {
                throw RoutingConfigurationError.duplicateTargetName(cleanName)
            }
            if target.mode == .alias {
                switch profile.resolveTarget(id: target.id) {
                case .resolved(let leaf, _):
                    resolvedLeafByTargetID[target.id] = leaf
                case .missingTarget(let source, _):
                    throw RoutingConfigurationError.invalidTarget("「\(source.name)」未选择指向的网络目标，或所指向的目标不存在。")
                case .cycle(let path):
                    let chain = path.map(\.name).joined(separator: " → ")
                    throw RoutingConfigurationError.invalidTarget("网络目标存在循环引用：\(chain)。")
                case .notFound:
                    throw RoutingConfigurationError.invalidTarget("网络目标「\(cleanName)」不存在。")
                }
            } else {
                leafOutboundNameByID[target.id] = cleanName
                resolvedLeafByTargetID[target.id] = target
            }
        }

        var outboundNameByTargetID: [UUID: String] = [:]
        for (targetID, leaf) in resolvedLeafByTargetID {
            if let leafName = leafOutboundNameByID[leaf.id] {
                outboundNameByTargetID[targetID] = leafName
            }
        }

        // Verify fallback target exists if not REJECT
        if case .target(let id) = profile.fallbackTarget, outboundNameByTargetID[id] == nil {
            throw RoutingConfigurationError.invalidTarget("默认兜底目标不存在，请重新选择。")
        }

        // Verify every effectively active rule group points to an existing target
        for group in profile.ruleGroups where group.isEffectivelyActive {
            if case .target(let id) = group.target, outboundNameByTargetID[id] == nil {
                throw RoutingConfigurationError.invalidTarget("规则组「\(group.name)」指向的网络目标不存在。")
            }
        }

        // 3. Build proxies, proxy-providers, and proxy-groups for all active concrete (leaf) targets
        var proxies: [[String: Any]] = []
        var providers: [String: [String: Any]] = [:]
        var providerKeyBySignature: [String: String] = [:]
        var proxyGroups: [[String: Any]] = []
        var activeProxyGroupNames: [String] = []
        var requiredInterfaces = Set<String>()
        var usedOutboundNames = Set(leafOutboundNameByID.values)

        func ensureSharedProvider(url: String, interface: String?) -> String {
            let signature = "\(url)\u{0}\(interface ?? "")"
            if let existing = providerKeyBySignature[signature] {
                return existing
            }
            let key = "p-\(shortHash(signature))"
            providers[key] = provider(
                url: url,
                key: key,
                pattern: "",
                excludePattern: "",
                prefix: "",
                dialer: "",
                interface: interface
            )
            providerKeyBySignature[signature] = key
            return key
        }

        for (index, target) in profile.targets.enumerated() where leafOutboundNameByID[target.id] != nil {
            let outboundName = leafOutboundNameByID[target.id]!
            let boundInterface: String?
            if let rawIface = target.normalizedInterface {
                let checked = try checkedInterface(rawIface, field: "网络目标「\(outboundName)」网卡")
                boundInterface = checked
                requiredInterfaces.insert(checked)
            } else {
                boundInterface = nil
            }

            switch target.mode {
            case .alias:
                continue

            case .direct:
                proxies.append(directProxy(outboundName, interface: boundInterface))

            case .proxy:
                guard let exitGroup = profile.nodeGroup(id: target.exitGroupID) else {
                    throw RoutingConfigurationError.invalidTarget("「\(outboundName)」未选择出口节点组。")
                }
                guard let exitSub = profile.subscription(id: exitGroup.subscriptionID) else {
                    throw RoutingConfigurationError.invalidTarget("「\(outboundName)」的出口节点组「\(exitGroup.name)」尚未绑定订阅。")
                }
                let exitURL = try checkedURL(exitSub.url, field: "订阅「\(exitSub.name)」")
                let exitPattern = try checkedPattern(exitGroup.filterPattern, field: "节点组「\(exitGroup.name)」")
                let exitExcludePattern = try checkedPattern(exitGroup.excludeFilterPattern, field: "节点组「\(exitGroup.name)」排除正则")

                var dialerGroupName = ""

                if let relayID = target.relayGroupID {
                    guard let relayGroup = profile.nodeGroup(id: relayID) else {
                        throw RoutingConfigurationError.invalidTarget("「\(outboundName)」选择的链式节点组不存在。")
                    }
                    guard let relaySub = profile.subscription(id: relayGroup.subscriptionID) else {
                        throw RoutingConfigurationError.invalidTarget("「\(outboundName)」的链式节点组「\(relayGroup.name)」尚未绑定订阅。")
                    }
                    let relayURL = try checkedURL(relaySub.url, field: "订阅「\(relaySub.name)」")
                    let relayPattern = try checkedPattern(relayGroup.filterPattern, field: "节点组「\(relayGroup.name)」")
                    let relayExcludePattern = try checkedPattern(relayGroup.excludeFilterPattern, field: "节点组「\(relayGroup.name)」排除正则")

                    if relayURL == exitURL,
                       (relayPattern.isEmpty && relayExcludePattern.isEmpty)
                       || (relayPattern == exitPattern && relayExcludePattern == exitExcludePattern) {
                        throw RoutingConfigurationError.ambiguousRelayPattern(outboundName)
                    }

                    let relayMihomoGroupName = Self.relayGroupName(for: outboundName)
                    guard usedOutboundNames.insert(relayMihomoGroupName).inserted else {
                        throw RoutingConfigurationError.duplicateTargetName(relayMihomoGroupName)
                    }
                    let relayProviderKey = ensureSharedProvider(url: relayURL, interface: boundInterface)
                    proxyGroups.append(
                        proxyGroup(
                            relayMihomoGroupName,
                            provider: relayProviderKey,
                            pattern: relayPattern,
                            excludePattern: relayExcludePattern,
                            automatic: relayGroup.autoTest
                        )
                    )
                    activeProxyGroupNames.append(relayMihomoGroupName)
                    dialerGroupName = relayMihomoGroupName
                }

                if dialerGroupName.isEmpty {
                    let exitProviderKey = ensureSharedProvider(url: exitURL, interface: boundInterface)
                    proxyGroups.append(
                        proxyGroup(
                            outboundName,
                            provider: exitProviderKey,
                            pattern: exitPattern,
                            excludePattern: exitExcludePattern,
                            automatic: exitGroup.autoTest
                        )
                    )
                } else {
                    // Chained exit needs a dedicated provider for `dialer-proxy` and `additional-prefix`;
                    // apply filter/exclude-filter on the provider so they run before `additional-prefix`.
                    let exitProviderKey = "t\(index)-\(shortHash(target.id.uuidString))-exit"
                    providers[exitProviderKey] = provider(
                        url: exitURL,
                        key: exitProviderKey,
                        pattern: exitPattern,
                        excludePattern: exitExcludePattern,
                        prefix: "[\(outboundName)] ",
                        dialer: dialerGroupName,
                        interface: nil
                    )
                    proxyGroups.append(
                        proxyGroup(
                            outboundName,
                            provider: exitProviderKey,
                            pattern: "",
                            excludePattern: "",
                            automatic: exitGroup.autoTest,
                            tolerance: 100
                        )
                    )
                }
                activeProxyGroupNames.append(outboundName)
            }
        }

        // 4. Collect resolved target metadata (mode & bound interface) for DNS routing and rule-provider proxy selection
        var targetByID: [UUID: NetworkTarget] = [:]
        var boundInterfaceByTargetID: [UUID: String] = [:]
        for (targetID, leaf) in resolvedLeafByTargetID {
            targetByID[targetID] = leaf
            if let iface = leaf.normalizedInterface {
                boundInterfaceByTargetID[targetID] = iface
            }
        }

        let activeLeafTargetIDs = Set(leafOutboundNameByID.keys)
        let preferredProxyGroupName: String? = {
            if case .target(let id) = profile.fallbackTarget,
               targetByID[id]?.mode == .proxy,
               let name = outboundNameByTargetID[id] {
                return name
            }
            for target in profile.targets where activeLeafTargetIDs.contains(target.id) && target.mode == .proxy {
                if let name = leafOutboundNameByID[target.id] {
                    return name
                }
            }
            return nil
        }()

        // 5. Build rules, rule-providers, and DNS nameserver-policy entries in rule priority order
        let builtRules = try buildRules(
            profile: profile,
            outboundNameByTargetID: outboundNameByTargetID,
            targetByID: targetByID,
            boundInterfaceByTargetID: boundInterfaceByTargetID,
            preferredProxyGroupName: preferredProxyGroupName,
            interfaceDNS: interfaceDNS
        )

        let useTun = profile.effectiveTunEnabled
        let allowLAN = profile.effectiveAllowLAN
        let gatewayEnabled = profile.gatewayModeEnabled

        let tunConfig: [String: Any]
        if useTun {
            var tun: [String: Any] = [
                "enable": true,
                "stack": profile.tunStack.rawValue,
                "auto-route": true,
                "auto-detect-interface": true,
                "strict-route": profile.tunStrictRoute,
                "dns-hijack": ["any:53", "tcp://any:53"],
            ]
            if gatewayEnabled {
                tun["endpoint-independent-nat"] = true
            }
            tunConfig = tun
        } else {
            tunConfig = ["enable": false]
        }

        var config: [String: Any] = [
            "mode": "rule",
            "mixed-port": profile.mixedPort,
            "allow-lan": allowLAN,
            "bind-address": allowLAN ? "*" : "127.0.0.1",
            "log-level": profile.logLevel.rawValue,
            "ipv6": profile.ipv6Enabled,
            "tcp-concurrent": true,
            "unified-delay": true,
            "keep-alive-idle": 15,
            "keep-alive-interval": 15,
            "find-process-mode": (useTun || builtRules.hasProcessRule || !builtRules.ruleProviders.isEmpty) ? "strict" : "off",
            "geo-auto-update": false,
            "geox-url": BundledResourceManager.defaultGeoURLs,
            "tun": tunConfig,
            "profile": ["store-selected": true],
            "proxies": proxies,
            "proxy-providers": providers,
            "proxy-groups": proxyGroups,
            "rules": builtRules.rules,
        ]
        if useTun {
            config["sniffer"] = [
                "enable": true,
                "parse-pure-ip": true,
                "sniff": [
                    "HTTP": [
                        "ports": [80, "8080-8880"],
                        "override-destination": true,
                    ],
                    "TLS": [
                        "ports": [443, 8443],
                    ],
                    "QUIC": [
                        "ports": [443, 8443],
                    ],
                ],
            ]
        }
        if !builtRules.subRules.isEmpty {
            config["sub-rules"] = builtRules.subRules
        }
        if !builtRules.ruleProviders.isEmpty {
            config["rule-providers"] = builtRules.ruleProviders
        }

        // 6. Merge enabled Host modules (e.g. Surge .sgmodule [Host] CNAME/IP mappings)
        //    and custom DNS Host entries (exact or wildcard hosts; custom entries override module entries).
        var mergedHosts: [String: Any] = [:]
        for module in profile.hostModules where module.isEnabled {
            for (rawHost, rawTarget) in module.cachedHosts {
                let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
                let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty, !target.isEmpty,
                      host.caseInsensitiveCompare(target) != .orderedSame,
                      !host.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      !target.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                    continue
                }
                if target.contains(",") {
                    let values = target.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty && $0.caseInsensitiveCompare(host) != .orderedSame }
                    if values.count > 1 {
                        mergedHosts[host] = values
                    } else if let only = values.first {
                        mergedHosts[host] = only
                    }
                } else {
                    mergedHosts[host] = target
                }
            }
        }

        // Validate & collect custom DNS entries (Host mappings, per-domain Server policies, and Fake-IP bypass patterns)
        var customDNSPolicies: [(key: String, servers: [String])] = []
        var customFakeIPFilters: [String] = []
        for entry in profile.customDNS.entries where entry.isEnabled {
            let pattern = entry.trimmedPattern
            switch entry.kind {
            case .host:
                if entry.isLikelySwappedHost {
                    throw RoutingConfigurationError.invalidDNS("Host 规则「\(pattern) → \(entry.value)」域名与 IP 顺序填反了，请在「自定义 DNS」页点击一键纠正。")
                }
                guard CustomDNSValidator.isValidPattern(pattern, allowPolicyPrefix: false) else {
                    throw RoutingConfigurationError.invalidDNS("Host 域名或通配符「\(entry.pattern)」格式无效。")
                }
                let values = entry.splitValues
                guard !values.isEmpty,
                      values.allSatisfy({ CustomDNSValidator.isValidHostTarget($0, forPattern: pattern) }) else {
                    throw RoutingConfigurationError.invalidDNS("Host「\(pattern)」的映射值无效，或与域名自身相同。")
                }
                if values.count > 1 {
                    mergedHosts[pattern] = values
                } else if let only = values.first {
                    mergedHosts[pattern] = only
                }
            case .server:
                guard CustomDNSValidator.isValidPattern(pattern, allowPolicyPrefix: true) else {
                    throw RoutingConfigurationError.invalidDNS("DNS 策略域名或通配符「\(entry.pattern)」格式无效。")
                }
                let rawServers = entry.splitValues
                guard !rawServers.isEmpty, rawServers.allSatisfy(CustomDNSValidator.isValidServer) else {
                    throw RoutingConfigurationError.invalidDNS("域名「\(pattern)」的 DNS 服务器地址格式无效。")
                }
                let boundOutboundName: String?
                if let targetID = entry.targetID {
                    guard let resolved = outboundNameByTargetID[targetID] else {
                        throw RoutingConfigurationError.invalidDNS("域名「\(pattern)」指定的解析出口目标不存在，请重新选择。")
                    }
                    boundOutboundName = resolved
                } else {
                    boundOutboundName = nil
                }
                let resolvedServers = rawServers.map { rawServer -> String in
                    let server = CustomDNSValidator.normalizedServer(rawServer)
                    if let outbound = boundOutboundName, !server.contains("#") {
                        return "\(server)#\(outbound)"
                    }
                    return server
                }
                customDNSPolicies.append((key: pattern, servers: resolvedServers))
                if entry.bypassFakeIP,
                   !pattern.lowercased().hasPrefix("geosite:"),
                   !pattern.lowercased().hasPrefix("rule-set:") {
                    customFakeIPFilters.append(pattern)
                }
            }
        }

        let customDirectServers = profile.customDNS.directServers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for server in customDirectServers where !CustomDNSValidator.isValidServer(server) {
            throw RoutingConfigurationError.invalidDNS("自定义直连上游 DNS「\(server)」格式无效。")
        }
        let normalizedCustomDirectServers = customDirectServers.map(CustomDNSValidator.normalizedServer)

        let customBootstrapServers = profile.customDNS.bootstrapServers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for server in customBootstrapServers where !CustomDNSValidator.isValidServer(server) {
            throw RoutingConfigurationError.invalidDNS("自定义引导 DNS「\(server)」格式无效。")
        }
        let normalizedCustomBootstrapServers = customBootstrapServers.map(CustomDNSValidator.normalizedServer)

        if !mergedHosts.isEmpty {
            config["hosts"] = mergedHosts
        }

        // 7. Build anti-DNS-leak & interface-aware DNS configuration:
        //    - Proxy-routed traffic resolves via its proxy group (`#<proxyGroup>`), never leaking to domestic DNS.
        //    - Direct-routed traffic resolves via domestic DoH bound to its target interface (`#<interface>`).
        //    - Proxy node domains stay isolated on `proxy-server-nameserver` with `respect-rules: false` (no loop).
        //    - Subscription & direct rule-provider hosts are pinned to direct DNS in `nameserver-policy` so
        //      `direct-nameserver-follow-policy: true` can never deadlock provider downloads through a proxy group.
        var directBypassHosts: [String] = []
        var seenBypassHosts = Set<String>()
        func recordBypassHost(from rawURL: String) {
            guard let host = URLComponents(string: rawURL)?.host?.lowercased(),
                  !host.isEmpty,
                  seenBypassHosts.insert(host).inserted else { return }
            directBypassHosts.append(host)
        }
        for (_, providerEntry) in providers.sorted(by: { $0.key < $1.key }) {
            if let rawURL = providerEntry["url"] as? String {
                recordBypassHost(from: rawURL)
            }
        }
        for (_, ruleProviderEntry) in builtRules.ruleProviders.sorted(by: { $0.key < $1.key }) {
            if (ruleProviderEntry["proxy"] as? String) == "DIRECT",
               let rawURL = ruleProviderEntry["url"] as? String {
                recordBypassHost(from: rawURL)
            }
        }

        config["dns"] = buildDNSConfig(
            profile: profile,
            activeLeafTargetIDs: activeLeafTargetIDs,
            outboundNameByTargetID: outboundNameByTargetID,
            targetByID: targetByID,
            boundInterfaceByTargetID: boundInterfaceByTargetID,
            dnsPolicies: builtRules.dnsPolicies,
            customDNSPolicies: customDNSPolicies,
            customFakeIPFilters: customFakeIPFilters,
            customDirectServers: normalizedCustomDirectServers,
            customBootstrapServers: normalizedCustomBootstrapServers,
            directBypassHosts: directBypassHosts,
            interfaceDNS: interfaceDNS
        )

        if let httpPort = profile.httpPort {
            config["port"] = httpPort
        }
        if let socksPort = profile.socksPort {
            config["socks-port"] = socksPort
        }

        switch (controllerPort, secret) {
        case (nil, nil):
            break
        case let (.some(port), .some(key)):
            guard (1024...65535).contains(port), !usedPorts.contains(port) else {
                throw RoutingConfigurationError.invalidPort("控制端口")
            }
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw RoutingConfigurationError.invalidController
            }
            config["external-controller"] = "127.0.0.1:\(port)"
            config["secret"] = key
        default:
            throw RoutingConfigurationError.invalidController
        }

        let data = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )

        var preloadResources: [PreloadResourceItem] = []
        for (key, entry) in providers.sorted(by: { $0.key < $1.key }) {
            if let url = entry["url"] as? String,
               let relPath = entry["path"] as? String {
                preloadResources.append(
                    PreloadResourceItem(key: key, url: url, relativePath: relPath, kind: .proxyProvider)
                )
            }
        }
        for (key, entry) in builtRules.ruleProviders.sorted(by: { $0.key < $1.key }) {
            if let url = entry["url"] as? String,
               let relPath = entry["path"] as? String {
                preloadResources.append(
                    PreloadResourceItem(key: key, url: url, relativePath: relPath, kind: .ruleProvider)
                )
            }
        }

        return RenderedMihomoConfig(
            data: data,
            activeProxyGroupNames: activeProxyGroupNames,
            requiredInterfaces: requiredInterfaces.sorted(),
            tunEnabled: useTun,
            gatewayModeEnabled: gatewayEnabled,
            preloadResources: preloadResources
        )
    }

    private struct BuiltRulesResult {
        let rules: [String]
        let subRules: [String: [String]]
        let ruleProviders: [String: [String: Any]]
        let hasProcessRule: Bool
        let dnsPolicies: [(key: String, servers: [String])]
    }

    private static func usableInterfaceDNS(
        for interface: String?,
        in interfaceDNS: [String: [String]]
    ) -> [String] {
        guard let interface, let discovered = interfaceDNS[interface], !discovered.isEmpty else {
            return []
        }
        var result: [String] = []
        for rawIP in discovered {
            let trimmed = rawIP.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !CustomDNSValidator.isLinkLocalIPv6(trimmed) else { continue }
            let formatted = CustomDNSValidator.normalizedServer(trimmed)
            if !result.contains(formatted) {
                result.append(formatted)
            }
        }
        return result
    }

    private static func bootstrapDNS(
        interface: String?,
        interfaceDNS: [String: [String]],
        avoidSystemDNS: Bool = false
    ) -> [String] {
        var result: [String] = []
        let discovered = usableInterfaceDNS(for: interface, in: interfaceDNS)
        if !discovered.isEmpty {
            result.append(contentsOf: discovered)
        } else if !avoidSystemDNS {
            result.append("system")
        }
        for fallback in ["223.5.5.5", "119.29.29.29"] where !result.contains(fallback) {
            result.append(fallback)
        }
        return result
    }

    /// Resolves DNS for a direct target:
    /// - When bound to a specific interface (e.g. USB eSIM `en10`), binds DNS strictly through the direct
    ///   target outbound (`#<outboundName>`) using discovered interface DNS + DoH, avoiding Mihomo's
    ///   `dhcp://<iface>` broadcast which fails with `sendto: no route to host` on macOS.
    /// - When unbound, uses system + reliable IP fallbacks (or omits `system` in TUN mode where macOS
    ///   system DNS is hijacked to `198.18.0.2` to prevent a self-lookup loop).
    private static func directTargetDNS(
        outboundName: String?,
        interface: String?,
        interfaceDNS: [String: [String]],
        customDirectServers: [String] = [],
        avoidSystemDNS: Bool = false
    ) -> [String] {
        if !customDirectServers.isEmpty {
            let normalized = customDirectServers.map(CustomDNSValidator.normalizedServer)
            if let interface, !interface.isEmpty, let outboundName {
                return normalized.map { server in
                    server.contains("#") ? server : "\(server)#\(outboundName)"
                }
            }
            return normalized
        }
        guard let interface else {
            return avoidSystemDNS ? ["223.5.5.5", "119.29.29.29"] : ["system", "223.5.5.5", "119.29.29.29"]
        }
        if let outboundName {
            let discovered = usableInterfaceDNS(for: interface, in: interfaceDNS)
            if !discovered.isEmpty {
                var servers: [String] = []
                for ip in discovered {
                    let entry = "\(ip)#\(outboundName)"
                    if !servers.contains(entry) {
                        servers.append(entry)
                    }
                }
                return servers
            }
            return [
                "https://1.1.1.1/dns-query#\(outboundName)",
                "https://8.8.8.8/dns-query#\(outboundName)",
            ]
        }
        return bootstrapDNS(interface: interface, interfaceDNS: interfaceDNS, avoidSystemDNS: avoidSystemDNS)
    }

    private static func proxyDoH(group: String) -> [String] {
        [
            "https://1.1.1.1/dns-query#\(group)",
            "https://8.8.8.8/dns-query#\(group)",
        ]
    }

    private static func buildDNSConfig(
        profile: RoutingProfile,
        activeLeafTargetIDs: Set<UUID>,
        outboundNameByTargetID: [UUID: String],
        targetByID: [UUID: NetworkTarget],
        boundInterfaceByTargetID: [UUID: String],
        dnsPolicies: [(key: String, servers: [String])],
        customDNSPolicies: [(key: String, servers: [String])],
        customFakeIPFilters: [String],
        customDirectServers: [String],
        customBootstrapServers: [String],
        directBypassHosts: [String],
        interfaceDNS: [String: [String]]
    ) -> [String: Any] {
        let useTun = profile.effectiveTunEnabled
        let activeTargets = profile.targets.filter { activeLeafTargetIDs.contains($0.id) }

        // If every active target binds the exact same interface (e.g. USB-only en10),
        // prefer that interface's discovered DNS; otherwise use system + IP fallbacks.
        let allTargetInterfaces = Set(activeTargets.map { boundInterfaceByTargetID[$0.id] ?? "" })
        let sharedBootstrapInterface: String? = (allTargetInterfaces.count == 1 && allTargetInterfaces.first != "")
            ? allTargetInterfaces.first
            : nil

        // If all active proxy targets share a single first-hop bound interface, prefer its discovered DNS.
        let activeProxyTargets = activeTargets.filter { $0.mode == .proxy }
        let proxyInterfaces = Set(activeProxyTargets.map { boundInterfaceByTargetID[$0.id] ?? "" })
        let sharedProxyInterface: String? = (proxyInterfaces.count == 1 && proxyInterfaces.first != "")
            ? proxyInterfaces.first
            : nil

        // Choose default direct-nameserver target/interface:
        // - If MATCH is a direct target, follow its target outbound & interface.
        // - Otherwise, only bind a specific interface when ALL active direct targets share that same interface.
        let primaryDirectTarget: (name: String?, interface: String?) = {
            if case .target(let id) = profile.fallbackTarget,
               targetByID[id]?.mode == .direct {
                return (outboundNameByTargetID[id], boundInterfaceByTargetID[id])
            }
            let activeDirectTargets = activeTargets.filter { $0.mode == .direct }
            let directInterfaces = Set(activeDirectTargets.map { boundInterfaceByTargetID[$0.id] ?? "" })
            if directInterfaces.count == 1, let only = directInterfaces.first, !only.isEmpty {
                let firstTargetName = activeDirectTargets.first.flatMap { outboundNameByTargetID[$0.id] }
                return (firstTargetName, only)
            }
            return (nil, nil)
        }()

        // Default nameserver follows the fallback (MATCH) target to prevent DNS leaks:
        // - If MATCH goes to a proxy group P: default nameserver queries overseas DoH via `#P`.
        // - If MATCH goes to direct target D (or REJECT): default nameserver uses D's interface-bound DNS or system.
        let defaultNameserver: [String] = {
            if case .target(let id) = profile.fallbackTarget,
               let target = targetByID[id] {
                switch target.mode {
                case .proxy:
                    if let name = outboundNameByTargetID[id] {
                        return proxyDoH(group: name)
                    }
                case .direct:
                    return directTargetDNS(
                        outboundName: outboundNameByTargetID[id],
                        interface: boundInterfaceByTargetID[id],
                        interfaceDNS: interfaceDNS,
                        customDirectServers: customDirectServers,
                        avoidSystemDNS: useTun
                    )
                case .alias:
                    break
                }
            }
            return directTargetDNS(
                outboundName: primaryDirectTarget.name,
                interface: primaryDirectTarget.interface,
                interfaceDNS: interfaceDNS,
                customDirectServers: customDirectServers,
                avoidSystemDNS: useTun
            )
        }()

        let directNameserver = directTargetDNS(
            outboundName: primaryDirectTarget.name,
            interface: primaryDirectTarget.interface,
            interfaceDNS: interfaceDNS,
            customDirectServers: customDirectServers,
            avoidSystemDNS: useTun
        )

        // Build nameserver-policy preserving priority order:
        // 1. User-defined custom DNS server policies (highest priority; never omitted even if equal to defaultNameserver,
        //    so specific custom overrides still win over broader rule-group policies).
        // 2. Subscription & direct rule-provider bypass hosts (prevent circular deadlock on startup).
        // 3. Rule-group derived DNS policies (omit redundant entries matching defaultNameserver).
        var policyMap: [String: [String]] = [:]
        var seenPolicyKeys = Set<String>()
        for entry in customDNSPolicies {
            guard seenPolicyKeys.insert(entry.key).inserted else { continue }
            policyMap[entry.key] = entry.servers
        }
        for host in directBypassHosts {
            guard seenPolicyKeys.insert(host).inserted else { continue }
            if directNameserver != defaultNameserver {
                policyMap[host] = directNameserver
            }
        }
        for entry in dnsPolicies {
            guard seenPolicyKeys.insert(entry.key).inserted else { continue }
            if entry.servers != defaultNameserver {
                policyMap[entry.key] = entry.servers
            }
        }
        // Isolate domestic domains from proxy MATCH failures so a proxy outage never breaks CN DNS.
        if defaultNameserver != directNameserver,
           seenPolicyKeys.insert("geosite:cn").inserted {
            policyMap["geosite:cn"] = directNameserver
        }

        let resolvedDefaultBootstrap = customBootstrapServers.isEmpty
            ? bootstrapDNS(interface: sharedBootstrapInterface, interfaceDNS: interfaceDNS, avoidSystemDNS: useTun)
            : customBootstrapServers
        let resolvedProxyBootstrap = customBootstrapServers.isEmpty
            ? bootstrapDNS(interface: sharedProxyInterface, interfaceDNS: interfaceDNS, avoidSystemDNS: useTun)
            : customBootstrapServers

        let enhancedMode = useTun ? profile.tunDNSMode.rawValue : "redir-host"
        var dnsConfig: [String: Any] = [
            "enable": true,
            "ipv6": profile.ipv6Enabled,
            "cache-algorithm": "arc",
            "use-hosts": true,
            "use-system-hosts": true,
            "enhanced-mode": enhancedMode,
            "respect-rules": false,
            "default-nameserver": resolvedDefaultBootstrap,
            "proxy-server-nameserver": resolvedProxyBootstrap,
            "direct-nameserver": directNameserver,
            "direct-nameserver-follow-policy": true,
            "nameserver": defaultNameserver,
        ]
        if profile.gatewayModeEnabled {
            dnsConfig["listen"] = "0.0.0.0:53"
        }
        if useTun && profile.tunDNSMode == .fakeIP {
            dnsConfig["fake-ip-range"] = defaultFakeIPRange
            var fakeIPFilter = defaultFakeIPFilter
            for pattern in customFakeIPFilters where !fakeIPFilter.contains(pattern) {
                fakeIPFilter.append(pattern)
            }
            dnsConfig["fake-ip-filter"] = fakeIPFilter
        }
        if !policyMap.isEmpty {
            dnsConfig["nameserver-policy"] = policyMap
        }
        return dnsConfig
    }

    private static func buildRules(
        profile: RoutingProfile,
        outboundNameByTargetID: [UUID: String],
        targetByID: [UUID: NetworkTarget],
        boundInterfaceByTargetID: [UUID: String],
        preferredProxyGroupName: String?,
        interfaceDNS: [String: [String]]
    ) throws -> BuiltRulesResult {
        var result: [String] = []
        var subRules: [String: [String]] = [:]
        var ruleProviders: [String: [String: Any]] = [:]
        var hasProcessRule = false
        var dnsPolicies: [(key: String, servers: [String])] = []

        for (groupIndex, group) in profile.ruleGroups.enumerated() where group.isEnabled {
            let enabledRules = group.rules.filter(\.isEnabled)
            guard !enabledRules.isEmpty else { continue }

            var clientCIDRs: [String] = []
            if group.clientScopeMode != .all {
                let enabledClients = group.enabledClientEntries
                if group.clientScopeMode == .include && enabledClients.isEmpty {
                    continue
                }
                var seenCIDRs = Set<String>()
                for entry in enabledClients {
                    guard let cidr = ClientAddressValidator.normalizedCIDR(entry.address) else {
                        throw RoutingConfigurationError.invalidRule(
                            "规则组「\(group.name)」中的生效设备地址「\(entry.address)」格式无效，请输入有效的 IPv4/IPv6 地址或 CIDR 网段。"
                        )
                    }
                    if seenCIDRs.insert(cidr).inserted {
                        clientCIDRs.append(cidr)
                    }
                }
            }
            let isClientScoped = group.clientScopeMode != .all && !clientCIDRs.isEmpty

            let targetName: String
            let groupDNSServers: [String]?
            switch group.target {
            case .reject:
                targetName = "REJECT"
                groupDNSServers = nil
            case .target(let id):
                guard let resolved = outboundNameByTargetID[id], let target = targetByID[id] else {
                    throw RoutingConfigurationError.invalidTarget("规则组「\(group.name)」指向的网络目标不存在。")
                }
                targetName = resolved
                if isClientScoped {
                    // `dns.nameserver-policy` is global and cannot match by client source IP;
                    // skip emitting global DNS policies for device-scoped groups so other devices are unaffected.
                    groupDNSServers = nil
                } else {
                    switch target.mode {
                    case .proxy:
                        groupDNSServers = proxyDoH(group: resolved)
                    case .direct:
                        let customDirect = profile.customDNS.directServers
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        groupDNSServers = directTargetDNS(
                            outboundName: resolved,
                            interface: boundInterfaceByTargetID[id],
                            interfaceDNS: interfaceDNS,
                            customDirectServers: customDirect,
                            avoidSystemDNS: profile.effectiveTunEnabled
                        )
                    case .alias:
                        groupDNSServers = nil
                    }
                }
            }

            var groupRules: [String] = []
            for rule in enabledRules {
                let value = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if rule.type == .ruleSet {
                    let cleanURL = try checkedURL(value, field: "规则组「\(group.name)」远程规则集")
                    let resolved = try RuleSetResolver.resolve(
                        url: cleanURL,
                        format: rule.ruleSetFormat,
                        behavior: rule.ruleSetBehavior
                    )
                    let providerProxy = try resolveRuleProviderProxy(
                        url: cleanURL,
                        mode: profile.ruleProviderProxyMode,
                        outboundNameByTargetID: outboundNameByTargetID,
                        preferredProxyGroupName: preferredProxyGroupName
                    )
                    let key = Self.ruleSetProviderKey(for: cleanURL)
                    if ruleProviders[key] == nil {
                        ruleProviders[key] = [
                            "type": "http",
                            "behavior": resolved.behavior,
                            "format": resolved.format,
                            "url": cleanURL,
                            "path": "./rulesets-cache/\(key).\(resolved.fileExt)",
                            "interval": max(1, profile.ruleSetUpdateIntervalHours) * 3_600,
                            "proxy": providerProxy,
                            "size-limit": 5_242_880,
                        ]
                    }
                    // Mihomo nameserver-policy supports domain & classical rule-sets, but rejects ipcidr.
                    if let servers = groupDNSServers, resolved.behavior != "ipcidr" {
                        dnsPolicies.append(("rule-set:\(key)", servers))
                    }
                    if rule.ruleSetNoResolve == true {
                        groupRules.append("RULE-SET,\(key),\(targetName),no-resolve")
                    } else {
                        groupRules.append("RULE-SET,\(key),\(targetName)")
                    }
                    continue
                }

                guard !value.isEmpty,
                      !value.contains(","),
                      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                    throw RoutingConfigurationError.invalidRule("规则组「\(group.name)」中存在空值或含逗号/控制字符的规则。")
                }
                if !rule.type.allowsSpaces,
                   value.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) {
                    throw RoutingConfigurationError.invalidRule("规则组「\(group.name)」的 \(rule.type.rawValue) 规则不能包含空白字符。")
                }
                if rule.type == .dstPort {
                    guard let port = Int(value), (1...65535).contains(port) else {
                        throw RoutingConfigurationError.invalidRule("DST-PORT 必须为 1–65535 的整数。")
                    }
                }
                if rule.type == .srcIPCIDR {
                    guard ClientAddressValidator.normalizedCIDR(value) != nil else {
                        throw RoutingConfigurationError.invalidRule("规则组「\(group.name)」的 SRC-IP-CIDR 规则「\(value)」格式无效，请输入有效的 IPv4/IPv6 地址或 CIDR 网段。")
                    }
                }
                if rule.type.isProcessRule {
                    hasProcessRule = true
                }
                if let servers = groupDNSServers {
                    switch rule.type {
                    case .domain:
                        if value.lowercased() != "localhost" {
                            dnsPolicies.append((value, servers))
                        }
                    case .domainSuffix:
                        let cleanSuffix = value.hasPrefix(".") ? String(value.dropFirst()) : value
                        if !cleanSuffix.isEmpty {
                            dnsPolicies.append(("+.\(cleanSuffix)", servers))
                        }
                    case .geosite:
                        dnsPolicies.append(("geosite:\(value)", servers))
                    default:
                        break
                    }
                }
                groupRules.append(rule.formatted(target: targetName))
            }

            if isClientScoped {
                let subRuleName = "rg-\(groupIndex)-\(shortHash(group.id.uuidString))"
                let condition = clientScopeCondition(mode: group.clientScopeMode, cidrs: clientCIDRs)
                result.append("SUB-RULE,\(condition),\(subRuleName)")
                subRules[subRuleName] = groupRules
            } else {
                result.append(contentsOf: groupRules)
            }
        }

        let fallbackName: String
        switch profile.fallbackTarget {
        case .reject:
            fallbackName = "REJECT"
        case .target(let id):
            guard let resolved = outboundNameByTargetID[id] else {
                throw RoutingConfigurationError.invalidTarget("默认兜底目标不存在。")
            }
            fallbackName = resolved
        }
        result.append("MATCH,\(fallbackName)")
        return BuiltRulesResult(
            rules: result,
            subRules: subRules,
            ruleProviders: ruleProviders,
            hasProcessRule: hasProcessRule,
            dnsPolicies: dnsPolicies
        )
    }

    private static func clientScopeCondition(mode: RuleGroupClientScopeMode, cidrs: [String]) -> String {
        let matchExpr: String
        if cidrs.count == 1 {
            matchExpr = "(SRC-IP-CIDR,\(cidrs[0]))"
        } else {
            let items = cidrs.map { "(SRC-IP-CIDR,\($0))" }.joined(separator: ",")
            matchExpr = "(OR,(\(items)))"
        }
        switch mode {
        case .exclude:
            return "(NOT,(\(matchExpr)))"
        case .include, .all:
            return matchExpr
        }
    }

    private static let githubHosts: Set<String> = [
        "raw.githubusercontent.com",
        "github.com",
        "gist.githubusercontent.com",
        "objects.githubusercontent.com",
    ]

    private static func resolveRuleProviderProxy(
        url: String,
        mode: RuleProviderProxyMode,
        outboundNameByTargetID: [UUID: String],
        preferredProxyGroupName: String?
    ) throws -> String {
        switch mode {
        case .direct:
            return "DIRECT"
        case .target(let id):
            guard let name = outboundNameByTargetID[id] else {
                throw RoutingConfigurationError.invalidTarget("规则集下载指定的网络目标不存在，请重新选择。")
            }
            return name
        case .auto:
            let host = URLComponents(string: url)?.host?.lowercased() ?? ""
            if githubHosts.contains(host), let proxyGroup = preferredProxyGroupName {
                return proxyGroup
            }
            return "DIRECT"
        }
    }

    private static let reservedTargetNames: Set<String> = [
        "DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "GLOBAL",
    ]

    private static func checkedTargetName(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.contains(","),
              !value.contains("/"),
              !reservedTargetNames.contains(value.uppercased()),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RoutingConfigurationError.invalidTarget("目标名称不能为空，不能包含逗号、斜杠，且不能使用 Mihomo 保留名称（DIRECT、REJECT、REJECT-DROP、PASS、COMPATIBLE、GLOBAL）。")
        }
        return value
    }

    private static func checkedInterface(_ raw: String, field: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func directProxy(_ name: String, interface: String?) -> [String: Any] {
        var entry: [String: Any] = ["name": name, "type": "direct", "udp": true]
        if let interface {
            entry["interface-name"] = interface
        }
        return entry
    }

    private static func provider(
        url: String, key: String, pattern: String, excludePattern: String, prefix: String, dialer: String, interface: String? = nil
    ) -> [String: Any] {
        var override: [String: String] = ["dialer-proxy": dialer]
        if !prefix.isEmpty {
            override["additional-prefix"] = prefix
        }
        if let interface {
            override["interface-name"] = interface
        }
        var data: [String: Any] = [
            "type": "http",
            "url": url,
            "path": "./providers-cache/\(key)-\(shortHash(url + "\u{0}" + pattern + "\u{0}" + excludePattern)).yaml",
            "interval": 3600,
            "proxy": "DIRECT",
            "size-limit": 5_242_880,
            "exclude-type": "direct|reject|reject-drop|pass|compatible",
            "override": override,
            "health-check": [
                "enable": false,
                "url": healthCheckURL,
                "interval": 300,
                "timeout": 5_000,
                "lazy": true,
                "expected-status": "204",
            ],
        ]
        if !pattern.isEmpty {
            data["filter"] = pattern
        }
        if !excludePattern.isEmpty {
            data["exclude-filter"] = excludePattern
        }
        return data
    }

    public static func ruleSetProviderKey(for url: String) -> String {
        "rs-\(shortHash(url.trimmingCharacters(in: .whitespacesAndNewlines)))"
    }

    private static func shortHash(_ input: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in input.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private static func proxyGroup(
        _ name: String,
        provider: String,
        pattern: String,
        excludePattern: String,
        automatic: Bool,
        tolerance: Int = 50
    ) -> [String: Any] {
        var data: [String: Any] = [
            "name": name,
            "type": automatic ? "url-test" : "select",
            "use": [provider],
            "empty-fallback": "REJECT",
        ]
        if !pattern.isEmpty {
            data["filter"] = pattern
        }
        if !excludePattern.isEmpty {
            data["exclude-filter"] = excludePattern
        }
        if automatic {
            data["url"] = healthCheckURL
            data["interval"] = 120
            data["tolerance"] = tolerance
            data["lazy"] = false
            data["expected-status"] = "204"
        }
        return data
    }
}
