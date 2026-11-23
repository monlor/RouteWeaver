import Combine
import Darwin
import Foundation
import RoutingCore
import TunHelperProtocol

enum EnginePhase: Equatable, Sendable {
    case idle
    case checkingVersion
    case validating
    case preparingResources
    case starting
    case running
    case stopping

    var title: String {
        switch self {
        case .idle: return "未运行"
        case .checkingVersion: return "检查内核版本…"
        case .validating: return "校验配置…"
        case .preparingResources: return "预下载订阅与规则…"
        case .starting: return "启动核心…"
        case .running: return "运行中"
        case .stopping: return "停止中…"
        }
    }

    var isBusy: Bool {
        switch self {
        case .checkingVersion, .validating, .preparingResources, .starting, .stopping:
            return true
        case .idle, .running:
            return false
        }
    }
}

@MainActor
final class EngineController: ObservableObject {
    @Published private(set) var phase: EnginePhase = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var isTunActive = false
    @Published private(set) var isGatewayActive = false
    @Published private(set) var isLaunchdManaged = false
    @Published private(set) var launchdRestartCount = 0
    @Published private(set) var lastCoreRestartToken = UUID()
    @Published private(set) var isAttachedExternalCore = false

    let logStore = EngineLogStore()

    var isRunning: Bool { phase == .running }
    var isBusy: Bool { phase.isBusy }

    private let stateDir: URL
    private let sessionStore: RuntimeSessionStore
    private let driver: any CoreRuntimeDriver

    private var workDir: URL {
        stateDir.appendingPathComponent("work", isDirectory: true)
    }
    private var tunWorkDir: URL {
        stateDir.appendingPathComponent("work-tun", isDirectory: true)
    }
    var mihomoWorkDirectory: URL { workDir }
    var activeWorkDirectory: URL { isTunActive ? tunWorkDir : workDir }

    private var lastRunLogURL: URL {
        stateDir.appendingPathComponent("last-run.log")
    }

    private var activeHandle: (any CoreRuntimeHandle)?
    private var runDir: URL?
    private var pidFileURL: URL?
    private var startupTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var interfaceWatchTask: Task<Void, Never>?
    private var generation = UUID()
    private var stopRequested = false
    private var pendingSessionContext: EngineSessionContext?
    private var currentSession: RuntimeCoreSession?

    init(
        stateDir: URL? = nil,
        driver: any CoreRuntimeDriver = MacOSRuntimeDriver()
    ) {
        let dir = stateDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RouteWeaver/Mihomo", isDirectory: true)
        self.stateDir = dir
        self.sessionStore = RuntimeSessionStore(stateDir: dir)
        self.driver = driver
    }

    func prepareResourcesForHotReload(
        _ items: [PreloadResourceItem],
        subscriptionCacheDirectory: URL
    ) async {
        let targetDir = activeWorkDirectory
        let scan = ResourcePreloader.scanMissing(
            items,
            in: targetDir,
            syncFrom: isTunActive ? workDir : nil,
            subscriptionCacheDirectory: subscriptionCacheDirectory
        )
        if scan.seededFromSubscriptionCache > 0 {
            append("已从本地订阅缓存同步 \(scan.seededFromSubscriptionCache) 项节点数据。\n")
        }
        guard !scan.missing.isEmpty else { return }
        append("热重载前预下载新增资源（共 \(scan.missing.count) 项）…\n")
        let report = await ResourcePreloader.download(
            scan.missing,
            to: targetDir,
            subscriptionCacheDirectory: subscriptionCacheDirectory
        )
        if report.downloaded > 0 || report.failed > 0 {
            append("热重载预下载完成：成功 \(report.downloaded) 项，失败 \(report.failed) 项。\n")
        }
    }

    func clearLog() {
        logStore.clear()
    }

    func clearError() {
        lastError = nil
    }

    func validate(config: Data, binary: URL) {
        begin(
            config: config,
            binary: binary,
            interfaces: [],
            useTun: false,
            useGateway: false,
            useSystemKeepAlive: false,
            preloadResources: [],
            subscriptionCacheDirectory: ProfileStore().defaultDirectory,
            startAfterValidation: false
        )
    }

    func start(
        config: Data,
        binary: URL,
        interfaces: [String],
        useTun: Bool = false,
        useGateway: Bool = false,
        useSystemKeepAlive: Bool = true,
        preloadResources: [PreloadResourceItem] = [],
        subscriptionCacheDirectory: URL = ProfileStore().defaultDirectory,
        sessionContext: EngineSessionContext? = nil
    ) {
        pendingSessionContext = sessionContext
        begin(
            config: config,
            binary: binary,
            interfaces: interfaces,
            useTun: useTun || useGateway,
            useGateway: useGateway,
            useSystemKeepAlive: useSystemKeepAlive,
            preloadResources: preloadResources,
            subscriptionCacheDirectory: subscriptionCacheDirectory,
            startAfterValidation: true
        )
    }

    func updateRuntimeSession(trackedGroups: [String], runningProfile: RoutingProfile) {
        guard var session = currentSession else { return }
        session.trackedGroups = trackedGroups
        session.runningProfile = runningProfile
        currentSession = session
        sessionStore.save(session)
    }

    /// Persists hot-reloaded Mihomo YAML back to the active run config so a launchd crash-restart reloads the latest config.
    func persistHotReloadedConfig(_ data: Data) {
        guard let configPath = currentSession?.configPath, !configPath.isEmpty else { return }
        let url = URL(fileURLWithPath: configPath)
        try? ProfileStore.writePrivateFile(data, to: url, tempName: "config.yaml")
    }

    /// Resolves and reattaches to a previously persisted Mihomo core session if it is still healthy.
    func reattachRunningCore(
        using clientFactory: MihomoControlClientFactory
    ) async -> (session: RuntimeCoreSession, client: any MihomoControlClient)? {
        guard activeHandle == nil, !isRunning, !isBusy else { return nil }
        guard var session = sessionStore.load() else { return nil }

        switch await driver.probeExistingSession(session) {
        case .stale:
            sessionStore.clearStale(session)
            return nil
        case .launchdLoadedAwaitingPid:
            return nil
        case .alive(let pid):
            session.pid = pid
        }

        let client = clientFactory(session.controllerPort, session.secret, session.trackedGroups)
        do {
            _ = try await client.version(timeout: 2.0)
        } catch {
            if case .stale = await driver.probeExistingSession(session) {
                sessionStore.clearStale(session)
            }
            return nil
        }

        guard activeHandle == nil, !isRunning, !isBusy else { return nil }
        attachToRunningCore(session: session)
        return (session, client)
    }

    func attachToRunningCore(session: RuntimeCoreSession) {
        guard activeHandle == nil, !isBusy else { return }
        lastError = nil
        stopRequested = false
        let token = UUID()
        generation = token
        isTunActive = session.isTun
        isGatewayActive = session.isGateway
        isLaunchdManaged = session.isLaunchdManaged
        launchdRestartCount = 0
        isAttachedExternalCore = true
        runDir = URL(fileURLWithPath: session.runDirectoryPath, isDirectory: true)
        pidFileURL = session.pidFilePath.map { URL(fileURLWithPath: $0) }
        currentSession = session
        phase = .running

        let logURL = URL(fileURLWithPath: session.logFilePath)
        logStore.loadExistingTail(from: logURL)
        let modeSuffix = session.isGateway ? " · 局域网网关模式" : (session.isTun ? " · TUN 模式" : "")
        let keepAliveSuffix = session.isLaunchdManaged ? " · launchd 系统级保活" : ""
        logStore.appendMemoryOnly("已自动接管后台运行中的 Mihomo 核心（PID \(session.pid)\(modeSuffix)\(keepAliveSuffix)）。\n")
        startLogTail(at: logURL, token: token)

        let handle = driver.attachToSession(session)
        activeHandle = handle
        consumeHandleEvents(handle, token: token, isGateway: session.isGateway, isTun: session.isTun)
        if !session.requiredInterfaces.isEmpty {
            startInterfaceWatch(session.requiredInterfaces, token: token)
        }
    }

    func stop() {
        if phase == .checkingVersion || phase == .validating || phase == .preparingResources {
            guard !stopRequested else { return }
            stopRequested = true
            startupTask?.cancel()
            startupTask = nil
            append(phase == .preparingResources ? "已取消启动前资源预下载。\n" : "已停止。\n")
            cleanup()
            return
        }

        guard let handle = activeHandle, !stopRequested else { return }
        stopRequested = true
        phase = .stopping
        interfaceWatchTask?.cancel()
        interfaceWatchTask = nil

        let wasTun = isTunActive
        let wasGateway = isGatewayActive
        let wasLaunchd = isLaunchdManaged
        let token = generation

        if wasLaunchd {
            logStore.appendMemoryOnly(wasGateway
                ? "正在卸载系统级 launchd 守护、停止局域网网关并恢复系统路由、DNS 与 IP 转发…\n"
                : (wasTun
                    ? "正在卸载系统级 launchd 守护、停止 TUN 内核并恢复系统路由与 DNS…\n"
                    : "正在卸载系统级 launchd 守护并停止内核…\n"))
        } else {
            logStore.appendMemoryOnly(wasGateway
                ? "正在停止局域网网关并恢复系统路由、DNS 与 IP 转发…\n"
                : (wasTun ? "正在停止 TUN 内核并恢复系统路由与 DNS…\n" : "正在停止内核…\n"))
        }

        Task { [weak self] in
            let stopped = await handle.stopAsync()
            await MainActor.run {
                guard let self, self.generation == token else { return }
                if !stopped {
                    self.lastError = wasLaunchd
                        ? "无法卸载 TUN LaunchDaemon，请确认已在「设置与日志」中重新授权 TUN 权限。"
                        : "无法停止后台 TUN 核心，请确认已在「设置与日志」中重新授权 TUN 权限。"
                    self.logStore.appendMemoryOnly((self.lastError ?? "") + "\n")
                    self.stopRequested = false
                    self.phase = .running
                    if let ifaces = self.currentSession?.requiredInterfaces, !ifaces.isEmpty {
                        self.startInterfaceWatch(ifaces, token: token)
                    }
                } else {
                    if wasLaunchd {
                        self.logStore.appendMemoryOnly(wasGateway
                            ? "局域网网关系统级守护已停止。\n"
                            : (wasTun ? "TUN 核心系统级守护已停止。\n" : "核心系统级守护已停止。\n"))
                    } else {
                        self.logStore.appendMemoryOnly(wasTun ? "TUN 核心已停止。\n" : "已停止。\n")
                    }
                    self.cleanup()
                }
            }
        }
    }

    /// Leaves the running Mihomo core alive in the background when the RouteWeaver UI exits.
    func detachForAppExit() {
        startupTask?.cancel()
        startupTask = nil
        eventTask?.cancel()
        eventTask = nil
        interfaceWatchTask?.cancel()
        interfaceWatchTask = nil
        logStore.stopTailing()

        if let pidFile = pidFileURL, let pid = RuntimeSessionStore.readPidFile(at: pidFile), pid > 1,
           var session = currentSession, session.pid <= 1 {
            session.pid = pid
            currentSession = session
            sessionStore.save(session)
        }

        activeHandle?.detachForExit()
        activeHandle = nil
    }

    func terminateForAppExit() {
        startupTask?.cancel()
        startupTask = nil
        eventTask?.cancel()
        eventTask = nil
        interfaceWatchTask?.cancel()
        interfaceWatchTask = nil
        logStore.stopTailing()

        activeHandle?.stopSyncForExit()
        activeHandle = nil

        if let pidFile = pidFileURL { try? FileManager.default.removeItem(at: pidFile) }
        if let directory = runDir { try? FileManager.default.removeItem(at: directory) }
        sessionStore.removeSessionFile()
    }

    // MARK: - Startup Pipeline

    private func begin(
        config: Data,
        binary: URL,
        interfaces: [String],
        useTun: Bool,
        useGateway: Bool,
        useSystemKeepAlive: Bool,
        preloadResources: [PreloadResourceItem],
        subscriptionCacheDirectory: URL,
        startAfterValidation: Bool
    ) {
        guard activeHandle == nil, !isBusy else { return }
        lastError = nil
        guard binary.isFileURL, FileManager.default.isExecutableFile(atPath: binary.path) else {
            let msg = "请选择可执行的本地 Mihomo 内核。"
            lastError = msg
            append(msg + "\n")
            return
        }
        if startAfterValidation && useTun {
            let tunStatus = driver.checkTunPermission(for: binary)
            guard tunStatus == .ready else {
                let modeLabel = useGateway ? "局域网网关模式" : "TUN 模式"
                let msg = "\(modeLabel)尚未完成管理员授权（\(tunStatus.title)），请先在「设置与日志」中授权权限。"
                lastError = msg
                append(msg + "\n")
                return
            }
        }
        if startAfterValidation, !(checkInterfaces(interfaces) && checkPorts(config, useTun: useTun)) { return }
        logStore.resetForNewRun(logURL: lastRunLogURL)

        let configPath: URL
        do {
            configPath = try prepareRunDirectoriesAndConfig(config: config, useTun: useTun)
        } catch {
            let msg = "无法校验配置：\(error.localizedDescription)"
            lastError = msg
            append(msg + "\n")
            cleanup()
            return
        }

        let token = UUID()
        generation = token
        stopRequested = false
        phase = .checkingVersion
        append("正在检查 Mihomo 内核版本…\n")

        startupTask?.cancel()
        startupTask = Task { [weak self] in
            guard let self else { return }
            await self.runStartupPipeline(
                token: token,
                config: config,
                configPath: configPath,
                binary: binary,
                interfaces: interfaces,
                useTun: useTun,
                useGateway: useGateway,
                useSystemKeepAlive: useSystemKeepAlive,
                preloadResources: preloadResources,
                subscriptionCacheDirectory: subscriptionCacheDirectory,
                startAfterValidation: startAfterValidation
            )
        }
    }

    private func prepareRunDirectoriesAndConfig(config: Data, useTun: Bool) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDir.path)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workDir.path)
        if let seedReport = GeoResourceUpdater.seedIfNeeded(to: workDir) {
            if !seedReport.seeded.isEmpty {
                append("已从内置资源初始化：\(seedReport.seeded.joined(separator: "、"))。\n")
            }
            if !seedReport.repairedCorrupted.isEmpty {
                append("已修复损坏的本地资源：\(seedReport.repairedCorrupted.joined(separator: "、"))。\n")
            }
        }
        if useTun {
            try fm.createDirectory(at: tunWorkDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            try fm.createDirectory(at: tunWorkDir.appendingPathComponent("providers-cache", isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            try fm.createDirectory(at: tunWorkDir.appendingPathComponent("rulesets-cache", isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            _ = GeoResourceUpdater.seedIfNeeded(to: tunWorkDir)
            ResourcePreloader.syncUpdatedGeoFiles(from: workDir, to: tunWorkDir)
        } else {
            try fm.createDirectory(at: workDir.appendingPathComponent("providers-cache", isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            try fm.createDirectory(at: workDir.appendingPathComponent("rulesets-cache", isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        }
        let directory = stateDir.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        runDir = directory
        let configPath = directory.appendingPathComponent("config.yaml")
        guard fm.createFile(atPath: configPath.path, contents: config, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return configPath
    }

    private func runStartupPipeline(
        token: UUID,
        config: Data,
        configPath: URL,
        binary: URL,
        interfaces: [String],
        useTun: Bool,
        useGateway: Bool,
        useSystemKeepAlive: Bool,
        preloadResources: [PreloadResourceItem],
        subscriptionCacheDirectory: URL,
        startAfterValidation: Bool
    ) async {
        do {
            let (versionCode, versionStdout) = try await driver.runShortCommand(
                binary: binary,
                workDir: workDir,
                arguments: ["-v"],
                timeoutSeconds: 5
            ) { [weak self] chunk in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.append(chunk)
                }
            }
            guard !Task.isCancelled, generation == token, !stopRequested else { return }

            let versionText = String(decoding: versionStdout.prefix(8_192), as: UTF8.self)
            guard versionCode == 0, MihomoConfig.supportsVersionOutput(versionText) else {
                let msg = "无法确认内核版本。请使用官方 Mihomo v1.19.27 或更新稳定版。"
                lastError = msg
                append(msg + "\n")
                cleanup()
                return
            }

            phase = .validating
            append("正在用 Mihomo 校验配置…\n")
            let (validateCode, _) = try await driver.runShortCommand(
                binary: binary,
                workDir: workDir,
                arguments: ["-t", "-d", workDir.path, "-f", configPath.path],
                timeoutSeconds: 90
            ) { [weak self] chunk in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.append(chunk)
                }
            }
            guard !Task.isCancelled, generation == token, !stopRequested else { return }

            guard validateCode == 0 else {
                let msg = "Mihomo 校验失败（退出码 \(validateCode)）。请检查运行日志。"
                lastError = msg
                append(msg + "\n")
                cleanup()
                return
            }

            append("Mihomo 配置校验通过。\n")
            guard startAfterValidation, checkInterfaces(interfaces), checkPorts(config, useTun: useTun) else {
                cleanup()
                return
            }

            let targetDir = useTun ? tunWorkDir : workDir
            let scan = ResourcePreloader.scanMissing(
                preloadResources,
                in: targetDir,
                syncFrom: useTun ? workDir : nil,
                subscriptionCacheDirectory: subscriptionCacheDirectory
            )
            if scan.seededFromSubscriptionCache > 0 {
                append("已从本地订阅缓存同步 \(scan.seededFromSubscriptionCache) 项节点数据。\n")
            }
            if !scan.missing.isEmpty {
                phase = .preparingResources
                append("启动前预下载缺失资源（共 \(scan.missing.count) 项）…\n")
                let report = await ResourcePreloader.download(
                    scan.missing,
                    to: targetDir,
                    subscriptionCacheDirectory: subscriptionCacheDirectory
                )
                guard !Task.isCancelled, generation == token, !stopRequested else { return }
                if report.downloaded > 0 || report.failed > 0 || report.skippedReadOnly > 0 {
                    var parts: [String] = []
                    if report.downloaded > 0 { parts.append("成功 \(report.downloaded) 项") }
                    if report.failed > 0 { parts.append("失败 \(report.failed) 项（将由内核重试）") }
                    if report.skippedReadOnly > 0 { parts.append("\(report.skippedReadOnly) 项目录由 root 管理（由内核拉取）") }
                    append("启动前预下载结果：\(parts.joined(separator: "，"))。\n")
                }
                for detail in report.failureNotes.prefix(5) {
                    append("  · \(detail)\n")
                }
            }

            launchEngineProcess(
                configPath: configPath,
                binary: binary,
                interfaces: interfaces,
                useTun: useTun,
                useGateway: useGateway,
                useSystemKeepAlive: useSystemKeepAlive
            )
        } catch {
            guard !Task.isCancelled, generation == token, !stopRequested else { return }
            let msg = "无法校验配置：\(error.localizedDescription)"
            lastError = msg
            append(msg + "\n")
            cleanup()
        }
    }

    private func launchEngineProcess(
        configPath: URL,
        binary: URL,
        interfaces: [String],
        useTun: Bool,
        useGateway: Bool,
        useSystemKeepAlive: Bool
    ) {
        phase = .starting
        let mode: CoreExecutionMode
        if useSystemKeepAlive {
            mode = useTun ? .launchDaemon(useGateway: useGateway) : .launchAgent
        } else {
            mode = useTun ? .tunHelper(useGateway: useGateway) : .directSpawn
        }

        do {
            let logURL = lastRunLogURL
            logStore.prepareSharedLogFile(at: logURL, stateDir: stateDir)
            let runDirectoryPath = runDir?.path ?? configPath.deletingLastPathComponent().path
            let pidFile: URL? = mode.isTun
                ? (runDir ?? configPath.deletingLastPathComponent()).appendingPathComponent("mihomo.pid")
                : nil
            pidFileURL = pidFile

            let request = CoreLaunchRequest(
                mode: mode,
                binary: binary,
                workDir: mode.isTun ? tunWorkDir : workDir,
                configPath: configPath,
                logFile: logURL,
                pidFile: pidFile
            )
            let handle = try driver.startCore(request)
            let token = UUID()
            generation = token
            activeHandle = handle
            isTunActive = mode.isTun
            isGatewayActive = mode.isGateway
            isLaunchdManaged = mode.isLaunchdManaged
            launchdRestartCount = 0
            isAttachedExternalCore = false

            logStore.appendMemoryOnly(startupBanner(for: mode))

            if let ctx = pendingSessionContext {
                let session = RuntimeCoreSession(
                    pid: handle.initialPid ?? 0,
                    isTun: mode.isTun,
                    isGateway: mode.isGateway,
                    isLaunchdManaged: mode.isLaunchdManaged,
                    controllerPort: ctx.controllerPort,
                    secret: ctx.secret,
                    trackedGroups: ctx.trackedGroups,
                    runDirectoryPath: runDirectoryPath,
                    configPath: configPath.path,
                    logFilePath: logURL.path,
                    pidFilePath: pidFile?.path,
                    requiredInterfaces: interfaces,
                    startedAt: Date(),
                    runningProfile: ctx.runningProfile
                )
                currentSession = session
                sessionStore.save(session)
            }
            pendingSessionContext = nil
            phase = .running
            startLogTail(at: logURL, token: token)
            consumeHandleEvents(handle, token: token, isGateway: mode.isGateway, isTun: mode.isTun)
            if !interfaces.isEmpty {
                startInterfaceWatch(interfaces, token: token)
            }
        } catch {
            let msg = "内核启动失败：\(error.localizedDescription)"
            lastError = msg
            append(msg + "\n")
            cleanup()
        }
    }

    private func startupBanner(for mode: CoreExecutionMode) -> String {
        switch mode {
        case .launchDaemon(useGateway: true):
            return "内核进程已通过系统级 launchd（LaunchDaemon）守护启动（局域网网关模式，异常退出将自动拉起）。\n"
        case .launchDaemon(useGateway: false):
            return "内核进程已通过系统级 launchd（LaunchDaemon）守护启动（TUN 透明代理模式，异常退出将自动拉起）。\n"
        case .launchAgent:
            return "内核进程已通过系统级 launchd（LaunchAgent）守护启动（异常退出将自动拉起）。\n"
        case .tunHelper(useGateway: true):
            return "内核进程已以局域网网关模式启动（TUN + 系统 DNS 接管 + DNS 0.0.0.0:53 + IP 转发）。\n"
        case .tunHelper(useGateway: false):
            return "内核进程已以 TUN 透明代理模式启动（已自动接管系统 DNS 防止泄漏）。\n"
        case .directSpawn:
            return "内核进程已启动。\n"
        }
    }

    private func consumeHandleEvents(
        _ handle: any CoreRuntimeHandle,
        token: UUID,
        isGateway: Bool,
        isTun: Bool
    ) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in handle.events {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                switch event {
                case .output(let chunk):
                    self.logStore.appendMemoryOnly(chunk)
                case .pidUpdated(let pid):
                    if var session = self.currentSession, session.pid != pid {
                        session.pid = pid
                        self.currentSession = session
                        self.sessionStore.save(session)
                    }
                case .launchdRestarted(let pid):
                    self.launchdRestartCount += 1
                    if var session = self.currentSession {
                        session.pid = pid
                        self.currentSession = session
                        self.sessionStore.save(session)
                    }
                    self.logStore.appendMemoryOnly("检测到 Mihomo 进程已由系统级 launchd 自动重启（新 PID \(pid)，累计自动恢复 \(self.launchdRestartCount) 次）。\n")
                    self.lastCoreRestartToken = UUID()
                case .exited(let code):
                    if !self.stopRequested {
                        if isGateway {
                            self.lastError = "Mihomo 局域网网关模式已意外退出（退出码 \(code)）。请检查 53 端口是否被占用或查看日志。"
                        } else if isTun {
                            self.lastError = "Mihomo TUN 模式已意外退出（退出码 \(code)）。"
                        } else {
                            self.lastError = "Mihomo 已意外退出（退出码 \(code)）。"
                        }
                    }
                    self.logStore.appendMemoryOnly(self.stopRequested
                        ? (isGateway ? "局域网网关核心已停止。\n" : (isTun ? "TUN 核心已停止。\n" : "已停止。\n"))
                        : (isGateway ? "Mihomo 局域网网关模式已退出（退出码 \(code)）。\n" : (isTun ? "Mihomo TUN 模式已退出（退出码 \(code)）。\n" : "Mihomo 已退出（退出码 \(code)）。\n")))
                    self.cleanup()
                    return
                case .detachedExited:
                    if !self.stopRequested {
                        self.logStore.appendMemoryOnly(self.isLaunchdManaged
                            ? "系统级 launchd 守护服务已卸载，核心已停止。\n"
                            : "后台 Mihomo 核心已退出。\n")
                    }
                    self.cleanup()
                    return
                }
            }
        }
    }

    // MARK: - Preflight & Monitors

    private func checkInterfaces(_ names: [String]) -> Bool {
        guard !names.isEmpty else { return true }
        let active = driver.activeInterfaces()
        let missing = Set(names).subtracting(active)
        guard missing.isEmpty else {
            let msg = "绑定网卡缺失或无 IP：\(missing.sorted().joined(separator: "、"))。不会自动换出口。"
            lastError = msg
            append(msg + "\n")
            return false
        }
        return true
    }

    private func checkPorts(_ config: Data, useTun: Bool) -> Bool {
        if let errorMessage = driver.validatePorts(in: config, useTun: useTun) {
            lastError = errorMessage
            append(errorMessage + "\n")
            return false
        }
        return true
    }

    private func startInterfaceWatch(_ names: [String], token: UUID) {
        interfaceWatchTask?.cancel()
        interfaceWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, let self, self.generation == token, self.isRunning else { return }
                if !self.checkInterfaces(names) {
                    self.stop()
                    return
                }
            }
        }
    }

    private func startLogTail(at url: URL, token: UUID) {
        logStore.startTailing(at: url) { [weak self] in
            guard let self else { return false }
            return self.generation == token && (self.isRunning || self.phase == .stopping)
        }
    }

    private func cleanup(removeRunDir: Bool = true, clearSession: Bool = true) {
        startupTask?.cancel()
        startupTask = nil
        eventTask?.cancel()
        eventTask = nil
        interfaceWatchTask?.cancel()
        interfaceWatchTask = nil
        logStore.stopTailing()
        activeHandle = nil

        if removeRunDir {
            if let pidFile = pidFileURL { try? FileManager.default.removeItem(at: pidFile) }
            if let directory = runDir { try? FileManager.default.removeItem(at: directory) }
        }
        if clearSession {
            sessionStore.removeSessionFile()
            currentSession = nil
        }
        pidFileURL = nil
        runDir = nil
        pendingSessionContext = nil
        isTunActive = false
        isGatewayActive = false
        isLaunchdManaged = false
        launchdRestartCount = 0
        isAttachedExternalCore = false
        stopRequested = false
        phase = .idle
    }

    private func append(_ text: String) {
        logStore.append(text, persistTo: lastRunLogURL, stateDir: stateDir)
    }
}
