import AppKit
import Combine
import Foundation
import Network
import RoutingCore
import UniformTypeIdentifiers

enum SidebarSection: String, CaseIterable, Identifiable {
    case overview
    case monitor
    case ruleGroups
    case customDNS
    case targets
    case subscriptions
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "总览"
        case .monitor: return "请求监控"
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
        case .monitor: return "waveform.path.ecg"
        case .ruleGroups: return "list.bullet.rectangle.portrait"
        case .customDNS: return "globe"
        case .targets: return "point.topleft.down.to.point.bottomright.curvepath"
        case .subscriptions: return "point.3.filled.connected.trianglepath.dotted"
        case .settings: return "gearshape.2"
        }
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
final class AppState: ObservableObject {
    @Published var selectedSection: SidebarSection? = .overview
    @Published var profile: RoutingProfile = .starter() {
        didSet {
            recomputeConfigValidation()
            scheduleAutoSave()
            if engine.isRunning, let baseline = runningProfileSnapshot {
                hasPendingHotReload = (profile != baseline)
            }
        }
    }

    @Published var controllerPort: Int = 19090 {
        didSet {
            recomputeConfigValidation()
            saveSettings()
        }
    }
    @Published var customProfileDirectory: URL? {
        didSet { saveSettings() }
    }
    @Published var autoStartCoreOnLaunch: Bool = false {
        didSet { saveSettings() }
    }
    @Published private(set) var launchAtLoginStatus: LaunchAtLoginStatus = .disabled
    @Published var interfaces: [NetworkInterfaceInfo] = []
    @Published var activeProxyGroups: [String] = []
    @Published var groupStatus: [String: LocalController.ProxyGroup] = [:]
    @Published var groupSelection: [String: String] = [:]
    @Published var readsGroups = false
    @Published var testingGroups: Set<String> = []
    @Published private(set) var hasPendingHotReload = false
    @Published private(set) var isHotReloading = false
    @Published var updatingRuleProviders = false
    @Published var updatingGeoResources = false
    @Published var geoUpdateMessage: String?
    @Published private(set) var tunPermissionStatus: TunPermissionStatus = .notAuthorized
    @Published private(set) var isAuthorizingTun = false
    @Published private(set) var isIPForwardingEnabled = NetworkEnvironment.isIPForwardingEnabled()
    @Published private(set) var configValidationError: String?
    @Published var alertText: String?
    @Published var feedback: String = ""

    let engine = EngineController()
    let coreBinaryStore = CoreBinaryStore()
    let subscriptionStore = SubscriptionStore()
    let connectionMonitor = ConnectionMonitorService()

    private var controller: (any MihomoControlClient)?
    private var cancellables = Set<AnyCancellable>()
    private var feedbackTask: Task<Void, Never>?
    private var groupPollTask: Task<Void, Never>?
    private var autoSaveTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "local.routeweaver.path-monitor", qos: .utility)
    private var isRestoring = false
    private var runningProfileSnapshot: RoutingProfile?

    // MARK: - Domain Store Forwarding Accessors

    var binary: URL? { coreBinaryStore.binary }
    var binarySource: CoreBinarySource { coreBinaryStore.source }
    var binaryVersion: String? { coreBinaryStore.version }
    var latestCoreRelease: MihomoRelease? { coreBinaryStore.latestRelease }
    var latestCoreAsset: MihomoReleaseAsset? { coreBinaryStore.latestAsset }
    var isCheckingCoreUpdate: Bool { coreBinaryStore.isCheckingUpdate }
    var isUpdatingCore: Bool { coreBinaryStore.isUpdating }
    var coreUpdateMessage: String? { coreBinaryStore.updateMessage }
    var coreUpdateError: String? { coreBinaryStore.updateError }
    var pendingCoreRestart: Bool { coreBinaryStore.pendingRestart }
    var hasNewerCoreVersion: Bool { coreBinaryStore.hasNewerVersion }
    var canResetToBundledCore: Bool { coreBinaryStore.canResetToBundled }

    var subscriptionCache: [UUID: SubscriptionNodeCacheEntry] { subscriptionStore.cache }
    var fetchingSubscriptionIDs: Set<UUID> { subscriptionStore.fetchingIDs }
    var subscriptionFetchErrors: [UUID: String] { subscriptionStore.fetchErrors }
    var updatingHostModuleIDs: Set<UUID> { subscriptionStore.updatingHostModuleIDs }

    private var profileStore: ProfileStore {
        ProfileStore(customDirectory: customProfileDirectory)
    }

    var activeProfileDirectory: URL { profileStore.activeDirectory }
    var savedProfileURL: URL { profileStore.activeProfileURL }
    var isUsingCustomProfileDirectory: Bool { profileStore.isUsingCustomDirectory }

    private enum DefaultsKey {
        static let controllerPort = "RouteWeaver.controllerPort"
        static let profileDirectoryPath = "RouteWeaver.profileDirectoryPath"
        static let autoStartCoreOnLaunch = "RouteWeaver.autoStartCoreOnLaunch"
    }

    var editingLocked: Bool { engine.isRunning || engine.isBusy }
    var hotReloadEditingLocked: Bool { engine.isBusy || isHotReloading }
    var activeMixedPort: Int { runningProfileSnapshot?.mixedPort ?? profile.mixedPort }

    var localProxyAddress: String { "127.0.0.1:\(activeMixedPort)" }

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

    var missingInterfaces: [String] {
        let active = Set(interfaces.filter(\.isUpWithAddress).map(\.bsdName))
        return profile.requiredInterfaces.filter { !active.contains($0) }.sorted()
    }

    var canStart: Bool {
        let tunReady = !profile.effectiveTunEnabled || tunPermissionStatus.isReady
        return !engine.isBusy && !isAuthorizingTun && binary != nil && configValidationError == nil && missingInterfaces.isEmpty && tunReady
    }

    var readinessItems: [ReadinessItem] {
        let hasBinary = binary.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
        let binaryDetail: String
        if hasBinary {
            let ver = binaryVersion.map { " (\($0))" } ?? ""
            binaryDetail = "\(binarySource.title)\(ver)"
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

        let required = profile.requiredInterfaces
        let interfaceReady = missingInterfaces.isEmpty
        let interfaceDetail: String
        if required.isEmpty {
            interfaceDetail = "使用系统默认网卡（未强制绑定）"
        } else if !missingInterfaces.isEmpty {
            interfaceDetail = "绑定网卡不可用或无 IP：\(missingInterfaces.joined(separator: "、"))"
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
                    isReady: tunPermissionStatus.isReady,
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

    init() {
        restoreState()
        recomputeConfigValidation()
        refreshInterfaces()
        startInterfaceMonitoring()
        refreshResolvedBinary()
        refreshLaunchAtLoginStatus()
        subscriptionStore.loadCache(in: activeProfileDirectory)
        connectionMonitor.configureHistory(directory: activeProfileDirectory)
        startInitialCoreBootstrap()

        // Only low-frequency engine lifecycle state lives on EngineController (logs live in EngineLogStore).
        engine.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Forward resolved binary changes so OverviewView / MenuBarExtra stay in sync without observing update progress.
        coreBinaryStore.$binary
            .dropFirst()
            .sink { [weak self] _ in
                self?.refreshTunPermissionStatus()
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        coreBinaryStore.$version
            .dropFirst()
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        engine.$phase
            .removeDuplicates()
            .sink { [weak self] newPhase in
                guard let self else { return }
                if newPhase == .running {
                    self.refreshIPForwardingStatus()
                    self.startGroupPolling()
                    if let active = self.controller {
                        self.connectionMonitor.start(controller: active)
                    }
                } else if newPhase == .idle {
                    self.refreshIPForwardingStatus()
                    self.connectionMonitor.stop()
                    self.resetActiveGroups()
                    self.runningProfileSnapshot = nil
                    self.hasPendingHotReload = false
                    self.isHotReloading = false
                    self.coreBinaryStore.handleEngineStopped()
                }
            }
            .store(in: &cancellables)
    }

    private func recomputeConfigValidation() {
        do {
            _ = try MihomoConfig.renderDetailed(profile, controllerPort: controllerPort, secret: "validation-probe")
            configValidationError = nil
        } catch {
            configValidationError = error.localizedDescription
        }
    }

    func refreshInterfaces() {
        let updated = NetworkEnvironment.detailedInterfaces()
        if interfaces != updated {
            interfaces = updated
        }
        refreshIPForwardingStatus()
    }

    func refreshIPForwardingStatus() {
        let enabled = NetworkEnvironment.isIPForwardingEnabled()
        if isIPForwardingEnabled != enabled {
            isIPForwardingEnabled = enabled
        }
    }

    func setTunEnabled(_ enabled: Bool) {
        guard !editingLocked else { return }
        profile.tunEnabled = enabled
        if !enabled && profile.gatewayModeEnabled {
            profile.gatewayModeEnabled = false
        }
    }

    func setGatewayModeEnabled(_ enabled: Bool) {
        guard !editingLocked else { return }
        profile.gatewayModeEnabled = enabled
        if enabled {
            if !profile.tunEnabled {
                profile.tunEnabled = true
            }
            if !profile.allowLAN {
                profile.allowLAN = true
            }
        }
    }

    private func startInterfaceMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshInterfaces()
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    deinit {
        pathMonitor.cancel()
    }

    func interfaceDisplayLabel(for bsdName: String?) -> String {
        guard let bsd = bsdName?.trimmingCharacters(in: .whitespacesAndNewlines), !bsd.isEmpty else {
            return "系统默认网卡"
        }
        if let info = interfaces.first(where: { $0.bsdName == bsd }) {
            return info.shortLabel
        }
        return bsd
    }

    func targetSummaryChain(for target: NetworkTarget) -> [String] {
        switch target.mode {
        case .direct:
            return ["直连", interfaceDisplayLabel(for: target.interfaceName)]
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
            return chain
        }
    }

    // MARK: - Quick Mutations

    func removeRelay(fromTargetID id: UUID) {
        guard let idx = profile.targets.firstIndex(where: { $0.id == id }) else { return }
        profile.targets[idx].relayGroupID = nil
        showFeedback("已移除「\(profile.targets[idx].name)」的链式代理")
    }

    func deleteSubscription(id: UUID) {
        let removedURL = profile.subscriptions.first(where: { $0.id == id })?.url
        profile.subscriptions.removeAll { $0.id == id }
        for idx in profile.nodeGroups.indices where profile.nodeGroups[idx].subscriptionID == id {
            profile.nodeGroups[idx].subscriptionID = nil
        }
        subscriptionStore.removeSubscription(
            id: id,
            removedURL: removedURL,
            remainingURLs: profile.subscriptions.map(\.url),
            in: activeProfileDirectory
        )
    }

    // MARK: - Subscription Node Preview

    func nodes(forSubscriptionID id: UUID?) -> [SubscriptionNode] {
        subscriptionStore.nodes(forSubscriptionID: id)
    }

    func matchedNodes(for group: NodeGroup) -> [SubscriptionNode]? {
        subscriptionStore.matchedNodes(for: group)
    }

    func fetchSubscriptionNodes(_ sub: ProxySubscription) {
        let fallbackProxyPort = engine.isRunning ? activeMixedPort : nil
        subscriptionStore.fetchSubscriptionNodes(
            sub,
            fallbackProxyPort: fallbackProxyPort,
            cacheDirectory: activeProfileDirectory
        ) { [weak self] message in
            self?.showFeedback(message)
        }
    }

    func fetchAllSubscriptionNodes() {
        for sub in profile.subscriptions {
            fetchSubscriptionNodes(sub)
        }
    }

    func deleteHostModule(id: UUID) {
        profile.hostModules.removeAll { $0.id == id }
    }

    func refreshAllHostModules() {
        for module in profile.hostModules where !subscriptionStore.updatingHostModuleIDs.contains(module.id) {
            refreshHostModule(id: module.id)
        }
    }

    func refreshHostModule(id: UUID) {
        guard let idx = profile.hostModules.firstIndex(where: { $0.id == id }) else { return }
        let rawURL = profile.hostModules[idx].url
        subscriptionStore.refreshHostModule(
            id: id,
            rawURL: rawURL,
            onParsed: { [weak self] parsed, url in
                guard let self, let currentIdx = self.profile.hostModules.firstIndex(where: { $0.id == id }) else { return }
                self.profile.hostModules[currentIdx].cachedHosts = parsed.hosts
                self.profile.hostModules[currentIdx].lastUpdated = Date()
                if self.profile.hostModules[currentIdx].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let parsedName = parsed.name {
                    self.profile.hostModules[currentIdx].name = parsedName
                }
                let displayName = self.profile.hostModules[currentIdx].name.isEmpty ? url.lastPathComponent : self.profile.hostModules[currentIdx].name
                self.showFeedback("已更新「\(displayName)」：解析出 \(parsed.hosts.count) 条有效 Host 映射")
            },
            onError: { [weak self] message in
                self?.alertText = message
            }
        )
    }

    func deleteNodeGroup(id: UUID) {
        profile.nodeGroups.removeAll { $0.id == id }
        for idx in profile.targets.indices {
            if profile.targets[idx].exitGroupID == id { profile.targets[idx].exitGroupID = nil }
            if profile.targets[idx].relayGroupID == id { profile.targets[idx].relayGroupID = nil }
        }
    }

    func deleteTarget(id: UUID) {
        profile.targets.removeAll { $0.id == id }
        let replacement: TargetReference = profile.targets.first.map { .target($0.id) } ?? .reject
        for idx in profile.ruleGroups.indices where profile.ruleGroups[idx].target == .target(id) {
            profile.ruleGroups[idx].target = replacement
        }
        if profile.fallbackTarget == .target(id) {
            profile.fallbackTarget = replacement
        }
        if profile.ruleProviderProxyMode == .target(id) {
            profile.ruleProviderProxyMode = .auto
        }
        for idx in profile.customDNS.entries.indices where profile.customDNS.entries[idx].targetID == id {
            profile.customDNS.entries[idx].targetID = nil
        }
    }

    func deleteCustomDNSEntry(id: UUID) {
        profile.customDNS.entries.removeAll { $0.id == id }
    }

    func upsertCustomDNSEntry(_ entry: CustomDNSEntry) {
        if let idx = profile.customDNS.entries.firstIndex(where: { $0.id == entry.id }) {
            profile.customDNS.entries[idx] = entry
        } else {
            profile.customDNS.entries.append(entry)
        }
    }

    func importCustomDNSEntries(_ entries: [CustomDNSEntry]) {
        guard !entries.isEmpty else { return }
        var added = 0
        var updated = 0
        for item in entries {
            if let existingIdx = profile.customDNS.entries.firstIndex(where: {
                $0.kind == item.kind && $0.trimmedPattern.caseInsensitiveCompare(item.trimmedPattern) == .orderedSame
            }) {
                var merged = profile.customDNS.entries[existingIdx]
                merged.value = item.value
                merged.isEnabled = true
                profile.customDNS.entries[existingIdx] = merged
                updated += 1
            } else {
                profile.customDNS.entries.append(item)
                added += 1
            }
        }
        if updated > 0 && added > 0 {
            showFeedback("已导入 \(added) 条并更新 \(updated) 条自定义 DNS")
        } else if updated > 0 {
            showFeedback("已更新 \(updated) 条自定义 DNS")
        } else {
            showFeedback("已导入 \(added) 条自定义 DNS")
        }
    }

    // MARK: - Core Binary Management & In-App Updater

    func refreshResolvedBinary() {
        coreBinaryStore.refresh()
        refreshTunPermissionStatus()
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = LaunchAtLoginManager.currentStatus()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            launchAtLoginStatus = try LaunchAtLoginManager.setEnabled(enabled)
            if enabled && !autoStartCoreOnLaunch {
                autoStartCoreOnLaunch = true
            }
            if launchAtLoginStatus == .requiresApproval {
                showFeedback("已注册开机自启，请在系统设置「登录项」中允许")
            } else {
                showFeedback(enabled ? "已开启开机自动启动" : "已关闭开机自动启动")
            }
        } catch {
            refreshLaunchAtLoginStatus()
            alertText = "设置开机自动启动失败：\(error.localizedDescription)"
        }
    }

    func openLoginItemsSettings() {
        LaunchAtLoginManager.openSystemSettingsLoginItems()
    }

    private func startInitialCoreBootstrap() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let attached = await self.reattachRunningCoreIfNeeded()
            if !attached {
                self.scheduleAutoStartCoreIfNeeded()
            }
        }
    }

    @discardableResult
    func reattachRunningCoreIfNeeded() async -> Bool {
        guard !engine.isRunning, !engine.isBusy else { return false }
        guard let session = engine.loadRuntimeSession() else { return false }

        guard session.pid > 1,
              RuntimeSessionStore.isMihomoProcess(pid: session.pid, expectTunAuthorized: session.isTun) else {
            engine.clearStaleSession(session)
            return false
        }

        let candidate = LocalController(
            port: session.controllerPort,
            secret: session.secret,
            trackedGroups: session.trackedGroups
        )
        do {
            _ = try await candidate.version(timeout: 2.0)
        } catch {
            if !RuntimeSessionStore.isProcessAlive(session.pid) {
                engine.clearStaleSession(session)
            }
            return false
        }

        guard !engine.isRunning, !engine.isBusy else { return false }

        resetActiveGroups()
        controller = candidate
        activeProxyGroups = session.trackedGroups
        runningProfileSnapshot = session.runningProfile ?? profile
        hasPendingHotReload = (profile != runningProfileSnapshot)
        engine.attachToRunningCore(session: session)
        showFeedback("已接管后台运行中的 Mihomo 核心")
        return true
    }

    var shouldConfirmCoreOnQuit: Bool {
        engine.isRunning || engine.isBusy
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

    private func scheduleAutoStartCoreIfNeeded() {
        guard autoStartCoreOnLaunch else { return }
        Task { @MainActor [weak self] in
            // Wait briefly for initial binary/interface checks and allow NICs (e.g. USB/Wi-Fi) to come up after boot.
            try? await Task.sleep(nanoseconds: 800_000_000)
            for _ in 0..<10 {
                guard let self, self.autoStartCoreOnLaunch else { return }
                if self.engine.isRunning || self.engine.isBusy { return }
                self.refreshInterfaces()
                self.refreshTunPermissionStatus()
                if self.canStart {
                    self.start()
                    self.showFeedback("已自动启动 Mihomo 核心")
                    return
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func refreshTunPermissionStatus() {
        tunPermissionStatus = TunHelperManager.status(for: binary)
    }

    func authorizeTun() {
        guard !isAuthorizingTun, !engine.isBusy else { return }
        isAuthorizingTun = true
        let currentBinary = binary
        let shouldRestart = engine.isRunning
        Task { @MainActor in
            var authorized = false
            defer {
                isAuthorizingTun = false
                refreshTunPermissionStatus()
                if authorized && shouldRestart && canStart {
                    start()
                    showFeedback("TUN 权限已重新授权，正在重启核心…")
                }
            }
            if shouldRestart {
                showFeedback("正在停止核心以重新授权 TUN 权限…")
                connectionMonitor.stop()
                engine.stop()
                let deadline = Date().addingTimeInterval(10)
                while (engine.isRunning || engine.isBusy) && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if engine.isRunning || engine.isBusy {
                    alertText = "等待核心停止超时，请先手动停止核心后再重新授权。"
                    return
                }
            }
            do {
                try await TunHelperManager.authorize(mihomoBinary: currentBinary)
                authorized = true
                if !shouldRestart {
                    showFeedback("TUN 透明代理权限已授权")
                }
            } catch TunAuthorizationError.cancelled {
                showFeedback(shouldRestart ? "已取消授权，核心已停止" : "已取消授权")
            } catch {
                alertText = error.localizedDescription
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
            }
            do {
                try await TunHelperManager.revoke()
                showFeedback("已撤销 TUN 权限授权")
            } catch TunAuthorizationError.cancelled {
                showFeedback("已取消操作")
            } catch {
                alertText = error.localizedDescription
            }
        }
    }

    func resetToBundledCore() {
        guard !editingLocked else { return }
        coreBinaryStore.resetToBundled { [weak self] in
            self?.refreshTunPermissionStatus()
            self?.showFeedback("已恢复内置内核")
        }
    }

    func checkForCoreUpdate() {
        let proxyPort = engine.isRunning ? activeMixedPort : nil
        coreBinaryStore.checkForUpdate(proxyPort: proxyPort)
    }

    func installCoreUpdate() {
        let proxyPort = engine.isRunning ? activeMixedPort : nil
        coreBinaryStore.installUpdate(
            proxyPort: proxyPort,
            isEngineRunning: { [weak self] in self?.engine.isRunning ?? false },
            onInstalled: { [weak self] installedVersion in
                self?.refreshTunPermissionStatus()
                self?.showFeedback("Mihomo 内核已更新至 \(installedVersion)")
            }
        )
    }

    func validate() {
        guard let binary else { return }
        engine.clearError()
        do {
            let rendered = try MihomoConfig.renderDetailed(
                profile,
                interfaceDNS: NetworkEnvironment.interfaceDNSServers()
            )
            engine.validate(config: rendered.data, binary: binary)
            showFeedback("已开始校验配置…")
        } catch {
            alertText = error.localizedDescription
        }
    }

    func start() {
        guard let binary else { return }
        engine.clearError()
        do {
            let secret = UUID().uuidString + UUID().uuidString
            let rendered = try MihomoConfig.renderDetailed(
                profile,
                controllerPort: controllerPort,
                secret: secret,
                interfaceDNS: NetworkEnvironment.interfaceDNSServers()
            )
            let active = LocalController(port: controllerPort, secret: secret, trackedGroups: rendered.activeProxyGroupNames)
            resetActiveGroups()
            controller = active
            activeProxyGroups = rendered.activeProxyGroupNames
            runningProfileSnapshot = profile
            hasPendingHotReload = false
            let sessionContext = EngineSessionContext(
                controllerPort: controllerPort,
                secret: secret,
                trackedGroups: rendered.activeProxyGroupNames,
                runningProfile: profile
            )
            engine.start(
                config: rendered.data,
                binary: binary,
                interfaces: rendered.requiredInterfaces,
                useTun: rendered.tunEnabled,
                useGateway: rendered.gatewayModeEnabled,
                preloadResources: rendered.preloadResources,
                subscriptionCacheDirectory: activeProfileDirectory,
                sessionContext: sessionContext
            )
            if !engine.isBusy && !engine.isRunning {
                resetActiveGroups()
                runningProfileSnapshot = nil
            }
        } catch {
            alertText = error.localizedDescription
        }
    }

    func hotReload() {
        guard engine.isRunning, let active = controller, !isHotReloading else { return }
        let snapshot = profile
        let cacheDir = activeProfileDirectory
        let rendered: RenderedMihomoConfig
        do {
            rendered = try MihomoConfig.renderDetailed(
                snapshot,
                controllerPort: active.port,
                secret: active.secret,
                interfaceDNS: NetworkEnvironment.interfaceDNSServers()
            )
        } catch {
            alertText = "热重载失败：\(error.localizedDescription)"
            return
        }

        isHotReloading = true
        showFeedback("正在热重载配置…")
        Task { @MainActor in
            defer { isHotReloading = false }
            await engine.prepareResourcesForHotReload(
                rendered.preloadResources,
                subscriptionCacheDirectory: cacheDir
            )
            guard engine.isRunning, controller?.sessionID == active.sessionID else { return }
            do {
                try await active.reloadConfig(payload: rendered.data)
                let updatedController = LocalController(
                    port: active.port,
                    secret: active.secret,
                    trackedGroups: rendered.activeProxyGroupNames
                )
                controller = updatedController
                activeProxyGroups = rendered.activeProxyGroupNames
                runningProfileSnapshot = snapshot
                hasPendingHotReload = (profile != snapshot)
                engine.updateRuntimeSession(
                    trackedGroups: rendered.activeProxyGroupNames,
                    runningProfile: snapshot
                )
                try? await reloadGroups(updatedController)
                startGroupPolling()
                showFeedback("配置已热重载生效")
            } catch {
                alertText = "热重载失败：\(error.localizedDescription)"
            }
        }
    }

    func stop() {
        engine.stop()
    }

    // MARK: - Clipboard Helpers

    func copyText(_ text: String, label: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showFeedback("已复制\(label)")
    }

    func copyProxyAddress() {
        copyText(localProxyAddress, label: "本机代理地址 \(localProxyAddress)")
    }

    func copyShellExport() {
        let http = "http://127.0.0.1:\(profile.httpPort ?? profile.mixedPort)"
        let socks = "socks5://127.0.0.1:\(profile.socksPort ?? profile.mixedPort)"
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

    // MARK: - Live Proxy Groups

    func refreshGroups() {
        guard engine.isRunning, let active = controller, !readsGroups else { return }
        readsGroups = true
        Task { @MainActor in
            defer { if controller?.sessionID == active.sessionID { readsGroups = false } }
            do {
                try await reloadGroups(active)
                showFeedback("节点列表已刷新")
            } catch {
                if controller?.sessionID == active.sessionID { alertText = error.localizedDescription }
            }
        }
    }

    func selectNode(group: String, node: String) {
        guard engine.isRunning, let active = controller, !readsGroups,
              let status = groupStatus[group],
              !status.isAutoTest,
              status.all.contains(node) else { return }
        groupSelection[group] = node
        readsGroups = true
        Task { @MainActor in
            defer { if controller?.sessionID == active.sessionID { readsGroups = false } }
            do {
                try await active.select(group: group, node: node)
                try await reloadGroups(active)
                showFeedback("已切换 \(group) → \(node)")
            } catch {
                if controller?.sessionID == active.sessionID { alertText = error.localizedDescription }
            }
        }
    }

    func testGroupDelay(group: String) {
        guard engine.isRunning, let active = controller, !testingGroups.contains(group) else { return }
        testingGroups.insert(group)
        Task { @MainActor in
            defer {
                if controller?.sessionID == active.sessionID {
                    testingGroups.remove(group)
                }
            }
            do {
                _ = try await active.testGroupDelay(group: group)
                try await reloadGroups(active)
                if let updated = groupStatus[group], !updated.now.isEmpty {
                    let delayText = updated.currentDelay.map { " (\($0) ms)" } ?? ""
                    showFeedback("「\(group)」测速完成，当前节点：\(updated.now)\(delayText)")
                } else {
                    showFeedback("「\(group)」测速完成")
                }
            } catch {
                if controller?.sessionID == active.sessionID {
                    showFeedback("「\(group)」测速失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func updateOnlineRuleProviders() {
        guard engine.isRunning, let active = controller, !updatingRuleProviders else { return }
        updatingRuleProviders = true
        Task { @MainActor in
            defer { if controller?.sessionID == active.sessionID { updatingRuleProviders = false } }
            do {
                let count = try await active.updateAllRuleProviders()
                showFeedback(count > 0 ? "已更新 \(count) 个在线规则集" : "当前配置未启用远程规则集")
            } catch {
                if controller?.sessionID == active.sessionID { alertText = error.localizedDescription }
            }
        }
    }

    func updateGeoResources() {
        guard !updatingGeoResources else { return }
        updatingGeoResources = true
        geoUpdateMessage = "正在安全下载并校验 Geo 数据库…"
        let proxyPort = engine.isRunning ? activeMixedPort : nil
        let workDir = engine.mihomoWorkDirectory

        Task { @MainActor in
            defer { updatingGeoResources = false }
            let results = await GeoResourceUpdater.updateAll(in: workDir, proxyPort: proxyPort)
            guard !results.isEmpty else {
                geoUpdateMessage = "未找到内置资源清单，请先通过构建脚本打包。"
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
                let suffix = engine.isRunning ? "（重启核心后生效）" : ""
                geoUpdateMessage = "已安全更新 \(updatedCount) 项 Geo 数据库\(suffix)。"
                showFeedback("Geo 数据库已更新")
            } else if updatedCount > 0 {
                geoUpdateMessage = "已更新 \(updatedCount) 项，其余 \(keptCount + restoredCount) 项失败并保留原有可用版本。"
            } else if keptCount > 0 || restoredCount > 0 {
                geoUpdateMessage = "更新失败，已保留原有可用缓存（未覆盖）。"
            } else {
                geoUpdateMessage = "Geo 数据库更新失败，请检查网络或代理设置。"
            }
        }
    }

    func closeMonitoredConnection(id: String) {
        guard engine.isRunning else { return }
        Task { @MainActor in
            do {
                try await connectionMonitor.closeConnection(id: id)
                showFeedback("已断开连接")
            } catch {
                alertText = error.localizedDescription
            }
        }
    }

    func closeAllMonitoredConnections() {
        guard engine.isRunning else { return }
        Task { @MainActor in
            do {
                try await connectionMonitor.closeAllConnections()
                showFeedback("已断开全部活跃连接")
            } catch {
                alertText = error.localizedDescription
            }
        }
    }

    // MARK: - Profile Import / Export

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
                    applyProfileDirectory(targetDir)
                    applyProfileWithoutAutosave(loaded)
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
            autoSaveTask?.cancel()
            customProfileDirectory = nil
            showFeedback("已恢复默认配置目录并保存当前配置")
        } catch {
            alertText = "无法写入默认配置目录：\(error.localizedDescription)"
        }
    }

    func reloadProfileFromDisk() {
        guard !editingLocked else { return }
        autoSaveTask?.cancel()
        guard ProfileStore.profileExists(in: activeProfileDirectory) else {
            alertText = "当前配置目录中尚无 \(ProfileStore.fileName)。"
            return
        }
        do {
            let loaded = try ProfileStore.readProfile(from: activeProfileDirectory)
            applyProfileWithoutAutosave(loaded)
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
            autoSaveTask?.cancel()
            applyProfileDirectory(isDefault ? nil : directory)
            showFeedback("已切换配置目录并保存当前配置")
        } catch {
            alertText = "无法写入所选配置目录：\(error.localizedDescription)"
        }
    }

    private func applyProfileDirectory(_ directory: URL?) {
        let defaultDir = ProfileStore().defaultDirectory
        if let directory, directory.standardizedFileURL != defaultDir.standardizedFileURL {
            customProfileDirectory = directory.standardizedFileURL
        } else {
            customProfileDirectory = nil
        }
        connectionMonitor.configureHistory(directory: activeProfileDirectory)
    }

    private func applyProfileWithoutAutosave(_ newProfile: RoutingProfile) {
        autoSaveTask?.cancel()
        isRestoring = true
        profile = newProfile
        isRestoring = false
    }

    func exportConfig() {
        let config: Data
        do {
            config = try MihomoConfig.render(profile, interfaceDNS: NetworkEnvironment.interfaceDNSServers())
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

    // MARK: - Internal State Management

    private func startGroupPolling() {
        groupPollTask?.cancel()
        guard let active = controller, !active.trackedGroups.isEmpty else { return }
        groupPollTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self, self.engine.isRunning, self.controller?.sessionID == active.sessionID else { return }
                let delayNs: UInt64
                switch attempt {
                case 0: delayNs = 500_000_000
                case 1...4: delayNs = 1_500_000_000
                default: delayNs = 5_000_000_000
                }
                attempt += 1
                try? await Task.sleep(nanoseconds: delayNs)
                guard !Task.isCancelled, self.engine.isRunning, self.controller?.sessionID == active.sessionID else { return }
                do {
                    try await self.reloadGroups(active)
                } catch {
                    // Retry silently during startup warm-up or transient controller errors.
                }
            }
        }
    }

    private func reloadGroups(_ active: any MihomoControlClient) async throws {
        let values = try await active.groups()
        guard controller?.sessionID == active.sessionID, engine.isRunning else { return }
        groupStatus = values
        for (key, group) in values {
            groupSelection[key] = group.all.contains(group.now) ? group.now : ""
        }
    }

    private func resetActiveGroups() {
        groupPollTask?.cancel()
        controller = nil
        activeProxyGroups = []
        groupStatus = [:]
        groupSelection = [:]
        readsGroups = false
        testingGroups = []
    }

    private func restoreState() {
        isRestoring = true
        defer { isRestoring = false }

        let defaults = UserDefaults.standard
        let savedPort = defaults.integer(forKey: DefaultsKey.controllerPort)
        if (1024...65535).contains(savedPort) {
            controllerPort = savedPort
        }
        if let profileDirPath = defaults.string(forKey: DefaultsKey.profileDirectoryPath),
           !profileDirPath.isEmpty {
            applyProfileDirectory(URL(fileURLWithPath: profileDirPath, isDirectory: true))
        }
        autoStartCoreOnLaunch = defaults.bool(forKey: DefaultsKey.autoStartCoreOnLaunch)

        if ProfileStore.profileExists(in: activeProfileDirectory),
           let decoded = try? ProfileStore.readProfile(from: activeProfileDirectory) {
            profile = decoded
        }
    }

    private func saveSettings() {
        guard !isRestoring else { return }
        let defaults = UserDefaults.standard
        defaults.set(controllerPort, forKey: DefaultsKey.controllerPort)
        if let customProfileDirectory, isUsingCustomProfileDirectory {
            defaults.set(customProfileDirectory.path, forKey: DefaultsKey.profileDirectoryPath)
        } else {
            defaults.removeObject(forKey: DefaultsKey.profileDirectoryPath)
        }
        defaults.set(autoStartCoreOnLaunch, forKey: DefaultsKey.autoStartCoreOnLaunch)
    }

    private func scheduleAutoSave() {
        guard !isRestoring else { return }
        autoSaveTask?.cancel()
        let snapshot = profile
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
