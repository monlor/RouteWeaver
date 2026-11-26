import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum RemoteControlProtocol {
    public static let serviceType = "_routeweaver._tcp"
    public static let defaultPort: UInt16 = 19098
    public static let protocolVersion = 1
}

// MARK: - Pairing & Auth Models

public struct RemotePairingRequest: Codable, Equatable, Sendable {
    public let deviceId: String
    public let deviceName: String
    public let pairingCode: String

    public init(deviceId: String, deviceName: String, pairingCode: String) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.pairingCode = pairingCode
    }
}

public struct RemotePairingResponse: Codable, Equatable, Sendable {
    public let token: String
    public let hostDeviceId: String
    public let hostName: String

    public init(token: String, hostDeviceId: String, hostName: String) {
        self.token = token
        self.hostDeviceId = hostDeviceId
        self.hostName = hostName
    }
}

public struct RemotePairedClientRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String { deviceId }
    public let deviceId: String
    public let deviceName: String
    public let tokenHash: String
    public let pairedAt: Date
    public var lastSeenAt: Date?

    public init(
        deviceId: String,
        deviceName: String,
        tokenHash: String,
        pairedAt: Date = Date(),
        lastSeenAt: Date? = nil
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.tokenHash = tokenHash
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
    }
}

public struct RemoteSavedHost: Codable, Identifiable, Equatable, Sendable {
    public var id: String { hostDeviceId }
    public let hostDeviceId: String
    public var hostName: String
    public var host: String
    public var port: UInt16
    public let token: String
    public let pairedAt: Date

    public init(
        hostDeviceId: String,
        hostName: String,
        host: String,
        port: UInt16,
        token: String,
        pairedAt: Date = Date()
    ) {
        self.hostDeviceId = hostDeviceId
        self.hostName = hostName
        self.host = host
        self.port = port
        self.token = token
        self.pairedAt = pairedAt
    }
}

// MARK: - Remote Data & Command DTOs

public struct RemoteStatusSnapshot: Codable, Equatable, Sendable {
    public let hostDeviceId: String
    public let hostName: String
    public let phaseTitle: String
    public let isRunning: Bool
    public let isBusy: Bool
    public let isTunActive: Bool
    public let isGatewayActive: Bool
    public let isLaunchdManaged: Bool
    public let killSwitchActive: Bool
    public let isIPForwardingEnabled: Bool
    public let tunEnabled: Bool
    public let gatewayModeEnabled: Bool
    public let allowLAN: Bool
    public let mixedPort: Int
    public let ipv6Enabled: Bool
    public let lanIPAddresses: [String]
    public let coreVersion: String?
    public let configValidationError: String?
    public let lastError: String?
    public let uploadSpeed: Int64
    public let downloadSpeed: Int64
    public let uploadTotal: Int64
    public let downloadTotal: Int64
    public let activeConnectionCount: Int
    public let totalConnectionCount: Int
    public let gatewayDeviceCount: Int
    public let canStart: Bool
    public let hasPendingHotReload: Bool

    public init(
        hostDeviceId: String,
        hostName: String,
        phaseTitle: String,
        isRunning: Bool,
        isBusy: Bool,
        isTunActive: Bool,
        isGatewayActive: Bool,
        isLaunchdManaged: Bool,
        killSwitchActive: Bool,
        isIPForwardingEnabled: Bool,
        tunEnabled: Bool,
        gatewayModeEnabled: Bool,
        allowLAN: Bool,
        mixedPort: Int,
        ipv6Enabled: Bool,
        lanIPAddresses: [String],
        coreVersion: String?,
        configValidationError: String?,
        lastError: String?,
        uploadSpeed: Int64,
        downloadSpeed: Int64,
        uploadTotal: Int64,
        downloadTotal: Int64,
        activeConnectionCount: Int,
        totalConnectionCount: Int,
        gatewayDeviceCount: Int,
        canStart: Bool,
        hasPendingHotReload: Bool
    ) {
        self.hostDeviceId = hostDeviceId
        self.hostName = hostName
        self.phaseTitle = phaseTitle
        self.isRunning = isRunning
        self.isBusy = isBusy
        self.isTunActive = isTunActive
        self.isGatewayActive = isGatewayActive
        self.isLaunchdManaged = isLaunchdManaged
        self.killSwitchActive = killSwitchActive
        self.isIPForwardingEnabled = isIPForwardingEnabled
        self.tunEnabled = tunEnabled
        self.gatewayModeEnabled = gatewayModeEnabled
        self.allowLAN = allowLAN
        self.mixedPort = mixedPort
        self.ipv6Enabled = ipv6Enabled
        self.lanIPAddresses = lanIPAddresses
        self.coreVersion = coreVersion
        self.configValidationError = configValidationError
        self.lastError = lastError
        self.uploadSpeed = uploadSpeed
        self.downloadSpeed = downloadSpeed
        self.uploadTotal = uploadTotal
        self.downloadTotal = downloadTotal
        self.activeConnectionCount = activeConnectionCount
        self.totalConnectionCount = totalConnectionCount
        self.gatewayDeviceCount = gatewayDeviceCount
        self.canStart = canStart
        self.hasPendingHotReload = hasPendingHotReload
    }

    private enum CodingKeys: String, CodingKey {
        case hostDeviceId, hostName, phaseTitle, isRunning, isBusy
        case isTunActive, isGatewayActive, isLaunchdManaged, killSwitchActive, isIPForwardingEnabled
        case tunEnabled, gatewayModeEnabled, allowLAN, mixedPort, ipv6Enabled, lanIPAddresses
        case coreVersion, configValidationError, lastError
        case uploadSpeed, downloadSpeed, uploadTotal, downloadTotal
        case activeConnectionCount, totalConnectionCount, gatewayDeviceCount
        case canStart, hasPendingHotReload
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostDeviceId = try c.decodeIfPresent(String.self, forKey: .hostDeviceId) ?? ""
        hostName = try c.decodeIfPresent(String.self, forKey: .hostName) ?? "远程设备"
        phaseTitle = try c.decodeIfPresent(String.self, forKey: .phaseTitle) ?? "未知"
        isRunning = try c.decodeIfPresent(Bool.self, forKey: .isRunning) ?? false
        isBusy = try c.decodeIfPresent(Bool.self, forKey: .isBusy) ?? false
        isTunActive = try c.decodeIfPresent(Bool.self, forKey: .isTunActive) ?? false
        isGatewayActive = try c.decodeIfPresent(Bool.self, forKey: .isGatewayActive) ?? false
        isLaunchdManaged = try c.decodeIfPresent(Bool.self, forKey: .isLaunchdManaged) ?? false
        killSwitchActive = try c.decodeIfPresent(Bool.self, forKey: .killSwitchActive) ?? false
        isIPForwardingEnabled = try c.decodeIfPresent(Bool.self, forKey: .isIPForwardingEnabled) ?? false
        tunEnabled = try c.decodeIfPresent(Bool.self, forKey: .tunEnabled) ?? false
        gatewayModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .gatewayModeEnabled) ?? false
        allowLAN = try c.decodeIfPresent(Bool.self, forKey: .allowLAN) ?? false
        mixedPort = try c.decodeIfPresent(Int.self, forKey: .mixedPort) ?? 7890
        ipv6Enabled = try c.decodeIfPresent(Bool.self, forKey: .ipv6Enabled) ?? false
        lanIPAddresses = try c.decodeIfPresent([String].self, forKey: .lanIPAddresses) ?? []
        coreVersion = try c.decodeIfPresent(String.self, forKey: .coreVersion)
        configValidationError = try c.decodeIfPresent(String.self, forKey: .configValidationError)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        uploadSpeed = try c.decodeIfPresent(Int64.self, forKey: .uploadSpeed) ?? 0
        downloadSpeed = try c.decodeIfPresent(Int64.self, forKey: .downloadSpeed) ?? 0
        uploadTotal = try c.decodeIfPresent(Int64.self, forKey: .uploadTotal) ?? 0
        downloadTotal = try c.decodeIfPresent(Int64.self, forKey: .downloadTotal) ?? 0
        activeConnectionCount = try c.decodeIfPresent(Int.self, forKey: .activeConnectionCount) ?? 0
        totalConnectionCount = try c.decodeIfPresent(Int.self, forKey: .totalConnectionCount) ?? 0
        gatewayDeviceCount = try c.decodeIfPresent(Int.self, forKey: .gatewayDeviceCount) ?? 0
        canStart = try c.decodeIfPresent(Bool.self, forKey: .canStart) ?? !isRunning
        hasPendingHotReload = try c.decodeIfPresent(Bool.self, forKey: .hasPendingHotReload) ?? false
    }
}

public struct RemoteProxyGroupDTO: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let type: String
    public let now: String
    public let all: [String]
    public let delays: [String: Int]
    public let timedOutNodes: [String]
    public let isTesting: Bool
    public let lastVerifiedHealthyAt: Date?

    public init(
        name: String,
        type: String,
        now: String,
        all: [String],
        delays: [String: Int],
        timedOutNodes: [String] = [],
        isTesting: Bool = false,
        lastVerifiedHealthyAt: Date? = nil
    ) {
        self.name = name
        self.type = type
        self.now = now
        self.all = all
        self.delays = delays
        self.timedOutNodes = timedOutNodes
        self.isTesting = isTesting
        self.lastVerifiedHealthyAt = lastVerifiedHealthyAt
    }

    private enum CodingKeys: String, CodingKey {
        case name, type, now, all, delays, timedOutNodes, isTesting, lastVerifiedHealthyAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(String.self, forKey: .type)
        now = try c.decode(String.self, forKey: .now)
        all = try c.decode([String].self, forKey: .all)
        delays = try c.decode([String: Int].self, forKey: .delays)
        timedOutNodes = try c.decodeIfPresent([String].self, forKey: .timedOutNodes) ?? []
        isTesting = try c.decodeIfPresent(Bool.self, forKey: .isTesting) ?? false
        lastVerifiedHealthyAt = try c.decodeIfPresent(Date.self, forKey: .lastVerifiedHealthyAt)
    }
}

public struct RemoteConnectionDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let host: String
    public let network: String
    public let sourceIP: String
    public let destinationIP: String
    public let sourcePort: String?
    public let destinationPort: String?
    public let process: String?
    public let type: String?
    public let startDate: Date?
    public let closedAt: Date?
    public let rule: String
    public let matchedRuleSet: String?
    public let chain: String
    public let chains: [String]?
    public let upload: Int64
    public let download: Int64
    public let uploadSpeed: Int64
    public let downloadSpeed: Int64
    public let isActive: Bool

    public init(
        id: String,
        host: String,
        network: String,
        sourceIP: String,
        destinationIP: String,
        sourcePort: String? = nil,
        destinationPort: String? = nil,
        process: String? = nil,
        type: String? = nil,
        startDate: Date? = nil,
        closedAt: Date? = nil,
        rule: String,
        matchedRuleSet: String?,
        chain: String,
        chains: [String]? = nil,
        upload: Int64,
        download: Int64,
        uploadSpeed: Int64,
        downloadSpeed: Int64,
        isActive: Bool
    ) {
        self.id = id
        self.host = host
        self.network = network
        self.sourceIP = sourceIP
        self.destinationIP = destinationIP
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.process = process
        self.type = type
        self.startDate = startDate
        self.closedAt = closedAt
        self.rule = rule
        self.matchedRuleSet = matchedRuleSet
        self.chain = chain
        self.chains = chains
        self.upload = upload
        self.download = download
        self.uploadSpeed = uploadSpeed
        self.downloadSpeed = downloadSpeed
        self.isActive = isActive
    }
}

public struct RemoteDNSLogDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let timestamp: Date
    public let domain: String
    public let queryType: String
    public let status: String
    public let result: String
    public let upstream: String?
    public let elapsedMs: Int?
    public let rawPayload: String?

    public init(
        id: String,
        timestamp: Date,
        domain: String,
        queryType: String,
        status: String,
        result: String,
        upstream: String? = nil,
        elapsedMs: Int?,
        rawPayload: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.domain = domain
        self.queryType = queryType
        self.status = status
        self.result = result
        self.upstream = upstream
        self.elapsedMs = elapsedMs
        self.rawPayload = rawPayload
    }
}

public struct RemoteSnapshotDTO: Codable, Equatable, Sendable {
    public let status: RemoteStatusSnapshot
    public let proxies: [RemoteProxyGroupDTO]
    public let connections: [RemoteConnectionDTO]
    public let dnsLogs: [RemoteDNSLogDTO]
    public let gatewayDevices: [GatewayClientDevice]
    public let logs: String
    public let stateRevision: String
    public let outboundErrors: [OutboundErrorRecord]?
    public let targetSessionTotals: [String: TrafficBytes]?
    public let targetConnectionCounts: [String: Int]?
    public let targetSpeeds: [String: TrafficBytes]?
    public let ruleSessionTotals: [String: TrafficBytes]?

    public init(
        status: RemoteStatusSnapshot,
        proxies: [RemoteProxyGroupDTO],
        connections: [RemoteConnectionDTO],
        dnsLogs: [RemoteDNSLogDTO],
        gatewayDevices: [GatewayClientDevice],
        logs: String,
        stateRevision: String = "",
        outboundErrors: [OutboundErrorRecord]? = nil,
        targetSessionTotals: [String: TrafficBytes]? = nil,
        targetConnectionCounts: [String: Int]? = nil,
        targetSpeeds: [String: TrafficBytes]? = nil,
        ruleSessionTotals: [String: TrafficBytes]? = nil
    ) {
        self.status = status
        self.proxies = proxies
        self.connections = connections
        self.dnsLogs = dnsLogs
        self.gatewayDevices = gatewayDevices
        self.logs = logs
        self.stateRevision = stateRevision
        self.outboundErrors = outboundErrors
        self.targetSessionTotals = targetSessionTotals
        self.targetConnectionCounts = targetConnectionCounts
        self.targetSpeeds = targetSpeeds
        self.ruleSessionTotals = ruleSessionTotals
    }

    private enum CodingKeys: String, CodingKey {
        case status, proxies, connections, dnsLogs, gatewayDevices, logs, stateRevision
        case outboundErrors, targetSessionTotals, targetConnectionCounts, targetSpeeds, ruleSessionTotals
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(RemoteStatusSnapshot.self, forKey: .status)
        proxies = try container.decode([RemoteProxyGroupDTO].self, forKey: .proxies)
        connections = try container.decode([RemoteConnectionDTO].self, forKey: .connections)
        dnsLogs = try container.decode([RemoteDNSLogDTO].self, forKey: .dnsLogs)
        gatewayDevices = try container.decode([GatewayClientDevice].self, forKey: .gatewayDevices)
        logs = try container.decode(String.self, forKey: .logs)
        stateRevision = try container.decodeIfPresent(String.self, forKey: .stateRevision) ?? ""
        outboundErrors = try container.decodeIfPresent([OutboundErrorRecord].self, forKey: .outboundErrors)
        targetSessionTotals = try container.decodeIfPresent([String: TrafficBytes].self, forKey: .targetSessionTotals)
        targetConnectionCounts = try container.decodeIfPresent([String: Int].self, forKey: .targetConnectionCounts)
        targetSpeeds = try container.decodeIfPresent([String: TrafficBytes].self, forKey: .targetSpeeds)
        ruleSessionTotals = try container.decodeIfPresent([String: TrafficBytes].self, forKey: .ruleSessionTotals)
    }
}

public struct RemoteLogsDTO: Codable, Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public struct RemoteActionResult: Codable, Equatable, Sendable {
    public let ok: Bool
    public let message: String

    public init(ok: Bool, message: String) {
        self.ok = ok
        self.message = message
    }
}

public struct RemoteSelectProxyRequest: Codable, Equatable, Sendable {
    public let group: String
    public let node: String

    public init(group: String, node: String) {
        self.group = group
        self.node = node
    }
}

public struct RemoteDelayTestRequest: Codable, Equatable, Sendable {
    public let group: String

    public init(group: String) {
        self.group = group
    }
}

public struct RemoteModeUpdateRequest: Codable, Equatable, Sendable {
    public let tunEnabled: Bool?
    public let gatewayModeEnabled: Bool?
    public let allowLAN: Bool?

    public init(tunEnabled: Bool? = nil, gatewayModeEnabled: Bool? = nil, allowLAN: Bool? = nil) {
        self.tunEnabled = tunEnabled
        self.gatewayModeEnabled = gatewayModeEnabled
        self.allowLAN = allowLAN
    }
}

public struct RemoteInterfaceDTO: Codable, Equatable, Identifiable, Sendable {
    public var id: String { bsdName }
    public let bsdName: String
    public let displayName: String
    public let isUpWithAddress: Bool
    public let ipv4Address: String?
    public let ipv4Netmask: String?

    public init(
        bsdName: String,
        displayName: String,
        isUpWithAddress: Bool,
        ipv4Address: String?,
        ipv4Netmask: String?
    ) {
        self.bsdName = bsdName
        self.displayName = displayName
        self.isUpWithAddress = isUpWithAddress
        self.ipv4Address = ipv4Address
        self.ipv4Netmask = ipv4Netmask
    }
}

public struct RemoteSystemSettingsDTO: Codable, Equatable, Sendable {
    public let controllerPort: Int
    public let autoStartCoreOnLaunch: Bool
    public let systemKeepAliveEnabled: Bool
    public let launchAtLoginEnabled: Bool
    public let killSwitchActive: Bool
    public let killSwitchAllowLAN: Bool
    public let killSwitchPersistOnBoot: Bool
    public let tunPermissionTitle: String
    public let tunPermissionReady: Bool
    public let coreVersion: String?
    public let coreSourceTitle: String
    public let hasNewerCoreVersion: Bool
    public let latestCoreTag: String?
    public let geoUpdateMessage: String?
    public let coreUpdateMessage: String?

    public init(
        controllerPort: Int,
        autoStartCoreOnLaunch: Bool,
        systemKeepAliveEnabled: Bool,
        launchAtLoginEnabled: Bool,
        killSwitchActive: Bool,
        killSwitchAllowLAN: Bool,
        killSwitchPersistOnBoot: Bool,
        tunPermissionTitle: String,
        tunPermissionReady: Bool,
        coreVersion: String?,
        coreSourceTitle: String,
        hasNewerCoreVersion: Bool,
        latestCoreTag: String?,
        geoUpdateMessage: String?,
        coreUpdateMessage: String?
    ) {
        self.controllerPort = controllerPort
        self.autoStartCoreOnLaunch = autoStartCoreOnLaunch
        self.systemKeepAliveEnabled = systemKeepAliveEnabled
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.killSwitchActive = killSwitchActive
        self.killSwitchAllowLAN = killSwitchAllowLAN
        self.killSwitchPersistOnBoot = killSwitchPersistOnBoot
        self.tunPermissionTitle = tunPermissionTitle
        self.tunPermissionReady = tunPermissionReady
        self.coreVersion = coreVersion
        self.coreSourceTitle = coreSourceTitle
        self.hasNewerCoreVersion = hasNewerCoreVersion
        self.latestCoreTag = latestCoreTag
        self.geoUpdateMessage = geoUpdateMessage
        self.coreUpdateMessage = coreUpdateMessage
    }

    private enum CodingKeys: String, CodingKey {
        case controllerPort, autoStartCoreOnLaunch, systemKeepAliveEnabled, launchAtLoginEnabled
        case killSwitchActive, killSwitchAllowLAN, killSwitchPersistOnBoot
        case tunPermissionTitle, tunPermissionReady
        case coreVersion, coreSourceTitle, hasNewerCoreVersion, latestCoreTag
        case geoUpdateMessage, coreUpdateMessage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        controllerPort = try c.decodeIfPresent(Int.self, forKey: .controllerPort) ?? 19090
        autoStartCoreOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .autoStartCoreOnLaunch) ?? false
        systemKeepAliveEnabled = try c.decodeIfPresent(Bool.self, forKey: .systemKeepAliveEnabled) ?? true
        launchAtLoginEnabled = try c.decodeIfPresent(Bool.self, forKey: .launchAtLoginEnabled) ?? false
        killSwitchActive = try c.decodeIfPresent(Bool.self, forKey: .killSwitchActive) ?? false
        killSwitchAllowLAN = try c.decodeIfPresent(Bool.self, forKey: .killSwitchAllowLAN) ?? true
        killSwitchPersistOnBoot = try c.decodeIfPresent(Bool.self, forKey: .killSwitchPersistOnBoot) ?? false
        tunPermissionTitle = try c.decodeIfPresent(String.self, forKey: .tunPermissionTitle) ?? "未知"
        tunPermissionReady = try c.decodeIfPresent(Bool.self, forKey: .tunPermissionReady) ?? true
        coreVersion = try c.decodeIfPresent(String.self, forKey: .coreVersion)
        coreSourceTitle = try c.decodeIfPresent(String.self, forKey: .coreSourceTitle) ?? ""
        hasNewerCoreVersion = try c.decodeIfPresent(Bool.self, forKey: .hasNewerCoreVersion) ?? false
        latestCoreTag = try c.decodeIfPresent(String.self, forKey: .latestCoreTag)
        geoUpdateMessage = try c.decodeIfPresent(String.self, forKey: .geoUpdateMessage)
        coreUpdateMessage = try c.decodeIfPresent(String.self, forKey: .coreUpdateMessage)
    }
}

public struct RemoteSubscriptionUsageDTO: Codable, Equatable, Identifiable, Sendable {
    public var id: String { subscriptionId }
    public let subscriptionId: String
    public let nodeCount: Int
    public let nodes: [SubscriptionNode]?
    public let updatedAt: Date?
    public let usage: SubscriptionUsage?
    public let fetchError: String?

    public init(
        subscriptionId: String,
        nodeCount: Int,
        nodes: [SubscriptionNode]? = nil,
        updatedAt: Date?,
        usage: SubscriptionUsage?,
        fetchError: String?
    ) {
        self.subscriptionId = subscriptionId
        self.nodeCount = nodeCount
        self.nodes = nodes
        self.updatedAt = updatedAt
        self.usage = usage
        self.fetchError = fetchError
    }
}

public struct RemoteRelayInfoDTO: Codable, Equatable, Sendable {
    public let isEnabled: Bool
    public let serverURL: String
    public let password: String
    public let hostID: String
    public let hostPublicKeyBase64: String

    public init(
        isEnabled: Bool,
        serverURL: String,
        password: String,
        hostID: String,
        hostPublicKeyBase64: String
    ) {
        self.isEnabled = isEnabled
        self.serverURL = serverURL
        self.password = password
        self.hostID = hostID
        self.hostPublicKeyBase64 = hostPublicKeyBase64
    }
}

public struct RemoteFullStateDTO: Codable, Equatable, Sendable {
    public let profile: RoutingProfile
    public let interfaces: [RemoteInterfaceDTO]
    public let systemSettings: RemoteSystemSettingsDTO
    public let subscriptionUsages: [RemoteSubscriptionUsageDTO]
    public let trafficHistory: TrafficHistoryAccumulator
    public let trafficRanking: TrafficRankingAccumulator
    public let relayInfo: RemoteRelayInfoDTO?

    public init(
        profile: RoutingProfile,
        interfaces: [RemoteInterfaceDTO],
        systemSettings: RemoteSystemSettingsDTO,
        subscriptionUsages: [RemoteSubscriptionUsageDTO],
        trafficHistory: TrafficHistoryAccumulator,
        trafficRanking: TrafficRankingAccumulator,
        relayInfo: RemoteRelayInfoDTO? = nil
    ) {
        self.profile = profile
        self.interfaces = interfaces
        self.systemSettings = systemSettings
        self.subscriptionUsages = subscriptionUsages
        self.trafficHistory = trafficHistory
        self.trafficRanking = trafficRanking
        self.relayInfo = relayInfo
    }

    private enum CodingKeys: String, CodingKey {
        case profile, interfaces, systemSettings, subscriptionUsages, trafficHistory, trafficRanking, relayInfo
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = try c.decode(RoutingProfile.self, forKey: .profile)
        interfaces = try c.decodeIfPresent([RemoteInterfaceDTO].self, forKey: .interfaces) ?? []
        systemSettings = try c.decodeIfPresent(RemoteSystemSettingsDTO.self, forKey: .systemSettings) ?? RemoteSystemSettingsDTO(
            controllerPort: 19090,
            autoStartCoreOnLaunch: false,
            systemKeepAliveEnabled: true,
            launchAtLoginEnabled: false,
            killSwitchActive: false,
            killSwitchAllowLAN: true,
            killSwitchPersistOnBoot: false,
            tunPermissionTitle: "未知",
            tunPermissionReady: true,
            coreVersion: nil,
            coreSourceTitle: "",
            hasNewerCoreVersion: false,
            latestCoreTag: nil,
            geoUpdateMessage: nil,
            coreUpdateMessage: nil
        )
        subscriptionUsages = try c.decodeIfPresent([RemoteSubscriptionUsageDTO].self, forKey: .subscriptionUsages) ?? []
        trafficHistory = try c.decodeIfPresent(TrafficHistoryAccumulator.self, forKey: .trafficHistory) ?? TrafficHistoryAccumulator()
        trafficRanking = try c.decodeIfPresent(TrafficRankingAccumulator.self, forKey: .trafficRanking) ?? TrafficRankingAccumulator()
        relayInfo = try c.decodeIfPresent(RemoteRelayInfoDTO.self, forKey: .relayInfo)
    }
}

public struct RemoteSystemSettingsUpdateRequest: Codable, Equatable, Sendable {
    public let controllerPort: Int?
    public let autoStartCoreOnLaunch: Bool?
    public let systemKeepAliveEnabled: Bool?
    public let launchAtLoginEnabled: Bool?
    public let killSwitchActive: Bool?
    public let killSwitchAllowLAN: Bool?
    public let killSwitchPersistOnBoot: Bool?

    public init(
        controllerPort: Int? = nil,
        autoStartCoreOnLaunch: Bool? = nil,
        systemKeepAliveEnabled: Bool? = nil,
        launchAtLoginEnabled: Bool? = nil,
        killSwitchActive: Bool? = nil,
        killSwitchAllowLAN: Bool? = nil,
        killSwitchPersistOnBoot: Bool? = nil
    ) {
        self.controllerPort = controllerPort
        self.autoStartCoreOnLaunch = autoStartCoreOnLaunch
        self.systemKeepAliveEnabled = systemKeepAliveEnabled
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.killSwitchActive = killSwitchActive
        self.killSwitchAllowLAN = killSwitchAllowLAN
        self.killSwitchPersistOnBoot = killSwitchPersistOnBoot
    }
}

public struct RemoteCloseConnectionRequest: Codable, Equatable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}

public struct RemoteFlushDNSRequest: Codable, Equatable, Sendable {
    public let includeFakeIP: Bool
    public init(includeFakeIP: Bool) { self.includeFakeIP = includeFakeIP }
}

public struct RemoteRefreshSubscriptionRequest: Codable, Equatable, Sendable {
    public let id: String?
    public init(id: String? = nil) { self.id = id }
}

public struct RemoteRefreshHostModuleRequest: Codable, Equatable, Sendable {
    public let id: String?
    public init(id: String? = nil) { self.id = id }
}

// MARK: - Token & Pairing Code Helpers

public enum RemoteAuthHelper {
    public static func generatePairingCode() -> String {
        let value = Int.random(in: 0..<1_000_000)
        return String(format: "%06d", value)
    }

    public static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices {
            bytes[i] = UInt8.random(in: 0...255)
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func sha256Hex(_ input: String) -> String {
        let data = Data(input.utf8)
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        return data.base64EncodedString()
        #endif
    }
}

// MARK: - Lightweight HTTP/1.1 Parser & Serializer

public struct RemoteHTTPRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    public var bearerToken: String? {
        guard let auth = header("authorization") else { return nil }
        let prefix = "bearer "
        guard auth.lowercased().hasPrefix(prefix) else { return nil }
        let token = String(auth.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}

public enum RemoteHTTPParser {
    public enum ParseResult: Equatable, Sendable {
        case incomplete
        case parsed(RemoteHTTPRequest)
        case invalid
    }

    public static func parse(_ data: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEndRange = data.range(of: separator) else {
            return data.count > 65_536 ? .invalid : .incomplete
        }

        let headerData = data[..<headerEndRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .invalid
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .invalid }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return .invalid }

        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])
        let path = rawTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawTarget

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength >= 0, contentLength <= 2_097_152 else {
            return .invalid
        }

        let bodyStart = headerEndRange.upperBound
        let availableBody = data.count - bodyStart
        guard availableBody >= contentLength else {
            return .incomplete
        }

        let body = data[bodyStart..<(bodyStart + contentLength)]
        return .parsed(RemoteHTTPRequest(method: method, path: path, headers: headers, body: Data(body)))
    }
}

public struct RemoteHTTPPayload: Equatable, Sendable {
    public let status: Int
    public let contentType: String
    public let body: Data

    public init(status: Int, contentType: String = "application/json; charset=utf-8", body: Data) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    public static func json<T: Encodable>(status: Int = 200, _ value: T) -> RemoteHTTPPayload {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return RemoteHTTPPayload(status: status, body: body)
    }

    public static func error(status: Int, message: String) -> RemoteHTTPPayload {
        json(status: status, RemoteActionResult(ok: false, message: message))
    }

    public func serialized() -> Data {
        RemoteHTTPResponse.build(status: status, contentType: contentType, body: body)
    }
}

public enum RemoteHTTPResponse {
    public static func json<T: Encodable>(status: Int = 200, _ value: T) -> Data {
        RemoteHTTPPayload.json(status: status, value).serialized()
    }

    public static func error(status: Int, message: String) -> Data {
        RemoteHTTPPayload.error(status: status, message: message).serialized()
    }

    public static func build(status: Int, contentType: String, body: Data) -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        default: reason = "Internal Server Error"
        }
        let header = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n"
            + "Cache-Control: no-store\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }
}
