import CoreLocation
import Foundation
import Network
import NetworkExtension
import RoutingCore
import UIKit

struct DiscoveredLANHost: Identifiable, Equatable {
    let id: String
    let name: String
    let port: UInt16
    let ips: [String]
    let endpoint: Network.NWEndpoint
}

@MainActor
final class MobileAppModel: NSObject, ObservableObject {
    let remoteClient = MobileRemoteClient()
    let store = AppGroupStore.shared

    // MARK: - Published State

    @Published var vpnStatus: NEVPNStatus = .invalid
    @Published var syncedHostState: MobileSyncedHostState?
    @Published var relayConfig: RelayEndpointConfig
    @Published var interfaceMappings: [PCInterfaceMappingRule]
    @Published var switchPolicy: NetworkSwitchPolicy
    @Published var runtimeStatus: MobileTunnelRuntimeStatus?

    @Published var currentNetworkSnapshot = MobileNetworkSnapshot(interfaceKind: .other, wifiSSID: nil)
    @Published private(set) var discoveredHosts: [DiscoveredLANHost] = []
    @Published private(set) var isBrowsingLAN = false
    @Published private(set) var savedHosts: [RemoteSavedHost] = []
    @Published var activeHostID: String?

    @Published var remoteSnapshot: RemoteSnapshotDTO?
    @Published var remoteFullState: RemoteFullStateDTO?
    @Published var isConnectedViaRelay = false
    @Published var isSyncing = false
    @Published var isBusy = false
    @Published var lastError: String?
    @Published var statusMessage: String?

    // MARK: - Private Services

    private static let tunnelBundleIdentifier = "com.bytevela.routeweaver.packet-tunnel"
    private static let savedHostsDefaultsKey = "RouteWeaveriOS.savedHosts"
    private static let activeHostIDDefaultsKey = "RouteWeaveriOS.activeHostID"
    private static let deviceIDDefaultsKey = "RouteWeaveriOS.deviceID"

    private var tunnelManager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var browser: NWBrowser?
    private let browserQueue = DispatchQueue(label: "com.routeweaver.ios.bonjour", qos: .utility)
    private var pathMonitor: NWPathMonitor?
    private let pathQueue = DispatchQueue(label: "com.routeweaver.ios.path-monitor", qos: .utility)
    private let locationManager = CLLocationManager()
    private var hasBootstrapped = false

    private var localDeviceID: String {
        store.stableDeviceID
    }

    private var localDeviceName: String {
        UIDevice.current.name
    }

    var activeHost: RemoteSavedHost? {
        guard let activeHostID else { return savedHosts.first }
        return savedHosts.first(where: { $0.id == activeHostID }) ?? savedHosts.first
    }

    var effectiveMode: MobileVPNMode {
        switchPolicy.resolve(for: currentNetworkSnapshot)
    }

    override init() {
        let initialStore = AppGroupStore.shared
        self.syncedHostState = initialStore.syncedHostState
        self.relayConfig = initialStore.relayConfig
        self.interfaceMappings = initialStore.interfaceMappings
        self.switchPolicy = initialStore.switchPolicy
        self.runtimeStatus = initialStore.runtimeStatus
        super.init()
        loadSavedHosts()
        locationManager.delegate = self
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        browser?.cancel()
        pathMonitor?.cancel()
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        observeVPNStatus()
        startNetworkMonitor()
        startBonjourDiscovery()
        await loadTunnelManager()
        await refreshRuntimeStatusFromTunnel()

        if activeHost != nil {
            await refreshRemoteDashboard()
        }
    }

    // MARK: - VPN & OnDemand Management

    func loadTunnelManager() async {
        #if targetEnvironment(simulator)
        self.vpnStatus = .disconnected
        return
        #else
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            if let existing = managers.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.tunnelBundleIdentifier
            }) {
                self.tunnelManager = existing
                self.vpnStatus = existing.connection.status
            } else {
                let manager = Self.makeDefaultTunnelManager()
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
                self.tunnelManager = manager
                self.vpnStatus = manager.connection.status
            }
        } catch {
            lastError = "加载 VPN 配置失败：\(error.localizedDescription)"
        }
        #endif
    }

    private static func makeDefaultTunnelManager() -> NETunnelProviderManager {
        let manager = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = tunnelBundleIdentifier
        proto.serverAddress = "RouteWeaver"
        manager.protocolConfiguration = proto
        manager.localizedDescription = "RouteWeaver"
        manager.isEnabled = true
        return manager
    }

    func toggleVPN() async {
        switch vpnStatus {
        case .connected, .connecting, .reasserting:
            await stopVPN()
        default:
            await startVPN()
        }
    }

    func startVPN() async {
        isBusy = true
        defer { isBusy = false }
        lastError = nil

        #if targetEnvironment(simulator)
        await saveConfigurationToStore()
        let mode = effectiveMode
        if mode == .disabled {
            vpnStatus = .disconnected
            statusMessage = "当前场景为「临时禁用 VPN」，未启动隧道"
            return
        }
        do {
            let profile = activeSyncedProfile ?? RoutingProfile()
            let adapted = try MobileProfileAdapter.render(
                pcProfile: profile,
                mode: mode,
                relayConfig: relayConfig,
                interfaceMappings: interfaceMappings
            )
            let status = MobileTunnelRuntimeStatus(
                activeMode: mode,
                networkKind: currentNetworkSnapshot.interfaceKind.rawValue,
                wifiSSID: currentNetworkSnapshot.wifiSSID,
                relayedInterfaces: adapted.relayedPCInterfaces,
                relayConnected: relayConfig.isEnabled && !adapted.relayedPCInterfaces.isEmpty,
                engineVersion: "模拟器预览（真机启用 PacketTunnel）",
                lastError: nil,
                updatedAt: Date()
            )
            self.runtimeStatus = status
            store.runtimeStatus = status
            self.vpnStatus = .connected
            statusMessage = "模拟器预览已连接（已校验并生成 \(adapted.configData.count) 字节配置；系统级 VPN 隧道需部署到真机运行）"
        } catch {
            lastError = "配置渲染失败：\(error.localizedDescription)"
        }
        return
        #else
        if tunnelManager == nil {
            await loadTunnelManager()
        }
        guard let manager = tunnelManager else {
            lastError = "无法初始化 VPN 配置"
            return
        }

        do {
            await saveConfigurationToStore()
            applyOnDemandRules(to: manager)
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            try manager.connection.startVPNTunnel()
            statusMessage = "正在启动 RouteWeaver 隧道…"
        } catch {
            lastError = "启动 VPN 失败：\(error.localizedDescription)"
        }
        #endif
    }

    func stopVPN() async {
        isBusy = true
        defer { isBusy = false }

        #if targetEnvironment(simulator)
        vpnStatus = .disconnected
        runtimeStatus = nil
        store.runtimeStatus = nil
        statusMessage = "已断开模拟预览隧道"
        return
        #else
        guard let manager = tunnelManager else { return }

        if manager.isOnDemandEnabled {
            manager.isOnDemandEnabled = false
            try? await manager.saveToPreferences()
        }
        manager.connection.stopVPNTunnel()
        statusMessage = "已停止 RouteWeaver 隧道"
        #endif
    }

    func setManualScenario(_ mode: MobileVPNMode?) async {
        switchPolicy.manualOverride = mode
        await saveAndNotifyTunnel()

        if mode == .disabled {
            if vpnStatus == .connected || vpnStatus == .connecting {
                await stopVPN()
            }
        } else if vpnStatus == .disconnected || vpnStatus == .invalid {
            await startVPN()
        }
    }

    func saveAndNotifyTunnel() async {
        await saveConfigurationToStore()

        if let manager = tunnelManager {
            do {
                applyOnDemandRules(to: manager)
                manager.isEnabled = true
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
            } catch {
                lastError = "保存系统按需连接规则失败：\(error.localizedDescription)"
            }
        }

        await sendTunnelMessage(.reloadConfig)
        await refreshRuntimeStatusFromTunnel()
        statusMessage = "配置已保存并通知隧道生效"
    }

    private func saveConfigurationToStore() async {
        store.relayConfig = relayConfig
        store.interfaceMappings = interfaceMappings
        store.switchPolicy = switchPolicy
        if let syncedHostState {
            store.syncedHostState = syncedHostState
        }
    }

    private func applyOnDemandRules(to manager: NETunnelProviderManager) {
        if switchPolicy.manualOverride == .disabled {
            manager.isOnDemandEnabled = false
            manager.onDemandRules = []
            return
        }

        var onDemandRules: [NEOnDemandRule] = []

        for rule in switchPolicy.rules where rule.isEnabled {
            switch rule.condition {
            case .wifiSSID(let ssid):
                let trimmed = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let neRule: NEOnDemandRule = (rule.mode == .disabled) ? NEOnDemandRuleDisconnect() : NEOnDemandRuleConnect()
                neRule.interfaceTypeMatch = .wiFi
                neRule.ssidMatch = [trimmed]
                onDemandRules.append(neRule)

            case .anyWiFi:
                let neRule: NEOnDemandRule = (rule.mode == .disabled) ? NEOnDemandRuleDisconnect() : NEOnDemandRuleConnect()
                neRule.interfaceTypeMatch = .wiFi
                onDemandRules.append(neRule)

            case .cellular:
                let neRule: NEOnDemandRule = (rule.mode == .disabled) ? NEOnDemandRuleDisconnect() : NEOnDemandRuleConnect()
                neRule.interfaceTypeMatch = .cellular
                onDemandRules.append(neRule)
            }
        }

        let fallbackRule: NEOnDemandRule = (switchPolicy.defaultMode == .disabled)
            ? NEOnDemandRuleDisconnect()
            : NEOnDemandRuleConnect()
        onDemandRules.append(fallbackRule)

        manager.onDemandRules = onDemandRules
        manager.isOnDemandEnabled = !onDemandRules.isEmpty
    }

    private func observeVPNStatus() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let connection = notification.object as? NEVPNConnection {
                Task { @MainActor in
                    self.vpnStatus = connection.status
                    if connection.status == .connected {
                        await self.refreshRuntimeStatusFromTunnel()
                    }
                }
            }
        }
    }

    // MARK: - Tunnel IPC

    @discardableResult
    func sendTunnelMessage(_ command: AppTunnelCommand, manualOverride: MobileVPNMode? = nil) async -> MobileTunnelRuntimeStatus? {
        guard let session = tunnelManager?.connection as? NETunnelProviderSession,
              session.status == .connected || session.status == .connecting || session.status == .reasserting else {
            return nil
        }

        let message = AppTunnelMessage(command: command, manualOverride: manualOverride)
        guard let payload = try? JSONEncoder().encode(message) else { return nil }

        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(payload) { [weak self] responseData in
                    Task { @MainActor in
                        guard let responseData,
                              let decoded = try? JSONDecoder().decode(MobileTunnelRuntimeStatus.self, from: responseData) else {
                            continuation.resume(returning: nil)
                            return
                        }
                        self?.runtimeStatus = decoded
                        self?.store.runtimeStatus = decoded
                        continuation.resume(returning: decoded)
                    }
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    func refreshRuntimeStatusFromTunnel() async {
        if let latest = await sendTunnelMessage(.getStatus) {
            runtimeStatus = latest
        } else {
            runtimeStatus = store.runtimeStatus
        }
    }

    // MARK: - Pairing & Remote PC Sync

    func importPairingBundle(_ raw: String) async {
        isBusy = true
        defer { isBusy = false }
        lastError = nil

        do {
            let bundle = try RelayPairingBundle.decodeShareString(raw)
            let ok = await remoteClient.pair(bundle: bundle, deviceName: localDeviceName)
            if ok {
                self.relayConfig = store.relayConfig
                if let synced = store.syncedHostState {
                    self.syncedHostState = synced
                    upsertSavedHost(synced.savedHost)
                    mergeInterfacesIntoMappings(synced.pcInterfaces)
                }
                self.remoteFullState = remoteClient.fullState
                self.remoteSnapshot = remoteClient.snapshot
                self.isConnectedViaRelay = remoteClient.isUsingRelayTransport
                await saveAndNotifyTunnel()
                statusMessage = remoteClient.feedbackMessage ?? "已成功导入并配对 \(bundle.hostName)"
            } else {
                lastError = remoteClient.lastError ?? "导入配对包失败"
            }
        } catch {
            lastError = "导入配对包失败：\(error.localizedDescription)"
        }
    }

    func pairManualHost(host: String, port: UInt16, pairingCode: String) async {
        isBusy = true
        defer { isBusy = false }
        lastError = nil

        let ok = await remoteClient.pairManual(
            host: host,
            port: port,
            pairingCode: pairingCode,
            deviceName: localDeviceName
        )
        if ok {
            if let synced = store.syncedHostState {
                self.syncedHostState = synced
                upsertSavedHost(synced.savedHost)
                mergeInterfacesIntoMappings(synced.pcInterfaces)
            }
            self.remoteFullState = remoteClient.fullState
            self.remoteSnapshot = remoteClient.snapshot
            self.isConnectedViaRelay = remoteClient.isUsingRelayTransport
            await saveAndNotifyTunnel()
            statusMessage = remoteClient.feedbackMessage ?? "已成功配对"
        } else {
            lastError = remoteClient.lastError ?? "配对失败"
        }
    }

    private var activeRelayChainProxyPort: Int? {
        guard vpnStatus == .connected,
              let status = runtimeStatus,
              case .localCore(let opts) = status.activeMode,
              !opts.bypassChainedProxy else {
            return nil
        }
        let route = opts.relayRouteOverride ?? relayConfig.defaultRoute
        if case .chainedNodeGroup = route {
            return MobileProfileAdapter.defaultRelayChainEntryPort
        }
        return nil
    }

    func syncNow() async {
        guard let host = activeHost else {
            lastError = "尚未配对远程 PC，请先在「远程 PC」页面完成配对"
            return
        }

        isSyncing = true
        defer { isSyncing = false }
        lastError = nil

        let activeRelay = relayConfig.isEnabled ? relayConfig : nil
        await remoteClient.syncFullState(host: host, relayConfig: activeRelay, chainProxyPort: activeRelayChainProxyPort)
        await remoteClient.refreshSnapshot(host: host, relayConfig: activeRelay, chainProxyPort: activeRelayChainProxyPort)

        if let err = remoteClient.lastError {
            lastError = err
            return
        }

        self.remoteFullState = remoteClient.fullState
        self.remoteSnapshot = remoteClient.snapshot
        self.isConnectedViaRelay = remoteClient.isUsingRelayTransport

        if let synced = store.syncedHostState {
            self.syncedHostState = synced
            self.relayConfig = store.relayConfig
            mergeInterfacesIntoMappings(synced.pcInterfaces)
            await saveAndNotifyTunnel()
            statusMessage = "已同步 \(host.hostName) 配置（\(synced.profile.targets.count) 个目标 / \(synced.profile.ruleGroups.count) 条规则组）"
        }
    }

    func refreshRemoteDashboard() async {
        guard let host = activeHost else { return }
        let activeRelay = relayConfig.isEnabled ? relayConfig : nil
        await remoteClient.refreshSnapshot(host: host, relayConfig: activeRelay, chainProxyPort: activeRelayChainProxyPort)
        if let snap = remoteClient.snapshot {
            self.remoteSnapshot = snap
            self.isConnectedViaRelay = remoteClient.isUsingRelayTransport
        }
    }

    private func applyRemoteActionResult() {
        self.remoteSnapshot = remoteClient.snapshot
        self.isConnectedViaRelay = remoteClient.isUsingRelayTransport
        if let err = remoteClient.lastError {
            self.lastError = err
        } else if let msg = remoteClient.feedbackMessage {
            self.statusMessage = msg
        }
    }

    func startRemotePC() async {
        guard let host = activeHost else { return }
        isBusy = true
        defer { isBusy = false }
        lastError = nil
        await remoteClient.startPCEngine(host: host, relayConfig: relayConfig.isEnabled ? relayConfig : nil, chainProxyPort: activeRelayChainProxyPort)
        applyRemoteActionResult()
    }

    func stopRemotePC() async {
        guard let host = activeHost else { return }
        isBusy = true
        defer { isBusy = false }
        lastError = nil
        await remoteClient.stopPCEngine(host: host, relayConfig: relayConfig.isEnabled ? relayConfig : nil, chainProxyPort: activeRelayChainProxyPort)
        applyRemoteActionResult()
    }

    func hotReloadRemotePC() async {
        guard let host = activeHost else { return }
        isBusy = true
        defer { isBusy = false }
        lastError = nil
        await remoteClient.hotReloadPC(host: host, relayConfig: relayConfig.isEnabled ? relayConfig : nil, chainProxyPort: activeRelayChainProxyPort)
        applyRemoteActionResult()
    }

    func selectRemoteProxy(group: String, node: String) async {
        guard let host = activeHost else { return }
        isBusy = true
        defer { isBusy = false }
        lastError = nil
        await remoteClient.selectProxy(host: host, relayConfig: relayConfig.isEnabled ? relayConfig : nil, group: group, node: node, chainProxyPort: activeRelayChainProxyPort)
        applyRemoteActionResult()
    }

    func testRemoteDelay(group: String) async {
        guard let host = activeHost else { return }
        isBusy = true
        defer { isBusy = false }
        lastError = nil
        await remoteClient.testDelay(host: host, relayConfig: relayConfig.isEnabled ? relayConfig : nil, group: group, chainProxyPort: activeRelayChainProxyPort)
        applyRemoteActionResult()
    }

    func closeRemoteConnection(id: String) async {
        guard let host = activeHost else { return }
        await remoteClient.closeConnection(host: host, relayConfig: relayConfig.isEnabled ? relayConfig : nil, id: id, chainProxyPort: activeRelayChainProxyPort)
        applyRemoteActionResult()
    }

    func closeAllRemoteConnections() async {
        guard let host = activeHost else { return }
        isBusy = true
        defer { isBusy = false }
        await remoteClient.closeAllConnections(host: host, relayConfig: relayConfig.isEnabled ? relayConfig : nil, chainProxyPort: activeRelayChainProxyPort)
        applyRemoteActionResult()
    }

    func flushRemoteDNS(includeFakeIP: Bool = false) async {
        guard let host = activeHost else { return }
        isBusy = true
        defer { isBusy = false }
        await remoteClient.flushDNS(host: host, relayConfig: relayConfig.isEnabled ? relayConfig : nil, includeFakeIP: includeFakeIP, chainProxyPort: activeRelayChainProxyPort)
        applyRemoteActionResult()
    }

    // MARK: - Live Dashboard Polling

    private var livePollTask: Task<Void, Never>?

    func startLivePolling() {
        guard livePollTask == nil else { return }
        livePollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.activeHost != nil {
                    await self.refreshRemoteDashboard()
                }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
    }

    func stopLivePolling() {
        livePollTask?.cancel()
        livePollTask = nil
    }

    // MARK: - Rule-Referenced Interface Mapping Helpers

    var activeSyncedProfile: RoutingProfile? {
        remoteFullState?.profile ?? syncedHostState?.profile
    }

    /// Returns ONLY PC BSD interfaces actually referenced by active rules or the fallback target.
    var referencedPCInterfaceNames: [String] {
        guard let profile = activeSyncedProfile else { return [] }
        var used = Set<String>()
        func collect(from ref: TargetReference) {
            guard case .target(let id) = ref else { return }
            if case .resolved(let leaf, _) = profile.resolveTarget(id: id),
               let iface = leaf.normalizedInterface {
                used.insert(iface)
            }
        }
        for group in profile.ruleGroups {
            collect(from: group.target)
        }
        collect(from: profile.fallbackTarget)
        return used.sorted()
    }

    /// Filtered interface mappings containing ONLY interfaces referenced by rules.
    var referencedInterfaceMappings: [PCInterfaceMappingRule] {
        let names = referencedPCInterfaceNames
        let byName = Dictionary(uniqueKeysWithValues: interfaceMappings.map { ($0.bsdName, $0) })
        let dtoByName = Dictionary(uniqueKeysWithValues: (syncedHostState?.pcInterfaces ?? []).map { ($0.bsdName, $0) })
        return names.map { name in
            if let existing = byName[name] {
                return existing
            }
            return PCInterfaceMappingRule(
                bsdName: name,
                displayName: dtoByName[name]?.displayName ?? "",
                action: .useMobileDefault
            )
        }
    }

    func resolvedTargetInfo(for ref: TargetReference) -> (name: String, modeTitle: String, boundInterface: String?) {
        switch ref {
        case .reject:
            return ("拒绝连接 (REJECT)", "拒绝", nil)
        case .target(let id):
            guard let profile = activeSyncedProfile else {
                return ("未知目标", "未知", nil)
            }
            let directTarget = profile.targets.first(where: { $0.id == id })
            switch profile.resolveTarget(id: id) {
            case .resolved(let leaf, _):
                let displayName = directTarget?.name ?? leaf.name
                return (displayName, leaf.mode.title, leaf.normalizedInterface)
            default:
                return (directTarget?.name ?? "目标缺失", "无效", nil)
            }
        }
    }

    func interfaceDisplayName(for bsdName: String) -> String {
        if let dto = syncedHostState?.pcInterfaces.first(where: { $0.bsdName == bsdName }),
           !dto.displayName.isEmpty {
            return dto.displayName
        }
        if let rule = interfaceMappings.first(where: { $0.bsdName == bsdName }),
           !rule.displayName.isEmpty {
            return rule.displayName
        }
        return bsdName
    }

    func interfaceAction(for bsdName: String) -> PCInterfaceMappingAction {
        interfaceMappings.first(where: { $0.bsdName == bsdName })?.action ?? .useMobileDefault
    }

    func setInterfaceAction(_ action: PCInterfaceMappingAction, for bsdName: String) async {
        if let idx = interfaceMappings.firstIndex(where: { $0.bsdName == bsdName }) {
            interfaceMappings[idx].action = action
        } else {
            interfaceMappings.append(PCInterfaceMappingRule(
                bsdName: bsdName,
                displayName: interfaceDisplayName(for: bsdName),
                action: action
            ))
            interfaceMappings.sort { $0.bsdName < $1.bsdName }
        }
        await saveAndNotifyTunnel()
    }

    private func mergeInterfacesIntoMappings(_ interfaces: [RemoteInterfaceDTO]) {
        var existingByName = Dictionary(uniqueKeysWithValues: interfaceMappings.map { ($0.bsdName, $0) })
        for iface in interfaces {
            if var existing = existingByName[iface.bsdName] {
                existing.displayName = iface.displayName
                existingByName[iface.bsdName] = existing
            } else {
                existingByName[iface.bsdName] = PCInterfaceMappingRule(
                    bsdName: iface.bsdName,
                    displayName: iface.displayName,
                    action: .useMobileDefault
                )
            }
        }
        interfaceMappings = existingByName.values.sorted { $0.bsdName < $1.bsdName }
    }

    // MARK: - Saved Hosts Persistence

    func selectHost(_ host: RemoteSavedHost) async {
        activeHostID = host.id
        UserDefaults.standard.set(host.id, forKey: Self.activeHostIDDefaultsKey)
        await refreshRemoteDashboard()
    }

    func removeHost(_ host: RemoteSavedHost) {
        savedHosts.removeAll { $0.id == host.id }
        if activeHostID == host.id {
            activeHostID = savedHosts.first?.id
            UserDefaults.standard.set(activeHostID, forKey: Self.activeHostIDDefaultsKey)
        }
        persistSavedHosts()
    }

    private func upsertSavedHost(_ host: RemoteSavedHost) {
        if let idx = savedHosts.firstIndex(where: { $0.hostDeviceId == host.hostDeviceId }) {
            savedHosts[idx] = host
        } else {
            savedHosts.append(host)
        }
        activeHostID = host.hostDeviceId
        UserDefaults.standard.set(host.hostDeviceId, forKey: Self.activeHostIDDefaultsKey)
        persistSavedHosts()
    }

    private func loadSavedHosts() {
        if let data = UserDefaults.standard.data(forKey: Self.savedHostsDefaultsKey),
           let decoded = try? JSONDecoder().decode([RemoteSavedHost].self, from: data) {
            savedHosts = decoded
        }
        activeHostID = UserDefaults.standard.string(forKey: Self.activeHostIDDefaultsKey) ?? savedHosts.first?.id
    }

    private func persistSavedHosts() {
        if let data = try? JSONEncoder().encode(savedHosts) {
            UserDefaults.standard.set(data, forKey: Self.savedHostsDefaultsKey)
        }
    }

    // MARK: - Bonjour Discovery

    func startBonjourDiscovery() {
        guard browser == nil else { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: RemoteControlProtocol.serviceType,
            domain: nil
        )
        let newBrowser = NWBrowser(for: descriptor, using: params)

        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready:
                    self?.isBrowsingLAN = true
                case .failed, .cancelled:
                    self?.isBrowsingLAN = false
                default:
                    break
                }
            }
        }

        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            var parsed: [DiscoveredLANHost] = []
            for result in results {
                guard case .service(let serviceName, _, _, _) = result.endpoint else { continue }
                var deviceID = serviceName
                var displayName = serviceName
                var port = RemoteControlProtocol.defaultPort
                var ips: [String] = []

                if case .bonjour(let txt) = result.metadata {
                    let dict = txt.dictionary
                    if let id = dict["deviceId"], !id.isEmpty { deviceID = id }
                    if let name = dict["name"], !name.isEmpty { displayName = name }
                    if let rawPort = dict["port"], let parsedPort = UInt16(rawPort) { port = parsedPort }
                    if let rawIPs = dict["ips"], !rawIPs.isEmpty {
                        ips = rawIPs.split(separator: ",").map(String.init)
                    }
                }

                parsed.append(DiscoveredLANHost(
                    id: deviceID,
                    name: displayName,
                    port: port,
                    ips: ips,
                    endpoint: result.endpoint
                ))
            }

            Task { @MainActor [weak self] in
                self?.discoveredHosts = parsed.sorted { $0.name < $1.name }
            }
        }

        newBrowser.start(queue: browserQueue)
        browser = newBrowser
    }

    // MARK: - Network Path & Wi-Fi SSID Monitoring

    func requestLocationForSSID() {
        locationManager.requestWhenInUseAuthorization()
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let kind: MobileNetworkSnapshot.InterfaceKind
            if path.usesInterfaceType(.wifi) {
                kind = .wifi
            } else if path.usesInterfaceType(.cellular) {
                kind = .cellular
            } else if path.usesInterfaceType(.wiredEthernet) {
                kind = .wired
            } else {
                kind = .other
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                let ssid: String? = (kind == .wifi) ? await self.fetchCurrentWiFiSSID() : nil
                self.currentNetworkSnapshot = MobileNetworkSnapshot(interfaceKind: kind, wifiSSID: ssid)
            }
        }
        monitor.start(queue: pathQueue)
        pathMonitor = monitor
    }

    private func fetchCurrentWiFiSSID() async -> String? {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
    }
}

extension MobileAppModel: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if currentNetworkSnapshot.interfaceKind == .wifi {
                let ssid = await fetchCurrentWiFiSSID()
                currentNetworkSnapshot = MobileNetworkSnapshot(interfaceKind: .wifi, wifiSSID: ssid)
            }
        }
    }
}
