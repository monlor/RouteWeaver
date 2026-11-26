import Combine
import Foundation
import Network
import RoutingCore

@MainActor
protocol DeviceSessionDelegate: AnyObject {
    func deviceSession(_ session: any DeviceSession, didEmitFeedback message: String)
    func deviceSession(_ session: any DeviceSession, didEmitAlert message: String)
    func deviceSessionDidChangeState(_ session: any DeviceSession)
    func deviceSession(_ session: any DeviceSession, didSyncProfile profile: RoutingProfile)
    func deviceSessionDidLoseRemoteHost(_ session: any DeviceSession)
    func deviceSessionDidReattachLocalCore(_ session: LocalDeviceSession)
}

extension DeviceSessionDelegate {
    func deviceSessionDidReattachLocalCore(_ session: LocalDeviceSession) {}
}

@MainActor
protocol DeviceSession: AnyObject {
    var isRemote: Bool { get }
    var deviceDisplayName: String { get }

    var liveProxyStore: LiveProxyStore { get }
    var connectionMonitor: ConnectionMonitorService { get }
    var subscriptionStore: SubscriptionStore { get }
    var logStore: EngineLogStore { get }
    var gatewayDeviceStore: GatewayDeviceStore { get }

    var isCoreRunning: Bool { get }
    var isCoreBusy: Bool { get }
    var corePhaseTitle: String { get }
    var isTunActive: Bool { get }
    var isGatewayActive: Bool { get }
    var isLaunchdManaged: Bool { get }
    var coreLastError: String? { get }
    var hasPendingHotReload: Bool { get }
    var isHotReloading: Bool { get }
    var configValidationError: String? { get }

    var killSwitchActive: Bool { get }
    var killSwitchAllowLAN: Bool { get }
    var killSwitchPersistOnBoot: Bool { get }
    var isIPForwardingEnabled: Bool { get }

    var controllerPort: Int { get }
    var autoStartCoreOnLaunch: Bool { get }
    var systemKeepAliveEnabled: Bool { get }
    var launchAtLoginEnabled: Bool { get }
    var tunPermissionReady: Bool { get }
    var tunPermissionTitle: String { get }

    var interfaces: [NetworkInterfaceInfo] { get }
    var mixedPort: Int { get }
    var proxyHost: String { get }
    var canStart: Bool { get }
    func readinessItems(for profile: RoutingProfile) -> [ReadinessItem]

    var currentProfile: RoutingProfile { get }
    func handleProfileEdited(_ newProfile: RoutingProfile)

    func start()
    func stop()
    func hotReload()
    func validate()
    func clearLog()

    func setTunEnabled(_ enabled: Bool)
    func setGatewayModeEnabled(_ enabled: Bool)
    func setLaunchAtLogin(_ enabled: Bool)
    func setAutoStartCoreOnLaunch(_ enabled: Bool)
    func setSystemKeepAliveEnabled(_ enabled: Bool)
    func setControllerPort(_ port: Int)
    func setKillSwitchEnabled(_ enabled: Bool)
    func setKillSwitchAllowLAN(_ allow: Bool)
    func setKillSwitchPersistOnBoot(_ persist: Bool)

    func checkForCoreUpdate()
    func installCoreUpdate()
    func updateGeoResources()

    func refreshGroups()
    func selectNode(group: String, node: String)
    func testGroupDelay(group: String)
    func diagnoseTargetHops(targetName: String)
    func diagnoseAllActiveHops()
    func clearOutboundErrors()
    func updateOnlineRuleProviders()

    func fetchSubscriptionNodes(_ sub: ProxySubscription)
    func fetchAllSubscriptionNodes()
    func refreshHostModule(id: UUID)
    func refreshAllHostModules()

    func closeMonitoredConnection(id: String)
    func closeAllMonitoredConnections()
    func flushDNSCache(includeFakeIP: Bool)
    func clearDNSLogsAndCache(includeFakeIP: Bool)

    func refreshGatewayDevices()
}

extension DeviceSession {
    var editingLocked: Bool { isCoreRunning || isCoreBusy }
    var hotReloadEditingLocked: Bool { isCoreBusy || isHotReloading }
    var activeLANInterfaces: [NetworkInterfaceInfo] {
        interfaces.filter { $0.isUpWithAddress && $0.ipv4Address != nil }
    }
    var lanIPAddresses: [String] {
        activeLANInterfaces.compactMap(\.ipv4Address)
    }
    var primaryLANInterface: NetworkInterfaceInfo? {
        activeLANInterfaces.first
    }
    var primaryLANAddress: String? {
        lanIPAddresses.first
    }
    var proxyAddress: String {
        "\(proxyHost):\(mixedPort)"
    }
}

// MARK: - LocalDeviceSession

@MainActor
final class LocalDeviceSession: DeviceSession {
    weak var delegate: (any DeviceSessionDelegate)?

    let engine: EngineController
    let liveProxyStore: LiveProxyStore
    let connectionMonitor: ConnectionMonitorService
    let subscriptionStore: SubscriptionStore
    let gatewayDeviceStore: GatewayDeviceStore
    let coreBinaryStore: CoreBinaryStore

    var logStore: EngineLogStore { engine.logStore }
    var isRemote: Bool { false }
    var deviceDisplayName: String { "本机" }

    /// Authoritative profile for this local Mac (used by local core and RemoteServerService).
    private(set) var localProfile: RoutingProfile = .starter()
    private(set) var runningProfileSnapshot: RoutingProfile?

    private(set) var controllerPort: Int = 19090 {
        didSet {
            recomputeConfigValidation()
            saveSettings()
            delegate?.deviceSessionDidChangeState(self)
        }
    }
    private(set) var customProfileDirectory: URL? {
        didSet {
            saveSettings()
            delegate?.deviceSessionDidChangeState(self)
        }
    }
    private(set) var autoStartCoreOnLaunch: Bool = false {
        didSet {
            saveSettings()
            delegate?.deviceSessionDidChangeState(self)
        }
    }
    private(set) var systemKeepAliveEnabled: Bool = true {
        didSet {
            saveSettings()
            delegate?.deviceSessionDidChangeState(self)
        }
    }
    private(set) var launchAtLoginStatus: LaunchAtLoginStatus = .disabled {
        didSet { delegate?.deviceSessionDidChangeState(self) }
    }
    private(set) var interfaces: [NetworkInterfaceInfo] = [] {
        didSet { delegate?.deviceSessionDidChangeState(self) }
    }
    private(set) var hasPendingHotReload = false {
        didSet {
            if hasPendingHotReload != oldValue {
                delegate?.deviceSessionDidChangeState(self)
            }
        }
    }
    private(set) var isHotReloading = false {
        didSet {
            if isHotReloading != oldValue {
                delegate?.deviceSessionDidChangeState(self)
            }
        }
    }
    private(set) var updatingGeoResources = false {
        didSet {
            if updatingGeoResources != oldValue {
                delegate?.deviceSessionDidChangeState(self)
            }
        }
    }
    private(set) var geoUpdateMessage: String? {
        didSet {
            if geoUpdateMessage != oldValue {
                delegate?.deviceSessionDidChangeState(self)
            }
        }
    }
    private(set) var tunPermissionStatus: TunPermissionStatus = .notAuthorized {
        didSet {
            if tunPermissionStatus != oldValue {
                delegate?.deviceSessionDidChangeState(self)
            }
        }
    }
    private(set) var isAuthorizingTun = false {
        didSet {
            if isAuthorizingTun != oldValue {
                delegate?.deviceSessionDidChangeState(self)
            }
        }
    }
    private(set) var killSwitchActive = false {
        didSet {
            if killSwitchActive != oldValue {
                delegate?.deviceSessionDidChangeState(self)
            }
        }
    }
    private(set) var killSwitchAllowLAN: Bool = true {
        didSet {
            saveSettings()
            delegate?.deviceSessionDidChangeState(self)
        }
    }
    private(set) var killSwitchPersistOnBoot: Bool = false {
        didSet {
            saveSettings()
            delegate?.deviceSessionDidChangeState(self)
        }
    }
    private(set) var isUpdatingKillSwitch = false {
        didSet {
            if isUpdatingKillSwitch != oldValue {
                delegate?.deviceSessionDidChangeState(self)
            }
        }
    }
    private(set) var isIPForwardingEnabled = NetworkEnvironment.isIPForwardingEnabled() {
        didSet {
            if isIPForwardingEnabled != oldValue {
                delegate?.deviceSessionDidChangeState(self)
            }
        }
    }
    private(set) var configValidationError: String? {
        didSet {
            if configValidationError != oldValue {
                delegate?.deviceSessionDidChangeState(self)
            }
        }
    }

    private let userDefaults: UserDefaults
    private let activeRemoteBridgeDescriptionProvider: () -> String?
    private var cancellables = Set<AnyCancellable>()
    private var autoSaveTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "local.routeweaver.path-monitor", qos: .utility)
    private var isRestoring = false

    private enum DefaultsKey {
        static let controllerPort = "RouteWeaver.controllerPort"
        static let profileDirectoryPath = "RouteWeaver.profileDirectoryPath"
        static let autoStartCoreOnLaunch = "RouteWeaver.autoStartCoreOnLaunch"
        static let systemKeepAliveEnabled = "RouteWeaver.systemKeepAliveEnabled"
        static let killSwitchAllowLAN = "RouteWeaver.killSwitchAllowLAN"
        static let killSwitchPersistOnBoot = "RouteWeaver.killSwitchPersistOnBoot"
    }

    init(
        engine: EngineController? = nil,
        liveProxyStore: LiveProxyStore? = nil,
        connectionMonitor: ConnectionMonitorService? = nil,
        subscriptionStore: SubscriptionStore? = nil,
        gatewayDeviceStore: GatewayDeviceStore? = nil,
        coreBinaryStore: CoreBinaryStore? = nil,
        userDefaults: UserDefaults = .standard,
        bootstrapOnInit: Bool = true,
        activeRemoteBridgeDescriptionProvider: @escaping () -> String? = { nil }
    ) {
        self.engine = engine ?? EngineController()
        self.liveProxyStore = liveProxyStore ?? LiveProxyStore()
        self.connectionMonitor = connectionMonitor ?? ConnectionMonitorService()
        self.subscriptionStore = subscriptionStore ?? SubscriptionStore()
        self.gatewayDeviceStore = gatewayDeviceStore ?? GatewayDeviceStore()
        self.coreBinaryStore = coreBinaryStore ?? CoreBinaryStore()
        self.userDefaults = userDefaults
        self.activeRemoteBridgeDescriptionProvider = activeRemoteBridgeDescriptionProvider

        if bootstrapOnInit {
            restoreState()
            recomputeConfigValidation()
            refreshInterfaces()
            startInterfaceMonitoring()
            refreshResolvedBinary()
            refreshLaunchAtLoginStatus()
            refreshKillSwitchStatus()
            self.subscriptionStore.loadCache(in: activeProfileDirectory)
            self.subscriptionStore.hydrateMissingCacheEntries(
                for: localProfile,
                in: activeProfileDirectory,
                mihomoWorkDirectories: self.engine.candidateProviderWorkDirectories
            )
            self.connectionMonitor.configureHistory(directory: activeProfileDirectory)
            startInitialCoreBootstrap()
        } else {
            recomputeConfigValidation()
        }

        bindObservables()
    }

    deinit {
        pathMonitor?.cancel()
    }

    private func bindObservables() {
        connectionMonitor.onTargetAnomalyDetected = { [weak self] targetName in
            guard let self else { return }
            self.liveProxyStore.autoVerifyTargetIfNeeded(
                targetName: targetName,
                isEngineRunning: { [weak self] in self?.engine.isRunning ?? false }
            )
        }

        engine.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                self.delegate?.deviceSessionDidChangeState(self)
            }
            .store(in: &cancellables)

        coreBinaryStore.$binary
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshTunPermissionStatus()
                self.delegate?.deviceSessionDidChangeState(self)
            }
            .store(in: &cancellables)

        coreBinaryStore.$version
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.delegate?.deviceSessionDidChangeState(self)
            }
            .store(in: &cancellables)

        gatewayDeviceStore.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                self.delegate?.deviceSessionDidChangeState(self)
            }
            .store(in: &cancellables)

        engine.$phase
            .removeDuplicates()
            .sink { [weak self] newPhase in
                guard let self else { return }
                if newPhase == .running {
                    self.refreshIPForwardingStatus()
                    self.liveProxyStore.startPolling { [weak self] in self?.engine.isRunning ?? false }
                    if let active = self.liveProxyStore.controller {
                        self.connectionMonitor.start(controller: active)
                    }
                } else if newPhase == .idle {
                    self.refreshIPForwardingStatus()
                    self.connectionMonitor.stop()
                    self.liveProxyStore.reset()
                    self.runningProfileSnapshot = nil
                    self.hasPendingHotReload = false
                    self.isHotReloading = false
                    self.coreBinaryStore.handleEngineStopped()
                }
            }
            .store(in: &cancellables)

        engine.$lastCoreRestartToken
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.engine.isRunning, let active = self.liveProxyStore.controller else { return }
                self.connectionMonitor.stop()
                self.connectionMonitor.start(controller: active)
                self.liveProxyStore.startPolling { [weak self] in self?.engine.isRunning ?? false }
                self.delegate?.deviceSession(self, didEmitFeedback: "Mihomo 核心异常退出，已由系统级 launchd 自动拉起")
            }
            .store(in: &cancellables)
    }

    // MARK: - DeviceSession Properties

    var currentProfile: RoutingProfile { localProfile }
    var binary: URL? { coreBinaryStore.binary }
    var isCoreRunning: Bool { engine.isRunning }
    var isCoreBusy: Bool { engine.isBusy }
    var corePhaseTitle: String { engine.phase.title }
    var isTunActive: Bool { engine.isTunActive }
    var isGatewayActive: Bool { engine.isGatewayActive }
    var isLaunchdManaged: Bool { engine.isLaunchdManaged }
    var coreLastError: String? { engine.lastError }
    var launchAtLoginEnabled: Bool { launchAtLoginStatus.isEnabled }
    var tunPermissionReady: Bool { tunPermissionStatus.canLaunchTun }
    var tunPermissionTitle: String { tunPermissionStatus.title }
    var proxyHost: String { "127.0.0.1" }

    var mixedPort: Int {
        runningProfileSnapshot?.mixedPort ?? localProfile.mixedPort
    }

    var canStart: Bool {
        let tunReady = !localProfile.effectiveTunEnabled || tunPermissionStatus.canLaunchTun
        let bridgeInactive = activeRemoteBridgeDescriptionProvider() == nil
        return !engine.isRunning && !engine.isBusy && !isAuthorizingTun && binary != nil && configValidationError == nil && tunReady && bridgeInactive
    }

    func readinessItems(for profile: RoutingProfile) -> [ReadinessItem] {
        let hasBinary = binary.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
        let binaryDetail: String
        if hasBinary {
            let ver = coreBinaryStore.version.map { " (\($0))" } ?? ""
            binaryDetail = "\(coreBinaryStore.source.title)\(ver)"
        } else {
            binaryDetail = "尚未安装 Mihomo 内核，可在设置页一键下载"
        }
        let binaryItem = ReadinessItem(
            id: "binary",
            title: "Mihomo 内核",
            detail: binaryDetail,
            isReady: hasBinary,
            targetSection: .settings
        )

        let active = Set(interfaces.filter(\.isUpWithAddress).map(\.bsdName))
        let missing = profile.requiredInterfaces.filter { !active.contains($0) }.sorted()
        let required = profile.requiredInterfaces
        let interfaceReady = missing.isEmpty
        let interfaceDetail: String
        if required.isEmpty {
            interfaceDetail = "使用系统默认网卡（未强制绑定）"
        } else if !missing.isEmpty {
            interfaceDetail = "绑定网卡暂不可用或无 IP：\(missing.joined(separator: "、"))（不会阻止启动，就绪后自动生效）"
        } else {
            interfaceDetail = "已绑定：\(required.sorted().joined(separator: " / "))"
        }
        let interfaceItem = ReadinessItem(
            id: "interfaces",
            title: "网卡状态",
            detail: interfaceDetail,
            isReady: interfaceReady,
            targetSection: .targets
        )

        let configErr = configValidationError
        let configReady = configErr == nil
        let targetSection: SidebarSection = profile.subscriptions.isEmpty ? .subscriptions : .targets
        let configItem = ReadinessItem(
            id: "config",
            title: "路由与订阅配置",
            detail: configErr ?? "配置有效，共 \(profile.ruleGroups.filter(\.isEnabled).count) 个启用规则组",
            isReady: configReady,
            targetSection: targetSection
        )

        var items = [binaryItem, interfaceItem, configItem]
        if profile.effectiveTunEnabled {
            items.append(
                ReadinessItem(
                    id: "tun",
                    title: profile.gatewayModeEnabled ? "局域网网关 / TUN 权限" : "TUN 透明代理权限",
                    detail: tunPermissionStatus.detail,
                    isReady: tunPermissionStatus.canLaunchTun,
                    targetSection: .settings
                )
            )
        }
        if profile.gatewayModeEnabled && lanIPAddresses.isEmpty {
            items.append(
                ReadinessItem(
                    id: "gateway-lan",
                    title: "局域网网关接口",
                    detail: "未检测到活跃局域网 IPv4 地址，局域网其他设备将无法接入本机网关。",
                    isReady: false,
                    targetSection: .settings
                )
            )
        }
        return items
    }

    // MARK: - Profile Storage & Dirty Tracking

    private var profileStore: ProfileStore {
        ProfileStore(customDirectory: customProfileDirectory)
    }

    var activeProfileDirectory: URL { profileStore.activeDirectory }
    var savedProfileURL: URL { profileStore.activeProfileURL }
    var isUsingCustomProfileDirectory: Bool { profileStore.isUsingCustomDirectory }

    func handleProfileEdited(_ newProfile: RoutingProfile) {
        localProfile = newProfile
        recomputeConfigValidation()
        scheduleAutoSave()
        if engine.isRunning, let baseline = runningProfileSnapshot {
            hasPendingHotReload = (localProfile != baseline)
        }
    }

    func updateLocalProfileFromRemote(_ updated: RoutingProfile) {
        handleProfileEdited(updated)
        delegate?.deviceSession(self, didSyncProfile: updated)
    }

    func applyLoadedProfileWithoutAutosave(_ newProfile: RoutingProfile) {
        autoSaveTask?.cancel()
        isRestoring = true
        localProfile = newProfile
        recomputeConfigValidation()
        if engine.isRunning, let baseline = runningProfileSnapshot {
            hasPendingHotReload = (localProfile != baseline)
        }
        isRestoring = false
        subscriptionStore.hydrateMissingCacheEntries(
            for: newProfile,
            in: activeProfileDirectory,
            mihomoWorkDirectories: engine.candidateProviderWorkDirectories
        )
        delegate?.deviceSession(self, didSyncProfile: newProfile)
    }

    func applyProfileDirectory(_ directory: URL?) {
        let defaultDir = ProfileStore().defaultDirectory
        if let directory, directory.standardizedFileURL != defaultDir.standardizedFileURL {
            customProfileDirectory = directory.standardizedFileURL
        } else {
            customProfileDirectory = nil
        }
        connectionMonitor.configureHistory(directory: activeProfileDirectory)
    }

    func cancelAutoSave() {
        autoSaveTask?.cancel()
    }

    private func recomputeConfigValidation() {
        do {
            _ = try MihomoConfig.renderDetailed(localProfile, controllerPort: controllerPort, secret: "validation-probe")
            configValidationError = nil
        } catch {
            configValidationError = error.localizedDescription
        }
    }

    // MARK: - Environment & Interface Inspection

    func refreshInterfaces() {
        let updated = NetworkEnvironment.detailedInterfaces()
        if interfaces != updated {
            interfaces = updated
        }
        connectionMonitor.localIPs = Set(lanIPAddresses)
        refreshIPForwardingStatus()
    }

    func refreshIPForwardingStatus() {
        let enabled = NetworkEnvironment.isIPForwardingEnabled()
        if isIPForwardingEnabled != enabled {
            isIPForwardingEnabled = enabled
        }
    }

    private func startInterfaceMonitoring() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshInterfaces()
            }
        }
        monitor.start(queue: pathMonitorQueue)
        pathMonitor = monitor
    }

    func refreshGatewayDevices() {
        let localIPs = Set(lanIPAddresses)
        let records = connectionMonitor.tracker.allRecords
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.gatewayDeviceStore.refresh(connections: records, localIPs: localIPs)
        }
    }

    // MARK: - Mode & System Settings

    func setTunEnabled(_ enabled: Bool) {
        guard !editingLocked else { return }
        localProfile.setTunEnabled(enabled)
        recomputeConfigValidation()
        scheduleAutoSave()
        delegate?.deviceSession(self, didSyncProfile: localProfile)
    }

    func setGatewayModeEnabled(_ enabled: Bool) {
        guard !editingLocked else { return }
        localProfile.setGatewayModeEnabled(enabled)
        recomputeConfigValidation()
        scheduleAutoSave()
        delegate?.deviceSession(self, didSyncProfile: localProfile)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            launchAtLoginStatus = try LaunchAtLoginManager.setEnabled(enabled)
            if enabled && !autoStartCoreOnLaunch {
                autoStartCoreOnLaunch = true
            }
            if launchAtLoginStatus == .requiresApproval {
                delegate?.deviceSession(self, didEmitFeedback: "已注册开机自启，请在系统设置「登录项」中允许")
            } else {
                delegate?.deviceSession(self, didEmitFeedback: enabled ? "已开启开机自动启动" : "已关闭开机自动启动")
            }
        } catch {
            refreshLaunchAtLoginStatus()
            delegate?.deviceSession(self, didEmitAlert: "设置开机自动启动失败：\(error.localizedDescription)")
        }
    }

    func setAutoStartCoreOnLaunch(_ enabled: Bool) {
        autoStartCoreOnLaunch = enabled
    }

    func setSystemKeepAliveEnabled(_ enabled: Bool) {
        systemKeepAliveEnabled = enabled
    }

    func setControllerPort(_ port: Int) {
        guard (1024...65535).contains(port) else { return }
        controllerPort = port
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = LaunchAtLoginManager.currentStatus()
    }

    func refreshResolvedBinary() {
        coreBinaryStore.refresh()
        refreshTunPermissionStatus()
    }

    func refreshTunPermissionStatus() {
        tunPermissionStatus = TunHelperManager.status(for: binary)
    }

    func authorizeTun() {
        guard !isAuthorizingTun, !engine.isBusy else { return }
        isAuthorizingTun = true
        let currentBinary = binary
        let wasRunning = engine.isRunning
        Task { @MainActor in
            defer {
                isAuthorizingTun = false
                refreshResolvedBinary()
                refreshKillSwitchStatus()
            }
            do {
                // Perform atomic root installation FIRST while keeping any running core & Kill Switch alive,
                // so canceling the prompt or encountering an error never drops network connectivity.
                try await TunHelperManager.authorize(mihomoBinary: currentBinary)
                refreshResolvedBinary()

                if wasRunning && engine.isRunning {
                    delegate?.deviceSession(self, didEmitFeedback: "TUN 权限及免密自动更新已初始化，正在平滑重启核心…")
                    connectionMonitor.stop()
                    engine.stop()
                    let deadline = Date().addingTimeInterval(10)
                    while (engine.isRunning || engine.isBusy) && Date() < deadline {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    if !engine.isRunning && !engine.isBusy && canStart {
                        start()
                    }
                } else {
                    delegate?.deviceSession(self, didEmitFeedback: "TUN 权限及后续免密自动同步已初始化完成")
                }
            } catch TunAuthorizationError.cancelled {
                delegate?.deviceSession(self, didEmitFeedback: "已取消授权（当前核心运行状态未受影响）")
            } catch {
                delegate?.deviceSession(self, didEmitAlert: error.localizedDescription)
            }
        }
    }

    func revokeTunAuthorization() {
        guard !isAuthorizingTun, !editingLocked else { return }
        isAuthorizingTun = true
        Task { @MainActor in
            defer {
                isAuthorizingTun = false
                refreshTunPermissionStatus()
                refreshKillSwitchStatus()
            }
            do {
                try await TunHelperManager.revoke()
                killSwitchActive = false
                delegate?.deviceSession(self, didEmitFeedback: "已撤销 TUN 权限授权并清理断网保护规则")
            } catch TunAuthorizationError.cancelled {
                delegate?.deviceSession(self, didEmitFeedback: "已取消操作")
            } catch {
                delegate?.deviceSession(self, didEmitAlert: error.localizedDescription)
            }
        }
    }

    // MARK: - Kill Switch

    func refreshKillSwitchStatus() {
        Task { @MainActor [weak self] in
            let status = await KillSwitchManager.queryStatusAsync()
            guard let self else { return }
            self.killSwitchActive = status.isActive
            if status.isActive {
                self.isRestoring = true
                self.killSwitchAllowLAN = status.allowLAN
                self.killSwitchPersistOnBoot = status.persistOnBoot
                self.isRestoring = false
            }
        }
    }

    func setKillSwitchEnabled(_ enabled: Bool) {
        guard !isUpdatingKillSwitch else { return }
        if enabled && !tunPermissionStatus.canLaunchTun {
            delegate?.deviceSession(self, didEmitAlert: "开启断网保护前，请先在「TUN 透明代理模式」中完成管理员授权。")
            return
        }
        isUpdatingKillSwitch = true
        let allowLAN = killSwitchAllowLAN
        let persistOnBoot = killSwitchPersistOnBoot
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isUpdatingKillSwitch = false }
            do {
                let status = enabled
                    ? try await KillSwitchManager.enableAsync(allowLAN: allowLAN, persistOnBoot: persistOnBoot)
                    : try await KillSwitchManager.disableAsync()
                self.killSwitchActive = status.isActive
                if enabled {
                    self.delegate?.deviceSession(self, didEmitFeedback: "断网保护已开启：核心未启动或重启瞬间将自动阻断外网泄漏")
                } else {
                    self.delegate?.deviceSession(self, didEmitFeedback: "断网保护已关闭，已恢复正常联网")
                }
            } catch {
                self.refreshKillSwitchStatus()
                self.delegate?.deviceSession(self, didEmitAlert: error.localizedDescription)
            }
        }
    }

    func setKillSwitchAllowLAN(_ allow: Bool) {
        guard killSwitchAllowLAN != allow else { return }
        killSwitchAllowLAN = allow
        guard killSwitchActive, !isUpdatingKillSwitch else { return }
        applyLiveKillSwitchOptions(feedbackMessage: allow ? "断网保护已更新：放行局域网私有网段（仍拦截局域网 53 端口 DNS 泄漏）" : "断网保护已更新：已禁止局域网直连通信")
    }

    func setKillSwitchPersistOnBoot(_ persist: Bool) {
        guard killSwitchPersistOnBoot != persist else { return }
        killSwitchPersistOnBoot = persist
        guard killSwitchActive, !isUpdatingKillSwitch else { return }
        applyLiveKillSwitchOptions(feedbackMessage: persist ? "断网保护已设为开机自动生效" : "已取消断网保护开机自动生效")
    }

    private func applyLiveKillSwitchOptions(feedbackMessage: String) {
        isUpdatingKillSwitch = true
        let allowLAN = killSwitchAllowLAN
        let persistOnBoot = killSwitchPersistOnBoot
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isUpdatingKillSwitch = false }
            do {
                let status = try await KillSwitchManager.enableAsync(allowLAN: allowLAN, persistOnBoot: persistOnBoot)
                self.killSwitchActive = status.isActive
                self.delegate?.deviceSession(self, didEmitFeedback: feedbackMessage)
            } catch {
                self.refreshKillSwitchStatus()
                self.delegate?.deviceSession(self, didEmitAlert: error.localizedDescription)
            }
        }
    }

    // MARK: - Core Binary & Geo Resources

    func resetToBundledCore() {
        guard !editingLocked else { return }
        coreBinaryStore.resetToBundled { [weak self] in
            guard let self else { return }
            self.refreshTunPermissionStatus()
            self.delegate?.deviceSession(self, didEmitFeedback: "已恢复内置内核")
        }
    }

    func checkForCoreUpdate() {
        let proxyPort = engine.isRunning ? (runningProfileSnapshot?.mixedPort ?? localProfile.mixedPort) : nil
        coreBinaryStore.checkForUpdate(proxyPort: proxyPort)
    }

    func installCoreUpdate() {
        let proxyPort = engine.isRunning ? (runningProfileSnapshot?.mixedPort ?? localProfile.mixedPort) : nil
        coreBinaryStore.installUpdate(
            proxyPort: proxyPort,
            isEngineRunning: { [weak self] in self?.engine.isRunning ?? false },
            isTunDaemonRunning: { [weak self] in
                guard let self else { return false }
                return self.engine.isRunning && self.engine.isTunActive && self.engine.isLaunchdManaged
            },
            onInstalled: { [weak self] installedVersion in
                guard let self else { return }
                self.refreshTunPermissionStatus()
                self.delegate?.deviceSession(self, didEmitFeedback: "Mihomo 内核已更新至 \(installedVersion)")
            }
        )
    }

    func updateGeoResources() {
        guard !updatingGeoResources else { return }
        updatingGeoResources = true
        geoUpdateMessage = "正在安全下载并校验 Geo 数据库…"
        let proxyPort = engine.isRunning ? (runningProfileSnapshot?.mixedPort ?? localProfile.mixedPort) : nil
        let workDir = engine.mihomoWorkDirectory

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.updatingGeoResources = false }
            let results = await GeoResourceUpdater.updateAll(in: workDir, proxyPort: proxyPort)
            guard !results.isEmpty else {
                self.geoUpdateMessage = "未找到内置资源清单，请先通过构建脚本打包。"
                return
            }
            let updatedCount = results.filter { $0.outcome == .updated }.count
            let keptCount = results.filter {
                if case .keptExistingAfterFailure = $0.outcome { return true }
                return false
            }.count
            let restoredCount = results.filter {
                if case .restoredBundledAfterFailure = $0.outcome { return true }
                return false
            }.count

            if updatedCount == results.count {
                let suffix = self.engine.isRunning ? "（重启核心后生效）" : ""
                self.geoUpdateMessage = "已安全更新 \(updatedCount) 项 Geo 数据库\(suffix)。"
                self.delegate?.deviceSession(self, didEmitFeedback: "Geo 数据库已更新")
            } else if updatedCount > 0 {
                self.geoUpdateMessage = "已更新 \(updatedCount) 项，其余 \(keptCount + restoredCount) 项失败并保留原有可用版本。"
            } else if keptCount > 0 || restoredCount > 0 {
                self.geoUpdateMessage = "更新失败，已保留原有可用缓存（未覆盖）。"
            } else {
                self.geoUpdateMessage = "Geo 数据库更新失败，请检查网络或代理设置。"
            }
        }
    }

    // MARK: - Engine Lifecycle

    func validate() {
        guard let binary else { return }
        engine.clearError()
        do {
            let rendered = try MihomoConfig.renderDetailed(
                localProfile,
                interfaceDNS: NetworkEnvironment.interfaceDNSServers(includeIPv6: localProfile.ipv6Enabled)
            )
            engine.validate(config: rendered.data, binary: binary)
            delegate?.deviceSession(self, didEmitFeedback: "已开始校验配置…")
        } catch {
            delegate?.deviceSession(self, didEmitAlert: error.localizedDescription)
        }
    }

    func start() {
        guard !engine.isRunning, !engine.isBusy else { return }
        if let bridgeDescription = activeRemoteBridgeDescriptionProvider() {
            delegate?.deviceSession(
                self,
                didEmitAlert: "本机当前正在使用\(bridgeDescription)，不能同时启动本机核心。请先断开远程接入后再启动。"
            )
            return
        }
        guard let binary else { return }
        engine.clearError()
        do {
            let secret = UUID().uuidString + UUID().uuidString
            let rendered = try MihomoConfig.renderDetailed(
                localProfile,
                controllerPort: controllerPort,
                secret: secret,
                interfaceDNS: NetworkEnvironment.interfaceDNSServers(includeIPv6: localProfile.ipv6Enabled)
            )
            let active = liveProxyStore.makeClient(
                port: controllerPort,
                secret: secret,
                trackedGroups: rendered.activeProxyGroupNames
            )
            liveProxyStore.activate(controller: active, trackedGroups: rendered.activeProxyGroupNames)
            runningProfileSnapshot = localProfile
            hasPendingHotReload = false
            let sessionContext = EngineSessionContext(
                controllerPort: controllerPort,
                secret: secret,
                trackedGroups: rendered.activeProxyGroupNames,
                runningProfile: localProfile
            )
            engine.start(
                config: rendered.data,
                binary: binary,
                interfaces: rendered.requiredInterfaces,
                useTun: rendered.tunEnabled,
                useGateway: rendered.gatewayModeEnabled,
                useSystemKeepAlive: systemKeepAliveEnabled,
                preloadResources: rendered.preloadResources,
                subscriptionCacheDirectory: activeProfileDirectory,
                sessionContext: sessionContext
            )
            if !engine.isBusy && !engine.isRunning {
                liveProxyStore.reset()
                runningProfileSnapshot = nil
            }
        } catch {
            delegate?.deviceSession(self, didEmitAlert: error.localizedDescription)
        }
    }

    func hotReload() {
        guard engine.isRunning, !isHotReloading else { return }
        _ = beginHotReloadTask(emitLocalUIAlerts: true)
    }

    func hotReloadFromRemote(maxWaitNanoseconds: UInt64 = 1_800_000_000) async -> RemoteActionResult {
        guard engine.isRunning else {
            return RemoteActionResult(ok: false, message: "本机核心尚未运行，无法热重载。")
        }
        guard !isHotReloading else {
            return RemoteActionResult(ok: true, message: "正在执行热重载，请稍候…")
        }
        guard let task = beginHotReloadTask(emitLocalUIAlerts: false) else {
            return RemoteActionResult(ok: false, message: "核心控制连接尚未就绪，请稍后重试。")
        }

        return await withTaskGroup(of: RemoteActionResult?.self) { group in
            group.addTask {
                await task.value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: maxWaitNanoseconds)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if let result = first {
                return result
            }
            return RemoteActionResult(ok: true, message: "正在预下载新增资源并热重载配置…")
        }
    }

    private func resolveActiveOrRecoveredController(for snapshot: RoutingProfile) -> (any MihomoControlClient)? {
        if let active = liveProxyStore.controller {
            return active
        }
        guard let creds = engine.authoritativeControlCredentials() else { return nil }
        let groups = (try? MihomoConfig.renderDetailed(
            snapshot,
            controllerPort: creds.port,
            secret: creds.secret,
            interfaceDNS: NetworkEnvironment.interfaceDNSServers(includeIPv6: snapshot.ipv6Enabled)
        ).activeProxyGroupNames) ?? []
        let recovered = liveProxyStore.makeClient(port: creds.port, secret: creds.secret, trackedGroups: groups)
        liveProxyStore.activate(controller: recovered, trackedGroups: groups)
        connectionMonitor.start(controller: recovered)
        return recovered
    }

    private func beginHotReloadTask(emitLocalUIAlerts: Bool) -> Task<RemoteActionResult, Never>? {
        let snapshot = localProfile
        guard let active = resolveActiveOrRecoveredController(for: snapshot) else {
            if emitLocalUIAlerts {
                delegate?.deviceSession(self, didEmitAlert: "热重载失败：核心控制连接尚未就绪。")
            }
            return nil
        }

        let cacheDir = activeProfileDirectory
        let interfaceDNS = NetworkEnvironment.interfaceDNSServers(includeIPv6: snapshot.ipv6Enabled)
        let rendered: RenderedMihomoConfig
        do {
            rendered = try MihomoConfig.renderDetailed(
                snapshot,
                controllerPort: active.port,
                secret: active.secret,
                interfaceDNS: interfaceDNS
            )
        } catch {
            let msg = "热重载失败：\(error.localizedDescription)"
            if emitLocalUIAlerts {
                delegate?.deviceSession(self, didEmitAlert: msg)
            } else {
                engine.logStore.appendMemoryOnly("远程\(msg)\n")
            }
            return Task { RemoteActionResult(ok: false, message: msg) }
        }

        isHotReloading = true
        if emitLocalUIAlerts {
            delegate?.deviceSession(self, didEmitFeedback: "正在热重载配置…")
        }

        return Task { @MainActor [weak self] in
            guard let self else {
                return RemoteActionResult(ok: false, message: "应用状态已释放。")
            }
            defer { self.isHotReloading = false }

            await self.engine.prepareResourcesForHotReload(
                rendered.preloadResources,
                subscriptionCacheDirectory: cacheDir
            )
            guard self.engine.isRunning, self.liveProxyStore.controller?.sessionID == active.sessionID else {
                return RemoteActionResult(ok: false, message: "核心状态已变更，热重载已取消。")
            }

            do {
                try await active.reloadConfig(payload: rendered.data)
                self.finalizeSuccessfulHotReload(
                    port: active.port,
                    secret: active.secret,
                    rendered: rendered,
                    snapshot: snapshot,
                    rebindMonitor: false
                )
                self.delegate?.deviceSession(self, didEmitFeedback: "配置已热重载生效")
                return RemoteActionResult(ok: true, message: "配置已热重载生效。")
            } catch LocalController.ControllerError.http(401) {
                if let healedResult = await self.attemptCredentialHealedHotReload(
                    failedController: active,
                    snapshot: snapshot,
                    interfaceDNS: interfaceDNS
                ) {
                    switch healedResult {
                    case .success:
                        self.delegate?.deviceSession(self, didEmitFeedback: "配置已热重载生效")
                        return RemoteActionResult(ok: true, message: "配置已热重载生效。")
                    case .failure(let retryError):
                        return self.handleHotReloadFailure(retryError, emitLocalUIAlerts: emitLocalUIAlerts)
                    }
                }
                return self.handleHotReloadFailure(LocalController.ControllerError.http(401), emitLocalUIAlerts: emitLocalUIAlerts)
            } catch {
                return self.handleHotReloadFailure(error, emitLocalUIAlerts: emitLocalUIAlerts)
            }
        }
    }

    private func attemptCredentialHealedHotReload(
        failedController: any MihomoControlClient,
        snapshot: RoutingProfile,
        interfaceDNS: [String: [String]]
    ) async -> Result<Void, Error>? {
        guard let creds = engine.authoritativeControlCredentials(),
              creds.port != failedController.port || creds.secret != failedController.secret else {
            return nil
        }
        do {
            let healedRendered = try MihomoConfig.renderDetailed(
                snapshot,
                controllerPort: creds.port,
                secret: creds.secret,
                interfaceDNS: interfaceDNS
            )
            let probeClient = liveProxyStore.makeClient(
                port: creds.port,
                secret: creds.secret,
                trackedGroups: healedRendered.activeProxyGroupNames
            )
            try await probeClient.reloadConfig(payload: healedRendered.data)
            finalizeSuccessfulHotReload(
                port: creds.port,
                secret: creds.secret,
                rendered: healedRendered,
                snapshot: snapshot,
                rebindMonitor: true
            )
            engine.logStore.appendMemoryOnly("已自动同步控制接口认证凭据并完成热重载。\n")
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func finalizeSuccessfulHotReload(
        port: Int,
        secret: String,
        rendered: RenderedMihomoConfig,
        snapshot: RoutingProfile,
        rebindMonitor: Bool
    ) {
        let updatedController = liveProxyStore.makeClient(
            port: port,
            secret: secret,
            trackedGroups: rendered.activeProxyGroupNames
        )
        liveProxyStore.replaceController(updatedController, trackedGroups: rendered.activeProxyGroupNames)
        if rebindMonitor {
            connectionMonitor.start(controller: updatedController)
        }
        runningProfileSnapshot = snapshot
        hasPendingHotReload = (localProfile != snapshot)
        engine.persistHotReloadedConfig(rendered.data)
        engine.updateRuntimeSession(
            controllerPort: port,
            secret: secret,
            trackedGroups: rendered.activeProxyGroupNames,
            runningProfile: snapshot
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.liveProxyStore.reloadGroups(updatedController) { [weak self] in self?.engine.isRunning ?? false }
            self.liveProxyStore.startPolling { [weak self] in self?.engine.isRunning ?? false }
        }
    }

    private func handleHotReloadFailure(_ error: Error, emitLocalUIAlerts: Bool) -> RemoteActionResult {
        let msg = "热重载失败：\(error.localizedDescription)"
        if emitLocalUIAlerts {
            delegate?.deviceSession(self, didEmitAlert: msg)
        } else {
            engine.logStore.appendMemoryOnly("远程\(msg)\n")
        }
        return RemoteActionResult(ok: false, message: msg)
    }

    func stop() {
        engine.stop()
    }

    func clearLog() {
        engine.clearLog()
    }

    func markRunningProfileSnapshotForTesting(_ snapshot: RoutingProfile?) {
        runningProfileSnapshot = snapshot
        if engine.isRunning, let baseline = snapshot {
            hasPendingHotReload = (localProfile != baseline)
        } else {
            hasPendingHotReload = false
        }
    }

    private func startInitialCoreBootstrap() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if await TunHelperManager.autoSyncOnLaunchIfPossible(mihomoBinary: self.binary) {
                self.refreshResolvedBinary()
                self.engine.logStore.appendMemoryOnly("启动自检：已自动静默同步新版 TUN 辅助组件与内核。\n")
            }
            let attached = await self.reattachRunningCoreIfNeeded()
            if attached {
                self.delegate?.deviceSessionDidReattachLocalCore(self)
            } else {
                self.scheduleAutoStartCoreIfNeeded()
            }
        }
    }

    @discardableResult
    func reattachRunningCoreIfNeeded() async -> Bool {
        guard let reattached = await engine.reattachRunningCore(using: liveProxyStore.clientFactory) else {
            return false
        }
        liveProxyStore.activate(controller: reattached.client, trackedGroups: reattached.session.trackedGroups)
        runningProfileSnapshot = reattached.session.runningProfile ?? localProfile
        hasPendingHotReload = (localProfile != runningProfileSnapshot)
        connectionMonitor.start(controller: reattached.client)
        connectionMonitor.seedOutboundErrorsFromLogText(engine.logStore.text)
        liveProxyStore.startPolling { [weak self] in self?.engine.isRunning ?? false }
        delegate?.deviceSession(self, didEmitFeedback: "已接管后台运行中的 Mihomo 核心")
        return true
    }

    private func scheduleAutoStartCoreIfNeeded() {
        guard autoStartCoreOnLaunch else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            for _ in 0..<10 {
                guard let self, self.autoStartCoreOnLaunch else { return }
                if self.engine.isRunning || self.engine.isBusy { return }
                if await self.reattachRunningCoreIfNeeded() {
                    self.delegate?.deviceSessionDidReattachLocalCore(self)
                    return
                }
                self.refreshInterfaces()
                self.refreshTunPermissionStatus()
                if self.canStart {
                    self.start()
                    self.delegate?.deviceSession(self, didEmitFeedback: "已自动启动 Mihomo 核心")
                    return
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func prepareForQuit(stopCore: Bool) {
        connectionMonitor.flushHistory()
        if stopCore {
            connectionMonitor.stop()
            engine.terminateForAppExit()
        } else {
            connectionMonitor.stop()
            engine.detachForAppExit()
        }
    }

    // MARK: - Live Proxy & Subscriptions & Connections

    func refreshGroups() {
        liveProxyStore.refreshGroups(
            isEngineRunning: { [weak self] in self?.engine.isRunning ?? false },
            onFeedback: { [weak self] msg in
                guard let self else { return }
                self.delegate?.deviceSession(self, didEmitFeedback: msg)
            },
            onError: { [weak self] err in
                guard let self else { return }
                self.delegate?.deviceSession(self, didEmitAlert: err)
            }
        )
    }

    func selectNode(group: String, node: String) {
        liveProxyStore.selectNode(
            group: group,
            node: node,
            isEngineRunning: { [weak self] in self?.engine.isRunning ?? false },
            onFeedback: { [weak self] msg in
                guard let self else { return }
                self.delegate?.deviceSession(self, didEmitFeedback: msg)
            },
            onError: { [weak self] err in
                guard let self else { return }
                self.delegate?.deviceSession(self, didEmitAlert: err)
            }
        )
    }

    func testGroupDelay(group: String) {
        liveProxyStore.testGroupDelay(
            group: group,
            isEngineRunning: { [weak self] in self?.engine.isRunning ?? false },
            onFeedback: { [weak self] msg in
                guard let self else { return }
                self.delegate?.deviceSession(self, didEmitFeedback: msg)
            }
        )
    }

    func diagnoseTargetHops(targetName: String) {
        liveProxyStore.diagnoseTargetHops(
            targetName: targetName,
            isEngineRunning: { [weak self] in self?.engine.isRunning ?? false },
            onFeedback: { [weak self] msg in
                guard let self else { return }
                self.delegate?.deviceSession(self, didEmitFeedback: msg)
            }
        )
    }

    func diagnoseAllActiveHops() {
        liveProxyStore.diagnoseAllActiveGroups(
            isEngineRunning: { [weak self] in self?.engine.isRunning ?? false },
            onFeedback: { [weak self] msg in
                guard let self else { return }
                self.delegate?.deviceSession(self, didEmitFeedback: msg)
            }
        )
    }

    func clearOutboundErrors() {
        connectionMonitor.clearOutboundErrors()
        delegate?.deviceSession(self, didEmitFeedback: "已清空链路异常记录")
    }

    func updateOnlineRuleProviders() {
        liveProxyStore.updateOnlineRuleProviders(
            isEngineRunning: { [weak self] in self?.engine.isRunning ?? false },
            onFeedback: { [weak self] msg in
                guard let self else { return }
                self.delegate?.deviceSession(self, didEmitFeedback: msg)
            },
            onError: { [weak self] err in
                guard let self else { return }
                self.delegate?.deviceSession(self, didEmitAlert: err)
            }
        )
    }

    func fetchSubscriptionNodes(_ sub: ProxySubscription) {
        let fallbackProxyPort = engine.isRunning ? (runningProfileSnapshot?.mixedPort ?? localProfile.mixedPort) : nil
        subscriptionStore.fetchSubscriptionNodes(
            sub,
            fallbackProxyPort: fallbackProxyPort,
            cacheDirectory: activeProfileDirectory
        ) { [weak self] message in
            guard let self else { return }
            self.delegate?.deviceSession(self, didEmitFeedback: message)
        }
    }

    func fetchAllSubscriptionNodes() {
        for sub in localProfile.subscriptions {
            fetchSubscriptionNodes(sub)
        }
    }

    func refreshHostModule(id: UUID) {
        guard let idx = localProfile.hostModules.firstIndex(where: { $0.id == id }) else { return }
        let rawURL = localProfile.hostModules[idx].url
        subscriptionStore.refreshHostModule(
            id: id,
            rawURL: rawURL,
            onParsed: { [weak self] parsed, url in
                guard let self, let currentIdx = self.localProfile.hostModules.firstIndex(where: { $0.id == id }) else { return }
                self.localProfile.hostModules[currentIdx].cachedHosts = parsed.hosts
                self.localProfile.hostModules[currentIdx].lastUpdated = Date()
                if self.localProfile.hostModules[currentIdx].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let parsedName = parsed.name {
                    self.localProfile.hostModules[currentIdx].name = parsedName
                }
                let displayName = self.localProfile.hostModules[currentIdx].name.isEmpty ? url.lastPathComponent : self.localProfile.hostModules[currentIdx].name
                self.recomputeConfigValidation()
                self.scheduleAutoSave()
                if self.engine.isRunning, let baseline = self.runningProfileSnapshot {
                    self.hasPendingHotReload = (self.localProfile != baseline)
                }
                self.delegate?.deviceSession(self, didSyncProfile: self.localProfile)
                self.delegate?.deviceSession(self, didEmitFeedback: "已更新「\(displayName)」：解析出 \(parsed.hosts.count) 条有效 Host 映射")
            },
            onError: { [weak self] message in
                guard let self else { return }
                self.delegate?.deviceSession(self, didEmitAlert: message)
            }
        )
    }

    func refreshAllHostModules() {
        for module in localProfile.hostModules where !subscriptionStore.updatingHostModuleIDs.contains(module.id) {
            refreshHostModule(id: module.id)
        }
    }

    func closeMonitoredConnection(id: String) {
        guard engine.isRunning else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.connectionMonitor.closeConnection(id: id)
                self.delegate?.deviceSession(self, didEmitFeedback: "已断开连接")
            } catch {
                self.delegate?.deviceSession(self, didEmitAlert: error.localizedDescription)
            }
        }
    }

    func closeAllMonitoredConnections() {
        guard engine.isRunning else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.connectionMonitor.closeAllConnections()
                self.delegate?.deviceSession(self, didEmitFeedback: "已断开全部活跃连接")
            } catch {
                self.delegate?.deviceSession(self, didEmitAlert: error.localizedDescription)
            }
        }
    }

    func flushDNSCache(includeFakeIP: Bool) {
        guard engine.isRunning else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.connectionMonitor.flushDNSCache(includeFakeIP: includeFakeIP)
                self.delegate?.deviceSession(
                    self,
                    didEmitFeedback: includeFakeIP ? "已清空内核 DNS 与 Fake-IP 缓存" : "已清空内核 DNS 缓存"
                )
            } catch {
                self.delegate?.deviceSession(self, didEmitAlert: "清空 DNS 缓存失败：\(error.localizedDescription)")
            }
        }
    }

    func clearDNSLogsAndCache(includeFakeIP: Bool) {
        connectionMonitor.clearDNSLogs()
        guard engine.isRunning else {
            delegate?.deviceSession(self, didEmitFeedback: "已清空 DNS 解析日志")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.connectionMonitor.flushDNSCache(includeFakeIP: includeFakeIP)
                self.delegate?.deviceSession(
                    self,
                    didEmitFeedback: includeFakeIP ? "已清空 DNS 日志、DNS 缓存与 Fake-IP 缓存" : "已清空 DNS 日志与内核 DNS 缓存"
                )
            } catch {
                self.delegate?.deviceSession(self, didEmitAlert: "日志已清空，但清空内核 DNS 缓存失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Persistence

    private func restoreState() {
        isRestoring = true
        defer { isRestoring = false }

        let savedPort = userDefaults.integer(forKey: DefaultsKey.controllerPort)
        if (1024...65535).contains(savedPort) {
            controllerPort = savedPort
        }
        if let profileDirPath = userDefaults.string(forKey: DefaultsKey.profileDirectoryPath),
           !profileDirPath.isEmpty {
            applyProfileDirectory(URL(fileURLWithPath: profileDirPath, isDirectory: true))
        }
        autoStartCoreOnLaunch = userDefaults.bool(forKey: DefaultsKey.autoStartCoreOnLaunch)
        if userDefaults.object(forKey: DefaultsKey.systemKeepAliveEnabled) != nil {
            systemKeepAliveEnabled = userDefaults.bool(forKey: DefaultsKey.systemKeepAliveEnabled)
        } else {
            systemKeepAliveEnabled = true
        }
        if userDefaults.object(forKey: DefaultsKey.killSwitchAllowLAN) != nil {
            killSwitchAllowLAN = userDefaults.bool(forKey: DefaultsKey.killSwitchAllowLAN)
        } else {
            killSwitchAllowLAN = true
        }
        killSwitchPersistOnBoot = userDefaults.bool(forKey: DefaultsKey.killSwitchPersistOnBoot)

        if ProfileStore.profileExists(in: activeProfileDirectory),
           let decoded = try? ProfileStore.readProfile(from: activeProfileDirectory) {
            localProfile = decoded
        }
    }

    private func saveSettings() {
        guard !isRestoring else { return }
        userDefaults.set(controllerPort, forKey: DefaultsKey.controllerPort)
        if let customProfileDirectory, isUsingCustomProfileDirectory {
            userDefaults.set(customProfileDirectory.path, forKey: DefaultsKey.profileDirectoryPath)
        } else {
            userDefaults.removeObject(forKey: DefaultsKey.profileDirectoryPath)
        }
        userDefaults.set(autoStartCoreOnLaunch, forKey: DefaultsKey.autoStartCoreOnLaunch)
        userDefaults.set(systemKeepAliveEnabled, forKey: DefaultsKey.systemKeepAliveEnabled)
        userDefaults.set(killSwitchAllowLAN, forKey: DefaultsKey.killSwitchAllowLAN)
        userDefaults.set(killSwitchPersistOnBoot, forKey: DefaultsKey.killSwitchPersistOnBoot)
    }

    private func scheduleAutoSave() {
        guard !isRestoring else { return }
        autoSaveTask?.cancel()
        let snapshot = localProfile
        let targetDir = activeProfileDirectory
        let isDefault = !isUsingCustomProfileDirectory
        autoSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            _ = self
            do {
                try ProfileStore.writeProfile(snapshot, to: targetDir, enforcePrivateDirectoryPermissions: isDefault)
            } catch {
                // Silent failure for background autosave.
            }
        }
    }
}

// MARK: - RemoteDeviceSession

@MainActor
final class RemoteDeviceSession: DeviceSession {
    weak var delegate: (any DeviceSessionDelegate)?

    let remoteClient: RemoteClientService
    let liveProxyStore: LiveProxyStore
    let connectionMonitor: ConnectionMonitorService
    let subscriptionStore: SubscriptionStore
    let logStore: EngineLogStore
    let gatewayDeviceStore: GatewayDeviceStore

    private(set) var currentProfile: RoutingProfile = .starter()
    private var localEditGeneration: UInt64 = 0
    private var hasUnflushedLocalEdits = false
    private var profileSaveTask: Task<Void, Never>?
    private var lastAppStateSignature: RemoteAppStateSignature?
    private var cancellables = Set<AnyCancellable>()

    /// Low-frequency AppState-visible fields; high-frequency telemetry (connections, DNS logs, speeds, logs)
    /// updates the isolated stores directly without triggering full-window AppState.objectWillChange.
    private struct RemoteAppStateSignature: Equatable {
        let hostId: String?
        let hostName: String?
        let hostAddress: String?
        let phaseTitle: String?
        let isRunning: Bool
        let isBusy: Bool
        let isTunActive: Bool
        let isGatewayActive: Bool
        let isLaunchdManaged: Bool
        let statusLastError: String?
        let clientLastError: String?
        let hasPendingHotReload: Bool
        let configValidationError: String?
        let killSwitchActive: Bool?
        let isIPForwardingEnabled: Bool
        let mixedPort: Int?
        let canStart: Bool
        let systemSettings: RemoteSystemSettingsDTO?
        let interfaces: [RemoteInterfaceDTO]
        let gatewayDevicesSignature: [String]
    }

    init(
        remoteClient: RemoteClientService,
        liveProxyStore: LiveProxyStore? = nil,
        connectionMonitor: ConnectionMonitorService? = nil,
        subscriptionStore: SubscriptionStore? = nil,
        logStore: EngineLogStore? = nil,
        gatewayDeviceStore: GatewayDeviceStore? = nil
    ) {
        self.remoteClient = remoteClient
        self.liveProxyStore = liveProxyStore ?? LiveProxyStore()
        self.connectionMonitor = connectionMonitor ?? ConnectionMonitorService()
        self.subscriptionStore = subscriptionStore ?? SubscriptionStore()
        self.logStore = logStore ?? EngineLogStore()
        self.gatewayDeviceStore = gatewayDeviceStore ?? GatewayDeviceStore()

        bindRemoteClient()
    }

    private func bindRemoteClient() {
        remoteClient.$snapshotSequence
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.remoteClient.activeHostId != nil else { return }
                self.syncFromClient()
            }
            .store(in: &cancellables)

        remoteClient.$savedHosts
            .dropFirst()
            .sink { [weak self] hosts in
                guard let self else { return }
                if let activeId = self.remoteClient.activeHostId,
                   !hosts.contains(where: { $0.id == activeId }) {
                    self.delegate?.deviceSessionDidLoseRemoteHost(self)
                    return
                }
                self.delegate?.deviceSessionDidChangeState(self)
            }
            .store(in: &cancellables)

        gatewayDeviceStore.$includeARPOnly
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.remoteClient.activeHostId != nil else { return }
                self.delegate?.deviceSessionDidChangeState(self)
            }
            .store(in: &cancellables)
    }

    // MARK: - Activation

    func activate(hostId: String) {
        profileSaveTask?.cancel()
        profileSaveTask = nil
        hasUnflushedLocalEdits = false
        lastAppStateSignature = nil
        resetMirrors()
        remoteClient.activeHostId = hostId
        syncFromClient()
    }

    func deactivate() {
        profileSaveTask?.cancel()
        profileSaveTask = nil
        hasUnflushedLocalEdits = false
        lastAppStateSignature = nil
        remoteClient.activeHostId = nil
        resetMirrors()
    }

    private func resetMirrors() {
        liveProxyStore.reset()
        connectionMonitor.resetRemoteData()
        subscriptionStore.resetRemoteCache()
        logStore.clear()
        gatewayDeviceStore.replaceDevices([])
    }

    func syncFromClient() {
        liveProxyStore.applyRemoteGroups(remoteClient.remoteProxies)
        connectionMonitor.applyRemoteData(
            status: remoteClient.remoteStatus,
            connections: remoteClient.remoteConnections,
            dnsLogs: remoteClient.remoteDNSLogs,
            trafficHistory: remoteClient.remoteFullState?.trafficHistory,
            trafficRanking: remoteClient.remoteFullState?.trafficRanking,
            rawLogs: remoteClient.remoteLogs,
            outboundErrors: remoteClient.remoteOutboundErrors,
            targetSessionTotals: remoteClient.remoteTargetSessionTotals,
            targetConnectionCounts: remoteClient.remoteTargetConnectionCounts,
            targetSpeeds: remoteClient.remoteTargetSpeeds,
            ruleSessionTotals: remoteClient.remoteRuleSessionTotals
        )
        gatewayDeviceStore.replaceDevices(remoteClient.remoteGatewayDevices)
        logStore.replaceText(remoteClient.remoteLogs)

        if let full = remoteClient.remoteFullState {
            subscriptionStore.applyRemoteUsages(
                full.subscriptionUsages,
                subscriptions: full.profile.subscriptions,
                fallbackCacheDirectory: ProfileStore().defaultDirectory,
                fallbackProxyEndpoint: currentFallbackProxyEndpoint(for: full.profile),
                enableNetworkFallbackFetch: true
            )
            if !hasUnflushedLocalEdits && currentProfile != full.profile {
                currentProfile = full.profile
                delegate?.deviceSession(self, didSyncProfile: full.profile)
            }
        }

        let signature = makeSignature()
        if signature != lastAppStateSignature {
            lastAppStateSignature = signature
            delegate?.deviceSessionDidChangeState(self)
        }
    }

    private func makeSignature() -> RemoteAppStateSignature {
        let host = remoteClient.activeHost
        let status = remoteClient.remoteStatus
        let full = remoteClient.remoteFullState
        return RemoteAppStateSignature(
            hostId: host?.id,
            hostName: host?.hostName,
            hostAddress: host?.host,
            phaseTitle: status?.phaseTitle,
            isRunning: status?.isRunning ?? false,
            isBusy: status?.isBusy ?? false,
            isTunActive: status?.isTunActive ?? false,
            isGatewayActive: status?.isGatewayActive ?? false,
            isLaunchdManaged: status?.isLaunchdManaged ?? false,
            statusLastError: status?.lastError,
            clientLastError: remoteClient.lastError,
            hasPendingHotReload: status?.hasPendingHotReload ?? false,
            configValidationError: status?.configValidationError,
            killSwitchActive: full?.systemSettings.killSwitchActive ?? status?.killSwitchActive,
            isIPForwardingEnabled: status?.isIPForwardingEnabled ?? false,
            mixedPort: status?.mixedPort,
            canStart: status?.canStart ?? false,
            systemSettings: full?.systemSettings,
            interfaces: full?.interfaces ?? [],
            gatewayDevicesSignature: remoteClient.remoteGatewayDevices.map { "\($0.id)|\($0.hostname ?? "")|\($0.activeConnectionCount)|\($0.totalConnectionCount)|\($0.macAddress ?? "")|\($0.interfaceName ?? "")" }
        )
    }

    // MARK: - DeviceSession Properties

    var isRemote: Bool { true }
    var deviceDisplayName: String { remoteClient.activeHost?.hostName ?? "远程设备" }
    var isCoreRunning: Bool { remoteClient.remoteStatus?.isRunning ?? false }
    var isCoreBusy: Bool { remoteClient.remoteStatus?.isBusy ?? false }
    var corePhaseTitle: String {
        if let title = remoteClient.remoteStatus?.phaseTitle {
            return title
        }
        return remoteClient.lastError != nil ? "连接失败" : "连接中…"
    }
    var isTunActive: Bool { remoteClient.remoteStatus?.isTunActive ?? false }
    var isGatewayActive: Bool { remoteClient.remoteStatus?.isGatewayActive ?? false }
    var isLaunchdManaged: Bool { remoteClient.remoteStatus?.isLaunchdManaged ?? false }
    var coreLastError: String? { remoteClient.remoteStatus?.lastError ?? remoteClient.lastError }
    var hasPendingHotReload: Bool { remoteClient.remoteStatus?.hasPendingHotReload ?? false }
    var isHotReloading: Bool { false }
    var configValidationError: String? { remoteClient.remoteStatus?.configValidationError }

    var killSwitchActive: Bool {
        remoteClient.remoteFullState?.systemSettings.killSwitchActive
            ?? remoteClient.remoteStatus?.killSwitchActive
            ?? false
    }
    var killSwitchAllowLAN: Bool {
        remoteClient.remoteFullState?.systemSettings.killSwitchAllowLAN ?? true
    }
    var killSwitchPersistOnBoot: Bool {
        remoteClient.remoteFullState?.systemSettings.killSwitchPersistOnBoot ?? false
    }
    var isIPForwardingEnabled: Bool {
        remoteClient.remoteStatus?.isIPForwardingEnabled ?? false
    }

    var controllerPort: Int {
        remoteClient.remoteFullState?.systemSettings.controllerPort ?? 19090
    }
    var autoStartCoreOnLaunch: Bool {
        remoteClient.remoteFullState?.systemSettings.autoStartCoreOnLaunch ?? false
    }
    var systemKeepAliveEnabled: Bool {
        remoteClient.remoteFullState?.systemSettings.systemKeepAliveEnabled ?? true
    }
    var launchAtLoginEnabled: Bool {
        remoteClient.remoteFullState?.systemSettings.launchAtLoginEnabled ?? false
    }
    var tunPermissionReady: Bool {
        remoteClient.remoteFullState?.systemSettings.tunPermissionReady ?? true
    }
    var tunPermissionTitle: String {
        remoteClient.remoteFullState?.systemSettings.tunPermissionTitle ?? "未知"
    }

    var interfaces: [NetworkInterfaceInfo] {
        (remoteClient.remoteFullState?.interfaces ?? []).map {
            NetworkInterfaceInfo(
                bsdName: $0.bsdName,
                displayName: $0.displayName,
                isUpWithAddress: $0.isUpWithAddress,
                ipv4Address: $0.ipv4Address,
                ipv4Netmask: $0.ipv4Netmask
            )
        }
    }

    var mixedPort: Int {
        remoteClient.remoteStatus?.mixedPort ?? currentProfile.mixedPort
    }

    var proxyHost: String {
        remoteClient.activeHost?.host ?? "127.0.0.1"
    }

    var canStart: Bool {
        remoteClient.remoteStatus?.canStart ?? false
    }

    func readinessItems(for profile: RoutingProfile) -> [ReadinessItem] {
        var items: [ReadinessItem] = []
        if let status = remoteClient.remoteStatus {
            if let err = status.configValidationError, !err.isEmpty {
                items.append(ReadinessItem(
                    id: "remote-config",
                    title: "远程配置校验",
                    detail: err,
                    isReady: false,
                    targetSection: .targets
                ))
            }
            if profile.effectiveTunEnabled && !tunPermissionReady {
                items.append(ReadinessItem(
                    id: "remote-tun",
                    title: "远程 TUN 权限",
                    detail: "需在远程设备本机完成 TUN 管理员授权",
                    isReady: false,
                    targetSection: .settings
                ))
            }
        }
        return items
    }

    // MARK: - Profile Editing (Revision / Edit-Generation Tracking)

    func handleProfileEdited(_ newProfile: RoutingProfile) {
        currentProfile = newProfile
        localEditGeneration &+= 1
        let editGen = localEditGeneration
        hasUnflushedLocalEdits = true
        profileSaveTask?.cancel()
        profileSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, let self, self.remoteClient.activeHostId != nil else { return }
            await self.remoteClient.saveProfile(newProfile)
            if self.localEditGeneration == editGen {
                self.hasUnflushedLocalEdits = false
            }
            self.emitRemoteActionResult(showAlertOnError: true)
        }
    }

    // MARK: - Actions

    func start() { runRemoteAction { await $0.startEngine() } }
    func stop() { runRemoteAction { await $0.stopEngine() } }

    func hotReload() {
        let shouldFlushProfile = hasUnflushedLocalEdits
        let pendingProfile = currentProfile
        let editGen = localEditGeneration
        if shouldFlushProfile {
            profileSaveTask?.cancel()
            profileSaveTask = nil
        }
        runRemoteAction { [weak self] client in
            if shouldFlushProfile {
                await client.saveProfile(pendingProfile)
                guard client.lastError == nil else { return }
                if let self, self.localEditGeneration == editGen {
                    self.hasUnflushedLocalEdits = false
                }
            }
            await client.hotReload()
        }
    }

    func validate() { runRemoteAction { await $0.validateConfig() } }
    func clearLog() { runRemoteAction(showAlertOnError: false) { await $0.clearLogs() } }

    func setTunEnabled(_ enabled: Bool) {
        guard !editingLocked else { return }
        runRemoteAction { await $0.updateMode(tunEnabled: enabled) }
    }

    func setGatewayModeEnabled(_ enabled: Bool) {
        guard !editingLocked else { return }
        runRemoteAction { await $0.updateMode(gatewayModeEnabled: enabled) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        runRemoteAction(showAlertOnError: false) {
            await $0.updateSystemSettings(RemoteSystemSettingsUpdateRequest(launchAtLoginEnabled: enabled))
        }
    }

    func setAutoStartCoreOnLaunch(_ enabled: Bool) {
        runRemoteAction(showAlertOnError: false) {
            await $0.updateSystemSettings(RemoteSystemSettingsUpdateRequest(autoStartCoreOnLaunch: enabled))
        }
    }

    func setSystemKeepAliveEnabled(_ enabled: Bool) {
        runRemoteAction(showAlertOnError: false) {
            await $0.updateSystemSettings(RemoteSystemSettingsUpdateRequest(systemKeepAliveEnabled: enabled))
        }
    }

    func setControllerPort(_ port: Int) {
        guard (1024...65535).contains(port) else { return }
        runRemoteAction(showAlertOnError: false) {
            await $0.updateSystemSettings(RemoteSystemSettingsUpdateRequest(controllerPort: port))
        }
    }

    func setKillSwitchEnabled(_ enabled: Bool) {
        runRemoteAction(showAlertOnError: false) {
            await $0.updateSystemSettings(RemoteSystemSettingsUpdateRequest(killSwitchActive: enabled))
        }
    }

    func setKillSwitchAllowLAN(_ allow: Bool) {
        runRemoteAction(showAlertOnError: false) {
            await $0.updateSystemSettings(RemoteSystemSettingsUpdateRequest(killSwitchAllowLAN: allow))
        }
    }

    func setKillSwitchPersistOnBoot(_ persist: Bool) {
        runRemoteAction(showAlertOnError: false) {
            await $0.updateSystemSettings(RemoteSystemSettingsUpdateRequest(killSwitchPersistOnBoot: persist))
        }
    }

    func checkForCoreUpdate() {
        runRemoteAction(showAlertOnError: false) { await $0.checkForCoreUpdate() }
    }

    func installCoreUpdate() {
        runRemoteAction { await $0.installCoreUpdate() }
    }

    func updateGeoResources() {
        runRemoteAction(showAlertOnError: false) { await $0.updateGeoResources() }
    }

    func refreshGroups() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.remoteClient.refreshAll()
            self.delegate?.deviceSession(self, didEmitFeedback: "远程节点列表已刷新")
        }
    }

    func selectNode(group: String, node: String) {
        runRemoteAction { await $0.selectProxy(group: group, node: node) }
    }

    func testGroupDelay(group: String) {
        runRemoteAction(showAlertOnError: false) { await $0.testDelay(group: group) }
    }

    func diagnoseTargetHops(targetName: String) {
        let relayGroup = MihomoConfig.relayGroupName(for: targetName)
        let hasRelay = liveProxyStore.activeProxyGroups.contains(relayGroup)
        let hasExit = liveProxyStore.activeProxyGroups.contains(targetName)
        runRemoteAction(showAlertOnError: false) { client in
            if hasRelay {
                await client.testDelay(group: relayGroup)
            }
            if hasExit {
                await client.testDelay(group: targetName)
            }
        }
    }

    func diagnoseAllActiveHops() {
        let groups = liveProxyStore.activeProxyGroups
        guard !groups.isEmpty else { return }
        runRemoteAction(showAlertOnError: false) { client in
            for group in groups {
                await client.testDelay(group: group)
            }
        }
    }

    func clearOutboundErrors() {
        connectionMonitor.clearOutboundErrors()
        runRemoteAction(showAlertOnError: false) { await $0.clearOutboundErrors() }
    }

    func updateOnlineRuleProviders() {
        runRemoteAction(showAlertOnError: false) { await $0.updateOnlineRuleProviders() }
    }

    private func currentFallbackProxyEndpoint(for profile: RoutingProfile) -> (host: String, port: Int)? {
        guard isCoreRunning, profile.effectiveAllowLAN, let host = remoteClient.activeHost else {
            return nil
        }
        return (host.host, mixedPort)
    }

    func fetchSubscriptionNodes(_ sub: ProxySubscription) {
        let proxyEndpoint = currentFallbackProxyEndpoint(for: currentProfile)
        subscriptionStore.invalidateRemoteFallback(for: sub.id, url: sub.url)
        runRemoteAction(showAlertOnError: false) { [weak self] client in
            await client.refreshSubscription(id: sub.id.uuidString)
            guard let self else { return }
            let hasServerNodes = client.remoteFullState?.subscriptionUsages
                .first(where: { $0.subscriptionId == sub.id.uuidString })?
                .nodes?.isEmpty == false
            if !hasServerNodes {
                self.subscriptionStore.triggerRemoteFallbackFetch(
                    for: sub,
                    fallbackCacheDirectory: ProfileStore().defaultDirectory,
                    fallbackProxyEndpoint: proxyEndpoint
                )
            }
            self.schedulePostSubscriptionRefreshPoll()
        }
    }

    func fetchAllSubscriptionNodes() {
        let subs = currentProfile.subscriptions
        let proxyEndpoint = currentFallbackProxyEndpoint(for: currentProfile)
        subscriptionStore.invalidateAllRemoteFallbacks()
        runRemoteAction(showAlertOnError: false) { [weak self] client in
            await client.refreshSubscription(id: nil)
            guard let self else { return }
            for sub in subs {
                let hasServerNodes = client.remoteFullState?.subscriptionUsages
                    .first(where: { $0.subscriptionId == sub.id.uuidString })?
                    .nodes?.isEmpty == false
                if !hasServerNodes {
                    self.subscriptionStore.triggerRemoteFallbackFetch(
                        for: sub,
                        fallbackCacheDirectory: ProfileStore().defaultDirectory,
                        fallbackProxyEndpoint: proxyEndpoint
                    )
                }
            }
            self.schedulePostSubscriptionRefreshPoll()
        }
    }

    private func schedulePostSubscriptionRefreshPoll() {
        Task { @MainActor [weak self] in
            for delayNs in [UInt64(1_500_000_000), UInt64(2_500_000_000)] {
                try? await Task.sleep(nanoseconds: delayNs)
                guard let self, self.remoteClient.activeHostId != nil else { return }
                await self.remoteClient.refreshAll()
            }
        }
    }

    func refreshHostModule(id: UUID) {
        runRemoteAction(showAlertOnError: false) { await $0.refreshHostModule(id: id.uuidString) }
    }

    func refreshAllHostModules() {
        runRemoteAction(showAlertOnError: false) { await $0.refreshHostModule(id: nil) }
    }

    func closeMonitoredConnection(id: String) {
        runRemoteAction(showAlertOnError: false) { await $0.closeConnection(id: id) }
    }

    func closeAllMonitoredConnections() {
        runRemoteAction(showAlertOnError: false) { await $0.closeAllConnections() }
    }

    func flushDNSCache(includeFakeIP: Bool) {
        runRemoteAction(showAlertOnError: false) { await $0.flushDNS(includeFakeIP: includeFakeIP) }
    }

    func clearDNSLogsAndCache(includeFakeIP: Bool) {
        connectionMonitor.clearDNSLogs()
        guard isCoreRunning else {
            delegate?.deviceSession(self, didEmitFeedback: "已清空 DNS 解析日志")
            return
        }
        flushDNSCache(includeFakeIP: includeFakeIP)
    }

    func refreshGatewayDevices() {
        Task { @MainActor [weak self] in
            await self?.remoteClient.refreshAll()
        }
    }

    private func runRemoteAction(
        showAlertOnError: Bool = true,
        _ operation: @escaping @MainActor (RemoteClientService) async -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await operation(self.remoteClient)
            self.emitRemoteActionResult(showAlertOnError: showAlertOnError)
        }
    }

    private func emitRemoteActionResult(showAlertOnError: Bool) {
        if let fb = remoteClient.actionFeedback {
            delegate?.deviceSession(self, didEmitFeedback: fb)
        } else if showAlertOnError, let err = remoteClient.lastError {
            delegate?.deviceSession(self, didEmitAlert: err)
        }
    }
}
