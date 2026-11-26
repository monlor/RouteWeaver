import Foundation

// MARK: - Relay Connection Config (Reusing github.com/lumzel/relay)

/// How iOS reaches the `lumzel/relay` WebSocket server.
public enum RelayTransportRoute: Codable, Equatable, Hashable, Sendable {
    /// Connect directly to `wss://<relay>` without chaining (e.g. overseas SIM / Singapore eSIM).
    case direct
    /// Route the Relay WebSocket through an existing Mac-synced `NodeGroup` (chained proxy group)
    /// via a dedicated local Mihomo `IN-PORT` listener so zero duplicate proxy config is needed.
    case chainedNodeGroup(UUID)

    private enum CodingKeys: String, CodingKey {
        case kind, groupID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "chainedNodeGroup":
            self = .chainedNodeGroup(try c.decode(UUID.self, forKey: .groupID))
        default:
            self = .direct
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .direct:
            try c.encode("direct", forKey: .kind)
        case .chainedNodeGroup(let id):
            try c.encode("chainedNodeGroup", forKey: .kind)
            try c.encode(id, forKey: .groupID)
        }
    }
}

public struct RelayEndpointConfig: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    /// Base URL of the `lumzel/relay` instance (e.g. `wss://relay.example.com` or `https://relay.example.com`).
    public var serverURL: String
    /// Optional `LUMZEL_RELAY_PASSWORD` shared secret for private Relay deployments.
    public var password: String
    /// Derived 32-char base32 `host_id` of the paired PC's X25519 public key.
    public var hostID: String
    /// Base64-encoded 32-byte X25519 public key of the paired PC.
    public var hostPublicKeyBase64: String
    /// Default route to reach `lumzel/relay` (`.direct` or `.chainedNodeGroup(existingMacRelayGroupID)`).
    public var defaultRoute: RelayTransportRoute
    /// Auto-rotate `/data` session `sid` after transferring this many bytes (0 = disable rotation, e.g. unlimited private Relay).
    public var sessionRotateThresholdBytes: UInt64

    public init(
        isEnabled: Bool = false,
        serverURL: String = "",
        password: String = "",
        hostID: String = "",
        hostPublicKeyBase64: String = "",
        defaultRoute: RelayTransportRoute = .direct,
        sessionRotateThresholdBytes: UInt64 = 0
    ) {
        self.isEnabled = isEnabled
        self.serverURL = serverURL
        self.password = password
        self.hostID = hostID
        self.hostPublicKeyBase64 = hostPublicKeyBase64
        self.defaultRoute = defaultRoute
        self.sessionRotateThresholdBytes = sessionRotateThresholdBytes
    }

    public var normalizedWebSocketBaseURL: URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let wsString: String
        if trimmed.hasPrefix("https://") {
            wsString = "wss://" + trimmed.dropFirst("https://".count)
        } else if trimmed.hasPrefix("http://") {
            wsString = "ws://" + trimmed.dropFirst("http://".count)
        } else if trimmed.hasPrefix("wss://") || trimmed.hasPrefix("ws://") {
            wsString = trimmed
        } else {
            wsString = "wss://" + trimmed
        }
        return URL(string: wsString)
    }

    public func websocketURL(for plane: LumzelRelayPlane) -> URL? {
        guard let base = normalizedWebSocketBaseURL else { return nil }
        return base.appendingPathComponent(plane.rawValue)
    }

    public var hostInboxURL: URL? {
        guard let base = normalizedWebSocketBaseURL else { return nil }
        return base.appendingPathComponent("host")
    }
}

// MARK: - Per-PC-Interface Mapping Policy on iOS

/// How a PC-bound BSD interface (e.g. `en0` Wi-Fi, `en5` Singapore eSIM) behaves when running
/// the synced `RoutingProfile` locally on iOS.
public enum PCInterfaceMappingAction: Codable, Equatable, Hashable, Sendable {
    /// Drop the PC interface binding and route directly via iOS's default network interface.
    /// Example: PC `en0` (Home Wi-Fi direct) -> iOS local default interface.
    case useMobileDefault
    /// Tunnel traffic through `lumzel/relay` (`/data`) to the PC and egress via that exact PC interface (`IP_BOUND_IF`).
    /// `routeOverride`: nil inherits `RelayEndpointConfig.defaultRoute`, or overrides per-interface (`.direct` vs `.chainedNodeGroup`).
    case relayToPCInterface(routeOverride: RelayTransportRoute? = nil)

    private enum CodingKeys: String, CodingKey {
        case kind, routeOverride
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "relayToPCInterface":
            let override = try c.decodeIfPresent(RelayTransportRoute.self, forKey: .routeOverride)
            self = .relayToPCInterface(routeOverride: override)
        default:
            self = .useMobileDefault
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .useMobileDefault:
            try c.encode("useMobileDefault", forKey: .kind)
        case .relayToPCInterface(let override):
            try c.encode("relayToPCInterface", forKey: .kind)
            try c.encodeIfPresent(override, forKey: .routeOverride)
        }
    }
}

public struct PCInterfaceMappingRule: Codable, Equatable, Identifiable, Sendable {
    public var id: String { bsdName }
    /// BSD interface name on PC (e.g. `en0`, `en5`).
    public var bsdName: String
    /// Friendly label synced from PC (e.g. `Wi-Fi`, `Singapore eSIM USB`).
    public var displayName: String
    public var action: PCInterfaceMappingAction

    public init(bsdName: String, displayName: String = "", action: PCInterfaceMappingAction = .useMobileDefault) {
        self.bsdName = bsdName
        self.displayName = displayName
        self.action = action
    }
}

// MARK: - Local Core Mode Options & Dual-Mode Network Switching

public struct LocalCoreExecutionOptions: Codable, Equatable, Sendable {
    /// When `true` (e.g. using a Singapore eSIM / overseas network on iOS):
    /// 1) Strips `relayGroupID` from all `.proxy` targets so iOS connects directly to exit nodes without domestic relay hops.
    /// 2) Connects to `lumzel/relay` directly (no chained proxy) while STILL honoring PC interface Relay mappings.
    public var bypassChainedProxy: Bool
    /// Optional per-scenario override for how Relay itself is reached.
    /// Ignored (forced `.direct`) when `bypassChainedProxy == true`.
    public var relayRouteOverride: RelayTransportRoute?
    /// Optional per-scenario interface mapping overrides keyed by PC BSD interface name (e.g. `en5`).
    public var interfaceActionOverrides: [String: PCInterfaceMappingAction]

    public init(
        bypassChainedProxy: Bool = false,
        relayRouteOverride: RelayTransportRoute? = nil,
        interfaceActionOverrides: [String: PCInterfaceMappingAction] = [:]
    ) {
        self.bypassChainedProxy = bypassChainedProxy
        self.relayRouteOverride = relayRouteOverride
        self.interfaceActionOverrides = interfaceActionOverrides
    }
}

public enum MobileVPNMode: Codable, Equatable, Sendable {
    /// Temporarily disable / pause VPN (direct mobile network, e.g. Singapore eSIM direct usage).
    case disabled
    /// Run synced `RoutingProfile` inside iOS `NEPacketTunnelProvider` (MihomoKit) with interface mapping + Relay.
    case localCore(LocalCoreExecutionOptions)
    /// Lightweight global iOS VPN forwarding all traffic directly to the LAN PC's SOCKS5 port.
    case directPCSocks5(host: String, port: Int)

    private enum CodingKeys: String, CodingKey {
        case kind, options, host, port
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "disabled":
            self = .disabled
        case "directPCSocks5":
            let host = try c.decode(String.self, forKey: .host)
            let port = try c.decode(Int.self, forKey: .port)
            self = .directPCSocks5(host: host, port: port)
        default:
            let opts = try c.decodeIfPresent(LocalCoreExecutionOptions.self, forKey: .options) ?? LocalCoreExecutionOptions()
            self = .localCore(opts)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .disabled:
            try c.encode("disabled", forKey: .kind)
        case .localCore(let options):
            try c.encode("localCore", forKey: .kind)
            try c.encode(options, forKey: .options)
        case .directPCSocks5(let host, let port):
            try c.encode("directPCSocks5", forKey: .kind)
            try c.encode(host, forKey: .host)
            try c.encode(port, forKey: .port)
        }
    }
}

public enum NetworkMatchCondition: Codable, Equatable, Hashable, Sendable {
    case wifiSSID(String)
    case cellular
    case anyWiFi
}

public struct NetworkSwitchRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var condition: NetworkMatchCondition
    public var mode: MobileVPNMode

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        condition: NetworkMatchCondition,
        mode: MobileVPNMode
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.condition = condition
        self.mode = mode
    }
}

/// Snapshot of the current iOS network path used by `NetworkSwitchPolicy.resolve`.
public struct MobileNetworkSnapshot: Equatable, Sendable {
    public enum InterfaceKind: String, Codable, Equatable, Sendable {
        case wifi
        case cellular
        case wired
        case other
    }

    public let interfaceKind: InterfaceKind
    public let wifiSSID: String?

    public init(interfaceKind: InterfaceKind, wifiSSID: String? = nil) {
        self.interfaceKind = interfaceKind
        self.wifiSSID = wifiSSID
    }
}

/// Evaluates which `MobileVPNMode` should run given the active network path and optional manual override
/// (e.g. user manually switches Cellular preset between "国内流量卡" and "新加坡流量卡" or "临时禁用").
public struct NetworkSwitchPolicy: Codable, Equatable, Sendable {
    public var rules: [NetworkSwitchRule]
    public var defaultMode: MobileVPNMode
    /// Optional manual override (e.g. quick toggle for Singapore eSIM direct/no-chain or temp pause).
    public var manualOverride: MobileVPNMode?

    public init(
        rules: [NetworkSwitchRule] = [],
        defaultMode: MobileVPNMode = .localCore(LocalCoreExecutionOptions()),
        manualOverride: MobileVPNMode? = nil
    ) {
        self.rules = rules
        self.defaultMode = defaultMode
        self.manualOverride = manualOverride
    }

    public func resolve(for snapshot: MobileNetworkSnapshot) -> MobileVPNMode {
        if let manualOverride {
            return manualOverride
        }
        // Specific SSID rules always take priority over generic `.anyWiFi` / `.cellular` rules.
        if snapshot.interfaceKind == .wifi, let ssid = snapshot.wifiSSID, !ssid.isEmpty {
            if let exact = rules.first(where: { rule in
                guard rule.isEnabled else { return false }
                if case .wifiSSID(let target) = rule.condition {
                    return target.caseInsensitiveCompare(ssid) == .orderedSame
                }
                return false
            }) {
                return exact.mode
            }
            if let genericWiFi = rules.first(where: { $0.isEnabled && $0.condition == .anyWiFi }) {
                return genericWiFi.mode
            }
        }
        if snapshot.interfaceKind == .cellular {
            if let cellRule = rules.first(where: { $0.isEnabled && $0.condition == .cellular }) {
                return cellRule.mode
            }
        }
        return defaultMode
    }
}

// MARK: - One-Step Pairing Bundle (PC -> iOS via QR / Paste)

/// Self-contained pairing payload exported by macOS RouteWeaver and imported by iOS
/// so a single paste/scan configures LAN management, SOCKS5 port, and `lumzel/relay` E2EE.
public struct RelayPairingBundle: Codable, Equatable, Sendable {
    public let version: Int
    public let hostDeviceId: String
    public let hostName: String
    public let lanIPs: [String]
    public let remotePort: UInt16
    public let mixedPort: Int
    public let pairingCode: String
    public let relayServerURL: String?
    public let relayPassword: String?
    public let relayHostID: String?
    public let relayHostPublicKeyBase64: String?

    public init(
        version: Int = 1,
        hostDeviceId: String,
        hostName: String,
        lanIPs: [String],
        remotePort: UInt16,
        mixedPort: Int,
        pairingCode: String,
        relayServerURL: String? = nil,
        relayPassword: String? = nil,
        relayHostID: String? = nil,
        relayHostPublicKeyBase64: String? = nil
    ) {
        self.version = version
        self.hostDeviceId = hostDeviceId
        self.hostName = hostName
        self.lanIPs = lanIPs
        self.remotePort = remotePort
        self.mixedPort = mixedPort
        self.pairingCode = pairingCode
        self.relayServerURL = relayServerURL
        self.relayPassword = relayPassword
        self.relayHostID = relayHostID
        self.relayHostPublicKeyBase64 = relayHostPublicKeyBase64
    }

    public static let uriPrefix = "routeweaver://pair/"

    public func encodeShareString() throws -> String {
        let data = try JSONEncoder().encode(self)
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Self.uriPrefix + b64
    }

    public static func decodeShareString(_ raw: String) throws -> RelayPairingBundle {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            return try JSONDecoder().decode(RelayPairingBundle.self, from: Data(trimmed.utf8))
        }
        let stripped = trimmed.hasPrefix(uriPrefix) ? String(trimmed.dropFirst(uriPrefix.count)) : trimmed
        var b64 = stripped
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = b64.count % 4
        if rem > 0 {
            b64.append(String(repeating: "=", count: 4 - rem))
        }
        guard let data = Data(base64Encoded: b64) else {
            throw LumzelRelayError.invalidUTF8
        }
        return try JSONDecoder().decode(RelayPairingBundle.self, from: data)
    }
}
