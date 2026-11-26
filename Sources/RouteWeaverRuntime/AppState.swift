import AppKit
import Combine
import Foundation
import RoutingCore
import UniformTypeIdentifiers

enum SidebarSection: String, CaseIterable, Identifiable {
    case overview
    case topology
    case monitor
    case trafficStats
    case ruleGroups
    case customDNS
    case targets
    case subscriptions
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "总览"
        case .topology: return "网络拓扑"
        case .monitor: return "请求监控"
        case .trafficStats: return "流量统计"
        case .ruleGroups: return "规则组"
        case .customDNS: return "自定义 DNS"
        case .targets: return "网络目标"
        case .subscriptions: return "订阅与节点"
        case .settings: return "设置与日志"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .topology: return "point.3.connected.trianglepath.dotted"
        case .monitor: return "waveform.path.ecg"
        case .trafficStats: return "chart.bar.xaxis"
        case .ruleGroups: return "list.bullet.rectangle.portrait"
        case .customDNS: return "globe"
        case .targets: return "point.topleft.down.to.point.bottomright.curvepath"
        case .subscriptions: return "point.3.filled.connected.trianglepath.dotted"
        case .settings: return "gearshape.2"
        }
    }
}

enum ManagedDevice: Equatable, Hashable, Identifiable {
    case local
    case remote(String)

    var id: String {
        switch self {
        case .local: return "local"
        case .remote(let hostId): return "remote:\(hostId)"
        }
    }

    var remoteHostId: String? {
        if case .remote(let hostId) = self { return hostId }
        return nil
    }
}

struct ReadinessItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let isReady: Bool
    let targetSection: SidebarSection
}

@MainActor
final class AppState: ObservableObject, DeviceSessionDelegate {
    @Published var selectedSection: SidebarSection? = .overview
    @Published var selectedTopologyTargetKey: String? = nil
    @Published private(set) var selectedDevice: ManagedDevice = .local
    @Published var showingRemoteDeviceSheet: Bool = false

    @Published var profile: RoutingProfile = .starter() {
        didSet {
            ruleMatchDisplayIndex = RuleMatchDisplayIndex(profile: profile)
            if isSyncingDeviceContext { return }
            activeSession.handleProfileEdited(profile)
        }
    }
    private(set) var ruleMatchDisplayIndex: RuleMatchDisplayIndex = RuleMatchDisplayIndex(profile: .starter())

    @Published var alertText: String?
    @Published var feedback: String = ""

    let localSession: LocalDeviceSession
    let remoteSession: RemoteDeviceSession
    let remoteServer = RemoteServerService()
    let remoteClient: RemoteClientService
    let remoteBridge: RemoteNetworkBridge

    private let routingSnapshotProvider: () -> SystemNetworkRoutingSnapshot
    private var cancellables = Set<AnyCancellable>()
    private var feedbackTask: Task<Void, Never>?
    private var isSyncingDeviceContext = false
    private var hasUserManuallySelectedDevice = false

    // MARK: - Active Session Facade

    var activeSession: any DeviceSession {
        selectedDevice == .local ? localSession : remoteSession
    }

    var isViewingRemote: Bool {
        activeSession.isRemote
    }

    var activeRemoteHost: RemoteSavedHost? {
        guard case .remote(let hostId) = selectedDevice else { return nil }
        return remoteClient.savedHosts.first { $0.id == hostId }
    }

    var currentDeviceDisplayName: String { activeSession.deviceDisplayName }

    var activeLiveProxyStore: LiveProxyStore { activeSession.liveProxyStore }
    var activeConnectionMonitor: ConnectionMonitorService { activeSession.connectionMonitor }
    var activeSubscriptionStore: SubscriptionStore { activeSession.subscriptionStore }
    var activeLogStore: EngineLogStore { activeSession.logStore }
    var activeGatewayDeviceStore: GatewayDeviceStore { activeSession.gatewayDeviceStore }

    // MARK: - Local Store & Property Forwarders (for Local Controls, MenuBar & RemoteServerService)

    var engine: EngineController { localSession.engine }
    var liveProxyStore: LiveProxyStore { localSession.liveProxyStore }
    var coreBinaryStore: CoreBinaryStore { localSession.coreBinaryStore }
    var subscriptionStore: SubscriptionStore { localSession.subscriptionStore }
    var connectionMonitor: ConnectionMonitorService { localSession.connectionMonitor }
    var gatewayDeviceStore: GatewayDeviceStore { localSession.gatewayDeviceStore }

    var localProfile: RoutingProfile { localSession.localProfile }
    var controllerPort: Int { localSession.controllerPort }
    var customProfileDirectory: URL? { localSession.customProfileDirectory }
    var autoStartCoreOnLaunch: Bool { localSession.autoStartCoreOnLaunch }
    var systemKeepAliveEnabled: Bool { localSession.systemKeepAliveEnabled }
    var launchAtLoginStatus: LaunchAtLoginStatus { localSession.launchAtLoginStatus }
    var interfaces: [NetworkInterfaceInfo] { localSession.interfaces }
    var hasPendingHotReload: Bool { localSession.hasPendingHotReload }
    var isHotReloading: Bool { activeSession.isHotReloading }
    var updatingGeoResources: Bool { localSession.updatingGeoResources }
    var geoUpdateMessage: String? { localSession.geoUpdateMessage }
    var tunPermissionStatus: TunPermissionStatus { localSession.tunPermissionStatus }
    var isAuthorizingTun: Bool { localSession.isAuthorizingTun }
    var killSwitchActive: Bool { localSession.killSwitchActive }
    var killSwitchAllowLAN: Bool { localSession.killSwitchAllowLAN }
    var killSwitchPersistOnBoot: Bool { localSession.killSwitchPersistOnBoot }
    var isUpdatingKillSwitch: Bool { localSession.isUpdatingKillSwitch }
    var isIPForwardingEnabled: Bool { localSession.isIPForwardingEnabled }
    var configValidationError: String? { localSession.configValidationError }
    var binary: URL? { localSession.binary }
    var activeProfileDirectory: URL { localSession.activeProfileDirectory }
    var savedProfileURL: URL { localSession.savedProfileURL }
    var isUsingCustomProfileDirectory: Bool { localSession.isUsingCustomProfileDirectory }

    var gatewayDevices: [GatewayClientDevice] { localSession.gatewayDeviceStore.devices }
    var includeARPOnlyGatewayDevices: Bool {
        get { activeSession.gatewayDeviceStore.includeARPOnly }
        set {
            activeSession.gatewayDeviceStore.includeARPOnly = newValue
            refreshGatewayDevices()
        }
    }

    var localActiveLANInterfaces: [NetworkInterfaceInfo] { localSession.activeLANInterfaces }
    var localLANIPAddresses: [String] { localSession.lanIPAddresses }
    var localPrimaryLANInterface: NetworkInterfaceInfo? { localSession.primaryLANInterface }
    var localPrimaryLANAddress: String? { localSession.primaryLANAddress }
    var localEditingLocked: Bool { localSession.editingLocked }
    var localCanStart: Bool { localSession.canStart }

    // MARK: - Unified Active Device Properties (Delegated to activeSession)

    /// True while this Mac's local Mihomo core is running or starting/stopping.
    var isLocalCoreActive: Bool { engine.isRunning || engine.isBusy }

    /// True while this Mac's system HTTP proxy / SOCKS5 / gateway is routed to a remote device.
    var isRemoteBridgeActive: Bool { remoteBridge.activeLink != nil }

    /// Mutual exclusion: cannot configure this Mac's HTTP proxy or gateway to a remote device while local core is active.
    var canConfigureRemoteBridge: Bool { !isLocalCoreActive }

    var isCoreRunning: Bool { activeSession.isCoreRunning }
    var isCoreBusy: Bool { activeSession.isCoreBusy }
    var corePhaseTitle: String { activeSession.corePhaseTitle }
    var isTunActive: Bool { activeSession.isTunActive }
    var isGatewayActive: Bool { activeSession.isGatewayActive }
    var isLaunchdManaged: Bool { activeSession.isLaunchdManaged }
    var coreLastError: String? { activeSession.coreLastError }
    var activeHasPendingHotReload: Bool { activeSession.hasPendingHotReload }
    var activeConfigValidationError: String? { activeSession.configValidationError }
    var activeKillSwitchActive: Bool { activeSession.killSwitchActive }
    var activeKillSwitchAllowLAN: Bool { activeSession.killSwitchAllowLAN }
    var activeKillSwitchPersistOnBoot: Bool { activeSession.killSwitchPersistOnBoot }
    var activeIsIPForwardingEnabled: Bool { activeSession.isIPForwardingEnabled }
    var activeControllerPort: Int { activeSession.controllerPort }
    var activeAutoStartCoreOnLaunch: Bool { activeSession.autoStartCoreOnLaunch }
    var activeSystemKeepAliveEnabled: Bool { activeSession.systemKeepAliveEnabled }
    var activeLaunchAtLoginEnabled: Bool { activeSession.launchAtLoginEnabled }
    var activeTunPermissionReady: Bool { activeSession.tunPermissionReady }
    var activeTunPermissionTitle: String { activeSession.tunPermissionTitle }
    var activeInterfaces: [NetworkInterfaceInfo] { activeSession.interfaces }
    var activeGatewayDevices: [GatewayClientDevice] { activeSession.gatewayDeviceStore.devices }
    var editingLocked: Bool { activeSession.editingLocked }
    var hotReloadEditingLocked: Bool { activeSession.hotReloadEditingLocked }
    var activeMixedPort: Int { activeSession.mixedPort }
    var localProxyAddress: String { activeSession.proxyAddress }
    var activeLANInterfaces: [NetworkInterfaceInfo] { activeSession.activeLANInterfaces }
    var lanIPAddresses: [String] { activeSession.lanIPAddresses }
    var primaryLANInterface: NetworkInterfaceInfo? { activeSession.primaryLANInterface }
    var primaryLANAddress: String? { activeSession.primaryLANAddress }
    var canStart: Bool { activeSession.canStart }
    var readinessItems: [ReadinessItem] { activeSession.readinessItems(for: profile) }

    var missingInterfaces: [String] {
        let active = Set(activeInterfaces.filter(\.isUpWithAddress).map(\.bsdName))
        return profile.requiredInterfaces.filter { !active.contains($0) }.sorted()
    }

    // MARK: - Gateway Device Label Helpers (Delegated to GatewayDeviceStore)

    var lanDeviceNamesByIP: [String: String] {
        activeSession.gatewayDeviceStore.lanDeviceNamesByIP
    }

    func clientDisplayLabel(for clientKey: String) -> String {
        activeSession.gatewayDeviceStore.clientDisplayLabel(for: clientKey)
    }

    func clientShortLabel(for clientKey: String) -> String {
        activeSession.gatewayDeviceStore.clientShortLabel(for: clientKey)
    }

    func connectionClientKey(for item: MonitoredConnection) -> String {
        activeSession.gatewayDeviceStore.connectionClientKey(for: item, localIPs: Set(lanIPAddresses))
    }

    /// Returns a display label only when the connection originates from another LAN device (nil for local machine).
    func connectionLANClientLabel(for item: MonitoredConnection) -> String? {
        activeSession.gatewayDeviceStore.connectionLANClientLabel(for: item, localIPs: Set(lanIPAddresses))
    }

    // MARK: - Initialization

    init(
        engine: EngineController? = nil,
        liveProxyStore: LiveProxyStore? = nil,
        connectionMonitor: ConnectionMonitorService? = nil,
        remoteClient: RemoteClientService? = nil,
        remoteBridge: RemoteNetworkBridge? = nil,
        gatewayInspector: any GatewayDeviceInspecting = SystemGatewayDeviceInspector(),
        routingSnapshotProvider: (() -> SystemNetworkRoutingSnapshot)? = nil,
        userDefaults: UserDefaults = .standard,
        bootstrapOnInit: Bool = true
    ) {
        let resolvedRemoteClient = remoteClient ?? RemoteClientService(
            localDeviceId: remoteServer.deviceId,
            localDeviceName: remoteServer.hostDisplayName
        )
        self.remoteClient = resolvedRemoteClient
        let resolvedBridge = remoteBridge ?? RemoteNetworkBridge(
            linkStore: UserDefaultsRemoteNetworkLinkStore(defaults: userDefaults)
        )
        self.remoteBridge = resolvedBridge
        self.routingSnapshotProvider = routingSnapshotProvider ?? (
            bootstrapOnInit ? NetworkEnvironment.currentRoutingSnapshot : { SystemNetworkRoutingSnapshot() }
        )

        weak var weakBridge: RemoteNetworkBridge?
        let localGatewayStore = GatewayDeviceStore(inspector: gatewayInspector)
        self.localSession = LocalDeviceSession(
            engine: engine,
            liveProxyStore: liveProxyStore,
            connectionMonitor: connectionMonitor,
            gatewayDeviceStore: localGatewayStore,
            userDefaults: userDefaults,
            bootstrapOnInit: bootstrapOnInit,
            activeRemoteBridgeDescriptionProvider: {
                guard let link = weakBridge?.activeLink else { return nil }
                return "远程设备「\(link.remoteHostName)」的\(link.mode.title)"
            }
        )
        self.remoteSession = RemoteDeviceSession(remoteClient: resolvedRemoteClient)
        weakBridge = resolvedBridge

        self.localSession.delegate = self
        self.remoteSession.delegate = self

        self.isSyncingDeviceContext = true
        self.profile = self.localSession.localProfile
        self.isSyncingDeviceContext = false

        if bootstrapOnInit {
            remoteServer.attach(appState: self)
        }

        if bootstrapOnInit || remoteBridge != nil || routingSnapshotProvider != nil {
            syncSelectedDeviceOnWindowOpen()
        }

        self.remoteBridge.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - DeviceSessionDelegate

    func deviceSession(_ session: any DeviceSession, didEmitFeedback message: String) {
        guard session === activeSession || !session.isRemote else { return }
        showFeedback(message)
    }

    func deviceSession(_ session: any DeviceSession, didEmitAlert message: String) {
        guard session === activeSession || !session.isRemote else { return }
        alertText = message
    }

    func deviceSessionDidChangeState(_ session: any DeviceSession) {
        guard session === activeSession || !session.isRemote else { return }
        objectWillChange.send()
    }

    func deviceSession(_ session: any DeviceSession, didSyncProfile syncedProfile: RoutingProfile) {
        guard session === activeSession else { return }
        isSyncingDeviceContext = true
        profile = syncedProfile
        isSyncingDeviceContext = false
    }

    func deviceSessionDidLoseRemoteHost(_ session: any DeviceSession) {
        guard session === remoteSession, isViewingRemote else { return }
        selectDevice(.local, userInitiated: false)
    }

    func deviceSessionDidReattachLocalCore(_ session: LocalDeviceSession) {
        guard !hasUserManuallySelectedDevice else { return }
        selectDevice(.local, userInitiated: false)
    }

    // MARK: - Device Switching

    func selectDevice(_ device: ManagedDevice, userInitiated: Bool = true) {
        if userInitiated {
            hasUserManuallySelectedDevice = true
        }
        guard selectedDevice != device else { return }
        selectedDevice = device
        switch device {
        case .local:
            remoteSession.deactivate()
            isSyncingDeviceContext = true
            profile = localSession.localProfile
            isSyncingDeviceContext = false
        case .remote(let hostId):
            remoteSession.activate(hostId: hostId)
        }
        objectWillChange.send()
    }

    /// Resolves which device (local Mac vs. a paired remote host) is currently providing network routing/proxy
    /// for this Mac, checking local Mihomo state, live macOS gateway/proxy settings, and `RemoteNetworkBridge`.
    func resolveActiveDeviceInUse() -> ManagedDevice {
        if isLocalCoreActive {
            return .local
        }
        let savedHosts = remoteClient.savedHosts
        guard !savedHosts.isEmpty else {
            return .local
        }

        let routing = routingSnapshotProvider()
        let ignoredEndpoints = Set(localSession.lanIPAddresses.map { $0.lowercased() })
            .union(["127.0.0.1", "::1", "localhost"])

        func matchingSavedHost(for rawEndpoint: String?) -> RemoteSavedHost? {
            guard let ep = rawEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !ep.isEmpty,
                  !ignoredEndpoints.contains(ep.lowercased()) else {
                return nil
            }
            if let direct = savedHosts.first(where: { $0.host.caseInsensitiveCompare(ep) == .orderedSame }) {
                return direct
            }
            for host in savedHosts {
                if let discovered = remoteClient.discoveredDevices.first(where: { $0.id == host.id }),
                   discovered.ips.contains(where: { $0.caseInsensitiveCompare(ep) == .orderedSame }) {
                    return host
                }
            }
            return nil
        }

        // 1. Live system default gateway or active HTTP/HTTPS/SOCKS proxy matching a paired remote host
        for endpoint in [routing.defaultGatewayIPv4, routing.httpProxyServer, routing.httpsProxyServer, routing.socksProxyServer] {
            if let matched = matchingSavedHost(for: endpoint) {
                return .remote(matched.id)
            }
        }

        // 2. Persisted RemoteNetworkBridge link (when not superseded by a different live system gateway/proxy)
        if let link = remoteBridge.activeLink {
            let linkStillConsistent: Bool
            switch link.mode {
            case .gateway:
                linkStillConsistent = routing.defaultGatewayIPv4 == nil
                    || routing.defaultGatewayIPv4?.caseInsensitiveCompare(link.remoteIP) == .orderedSame
            case .httpProxy:
                linkStillConsistent = (routing.httpProxyServer == nil && routing.httpsProxyServer == nil && routing.defaultGatewayIPv4 == nil)
                    || routing.httpProxyServer?.caseInsensitiveCompare(link.remoteIP) == .orderedSame
                    || routing.httpsProxyServer?.caseInsensitiveCompare(link.remoteIP) == .orderedSame
            case .socks5:
                linkStillConsistent = (routing.socksProxyServer == nil && routing.defaultGatewayIPv4 == nil)
                    || routing.socksProxyServer?.caseInsensitiveCompare(link.remoteIP) == .orderedSame
            }
            if linkStillConsistent,
               let matched = savedHosts.first(where: {
                   $0.id == link.remoteHostId || $0.host.caseInsensitiveCompare(link.remoteIP) == .orderedSame
               }) {
                return .remote(matched.id)
            }
        }

        return .local
    }

    /// Automatically switches `selectedDevice` to whichever device is actively in use when launching or opening the window.
    func syncSelectedDeviceOnWindowOpen() {
        let target = resolveActiveDeviceInUse()
        selectDevice(target, userInitiated: false)
    }

    func syncRemoteMirrors() {
        guard isViewingRemote else { return }
        remoteSession.syncFromClient()
    }

    // MARK: - Remote Network Bridge (Mutually Exclusive with Local Core)

    func connectRemoteAsHTTPProxy(port: Int? = nil) {
        guard let host = activeRemoteHost else { return }
        guard !isLocalCoreActive else {
            alertText = "本机核心正在运行，请先停止本机核心后再将本机 HTTP 代理切换至远程设备。"
            return
        }
        let targetPort = port ?? remoteClient.remoteFullState?.profile.httpPort ?? remoteClient.remoteStatus?.mixedPort ?? profile.mixedPort
        Task { @MainActor [weak self] in
            guard let self else { return }
            let ok = await self.remoteBridge.connectAsHTTPProxy(
                host: host,
                port: targetPort,
                preferredBSDInterface: self.localPrimaryLANInterface?.bsdName
            )
            if ok, let fb = self.remoteBridge.feedback {
                self.showFeedback(fb)
            } else if let err = self.remoteBridge.lastError {
                self.alertText = err
            }
            self.objectWillChange.send()
        }
    }

    func connectRemoteAsGateway() {
        guard let host = activeRemoteHost else { return }
        guard !isLocalCoreActive else {
            alertText = "本机核心正在运行，请先停止本机核心后再将本机网关切换至远程设备。"
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let ok = await self.remoteBridge.connectAsGateway(
                host: host,
                preferredBSDInterface: self.localPrimaryLANInterface?.bsdName
            )
            if ok, let fb = self.remoteBridge.feedback {
                self.showFeedback(fb)
            } else if let err = self.remoteBridge.lastError {
                self.alertText = err
            }
            self.objectWillChange.send()
        }
    }

    func disconnectRemoteBridge() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let ok = await self.remoteBridge.disconnectAndRestore()
            if ok, let fb = self.remoteBridge.feedback {
                self.showFeedback(fb)
            } else if let err = self.remoteBridge.lastError {
                self.alertText = err
            }
            self.objectWillChange.send()
        }
    }

    // MARK: - Delegated Device Actions

    func refreshGatewayDevices() { activeSession.refreshGatewayDevices() }
    func refreshInterfaces() { localSession.refreshInterfaces() }
    func refreshIPForwardingStatus() { localSession.refreshIPForwardingStatus() }

    func updateLocalProfileFromRemote(_ updated: RoutingProfile) {
        localSession.updateLocalProfileFromRemote(updated)
    }

    func setTunEnabled(_ enabled: Bool) { activeSession.setTunEnabled(enabled) }
    func setLocalTunEnabled(_ enabled: Bool) { localSession.setTunEnabled(enabled) }
    func setGatewayModeEnabled(_ enabled: Bool) { activeSession.setGatewayModeEnabled(enabled) }
    func setLocalGatewayModeEnabled(_ enabled: Bool) { localSession.setGatewayModeEnabled(enabled) }

    func fetchSubscriptionNodes(_ sub: ProxySubscription) { activeSession.fetchSubscriptionNodes(sub) }
    func fetchLocalSubscriptionNodes(_ sub: ProxySubscription) { localSession.fetchSubscriptionNodes(sub) }
    func fetchAllSubscriptionNodes() { activeSession.fetchAllSubscriptionNodes() }
    func fetchAllLocalSubscriptionNodes() { localSession.fetchAllSubscriptionNodes() }

    func refreshAllHostModules() { activeSession.refreshAllHostModules() }
    func refreshAllLocalHostModules() { localSession.refreshAllHostModules() }
    func refreshHostModule(id: UUID) { activeSession.refreshHostModule(id: id) }
    func refreshLocalHostModule(id: UUID) { localSession.refreshHostModule(id: id) }

    func refreshResolvedBinary() { localSession.refreshResolvedBinary() }
    func refreshLaunchAtLoginStatus() { localSession.refreshLaunchAtLoginStatus() }
    func setLaunchAtLogin(_ enabled: Bool) { activeSession.setLaunchAtLogin(enabled) }
    func setLocalLaunchAtLogin(_ enabled: Bool) { localSession.setLaunchAtLogin(enabled) }
    func setAutoStartCoreOnLaunch(_ enabled: Bool) { activeSession.setAutoStartCoreOnLaunch(enabled) }
    func setLocalAutoStartCoreOnLaunch(_ enabled: Bool) { localSession.setAutoStartCoreOnLaunch(enabled) }
    func setSystemKeepAliveEnabled(_ enabled: Bool) { activeSession.setSystemKeepAliveEnabled(enabled) }
    func setLocalSystemKeepAliveEnabled(_ enabled: Bool) { localSession.setSystemKeepAliveEnabled(enabled) }
    func setControllerPort(_ port: Int) { activeSession.setControllerPort(port) }
    func setLocalControllerPort(_ port: Int) { localSession.setControllerPort(port) }

    func openLoginItemsSettings() { LaunchAtLoginManager.openSystemSettingsLoginItems() }

    @discardableResult
    func reattachRunningCoreIfNeeded() async -> Bool {
        await localSession.reattachRunningCoreIfNeeded()
    }

    var shouldConfirmCoreOnQuit: Bool { engine.isRunning || engine.isBusy }
    func prepareForQuit(stopCore: Bool) { localSession.prepareForQuit(stopCore: stopCore) }

    func refreshTunPermissionStatus() { localSession.refreshTunPermissionStatus() }
    func authorizeTun() { localSession.authorizeTun() }
    func revokeTunAuthorization() { localSession.revokeTunAuthorization() }

    func refreshKillSwitchStatus() { localSession.refreshKillSwitchStatus() }
    func setKillSwitchEnabled(_ enabled: Bool) { activeSession.setKillSwitchEnabled(enabled) }
    func setLocalKillSwitchEnabled(_ enabled: Bool) { localSession.setKillSwitchEnabled(enabled) }
    func setKillSwitchAllowLAN(_ allow: Bool) { activeSession.setKillSwitchAllowLAN(allow) }
    func setLocalKillSwitchAllowLAN(_ allow: Bool) { localSession.setKillSwitchAllowLAN(allow) }
    func setKillSwitchPersistOnBoot(_ persist: Bool) { activeSession.setKillSwitchPersistOnBoot(persist) }
    func setLocalKillSwitchPersistOnBoot(_ persist: Bool) { localSession.setKillSwitchPersistOnBoot(persist) }

    func resetToBundledCore() { localSession.resetToBundledCore() }
    func checkForCoreUpdate() { activeSession.checkForCoreUpdate() }
    func checkForLocalCoreUpdate() { localSession.checkForCoreUpdate() }
    func installCoreUpdate() { activeSession.installCoreUpdate() }
    func installLocalCoreUpdate() { localSession.installCoreUpdate() }

    func validate() { activeSession.validate() }
    func validateLocal() { localSession.validate() }
    func start() { activeSession.start() }
    func startLocal() { localSession.start() }
    func hotReload() { activeSession.hotReload() }
    func hotReloadLocal() { localSession.hotReload() }
    func hotReloadLocalFromRemote() async -> RemoteActionResult { await localSession.hotReloadFromRemote() }
    func stop() { activeSession.stop() }
    func stopLocal() { localSession.stop() }
    func clearActiveLog() { activeSession.clearLog() }

    func refreshGroups() { activeSession.refreshGroups() }
    func selectNode(group: String, node: String) { activeSession.selectNode(group: group, node: node) }
    func selectLocalNode(group: String, node: String) { localSession.selectNode(group: group, node: node) }
    func testGroupDelay(group: String) { activeSession.testGroupDelay(group: group) }
    func testLocalGroupDelay(group: String) { localSession.testGroupDelay(group: group) }
    func diagnoseTargetHops(targetName: String) { activeSession.diagnoseTargetHops(targetName: targetName) }
    func diagnoseAllActiveHops() { activeSession.diagnoseAllActiveHops() }
    func clearOutboundErrors() { activeSession.clearOutboundErrors() }

    func openTopology(focusingTarget targetKey: String? = nil) {
        if let targetKey {
            selectedTopologyTargetKey = targetKey
        }
        selectedSection = .topology
    }

    func buildTopologySnapshot() -> TopologySnapshot {
        let upInterfaces = Set(activeInterfaces.filter(\.isUpWithAddress).map(\.bsdName))
        var labels: [String: String] = [:]
        for info in activeInterfaces {
            labels[info.bsdName] = info.shortLabel
        }
        return TopologySnapshotBuilder.build(
            profile: profile,
            isCoreRunning: isCoreRunning,
            activeInterfaceNames: upInterfaces,
            interfaceLabels: labels,
            groupStatuses: activeLiveProxyStore.healthSnapshots,
            tracker: activeConnectionMonitor.tracker,
            dnsRecords: activeConnectionMonitor.dnsLogs,
            outboundErrorTracker: activeConnectionMonitor.outboundErrorTracker,
            ruleIndex: ruleMatchDisplayIndex
        )
    }
    func updateOnlineRuleProviders() { activeSession.updateOnlineRuleProviders() }
    func updateLocalOnlineRuleProviders() { localSession.updateOnlineRuleProviders() }
    func updateGeoResources() { activeSession.updateGeoResources() }
    func updateLocalGeoResources() { localSession.updateGeoResources() }
    func closeMonitoredConnection(id: String) { activeSession.closeMonitoredConnection(id: id) }
    func closeAllMonitoredConnections() { activeSession.closeAllMonitoredConnections() }
    func flushDNSCache(includeFakeIP: Bool = false) { activeSession.flushDNSCache(includeFakeIP: includeFakeIP) }
    func clearDNSLogsAndCache(includeFakeIP: Bool = false) { activeSession.clearDNSLogsAndCache(includeFakeIP: includeFakeIP) }

    // MARK: - Interface & Target Preview Helpers

    func interfaceDisplayLabel(for bsdName: String?) -> String {
        guard let bsd = bsdName?.trimmingCharacters(in: .whitespacesAndNewlines), !bsd.isEmpty else {
            return "系统默认网卡"
        }
        if let info = activeInterfaces.first(where: { $0.bsdName == bsd }) {
            return info.shortLabel
        }
        return bsd
    }

    struct TargetChainPreview {
        let steps: [String]
        let isDirect: Bool
        let aliasStepCount: Int
    }

    func targetChainPreview(for target: NetworkTarget) -> TargetChainPreview {
        switch target.mode {
        case .direct:
            return TargetChainPreview(
                steps: ["直连", interfaceDisplayLabel(for: target.interfaceName)],
                isDirect: true,
                aliasStepCount: 0
            )
        case .proxy:
            var chain: [String] = []
            if let exit = profile.nodeGroup(id: target.exitGroupID) {
                chain.append(exit.name)
            } else {
                chain.append("未选出口节点组")
            }
            if let relayID = target.relayGroupID {
                if let relay = profile.nodeGroup(id: relayID) {
                    chain.append(relay.name)
                } else {
                    chain.append("无效链式组")
                }
            }
            chain.append(interfaceDisplayLabel(for: target.interfaceName))
            return TargetChainPreview(steps: chain, isDirect: false, aliasStepCount: 0)
        case .alias:
            guard let firstID = target.targetID else {
                return TargetChainPreview(steps: ["未选择指向目标"], isDirect: false, aliasStepCount: 1)
            }
            var visited = Set<UUID>([target.id])
            var aliasSteps: [String] = []
            var currentID: UUID? = firstID
            while let nextID = currentID {
                guard let next = profile.target(id: nextID) else {
                    aliasSteps.append("目标已删除")
                    return TargetChainPreview(steps: aliasSteps, isDirect: false, aliasStepCount: aliasSteps.count)
                }
                if !visited.insert(next.id).inserted {
                    aliasSteps.append("循环引用")
                    return TargetChainPreview(steps: aliasSteps, isDirect: false, aliasStepCount: aliasSteps.count)
                }
                aliasSteps.append("指向 \(next.name)")
                if next.mode != .alias {
                    let leafPreview = targetChainPreview(for: next)
                    return TargetChainPreview(
                        steps: aliasSteps + leafPreview.steps,
                        isDirect: leafPreview.isDirect,
                        aliasStepCount: aliasSteps.count
                    )
                }
                currentID = next.targetID
            }
            aliasSteps.append("未选择指向目标")
            return TargetChainPreview(steps: aliasSteps, isDirect: false, aliasStepCount: aliasSteps.count)
        }
    }

    func targetSummaryChain(for target: NetworkTarget) -> [String] {
        targetChainPreview(for: target).steps
    }

    // MARK: - Quick Profile Mutations

    func removeRelay(fromTargetID id: UUID) {
        guard let name = profile.removeRelay(fromTargetID: id) else { return }
        showFeedback("已移除「\(name)」的链式代理")
    }

    func setAliasTarget(id: UUID, targetID: UUID?) {
        guard let result = profile.setAliasTarget(id: id, targetID: targetID) else { return }
        if let targetName = result.targetName {
            showFeedback("已将「\(result.sourceName)」切换指向「\(targetName)」")
        } else {
            showFeedback("已清空「\(result.sourceName)」的目标指向")
        }
    }

    func deleteSubscription(id: UUID) {
        let removedURL = profile.deleteSubscription(id: id)
        subscriptionStore.removeSubscription(
            id: id,
            removedURL: removedURL,
            remainingURLs: profile.subscriptions.map(\.url),
            in: activeProfileDirectory
        )
    }

    func nodes(forSubscriptionID id: UUID?) -> [SubscriptionNode] {
        activeSubscriptionStore.nodes(forSubscriptionID: id)
    }

    func matchedNodes(for group: NodeGroup) -> [SubscriptionNode]? {
        activeSubscriptionStore.matchedNodes(for: group)
    }

    func deleteHostModule(id: UUID) { profile.hostModules.removeAll { $0.id == id } }
    func deleteNodeGroup(id: UUID) { profile.deleteNodeGroup(id: id) }
    func deleteTarget(id: UUID) { profile.deleteTarget(id: id) }
    func deleteCustomDNSEntry(id: UUID) { profile.deleteCustomDNSEntry(id: id) }
    func upsertCustomDNSEntry(_ entry: CustomDNSEntry) { profile.upsertCustomDNSEntry(entry) }

    func fixSwappedCustomDNSHosts() {
        let fixedCount = profile.fixSwappedCustomDNSHosts()
        guard fixedCount > 0 else { return }
        showFeedback("已纠正 \(fixedCount) 条反序 Host 规则，请点击「热重载生效」应用")
    }

    func importCustomDNSEntries(_ entries: [CustomDNSEntry]) {
        let result = profile.importCustomDNSEntries(entries)
        guard result.added > 0 || result.updated > 0 else { return }
        if result.updated > 0 && result.added > 0 {
            showFeedback("已导入 \(result.added) 条并更新 \(result.updated) 条自定义 DNS")
        } else if result.updated > 0 {
            showFeedback("已更新 \(result.updated) 条自定义 DNS")
        } else {
            showFeedback("已导入 \(result.added) 条自定义 DNS")
        }
    }

    // MARK: - Clipboard Helpers

    func copyText(_ text: String, label: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showFeedback("已复制\(label)")
    }

    func copyProxyAddress() {
        let label = isViewingRemote ? "远程代理地址 \(localProxyAddress)" : "本机代理地址 \(localProxyAddress)"
        copyText(localProxyAddress, label: label)
    }

    func copyShellExport() {
        let host = activeRemoteHost?.host ?? "127.0.0.1"
        let http = "http://\(host):\(profile.httpPort ?? profile.mixedPort)"
        let socks = "socks5://\(host):\(profile.socksPort ?? profile.mixedPort)"
        let cmd = "export https_proxy=\(http) http_proxy=\(http) all_proxy=\(socks)"
        copyText(cmd, label: "终端代理命令")
    }

    func copyGatewaySetup(for info: NetworkInterfaceInfo) {
        guard let ip = info.ipv4Address else { return }
        var lines = [
            "网关 / 路由器：\(ip)",
            "DNS 服务器：\(ip)",
        ]
        if let mask = info.ipv4Netmask {
            lines.append("子网掩码：\(mask)")
        }
        copyText(lines.joined(separator: "\n"), label: "局域网网关配置（\(ip)）")
    }

    // MARK: - Profile Import / Export & Directory Picker

    func importProfile() {
        let panel = NSOpenPanel()
        panel.title = "打开 RouteWeaver 方案"
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let limit = 2 << 20
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            guard data.count <= limit else {
                alertText = "方案文件超过 2 MB，无法打开。"
                return
            }
            profile = try RoutingProfile.decodeOrMigrate(from: data)
            showFeedback("已打开方案「\(url.lastPathComponent)」")
        } catch {
            alertText = "无法读取 RouteWeaver 方案；请检查文件格式。"
        }
    }

    func saveProfile() {
        let panel = NSSavePanel()
        panel.title = "保存 RouteWeaver 方案"
        panel.message = "保留完整订阅地址，可能包含访问令牌。请存到自己有权访问的目录。"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "routeweaver-profile.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try ProfileStore.writePrivateFile(encoder.encode(profile), to: url, tempName: "routeweaver-profile.json")
            showFeedback("已保存方案")
        } catch {
            alertText = error.localizedDescription
        }
    }

    func chooseProfileDirectory() {
        guard !editingLocked else { return }
        let panel = NSOpenPanel()
        panel.title = "选择配置保存目录"
        panel.message = "可选择 iCloud Drive 等同步目录，软件会自动将 profile.json 保存到该目录。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = activeProfileDirectory
        guard panel.runModal() == .OK, let rawURL = panel.url else { return }

        let targetDir = rawURL.standardizedFileURL
        guard targetDir != activeProfileDirectory.standardizedFileURL else { return }

        if ProfileStore.profileExists(in: targetDir) {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "目标目录中已存在配置文件"
            alert.informativeText = "「\(targetDir.path)」中已存在 \(ProfileStore.fileName)。请选择加载该目录中的配置，或用当前软件中的配置覆盖它。"
            alert.addButton(withTitle: "加载已有配置")
            alert.addButton(withTitle: "用当前配置覆盖")
            alert.addButton(withTitle: "取消")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                do {
                    let loaded = try ProfileStore.readProfile(from: targetDir)
                    localSession.applyProfileDirectory(targetDir)
                    localSession.applyLoadedProfileWithoutAutosave(loaded)
                    subscriptionStore.loadCache(in: targetDir)
                    showFeedback("已切换配置目录并加载已有配置")
                } catch {
                    alertText = "无法读取目标目录中的 \(ProfileStore.fileName)：\(error.localizedDescription)"
                }
            case .alertSecondButtonReturn:
                saveCurrentProfileAndSwitchDirectory(to: targetDir)
            default:
                return
            }
        } else {
            saveCurrentProfileAndSwitchDirectory(to: targetDir)
        }
    }

    func resetProfileDirectory() {
        guard !editingLocked, isUsingCustomProfileDirectory else { return }
        let oldDir = activeProfileDirectory
        let defaultDir = ProfileStore().defaultDirectory
        do {
            try ProfileStore.writeProfile(profile, to: defaultDir, enforcePrivateDirectoryPermissions: true)
            subscriptionStore.migrateCache(urls: profile.subscriptions.map(\.url), from: oldDir, to: defaultDir)
            localSession.cancelAutoSave()
            localSession.applyProfileDirectory(nil)
            showFeedback("已恢复默认配置目录并保存当前配置")
        } catch {
            alertText = "无法写入默认配置目录：\(error.localizedDescription)"
        }
    }

    func reloadProfileFromDisk() {
        guard !editingLocked else { return }
        localSession.cancelAutoSave()
        guard ProfileStore.profileExists(in: activeProfileDirectory) else {
            alertText = "当前配置目录中尚无 \(ProfileStore.fileName)。"
            return
        }
        do {
            let loaded = try ProfileStore.readProfile(from: activeProfileDirectory)
            localSession.applyLoadedProfileWithoutAutosave(loaded)
            showFeedback("已从配置目录重新加载")
        } catch {
            alertText = "无法读取配置：\(error.localizedDescription)"
        }
    }

    func revealProfileDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: activeProfileDirectory.path) {
            try? fm.createDirectory(at: activeProfileDirectory, withIntermediateDirectories: true)
        }
        let target = fm.fileExists(atPath: savedProfileURL.path) ? savedProfileURL : activeProfileDirectory
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    private func saveCurrentProfileAndSwitchDirectory(to directory: URL) {
        let oldDir = activeProfileDirectory
        let isDefault = directory.standardizedFileURL == ProfileStore().defaultDirectory.standardizedFileURL
        do {
            try ProfileStore.writeProfile(profile, to: directory, enforcePrivateDirectoryPermissions: isDefault)
            subscriptionStore.migrateCache(urls: profile.subscriptions.map(\.url), from: oldDir, to: directory)
            localSession.cancelAutoSave()
            localSession.applyProfileDirectory(isDefault ? nil : directory)
            showFeedback("已切换配置目录并保存当前配置")
        } catch {
            alertText = "无法写入所选配置目录：\(error.localizedDescription)"
        }
    }

    func exportConfig() {
        let config: Data
        do {
            config = try MihomoConfig.render(
                profile,
                interfaceDNS: NetworkEnvironment.interfaceDNSServers(includeIPv6: profile.ipv6Enabled)
            )
        } catch {
            alertText = error.localizedDescription
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出 Mihomo 配置"
        panel.message = "文件包含订阅地址，可能带有访问令牌，请妥善保管。"
        panel.nameFieldStringValue = "routeweaver.yaml"
        if let yaml = UTType(filenameExtension: "yaml") { panel.allowedContentTypes = [yaml] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProfileStore.writePrivateFile(config, to: url, tempName: "routeweaver.yaml")
            showFeedback("已导出 Mihomo 配置")
        } catch {
            alertText = error.localizedDescription
        }
    }

    func showFeedback(_ message: String) {
        feedback = message
        feedbackTask?.cancel()
        guard !message.isEmpty else { return }
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.feedback == message {
                self.feedback = ""
            }
        }
    }
}
