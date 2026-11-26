import Foundation

/// Output of adapting a synced PC `RoutingProfile` for iOS `NEPacketTunnelProvider`.
public struct AdaptedMobileMihomoConfig: Sendable {
    public let configData: Data
    public let mode: MobileVPNMode
    /// Local SOCKS5 bridge port inside PacketTunnel that maps SOCKS5 `username` -> PC `target_iface` over `lumzel/relay`.
    public let relayBridgePort: Int
    /// Local Mihomo listener port (`IN-PORT`) that forwards Relay WebSocket traffic through an existing Mac chain `NodeGroup`.
    /// Nil when Relay connects directly (no chained proxy).
    public let relayChainEntryPort: Int?
    /// Name of the Mihomo proxy group used by `relayChainEntryPort` (reused from synced Mac `NodeGroup`).
    public let relayChainGroupName: String?
    /// PC BSD interfaces actively routed via `lumzel/relay` in this rendered config.
    public let relayedPCInterfaces: [String]
}

/// Adapts a PC-synced `RoutingProfile` into a ready-to-run iOS Mihomo configuration for:
/// - **Mode A (`.localCore`)**: Per-interface mapping (`useMobileDefault` vs `relayToPCInterface`),
///   optional `bypassChainedProxy` (for Singapore eSIM / overseas SIM), and optional `IN-PORT`
///   reuse of an existing Mac chained proxy `NodeGroup` to reach `lumzel/relay`.
/// - **Mode B (`.directPCSocks5`)**: Ultra-lightweight zero-rule Mihomo config forwarding all TUN
///   traffic directly to the LAN PC's SOCKS5 port (keeps NE memory tiny on home Wi-Fi).
public enum MobileProfileAdapter {
    public static let defaultRelayBridgePort = 19100
    public static let defaultRelayChainEntryPort = 19101
    public static let relayChainGroupOutboundName = "Relay·链式入口"

    public static func relayOutboundName(for pcInterface: String) -> String {
        "Relay-PC-\(pcInterface)"
    }

    public static func render(
        pcProfile: RoutingProfile,
        mode: MobileVPNMode,
        relayConfig: RelayEndpointConfig,
        interfaceMappings: [PCInterfaceMappingRule],
        relayBridgePort: Int = defaultRelayBridgePort,
        relayChainEntryPort: Int = defaultRelayChainEntryPort,
        controllerPort: Int? = nil,
        secret: String? = nil
    ) throws -> AdaptedMobileMihomoConfig {
        switch mode {
        case .disabled:
            return AdaptedMobileMihomoConfig(
                configData: Data("{}".utf8),
                mode: .disabled,
                relayBridgePort: relayBridgePort,
                relayChainEntryPort: nil,
                relayChainGroupName: nil,
                relayedPCInterfaces: []
            )

        case .directPCSocks5(let host, let port):
            let data = try renderDirectPCSocks5Config(
                host: host,
                port: port,
                ipv6Enabled: pcProfile.ipv6Enabled,
                tunStack: pcProfile.tunStack,
                controllerPort: controllerPort,
                secret: secret
            )
            return AdaptedMobileMihomoConfig(
                configData: data,
                mode: mode,
                relayBridgePort: relayBridgePort,
                relayChainEntryPort: nil,
                relayChainGroupName: nil,
                relayedPCInterfaces: []
            )

        case .localCore(let options):
            return try renderLocalCoreConfig(
                pcProfile: pcProfile,
                options: options,
                relayConfig: relayConfig,
                interfaceMappings: interfaceMappings,
                relayBridgePort: relayBridgePort,
                relayChainEntryPort: relayChainEntryPort,
                controllerPort: controllerPort,
                secret: secret
            )
        }
    }

    // MARK: - Mode B: Direct LAN PC SOCKS5 (Minimal Memory)

    private static func renderDirectPCSocks5Config(
        host: String,
        port: Int,
        ipv6Enabled: Bool,
        tunStack: TunStack,
        controllerPort: Int?,
        secret: String?
    ) throws -> Data {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty, (1...65535).contains(port) else {
            throw RoutingConfigurationError.invalidPort("PC SOCKS5 代理地址或端口")
        }

        let pcProxyName = "PC-LAN-SOCKS5"
        var config: [String: Any] = [
            "mode": "rule",
            "log-level": "warning",
            "ipv6": ipv6Enabled,
            "allow-lan": false,
            "bind-address": "127.0.0.1",
            "find-process-mode": "off",
            "geo-auto-update": false,
            "tun": [
                "enable": true,
                "stack": tunStack.rawValue,
                "auto-route": true,
                "auto-detect-interface": true,
                "strict-route": true,
                "dns-hijack": ["any:53", "tcp://any:53"],
            ],
            "dns": [
                "enable": true,
                "ipv6": ipv6Enabled,
                "enhanced-mode": "fake-ip",
                "fake-ip-range": MihomoConfig.defaultFakeIPRange,
                "fake-ip-filter": MihomoConfig.defaultFakeIPFilter,
                "default-nameserver": ["223.5.5.5", "119.29.29.29"],
                "nameserver": ["https://1.1.1.1/dns-query#\(pcProxyName)"],
            ],
            "proxies": [
                [
                    "name": pcProxyName,
                    "type": "socks5",
                    "server": cleanHost,
                    "port": port,
                    "udp": true,
                ]
            ],
            "rules": [
                "IP-CIDR,\(cleanHost)/32,DIRECT,no-resolve",
                "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
                "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
                "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
                "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
                "MATCH,\(pcProxyName)",
            ],
        ]

        if let controllerPort, let secret, !secret.isEmpty {
            config["external-controller"] = "127.0.0.1:\(controllerPort)"
            config["secret"] = secret
        }

        return try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    // MARK: - Mode A: Local Mihomo Core with Per-Interface Relay & Optional Chain Reuse

    private static func renderLocalCoreConfig(
        pcProfile: RoutingProfile,
        options: LocalCoreExecutionOptions,
        relayConfig: RelayEndpointConfig,
        interfaceMappings: [PCInterfaceMappingRule],
        relayBridgePort: Int,
        relayChainEntryPort: Int,
        controllerPort: Int?,
        secret: String?
    ) throws -> AdaptedMobileMihomoConfig {
        // 1. Build effective mapping lookup: scenario override > global interface mapping > `.useMobileDefault`.
        var actionByInterface: [String: PCInterfaceMappingAction] = [:]
        for rule in interfaceMappings {
            actionByInterface[rule.bsdName] = rule.action
        }
        for (iface, overrideAction) in options.interfaceActionOverrides {
            actionByInterface[iface] = overrideAction
        }

        // 2. Clone and sanitize the PC profile for iOS:
        //    - iOS PacketTunnel runs TUN itself; never enables macOS LAN gateway mode.
        //    - Strip `interfaceName` from all targets so base `MihomoConfig.renderDetailed` never emits macOS `enX` bindings.
        //    - When `bypassChainedProxy` is true (e.g. Singapore eSIM), strip `relayGroupID` from all `.proxy` targets.
        var mobileProfile = pcProfile
        mobileProfile.tunEnabled = true
        mobileProfile.gatewayModeEnabled = false
        mobileProfile.allowLAN = false

        var relayedDirectTargetToInterface: [String: String] = [:]
        var relayedProxyTargetToInterface: [String: String] = [:]
        var relayedInterfacesSet = Set<String>()

        for idx in mobileProfile.targets.indices {
            let target = mobileProfile.targets[idx]
            if let rawIface = target.normalizedInterface {
                let action = actionByInterface[rawIface] ?? .useMobileDefault
                switch action {
                case .useMobileDefault:
                    mobileProfile.targets[idx].interfaceName = nil
                case .relayToPCInterface:
                    relayedInterfacesSet.insert(rawIface)
                    let cleanName = target.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    switch target.mode {
                    case .direct:
                        relayedDirectTargetToInterface[cleanName] = rawIface
                    case .proxy:
                        relayedProxyTargetToInterface[cleanName] = rawIface
                    case .alias:
                        break
                    }
                    mobileProfile.targets[idx].interfaceName = nil
                }
            }
            if options.bypassChainedProxy && mobileProfile.targets[idx].mode == .proxy {
                mobileProfile.targets[idx].relayGroupID = nil
            }
        }

        // 3. Render base Mihomo JSON via the single source of truth `MihomoConfig`.
        let rendered = try MihomoConfig.renderDetailed(
            mobileProfile,
            controllerPort: controllerPort,
            secret: secret,
            interfaceDNS: [:]
        )

        guard var json = try JSONSerialization.jsonObject(with: rendered.data) as? [String: Any] else {
            throw RoutingConfigurationError.invalidTarget("无法解析 Mihomo 基础配置。")
        }

        // iOS PacketTunnel runs with strict memory budget: disable find-process-mode (unsupported on iOS NE).
        json["find-process-mode"] = "off"

        var proxies = (json["proxies"] as? [[String: Any]]) ?? []
        var providers = (json["proxy-providers"] as? [String: [String: Any]]) ?? [:]
        var proxyGroups = (json["proxy-groups"] as? [[String: Any]]) ?? []
        var rules = (json["rules"] as? [String]) ?? []

        let relayedInterfaces = relayedInterfacesSet.sorted()

        // 4. Inject local SOCKS5 proxies (`Relay-PC-<iface>`) pointing at the in-process `RelayBridge`
        //    with `username = <iface>` so a single local bridge port can route to any PC NIC.
        for iface in relayedInterfaces {
            proxies.append([
                "name": relayOutboundName(for: iface),
                "type": "socks5",
                "server": "127.0.0.1",
                "port": relayBridgePort,
                "username": iface,
                "password": "rw",
                "udp": true,
            ])
        }

        // 5. Rewrite `.direct` targets mapped to a relayed PC interface:
        //    replace their `type: direct` entry with `type: socks5` targeting `RelayBridge` (`username = iface`).
        for idx in proxies.indices {
            if let name = proxies[idx]["name"] as? String,
               let iface = relayedDirectTargetToInterface[name] {
                proxies[idx] = [
                    "name": name,
                    "type": "socks5",
                    "server": "127.0.0.1",
                    "port": relayBridgePort,
                    "username": iface,
                    "password": "rw",
                    "udp": true,
                ]
            }
        }

        // 6. Rewrite `.proxy` targets mapped to a relayed PC interface:
        //    bind their first-hop provider's `dialer-proxy` to `Relay-PC-<iface>`.
        //    - If the proxy target has a chained relay group (`<name>·链式`), bind that relay group's provider.
        //    - Otherwise bind the exit group's provider directly.
        if !relayedProxyTargetToInterface.isEmpty {
            for (targetName, iface) in relayedProxyTargetToInterface {
                let relayHopOutbound = relayOutboundName(for: iface)
                let relayGroupName = MihomoConfig.relayGroupName(for: targetName)
                let firstHopGroupName = proxyGroups.contains(where: { ($0["name"] as? String) == relayGroupName })
                    ? relayGroupName
                    : targetName

                if let groupIdx = proxyGroups.firstIndex(where: { ($0["name"] as? String) == firstHopGroupName }),
                   let usedProviders = proxyGroups[groupIdx]["use"] as? [String],
                   let sourceProviderKey = usedProviders.first,
                   var clonedProvider = providers[sourceProviderKey] {
                    // Clone provider so we don't mutate a shared provider used by non-relayed groups.
                    let dedicatedKey = "\(sourceProviderKey)-via-\(iface)"
                    var overrideBlock = (clonedProvider["override"] as? [String: Any]) ?? [:]
                    overrideBlock["dialer-proxy"] = relayHopOutbound
                    overrideBlock["additional-prefix"] = "[\(firstHopGroupName)@\(iface)] "
                    clonedProvider["override"] = overrideBlock
                    providers[dedicatedKey] = clonedProvider
                    proxyGroups[groupIdx]["use"] = [dedicatedKey]
                }
            }
        }

        // 7. Resolve whether `RelayBridge` itself should connect to `lumzel/relay` through an existing
        //    Mac chained proxy `NodeGroup` (via dedicated local `IN-PORT` listener).
        let effectiveRelayRoute: RelayTransportRoute = options.bypassChainedProxy
            ? .direct
            : (options.relayRouteOverride ?? relayConfig.defaultRoute)

        var activeRelayChainPort: Int? = nil
        var activeRelayChainGroupName: String? = nil

        if case .chainedNodeGroup(let chainGroupID) = effectiveRelayRoute,
           let chainNodeGroup = pcProfile.nodeGroup(id: chainGroupID),
           let chainSub = pcProfile.subscription(id: chainNodeGroup.subscriptionID),
           !chainSub.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let groupName = relayChainGroupOutboundName
            let providerKey = "rw-relay-chain-entry"
            var providerEntry: [String: Any] = [
                "type": "http",
                "url": chainSub.url.trimmingCharacters(in: .whitespacesAndNewlines),
                "path": "./providers/\(providerKey).yaml",
                "interval": 3600,
                "health-check": [
                    "enable": true,
                    "url": MihomoConfig.healthCheckURL,
                    "interval": 300,
                ],
            ]
            if !chainNodeGroup.filterPattern.isEmpty {
                providerEntry["filter"] = chainNodeGroup.filterPattern
            }
            if !chainNodeGroup.excludeFilterPattern.isEmpty {
                providerEntry["exclude-filter"] = chainNodeGroup.excludeFilterPattern
            }
            providers[providerKey] = providerEntry

            let groupEntry: [String: Any] = [
                "name": groupName,
                "type": chainNodeGroup.autoTest ? "url-test" : "select",
                "use": [providerKey],
                "url": MihomoConfig.healthCheckURL,
                "interval": 300,
            ]
            proxyGroups.append(groupEntry)

            var listeners = (json["listeners"] as? [[String: Any]]) ?? []
            listeners.append([
                "name": "rw-relay-chain-in",
                "type": "socks",
                "listen": "127.0.0.1:\(relayChainEntryPort)",
            ])
            json["listeners"] = listeners

            // Pin traffic entering `relayChainEntryPort` to the reused Mac chained proxy group.
            rules.insert("IN-PORT,\(relayChainEntryPort),\(groupName)", at: 0)

            activeRelayChainPort = relayChainEntryPort
            activeRelayChainGroupName = groupName
        }

        // Always allow direct loopback for local RelayBridge to avoid any routing loop.
        rules.insert("IP-CIDR,127.0.0.0/8,DIRECT,no-resolve", at: 0)

        json["proxies"] = proxies
        json["proxy-providers"] = providers
        json["proxy-groups"] = proxyGroups
        json["rules"] = rules

        let finalData = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )

        return AdaptedMobileMihomoConfig(
            configData: finalData,
            mode: .localCore(options),
            relayBridgePort: relayBridgePort,
            relayChainEntryPort: activeRelayChainPort,
            relayChainGroupName: activeRelayChainGroupName,
            relayedPCInterfaces: relayedInterfaces
        )
    }
}
