import Foundation
import Network
import RoutingCore

@MainActor
protocol RemoteHostBackend: AnyObject {
    var localLANIPAddresses: [String] { get }
    var cachedGatewayDevices: [GatewayClientDevice] { get }
    func triggerGatewayDevicesRefreshIfNeeded()

    func buildStatusSnapshot(hostDeviceId: String, hostName: String) -> RemoteStatusSnapshot
    func buildProxyGroups() -> [RemoteProxyGroupDTO]
    func buildConnections(limit: Int) -> [RemoteConnectionDTO]
    func buildDNSLogs(limit: Int) -> [RemoteDNSLogDTO]
    func buildOutboundErrors(limit: Int) -> [OutboundErrorRecord]
    func buildTargetSessionTotals() -> [String: TrafficBytes]?
    func buildTargetConnectionCounts() -> [String: Int]?
    func buildTargetSpeeds() -> [String: TrafficBytes]?
    func buildRuleSessionTotals() -> [String: TrafficBytes]?
    func buildLogsText(maxChars: Int) -> String
    func buildFullStateDTO() -> RemoteFullStateDTO
    func stateRevision(for fullState: RemoteFullStateDTO) -> String

    func updateProfile(_ updated: RoutingProfile) -> RemoteActionResult
    func updateSystemSettings(_ req: RemoteSystemSettingsUpdateRequest) -> RemoteActionResult
    func startEngine() -> RemoteActionResult
    func stopEngine() -> RemoteActionResult
    func hotReload() async -> RemoteActionResult
    func selectProxy(group: String, node: String) -> RemoteActionResult
    func testDelay(group: String) -> RemoteActionResult
    func closeConnection(id: String) async -> RemoteActionResult
    func closeAllConnections() async -> RemoteActionResult
    func flushDNS(includeFakeIP: Bool) async -> RemoteActionResult
    func refreshSubscription(id: String?) -> RemoteActionResult
    func refreshHostModule(id: String?) -> RemoteActionResult
    func updateOnlineRuleProviders() -> RemoteActionResult
    func updateGeoResources() -> RemoteActionResult
    func checkForCoreUpdate() -> RemoteActionResult
    func installCoreUpdate() -> RemoteActionResult
    func validateConfig() -> RemoteActionResult
    func clearLogs() -> RemoteActionResult
    func clearOutboundErrors() -> RemoteActionResult
    func updateMode(_ req: RemoteModeUpdateRequest) -> RemoteActionResult
}

extension RemoteHostBackend {
    func buildOutboundErrors(limit: Int) -> [OutboundErrorRecord] { [] }
    func buildTargetSessionTotals() -> [String: TrafficBytes]? { nil }
    func buildTargetConnectionCounts() -> [String: Int]? { nil }
    func buildTargetSpeeds() -> [String: TrafficBytes]? { nil }
    func buildRuleSessionTotals() -> [String: TrafficBytes]? { nil }
    func clearOutboundErrors() -> RemoteActionResult {
        RemoteActionResult(ok: true, message: "已清空链路异常记录。")
    }
    func installCoreUpdate() -> RemoteActionResult {
        RemoteActionResult(ok: true, message: "已触发免密更新 Mihomo 内核。")
    }
    func stateRevision(for fullState: RemoteFullStateDTO) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(fullState),
              let text = String(data: data, encoding: .utf8) else {
            return UUID().uuidString
        }
        return RemoteAuthHelper.sha256Hex(text)
    }
}

@MainActor
final class RemoteAPIHandler {
    let deviceId: String
    private let hostNameProvider: () -> String
    private let userDefaults: UserDefaults
    private let pairedClientsDefaultsKey: String
    private let lastSeenPersistInterval: TimeInterval
    private let nowProvider: () -> Date

    private(set) var activePairingCode: String
    private(set) var pairingCodeExpiresAt: Date
    private(set) var pairedClients: [RemotePairedClientRecord]
    private var lastPersistedSeenAt: [String: Date] = [:]

    weak var backend: (any RemoteHostBackend)?
    var onStateChanged: (() -> Void)?

    var hostDisplayName: String {
        hostNameProvider()
    }

    init(
        deviceId: String,
        hostNameProvider: @escaping () -> String,
        userDefaults: UserDefaults = .standard,
        pairedClientsDefaultsKey: String = "RouteWeaver.remotePairedClients",
        lastSeenPersistInterval: TimeInterval = 30,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.deviceId = deviceId
        self.hostNameProvider = hostNameProvider
        self.userDefaults = userDefaults
        self.pairedClientsDefaultsKey = pairedClientsDefaultsKey
        self.lastSeenPersistInterval = lastSeenPersistInterval
        self.nowProvider = nowProvider
        let now = nowProvider()
        self.activePairingCode = RemoteAuthHelper.generatePairingCode()
        self.pairingCodeExpiresAt = now.addingTimeInterval(300)
        self.pairedClients = Self.loadPairedClients(from: userDefaults, key: pairedClientsDefaultsKey)
        for client in pairedClients {
            if let seen = client.lastSeenAt {
                lastPersistedSeenAt[client.deviceId] = seen
            }
        }
    }

    func regeneratePairingCode() {
        activePairingCode = RemoteAuthHelper.generatePairingCode()
        pairingCodeExpiresAt = nowProvider().addingTimeInterval(300)
        onStateChanged?()
    }

    func isTokenAuthorized(_ token: String) -> Bool {
        authenticateToken(token) != nil
    }

    func isPairingCodeValid(_ code: String) -> Bool {
        let now = nowProvider()
        guard now <= pairingCodeExpiresAt else { return false }
        return code.trimmingCharacters(in: .whitespacesAndNewlines) == activePairingCode
    }

    func revokeClient(_ id: String) {
        pairedClients.removeAll { $0.id == id }
        lastPersistedSeenAt.removeValue(forKey: id)
        savePairedClients()
        onStateChanged?()
    }

    func revokeAllClients() {
        pairedClients.removeAll()
        lastPersistedSeenAt.removeAll()
        savePairedClients()
        onStateChanged?()
    }

    func handle(_ request: RemoteHTTPRequest) async -> RemoteHTTPPayload {
        if request.method == "GET" && request.path == "/api/v1/info" {
            return RemoteHTTPPayload.json([
                "hostDeviceId": deviceId,
                "hostName": hostDisplayName,
                "protocolVersion": String(RemoteControlProtocol.protocolVersion),
            ])
        }

        if request.method == "POST" && request.path == "/api/v1/pair" {
            return handlePairing(request.body)
        }

        guard let token = request.bearerToken,
              let clientIndex = authenticateToken(token) else {
            return RemoteHTTPPayload.error(status: 401, message: "未授权或配对已失效，请重新配对。")
        }

        let now = nowProvider()
        let clientDeviceId = pairedClients[clientIndex].deviceId
        pairedClients[clientIndex].lastSeenAt = now
        let lastPersisted = lastPersistedSeenAt[clientDeviceId]
        if lastPersisted == nil || now.timeIntervalSince(lastPersisted!) >= lastSeenPersistInterval {
            lastPersistedSeenAt[clientDeviceId] = now
            savePairedClients()
            onStateChanged?()
        }

        guard let backend else {
            return RemoteHTTPPayload.error(status: 500, message: "应用状态尚未就绪。")
        }

        switch (request.method, request.path) {
        case ("GET", "/api/v1/snapshot"):
            backend.triggerGatewayDevicesRefreshIfNeeded()
            let fullState = backend.buildFullStateDTO()
            let snapshot = RemoteSnapshotDTO(
                status: backend.buildStatusSnapshot(hostDeviceId: deviceId, hostName: hostDisplayName),
                proxies: backend.buildProxyGroups(),
                connections: backend.buildConnections(limit: 350),
                dnsLogs: backend.buildDNSLogs(limit: 200),
                gatewayDevices: backend.cachedGatewayDevices,
                logs: backend.buildLogsText(maxChars: 12_000),
                stateRevision: backend.stateRevision(for: fullState),
                outboundErrors: backend.buildOutboundErrors(limit: 300),
                targetSessionTotals: backend.buildTargetSessionTotals(),
                targetConnectionCounts: backend.buildTargetConnectionCounts(),
                targetSpeeds: backend.buildTargetSpeeds(),
                ruleSessionTotals: backend.buildRuleSessionTotals()
            )
            return RemoteHTTPPayload.json(snapshot)

        case ("GET", "/api/v1/status"):
            return RemoteHTTPPayload.json(backend.buildStatusSnapshot(hostDeviceId: deviceId, hostName: hostDisplayName))

        case ("GET", "/api/v1/proxies"):
            return RemoteHTTPPayload.json(backend.buildProxyGroups())

        case ("GET", "/api/v1/connections"):
            return RemoteHTTPPayload.json(backend.buildConnections(limit: 250))

        case ("GET", "/api/v1/dns-logs"):
            return RemoteHTTPPayload.json(backend.buildDNSLogs(limit: 200))

        case ("GET", "/api/v1/gateway-devices"):
            backend.triggerGatewayDevicesRefreshIfNeeded()
            return RemoteHTTPPayload.json(backend.cachedGatewayDevices)

        case ("GET", "/api/v1/logs"):
            return RemoteHTTPPayload.json(RemoteLogsDTO(text: backend.buildLogsText(maxChars: 12_000)))

        case ("GET", "/api/v1/state"):
            return RemoteHTTPPayload.json(backend.buildFullStateDTO())

        case ("POST", "/api/v1/profile"):
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let updated = try? decoder.decode(RoutingProfile.self, from: request.body) else {
                return RemoteHTTPPayload.error(status: 400, message: "无效的配置格式。")
            }
            return RemoteHTTPPayload.json(backend.updateProfile(updated))

        case ("POST", "/api/v1/settings/system"):
            guard let req = try? JSONDecoder().decode(RemoteSystemSettingsUpdateRequest.self, from: request.body) else {
                return RemoteHTTPPayload.error(status: 400, message: "无效的系统设置参数。")
            }
            return RemoteHTTPPayload.json(backend.updateSystemSettings(req))

        case ("POST", "/api/v1/engine/start"):
            return RemoteHTTPPayload.json(backend.startEngine())

        case ("POST", "/api/v1/engine/stop"):
            return RemoteHTTPPayload.json(backend.stopEngine())

        case ("POST", "/api/v1/engine/hot-reload"):
            return RemoteHTTPPayload.json(await backend.hotReload())

        case ("POST", "/api/v1/proxies/select"):
            guard let payload = try? JSONDecoder().decode(RemoteSelectProxyRequest.self, from: request.body) else {
                return RemoteHTTPPayload.error(status: 400, message: "无效的节点切换参数。")
            }
            return RemoteHTTPPayload.json(backend.selectProxy(group: payload.group, node: payload.node))

        case ("POST", "/api/v1/proxies/delay"):
            guard let payload = try? JSONDecoder().decode(RemoteDelayTestRequest.self, from: request.body) else {
                return RemoteHTTPPayload.error(status: 400, message: "无效的测速参数。")
            }
            return RemoteHTTPPayload.json(backend.testDelay(group: payload.group))

        case ("POST", "/api/v1/connections/close"):
            guard let req = try? JSONDecoder().decode(RemoteCloseConnectionRequest.self, from: request.body) else {
                return RemoteHTTPPayload.error(status: 400, message: "无效的连接 ID。")
            }
            return RemoteHTTPPayload.json(await backend.closeConnection(id: req.id))

        case ("POST", "/api/v1/connections/close-all"):
            return RemoteHTTPPayload.json(await backend.closeAllConnections())

        case ("POST", "/api/v1/dns/flush"):
            let req = try? JSONDecoder().decode(RemoteFlushDNSRequest.self, from: request.body)
            return RemoteHTTPPayload.json(await backend.flushDNS(includeFakeIP: req?.includeFakeIP ?? false))

        case ("POST", "/api/v1/subscriptions/refresh"):
            let req = try? JSONDecoder().decode(RemoteRefreshSubscriptionRequest.self, from: request.body)
            return RemoteHTTPPayload.json(backend.refreshSubscription(id: req?.id))

        case ("POST", "/api/v1/host-modules/refresh"):
            let req = try? JSONDecoder().decode(RemoteRefreshHostModuleRequest.self, from: request.body)
            return RemoteHTTPPayload.json(backend.refreshHostModule(id: req?.id))

        case ("POST", "/api/v1/rule-providers/update"):
            return RemoteHTTPPayload.json(backend.updateOnlineRuleProviders())

        case ("POST", "/api/v1/geo/update"):
            return RemoteHTTPPayload.json(backend.updateGeoResources())

        case ("POST", "/api/v1/core/check-update"):
            return RemoteHTTPPayload.json(backend.checkForCoreUpdate())

        case ("POST", "/api/v1/core/install-update"):
            return RemoteHTTPPayload.json(backend.installCoreUpdate())

        case ("POST", "/api/v1/core/validate"):
            return RemoteHTTPPayload.json(backend.validateConfig())

        case ("POST", "/api/v1/logs/clear"):
            return RemoteHTTPPayload.json(backend.clearLogs())

        case ("POST", "/api/v1/outbound-errors/clear"):
            return RemoteHTTPPayload.json(backend.clearOutboundErrors())

        case ("POST", "/api/v1/settings/mode"):
            guard let payload = try? JSONDecoder().decode(RemoteModeUpdateRequest.self, from: request.body) else {
                return RemoteHTTPPayload.error(status: 400, message: "无效的模式参数。")
            }
            return RemoteHTTPPayload.json(backend.updateMode(payload))

        default:
            return RemoteHTTPPayload.error(status: 404, message: "未知接口：\(request.method) \(request.path)")
        }
    }

    private func handlePairing(_ body: Data) -> RemoteHTTPPayload {
        guard let req = try? JSONDecoder().decode(RemotePairingRequest.self, from: body) else {
            return RemoteHTTPPayload.error(status: 400, message: "配对请求格式错误。")
        }
        let now = nowProvider()
        guard now <= pairingCodeExpiresAt else {
            regeneratePairingCode()
            return RemoteHTTPPayload.error(status: 403, message: "配对码已过期，已在被控端自动刷新，请重新输入。")
        }
        guard req.pairingCode.trimmingCharacters(in: .whitespacesAndNewlines) == activePairingCode else {
            return RemoteHTTPPayload.error(status: 403, message: "配对码不正确。")
        }

        let rawToken = RemoteAuthHelper.generateToken()
        let tokenHash = RemoteAuthHelper.sha256Hex(rawToken)
        if let idx = pairedClients.firstIndex(where: { $0.deviceId == req.deviceId }) {
            pairedClients[idx] = RemotePairedClientRecord(
                deviceId: req.deviceId,
                deviceName: req.deviceName,
                tokenHash: tokenHash,
                pairedAt: now,
                lastSeenAt: now
            )
        } else {
            pairedClients.append(RemotePairedClientRecord(
                deviceId: req.deviceId,
                deviceName: req.deviceName,
                tokenHash: tokenHash,
                pairedAt: now,
                lastSeenAt: now
            ))
        }
        lastPersistedSeenAt[req.deviceId] = now
        savePairedClients()
        regeneratePairingCode()

        return RemoteHTTPPayload.json(RemotePairingResponse(
            token: rawToken,
            hostDeviceId: deviceId,
            hostName: hostDisplayName
        ))
    }

    private func authenticateToken(_ token: String) -> Int? {
        let hash = RemoteAuthHelper.sha256Hex(token)
        return pairedClients.firstIndex { $0.tokenHash == hash }
    }

    private static func loadPairedClients(from defaults: UserDefaults, key: String) -> [RemotePairedClientRecord] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RemotePairedClientRecord].self, from: data) else {
            return []
        }
        return decoded
    }

    private func savePairedClients() {
        if let data = try? JSONEncoder().encode(pairedClients) {
            userDefaults.set(data, forKey: pairedClientsDefaultsKey)
        }
    }
}

@MainActor
private final class AppStateRemoteHostBackend: RemoteHostBackend {
    private weak var appState: AppState?
    private var lastGatewayRefreshAt: Date = .distantPast

    init(appState: AppState) {
        self.appState = appState
    }

    var localLANIPAddresses: [String] {
        appState?.localLANIPAddresses ?? []
    }

    var cachedGatewayDevices: [GatewayClientDevice] {
        appState?.gatewayDevices ?? []
    }

    func triggerGatewayDevicesRefreshIfNeeded() {
        guard let appState else { return }
        let now = Date()
        guard now.timeIntervalSince(lastGatewayRefreshAt) >= 5 else { return }
        lastGatewayRefreshAt = now
        appState.refreshGatewayDevices()
    }

    func buildStatusSnapshot(hostDeviceId: String, hostName: String) -> RemoteStatusSnapshot {
        guard let state = appState else {
            return RemoteStatusSnapshot(
                hostDeviceId: hostDeviceId,
                hostName: hostName,
                phaseTitle: "未就绪",
                isRunning: false,
                isBusy: false,
                isTunActive: false,
                isGatewayActive: false,
                isLaunchdManaged: false,
                killSwitchActive: false,
                isIPForwardingEnabled: false,
                tunEnabled: false,
                gatewayModeEnabled: false,
                allowLAN: false,
                mixedPort: 7890,
                ipv6Enabled: false,
                lanIPAddresses: [],
                coreVersion: nil,
                configValidationError: nil,
                lastError: nil,
                uploadSpeed: 0,
                downloadSpeed: 0,
                uploadTotal: 0,
                downloadTotal: 0,
                activeConnectionCount: 0,
                totalConnectionCount: 0,
                gatewayDeviceCount: 0,
                canStart: false,
                hasPendingHotReload: false
            )
        }
        let tracker = state.connectionMonitor.tracker
        return RemoteStatusSnapshot(
            hostDeviceId: hostDeviceId,
            hostName: hostName,
            phaseTitle: state.engine.phase.title,
            isRunning: state.engine.isRunning,
            isBusy: state.engine.isBusy,
            isTunActive: state.engine.isTunActive,
            isGatewayActive: state.engine.isGatewayActive,
            isLaunchdManaged: state.engine.isLaunchdManaged,
            killSwitchActive: state.killSwitchActive,
            isIPForwardingEnabled: state.isIPForwardingEnabled,
            tunEnabled: state.localProfile.tunEnabled,
            gatewayModeEnabled: state.localProfile.gatewayModeEnabled,
            allowLAN: state.localProfile.allowLAN,
            mixedPort: state.localProfile.mixedPort,
            ipv6Enabled: state.localProfile.ipv6Enabled,
            lanIPAddresses: state.localLANIPAddresses,
            coreVersion: state.coreBinaryStore.version,
            configValidationError: state.configValidationError,
            lastError: state.engine.lastError,
            uploadSpeed: tracker.uploadSpeed,
            downloadSpeed: tracker.downloadSpeed,
            uploadTotal: tracker.uploadTotal,
            downloadTotal: tracker.downloadTotal,
            activeConnectionCount: tracker.activeCount,
            totalConnectionCount: tracker.recordsByID.count,
            gatewayDeviceCount: state.gatewayDevices.count,
            canStart: state.localCanStart,
            hasPendingHotReload: state.hasPendingHotReload
        )
    }

    func buildProxyGroups() -> [RemoteProxyGroupDTO] {
        guard let state = appState else { return [] }
        return state.liveProxyStore.activeProxyGroups.compactMap { groupName -> RemoteProxyGroupDTO? in
            guard let group = state.liveProxyStore.groupStatus[groupName] else { return nil }
            return RemoteProxyGroupDTO(
                name: groupName,
                type: group.type,
                now: group.now,
                all: group.all,
                delays: group.delays,
                timedOutNodes: group.timedOutNodes.sorted(),
                isTesting: state.liveProxyStore.testingGroups.contains(groupName),
                lastVerifiedHealthyAt: state.liveProxyStore.verifiedHealthyAt[groupName]
            )
        }
    }

    func buildConnections(limit: Int) -> [RemoteConnectionDTO] {
        guard let state = appState else { return [] }
        let sorted = state.connectionMonitor.tracker.allRecords
            .sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive { return lhs.isActive }
                return lhs.lastSeenAt > rhs.lastSeenAt
            }
            .prefix(limit)
            .map { toConnectionDTO($0) }
        return Array(sorted)
    }

    func buildDNSLogs(limit: Int) -> [RemoteDNSLogDTO] {
        guard let state = appState else { return [] }
        let logs = state.connectionMonitor.dnsLogs.prefix(limit).map { record in
            let resultText: String
            if !record.answers.isEmpty {
                resultText = record.answers.joined(separator: ", ")
            } else if let err = record.errorMessage, !err.isEmpty {
                resultText = err
            } else {
                resultText = record.upstream
            }
            return RemoteDNSLogDTO(
                id: record.id.uuidString,
                timestamp: record.timestamp,
                domain: record.domain,
                queryType: record.recordType,
                status: record.status.rawValue,
                result: resultText,
                upstream: record.upstream,
                elapsedMs: nil,
                rawPayload: record.status == .failed ? record.rawPayload : nil
            )
        }
        return Array(logs)
    }

    func buildOutboundErrors(limit: Int) -> [OutboundErrorRecord] {
        guard let state = appState else { return [] }
        return Array(state.connectionMonitor.outboundErrors.prefix(limit))
    }

    func buildTargetSessionTotals() -> [String: TrafficBytes]? {
        appState?.connectionMonitor.tracker.sessionTargetTotals
    }

    func buildTargetConnectionCounts() -> [String: Int]? {
        appState?.connectionMonitor.tracker.sessionTargetConnectionCounts
    }

    func buildTargetSpeeds() -> [String: TrafficBytes]? {
        appState?.connectionMonitor.tracker.targetSpeeds
    }

    func buildRuleSessionTotals() -> [String: TrafficBytes]? {
        appState?.connectionMonitor.tracker.sessionRuleTotals
    }

    func buildLogsText(maxChars: Int) -> String {
        guard let state = appState else { return "" }
        return String(state.engine.logStore.text.suffix(maxChars))
    }

    func buildFullStateDTO() -> RemoteFullStateDTO {
        guard let state = appState else {
            return RemoteFullStateDTO(
                profile: RoutingProfile(),
                interfaces: [],
                systemSettings: RemoteSystemSettingsDTO(
                    controllerPort: 19090,
                    autoStartCoreOnLaunch: false,
                    systemKeepAliveEnabled: true,
                    launchAtLoginEnabled: false,
                    killSwitchActive: false,
                    killSwitchAllowLAN: true,
                    killSwitchPersistOnBoot: false,
                    tunPermissionTitle: "未知",
                    tunPermissionReady: false,
                    coreVersion: nil,
                    coreSourceTitle: "",
                    hasNewerCoreVersion: false,
                    latestCoreTag: nil,
                    geoUpdateMessage: nil,
                    coreUpdateMessage: nil
                ),
                subscriptionUsages: [],
                trafficHistory: TrafficHistoryAccumulator(),
                trafficRanking: TrafficRankingAccumulator()
            )
        }

        let interfaces = state.interfaces.map {
            RemoteInterfaceDTO(
                bsdName: $0.bsdName,
                displayName: $0.displayName,
                isUpWithAddress: $0.isUpWithAddress,
                ipv4Address: $0.ipv4Address,
                ipv4Netmask: $0.ipv4Netmask
            )
        }

        let sys = RemoteSystemSettingsDTO(
            controllerPort: state.controllerPort,
            autoStartCoreOnLaunch: state.autoStartCoreOnLaunch,
            systemKeepAliveEnabled: state.systemKeepAliveEnabled,
            launchAtLoginEnabled: state.launchAtLoginStatus.isEnabled,
            killSwitchActive: state.killSwitchActive,
            killSwitchAllowLAN: state.killSwitchAllowLAN,
            killSwitchPersistOnBoot: state.killSwitchPersistOnBoot,
            tunPermissionTitle: state.tunPermissionStatus.title,
            tunPermissionReady: state.tunPermissionStatus.canLaunchTun,
            coreVersion: state.coreBinaryStore.version,
            coreSourceTitle: state.coreBinaryStore.source.title,
            hasNewerCoreVersion: state.coreBinaryStore.hasNewerVersion,
            latestCoreTag: state.coreBinaryStore.latestRelease?.tagName,
            geoUpdateMessage: state.geoUpdateMessage,
            coreUpdateMessage: state.coreBinaryStore.updateMessage
        )

        state.subscriptionStore.hydrateMissingCacheEntries(
            for: state.localProfile,
            in: state.activeProfileDirectory,
            mihomoWorkDirectories: state.engine.candidateProviderWorkDirectories
        )

        let usages = state.localProfile.subscriptions.map { sub in
            let cached = state.subscriptionStore.cache[sub.id]
            return RemoteSubscriptionUsageDTO(
                subscriptionId: sub.id.uuidString,
                nodeCount: cached?.effectiveNodeCount ?? 0,
                nodes: cached?.hasNodeDetails == true ? cached?.nodes : nil,
                updatedAt: cached?.updatedAt,
                usage: cached?.usage,
                fetchError: state.subscriptionStore.fetchErrors[sub.id]
            )
        }

        let relayHost = state.remoteServer.relayHost
        let relayInfo = RemoteRelayInfoDTO(
            isEnabled: relayHost.isEnabled,
            serverURL: relayHost.serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
            password: relayHost.password,
            hostID: relayHost.hostID,
            hostPublicKeyBase64: relayHost.publicKeyBase64
        )

        return RemoteFullStateDTO(
            profile: state.localProfile,
            interfaces: interfaces,
            systemSettings: sys,
            subscriptionUsages: usages,
            trafficHistory: state.connectionMonitor.trafficHistory,
            trafficRanking: state.connectionMonitor.trafficRanking,
            relayInfo: relayInfo
        )
    }

    func updateProfile(_ updated: RoutingProfile) -> RemoteActionResult {
        guard let state = appState else { return RemoteActionResult(ok: false, message: "应用状态尚未就绪。") }
        if state.localEditingLocked && (updated.tunEnabled != state.localProfile.tunEnabled || updated.gatewayModeEnabled != state.localProfile.gatewayModeEnabled) {
            return RemoteActionResult(ok: false, message: "核心运行中无法切换 TUN 或网关模式，请先停止核心。")
        }
        state.updateLocalProfileFromRemote(updated)
        return RemoteActionResult(ok: true, message: state.engine.isRunning ? "配置已更新（可点击热重载生效）。" : "配置已保存。")
    }

    func updateSystemSettings(_ req: RemoteSystemSettingsUpdateRequest) -> RemoteActionResult {
        guard let state = appState else { return RemoteActionResult(ok: false, message: "应用状态尚未就绪。") }
        if let port = req.controllerPort {
            guard !state.localEditingLocked else {
                return RemoteActionResult(ok: false, message: "核心运行中无法修改控制端口。")
            }
            if (1024...65535).contains(port) { state.setLocalControllerPort(port) }
        }
        if let autoStart = req.autoStartCoreOnLaunch { state.setLocalAutoStartCoreOnLaunch(autoStart) }
        if let keepAlive = req.systemKeepAliveEnabled {
            if !state.localEditingLocked { state.setLocalSystemKeepAliveEnabled(keepAlive) }
        }
        if let login = req.launchAtLoginEnabled { state.setLocalLaunchAtLogin(login) }
        if let ks = req.killSwitchActive { state.setLocalKillSwitchEnabled(ks) }
        if let ksLAN = req.killSwitchAllowLAN { state.setLocalKillSwitchAllowLAN(ksLAN) }
        if let ksBoot = req.killSwitchPersistOnBoot { state.setLocalKillSwitchPersistOnBoot(ksBoot) }
        return RemoteActionResult(ok: true, message: "系统设置已更新。")
    }

    func startEngine() -> RemoteActionResult {
        guard let state = appState else { return RemoteActionResult(ok: false, message: "应用状态尚未就绪。") }
        if state.engine.isRunning {
            return RemoteActionResult(ok: true, message: "核心已在运行中。")
        }
        if state.engine.isBusy {
            return RemoteActionResult(ok: true, message: "核心正在启动或停止中，请稍候。")
        }
        guard state.localCanStart else {
            return RemoteActionResult(ok: false, message: "当前无法启动核心（请检查内核、配置或权限）。")
        }
        state.startLocal()
        return RemoteActionResult(ok: true, message: "已触发启动核心。")
    }

    func stopEngine() -> RemoteActionResult {
        guard let state = appState else { return RemoteActionResult(ok: false, message: "应用状态尚未就绪。") }
        guard state.engine.isRunning || state.engine.isBusy else {
            return RemoteActionResult(ok: true, message: "核心当前未在运行。")
        }
        state.stopLocal()
        return RemoteActionResult(ok: true, message: "已触发停止核心。")
    }

    func hotReload() async -> RemoteActionResult {
        guard let state = appState else { return RemoteActionResult(ok: false, message: "应用状态尚未就绪。") }
        return await state.hotReloadLocalFromRemote()
    }

    func selectProxy(group: String, node: String) -> RemoteActionResult {
        guard let state = appState else { return RemoteActionResult(ok: false, message: "应用状态尚未就绪。") }
        state.selectLocalNode(group: group, node: node)
        return RemoteActionResult(ok: true, message: "已将 \(group) 切换为 \(node)。")
    }

    func testDelay(group: String) -> RemoteActionResult {
        guard let state = appState else { return RemoteActionResult(ok: false, message: "应用状态尚未就绪。") }
        state.testLocalGroupDelay(group: group)
        return RemoteActionResult(ok: true, message: "已开始测试 \(group) 延迟。")
    }

    func closeConnection(id: String) async -> RemoteActionResult {
        guard let state = appState else { return RemoteActionResult(ok: false, message: "应用状态尚未就绪。") }
        do {
            try await state.connectionMonitor.closeConnection(id: id)
            return RemoteActionResult(ok: true, message: "已关闭连接。")
        } catch {
            return RemoteActionResult(ok: false, message: "关闭连接失败：\(error.localizedDescription)")
        }
    }

    func closeAllConnections() async -> RemoteActionResult {
        guard let state = appState else { return RemoteActionResult(ok: false, message: "应用状态尚未就绪。") }
        do {
            try await state.connectionMonitor.closeAllConnections()
            return RemoteActionResult(ok: true, message: "已关闭全部连接。")
        } catch {
            return RemoteActionResult(ok: false, message: "关闭连接失败：\(error.localizedDescription)")
        }
    }

    func flushDNS(includeFakeIP: Bool) async -> RemoteActionResult {
        guard let state = appState else { return RemoteActionResult(ok: false, message: "应用状态尚未就绪。") }
        do {
            try await state.connectionMonitor.flushDNSCache(includeFakeIP: includeFakeIP)
            return RemoteActionResult(ok: true, message: "已清空 DNS 缓存。")
        } catch {
            return RemoteActionResult(ok: false, message: "清空 DNS 缓存失败：\(error.localizedDescription)")
        }
    }

    func refreshSubscription(id: String?) -> RemoteActionResult {
        guard let state = appState else { return RemoteActionResult(ok: false, message: "应用状态尚未就绪。") }
        if let id, let uuid = UUID(uuidString: id),
           let sub = state.localProfile.subscriptions.first(where: { $0.id == uuid }) {
            state.fetchLocalSubscriptionNodes(sub)
            return RemoteActionResult(ok: true, message: "已触发刷新订阅「\(sub.name)」。")
        }
        state.fetchAllLocalSubscriptionNodes()
        return RemoteActionResult(ok: true, message: "已触发刷新全部订阅。")
    }

    func refreshHostModule(id: String?) -> RemoteActionResult {
        guard let state = appState else { return RemoteActionResult(ok: false, message: "应用状态尚未就绪。") }
        if let id, let uuid = UUID(uuidString: id) {
            state.refreshLocalHostModule(id: uuid)
            return RemoteActionResult(ok: true, message: "已触发刷新 Host 模块。")
        }
        state.refreshAllLocalHostModules()
        return RemoteActionResult(ok: true, message: "已触发刷新全部 Host 模块。")
    }

    func updateOnlineRuleProviders() -> RemoteActionResult {
        guard let state = appState else { return RemoteActionResult(ok: false, message: "应用状态尚未就绪。") }
        state.updateLocalOnlineRuleProviders()
        return RemoteActionResult(ok: true, message: "已触发更新在线规则集。")
    }

    func updateGeoResources() -> RemoteActionResult {
        guard let state = appState else { return RemoteActionResult(ok: false, message: "应用状态尚未就绪。") }
        state.updateLocalGeoResources()
        return RemoteActionResult(ok: true, message: "已触发更新 Geo 数据库。")
    }

    func checkForCoreUpdate() -> RemoteActionResult {
        guard let state = appState else { return RemoteActionResult(ok: false, message: "应用状态尚未就绪。") }
        state.checkForLocalCoreUpdate()
        return RemoteActionResult(ok: true, message: "正在检查内核更新。")
    }

    func installCoreUpdate() -> RemoteActionResult {
        guard let state = appState else { return RemoteActionResult(ok: false, message: "应用状态尚未就绪。") }
        state.installLocalCoreUpdate()
        return RemoteActionResult(ok: true, message: "正在下载并更新 Mihomo 内核…")
    }

    func validateConfig() -> RemoteActionResult {
        guard let state = appState else { return RemoteActionResult(ok: false, message: "应用状态尚未就绪。") }
        state.validateLocal()
        return RemoteActionResult(ok: true, message: "已触发配置校验。")
    }

    func clearLogs() -> RemoteActionResult {
        guard let state = appState else { return RemoteActionResult(ok: false, message: "应用状态尚未就绪。") }
        state.engine.clearLog()
        return RemoteActionResult(ok: true, message: "已清空运行日志。")
    }

    func clearOutboundErrors() -> RemoteActionResult {
        guard let state = appState else { return RemoteActionResult(ok: false, message: "应用状态尚未就绪。") }
        state.connectionMonitor.clearOutboundErrors()
        return RemoteActionResult(ok: true, message: "已清空链路异常记录。")
    }

    func updateMode(_ req: RemoteModeUpdateRequest) -> RemoteActionResult {
        guard let state = appState else { return RemoteActionResult(ok: false, message: "应用状态尚未就绪。") }
        if let tun = req.tunEnabled {
            guard !state.localEditingLocked else {
                return RemoteActionResult(ok: false, message: "核心运行中无法直接切换 TUN 模式，请先停止核心。")
            }
            state.setLocalTunEnabled(tun)
        }
        if let gateway = req.gatewayModeEnabled {
            guard !state.localEditingLocked else {
                return RemoteActionResult(ok: false, message: "核心运行中无法直接切换网关模式，请先停止核心。")
            }
            state.setLocalGatewayModeEnabled(gateway)
        }
        if let allowLAN = req.allowLAN {
            var updated = state.localProfile
            updated.allowLAN = allowLAN
            state.updateLocalProfileFromRemote(updated)
        }
        return RemoteActionResult(ok: true, message: "模式设置已更新。")
    }

    private func toConnectionDTO(_ record: MonitoredConnection) -> RemoteConnectionDTO {
        let meta = record.metadata
        return RemoteConnectionDTO(
            id: record.id,
            host: record.hostOnly,
            network: meta.network,
            sourceIP: meta.sourceIP,
            destinationIP: meta.destinationIP,
            sourcePort: meta.sourcePort.isEmpty ? nil : meta.sourcePort,
            destinationPort: meta.destinationPort.isEmpty ? nil : meta.destinationPort,
            process: meta.process.isEmpty ? nil : meta.process,
            type: meta.type.isEmpty ? nil : meta.type,
            startDate: record.startDate,
            closedAt: record.closedAt,
            rule: record.rule,
            matchedRuleSet: record.rulePayload.isEmpty ? nil : record.rulePayload,
            chain: record.displayChain.joined(separator: " → "),
            chains: record.chains,
            upload: record.upload,
            download: record.download,
            uploadSpeed: record.uploadSpeed,
            downloadSpeed: record.downloadSpeed,
            isActive: record.isActive
        )
    }
}

@MainActor
final class RemoteServerService: ObservableObject {
    @Published var isEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: DefaultsKey.enabled)
            if isEnabled {
                startListener()
            } else {
                stopListener()
            }
        }
    }
    @Published var port: UInt16 = RemoteControlProtocol.defaultPort {
        didSet {
            UserDefaults.standard.set(Int(port), forKey: DefaultsKey.port)
            if isEnabled {
                stopListener()
                startListener()
            }
        }
    }
    @Published private(set) var isListening = false
    @Published private(set) var listeningPort: UInt16?
    @Published private(set) var lastError: String?
    @Published private(set) var activePairingCode: String
    @Published private(set) var pairingCodeExpiresAt: Date
    @Published private(set) var pairedClients: [RemotePairedClientRecord]

    let deviceId: String
    var hostDisplayName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    let apiHandler: RemoteAPIHandler
    let relayHost = LumzelRelayHostService()
    private var backendAdapter: AppStateRemoteHostBackend?
    private var listener: NWListener?
    private let listenerQueue = DispatchQueue(label: "local.routeweaver.remote-server", qos: .userInitiated)

    private enum DefaultsKey {
        static let enabled = "RouteWeaver.remoteServerEnabled"
        static let port = "RouteWeaver.remoteServerPort"
        static let deviceId = "RouteWeaver.remoteDeviceId"
        static let pairedClients = "RouteWeaver.remotePairedClients"
    }

    init() {
        let resolvedDeviceId: String
        if let existing = UserDefaults.standard.string(forKey: DefaultsKey.deviceId), !existing.isEmpty {
            resolvedDeviceId = existing
        } else {
            let created = UUID().uuidString
            UserDefaults.standard.set(created, forKey: DefaultsKey.deviceId)
            resolvedDeviceId = created
        }
        self.deviceId = resolvedDeviceId

        let handler = RemoteAPIHandler(
            deviceId: resolvedDeviceId,
            hostNameProvider: { Host.current().localizedName ?? ProcessInfo.processInfo.hostName },
            pairedClientsDefaultsKey: DefaultsKey.pairedClients
        )
        self.apiHandler = handler
        self.relayHost.attach(apiHandler: handler)
        self.activePairingCode = handler.activePairingCode
        self.pairingCodeExpiresAt = handler.pairingCodeExpiresAt
        self.pairedClients = handler.pairedClients

        handler.onStateChanged = { [weak self] in
            self?.syncPublishedHandlerState()
        }

        let savedPort = UserDefaults.standard.integer(forKey: DefaultsKey.port)
        if savedPort > 0 && savedPort <= 65535 {
            self.port = UInt16(savedPort)
        }
        self.isEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.enabled)
    }

    func attach(appState: AppState) {
        let adapter = AppStateRemoteHostBackend(appState: appState)
        self.backendAdapter = adapter
        apiHandler.backend = adapter
        relayHost.attach(apiHandler: apiHandler)
        if isEnabled && listener == nil {
            startListener()
        }
    }

    func regeneratePairingCode() {
        apiHandler.regeneratePairingCode()
    }

    func revokeClient(_ id: String) {
        apiHandler.revokeClient(id)
    }

    func revokeAllClients() {
        apiHandler.revokeAllClients()
    }

    func startListener() {
        guard listener == nil else { return }
        lastError = nil

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let nwPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: RemoteControlProtocol.defaultPort)!
            let newListener = try NWListener(using: params, on: nwPort)

            let lanIPs = backendAdapter?.localLANIPAddresses ?? NetworkEnvironment.detailedInterfaces().compactMap(\.ipv4Address)
            var txtDict: [String: String] = [
                "deviceId": deviceId,
                "name": hostDisplayName,
                "port": String(port),
                "v": String(RemoteControlProtocol.protocolVersion)
            ]
            if !lanIPs.isEmpty {
                txtDict["ips"] = lanIPs.joined(separator: ",")
            }
            let txt = NWTXTRecord(txtDict)
            newListener.service = NWListener.Service(
                name: hostDisplayName,
                type: RemoteControlProtocol.serviceType,
                domain: nil,
                txtRecord: txt
            )

            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isListening = true
                        self.listeningPort = newListener.port?.rawValue ?? self.port
                        self.lastError = nil
                    case .failed(let error):
                        self.isListening = false
                        self.listeningPort = nil
                        self.lastError = "远程服务监听失败：\(error.localizedDescription)"
                        self.listener?.cancel()
                        self.listener = nil
                    case .cancelled:
                        self.isListening = false
                        self.listeningPort = nil
                    default:
                        break
                    }
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }

            self.listener = newListener
            newListener.start(queue: listenerQueue)
        } catch {
            lastError = "无法启动远程管理监听：\(error.localizedDescription)"
            isListening = false
            listeningPort = nil
        }
    }

    func stopListener() {
        listener?.cancel()
        listener = nil
        isListening = false
        listeningPort = nil
    }

    private func syncPublishedHandlerState() {
        if activePairingCode != apiHandler.activePairingCode {
            activePairingCode = apiHandler.activePairingCode
        }
        if pairingCodeExpiresAt != apiHandler.pairingCodeExpiresAt {
            pairingCodeExpiresAt = apiHandler.pairingCodeExpiresAt
        }
        if pairedClients != apiHandler.pairedClients {
            pairedClients = apiHandler.pairedClients
        }
    }

    private nonisolated func handleNewConnection(_ connection: NWConnection) {
        connection.start(queue: listenerQueue)
        receiveLoop(connection: connection, buffer: Data())
    }

    private nonisolated func receiveLoop(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data, !data.isEmpty {
                accumulated.append(data)
            }

            switch RemoteHTTPParser.parse(accumulated) {
            case .parsed(let request):
                Task { @MainActor [weak self] in
                    let responseData: Data
                    if let self {
                        responseData = await self.apiHandler.handle(request).serialized()
                    } else {
                        responseData = RemoteHTTPResponse.error(status: 500, message: "Service unavailable")
                    }
                    connection.send(
                        content: responseData,
                        contentContext: .finalMessage,
                        isComplete: true,
                        completion: .contentProcessed { _ in
                            connection.cancel()
                        }
                    )
                }
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receiveLoop(connection: connection, buffer: accumulated)
                }
            case .invalid:
                let responseData = RemoteHTTPResponse.error(status: 400, message: "Malformed HTTP request")
                connection.send(content: responseData, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }
}
