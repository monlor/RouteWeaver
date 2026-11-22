import Combine
import Darwin
import Foundation
import RoutingCore

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
    @Published private(set) var isAttachedExternalCore = false

    let logStore = EngineLogStore()

    var isRunning: Bool { phase == .running }
    var isBusy: Bool { phase.isBusy }

    private let stateDir: URL
    private let sessionStore: RuntimeSessionStore

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

    private var process: Process?
    private var attachedPid: pid_t?
    private var spawnedCorePid: pid_t?
    private var processExitSource: DispatchSourceProcess?
    private var runDir: URL?
    private var pidFileURL: URL?
    private var output: Pipe?
    private var inputPipe: Pipe?
    private var runningWithTun = false
    private var runningWithGateway = false
    private var watchTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?
    private var pidPollTask: Task<Void, Never>?
    private var generation = UUID()
    private var stopRequested = false
    private var pendingSessionContext: EngineSessionContext?
    private var currentSession: RuntimeCoreSession?

    init(stateDir: URL? = nil) {
        let dir = stateDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RouteWeaver/Mihomo", isDirectory: true)
        self.stateDir = dir
        self.sessionStore = RuntimeSessionStore(stateDir: dir)
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
            preloadResources: preloadResources,
            subscriptionCacheDirectory: subscriptionCacheDirectory,
            startAfterValidation: true
        )
    }

    func loadRuntimeSession() -> RuntimeCoreSession? {
        sessionStore.load()
    }

    func clearStaleSession(_ session: RuntimeCoreSession?) {
        sessionStore.clearStale(session)
    }

    func updateRuntimeSession(trackedGroups: [String], runningProfile: RoutingProfile) {
        guard var session = currentSession else { return }
        session.trackedGroups = trackedGroups
        session.runningProfile = runningProfile
        currentSession = session
        sessionStore.save(session)
    }

    func attachToRunningCore(session: RuntimeCoreSession) {
        guard process == nil, attachedPid == nil, spawnedCorePid == nil, !isBusy else { return }
        lastError = nil
        stopRequested = false
        let token = UUID()
        generation = token
        runningWithTun = session.isTun
        runningWithGateway = session.isGateway
        isTunActive = session.isTun
        isGatewayActive = session.isGateway
        isAttachedExternalCore = true
        attachedPid = session.pid
        runDir = URL(fileURLWithPath: session.runDirectoryPath, isDirectory: true)
        pidFileURL = session.pidFilePath.map { URL(fileURLWithPath: $0) }
        currentSession = session
        phase = .running

        let logURL = URL(fileURLWithPath: session.logFilePath)
        logStore.loadExistingTail(from: logURL)
        let modeSuffix = session.isGateway ? " · 局域网网关模式" : (session.isTun ? " · TUN 模式" : "")
        logStore.appendMemoryOnly("已自动接管后台运行中的 Mihomo 核心（PID \(session.pid)\(modeSuffix)）。\n")
        startLogTail(at: logURL, token: token)
        monitorAttachedProcess(pid: session.pid, interfaces: session.requiredInterfaces)
    }

    func stop() {
        if phase == .preparingResources, !stopRequested {
            stopRequested = true
            preloadTask?.cancel()
            preloadTask = nil
            append("已取消启动前资源预下载。\n")
            cleanup()
            return
        }

        if let process, process.isRunning {
            guard !stopRequested else { return }
            stopRequested = true
            phase = .stopping
            append(runningWithGateway ? "正在停止局域网网关并恢复系统路由、DNS 与 IP 转发…\n" : (runningWithTun ? "正在停止 TUN 内核并恢复系统路由与 DNS…\n" : "正在停止内核…\n"))
            if runningWithTun {
                signalTunHelperStop()
                let token = generation
                let fallbackPid = currentSession?.pid ?? pidFileURL.flatMap { RuntimeSessionStore.readPidFile(at: $0) }
                timeoutTask?.cancel()
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    guard !Task.isCancelled, let self, self.generation == token, self.stopRequested else { return }
                    if let pid = fallbackPid, pid > 1 {
                        _ = await RuntimeSessionStore.stopTunPidAsync(pid)
                    }
                    if process.isRunning {
                        Darwin.kill(process.processIdentifier, SIGKILL)
                    }
                }
            } else {
                process.terminate()
                let token = generation
                timeoutTask?.cancel()
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled, let self, self.generation == token,
                          self.process === process, process.isRunning, self.stopRequested else { return }
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
            return
        }

        if let pid = spawnedCorePid ?? attachedPid, !stopRequested {
            stopRequested = true
            phase = .stopping
            watchTask?.cancel()
            let wasTun = runningWithTun
            let wasGateway = runningWithGateway
            let isDirectSpawn = (spawnedCorePid != nil)
            let token = generation
            logStore.appendMemoryOnly(wasGateway ? "正在停止后台局域网网关并恢复系统路由、DNS 与 IP 转发…\n" : (wasTun ? "正在停止后台 TUN 内核并恢复系统路由与 DNS…\n" : (isDirectSpawn ? "正在停止内核…\n" : "正在停止后台内核…\n")))
            Task { [weak self] in
                if wasTun {
                    let ok = await RuntimeSessionStore.stopTunPidAsync(pid)
                    await MainActor.run {
                        guard let self, self.generation == token else { return }
                        if !ok && RuntimeSessionStore.isProcessAlive(pid) {
                            self.lastError = "无法停止后台 TUN 核心（PID \(pid)），请确认已在「设置与日志」中重新授权 TUN 权限。"
                            self.logStore.appendMemoryOnly(self.lastError! + "\n")
                            self.stopRequested = false
                            self.phase = .running
                            self.monitorAttachedProcess(pid: pid, interfaces: self.currentSession?.requiredInterfaces ?? [])
                        } else {
                            self.logStore.appendMemoryOnly("后台 TUN 核心已停止。\n")
                            self.cleanup()
                        }
                    }
                } else {
                    await RuntimeSessionStore.stopUserPidAsync(pid)
                    await MainActor.run {
                        guard let self, self.generation == token else { return }
                        self.logStore.appendMemoryOnly(isDirectSpawn ? "已停止。\n" : "后台核心已停止。\n")
                        self.cleanup()
                    }
                }
            }
        }
    }

    /// Leaves the running Mihomo core alive in the background when the RouteWeaver UI exits.
    func detachForAppExit() {
        watchTask?.cancel()
        watchTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        preloadTask?.cancel()
        preloadTask = nil
        logStore.stopTailing()
        pidPollTask?.cancel()
        pidPollTask = nil

        if let pidFile = pidFileURL, let pid = RuntimeSessionStore.readPidFile(at: pidFile), pid > 1,
           var session = currentSession, session.pid <= 1 {
            session.pid = pid
            currentSession = session
            sessionStore.save(session)
        }

        // Prevent terminationHandler / processExitSource callbacks during app shutdown and close stdin so TUN helper enters detached mode.
        processExitSource?.cancel()
        processExitSource = nil
        process?.terminationHandler = nil
        output?.fileHandleForReading.readabilityHandler = nil
        output = nil
        if let pipe = inputPipe {
            try? pipe.fileHandleForWriting.close()
            inputPipe = nil
        }
    }

    func terminateForAppExit() {
        watchTask?.cancel()
        timeoutTask?.cancel()
        preloadTask?.cancel()
        logStore.stopTailing()
        pidPollTask?.cancel()
        processExitSource?.cancel()
        processExitSource = nil

        if let process, process.isRunning {
            if runningWithTun {
                let fallbackPid = currentSession?.pid ?? pidFileURL.flatMap { RuntimeSessionStore.readPidFile(at: $0) }
                signalTunHelperStop()
                let deadline = Date().addingTimeInterval(2.5)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning, let pid = fallbackPid, pid > 1 {
                    _ = RuntimeSessionStore.stopTunPidSync(pid)
                }
            } else {
                process.terminate()
                let deadline = Date().addingTimeInterval(2.0)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
        } else if let pid = spawnedCorePid ?? attachedPid {
            if runningWithTun {
                _ = RuntimeSessionStore.stopTunPidSync(pid)
            } else {
                RuntimeSessionStore.stopUserPidSync(pid)
            }
        }

        if let pidFile = pidFileURL { try? FileManager.default.removeItem(at: pidFile) }
        if let directory = runDir { try? FileManager.default.removeItem(at: directory) }
        sessionStore.removeSessionFile()
    }

    // MARK: - Startup Pipeline

    private func signalTunHelperStop() {
        if let pipe = inputPipe {
            let stopCmd = Data("stop\n".utf8)
            try? pipe.fileHandleForWriting.write(contentsOf: stopCmd)
        }
    }

    private func begin(
        config: Data,
        binary: URL,
        interfaces: [String],
        useTun: Bool,
        useGateway: Bool,
        preloadResources: [PreloadResourceItem],
        subscriptionCacheDirectory: URL,
        startAfterValidation: Bool
    ) {
        guard process == nil, attachedPid == nil, spawnedCorePid == nil, !isBusy else { return }
        lastError = nil
        guard binary.isFileURL, FileManager.default.isExecutableFile(atPath: binary.path) else {
            let msg = "请选择可执行的本地 Mihomo 内核。"
            lastError = msg
            append(msg + "\n")
            return
        }
        if startAfterValidation && useTun {
            let tunStatus = TunHelperManager.status(for: binary)
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
        do {
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
            phase = .checkingVersion
            stopRequested = false
            append("正在检查 Mihomo 内核版本…\n")
            let versionPath = directory.appendingPathComponent("engine-version.txt")
            guard fm.createFile(atPath: versionPath.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let versionOutput = try FileHandle(forWritingTo: versionPath)
            defer { try? versionOutput.close() }
            try launch(
                binary: binary, config: configPath, test: true,
                argumentsOverride: ["-v"], captureOutput: versionOutput
            ) { [weak self] code in
                guard let self else { return }
                guard !self.stopRequested, code == 0, self.supportsRequiredVersion(at: versionPath) else {
                    let msg = self.stopRequested ? "已停止。" : "无法确认内核版本。请使用官方 Mihomo v1.19.27 或更新稳定版。"
                    if !self.stopRequested { self.lastError = msg }
                    self.append(msg + "\n")
                    self.cleanup()
                    return
                }
                self.phase = .validating
                self.append("正在用 Mihomo 校验配置…\n")
                self.runValidation(
                    config: config,
                    configPath: configPath,
                    binary: binary,
                    interfaces: interfaces,
                    useTun: useTun,
                    useGateway: useGateway,
                    preloadResources: preloadResources,
                    subscriptionCacheDirectory: subscriptionCacheDirectory,
                    startAfterValidation: startAfterValidation
                )
            }
        } catch {
            let msg = "无法校验配置：\(error.localizedDescription)"
            lastError = msg
            append(msg + "\n")
            cleanup()
        }
    }

    private func supportsRequiredVersion(at path: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: path) else { return false }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: 8_192) else { return false }
        return MihomoConfig.supportsVersionOutput(String(decoding: chunk, as: UTF8.self))
    }

    private func runValidation(
        config: Data,
        configPath: URL,
        binary: URL,
        interfaces: [String],
        useTun: Bool,
        useGateway: Bool,
        preloadResources: [PreloadResourceItem],
        subscriptionCacheDirectory: URL,
        startAfterValidation: Bool
    ) {
        do {
            try launch(binary: binary, config: configPath, test: true) { [weak self] code in
                guard let self else { return }
                guard !self.stopRequested, code == 0 else {
                    let msg = self.stopRequested ? "已停止。" : "Mihomo 校验失败（退出码 \(code)）。请检查运行日志。"
                    if !self.stopRequested { self.lastError = msg }
                    self.append(msg + "\n")
                    self.cleanup()
                    return
                }
                self.append("Mihomo 配置校验通过。\n")
                guard startAfterValidation, self.checkInterfaces(interfaces), self.checkPorts(config, useTun: useTun) else {
                    self.cleanup()
                    return
                }
                let targetDir = useTun ? self.tunWorkDir : self.workDir
                let scan = ResourcePreloader.scanMissing(
                    preloadResources,
                    in: targetDir,
                    syncFrom: useTun ? self.workDir : nil,
                    subscriptionCacheDirectory: subscriptionCacheDirectory
                )
                if scan.seededFromSubscriptionCache > 0 {
                    self.append("已从本地订阅缓存同步 \(scan.seededFromSubscriptionCache) 项节点数据。\n")
                }
                if scan.missing.isEmpty {
                    self.launchEngineProcess(configPath: configPath, binary: binary, interfaces: interfaces, useTun: useTun, useGateway: useGateway)
                } else {
                    self.phase = .preparingResources
                    self.append("启动前预下载缺失资源（共 \(scan.missing.count) 项）…\n")
                    let token = self.generation
                    self.preloadTask?.cancel()
                    self.preloadTask = Task { [weak self] in
                        guard let self else { return }
                        let report = await ResourcePreloader.download(
                            scan.missing,
                            to: targetDir,
                            subscriptionCacheDirectory: subscriptionCacheDirectory
                        )
                        guard !Task.isCancelled, self.generation == token, !self.stopRequested else { return }
                        self.preloadTask = nil
                        if report.downloaded > 0 || report.failed > 0 || report.skippedReadOnly > 0 {
                            var parts: [String] = []
                            if report.downloaded > 0 { parts.append("成功 \(report.downloaded) 项") }
                            if report.failed > 0 { parts.append("失败 \(report.failed) 项（将由内核重试）") }
                            if report.skippedReadOnly > 0 { parts.append("\(report.skippedReadOnly) 项目录由 root 管理（由内核拉取）") }
                            self.append("启动前预下载结果：\(parts.joined(separator: "，"))。\n")
                        }
                        for detail in report.failureNotes.prefix(5) {
                            self.append("  · \(detail)\n")
                        }
                        self.launchEngineProcess(configPath: configPath, binary: binary, interfaces: interfaces, useTun: useTun, useGateway: useGateway)
                    }
                }
            }
        } catch {
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
        useGateway: Bool
    ) {
        phase = .starting
        do {
            let logURL = lastRunLogURL
            logStore.prepareSharedLogFile(at: logURL, stateDir: stateDir)
            let runDirectoryPath = runDir?.path ?? configPath.deletingLastPathComponent().path

            if useTun {
                let pidFile = (runDir ?? configPath.deletingLastPathComponent()).appendingPathComponent("mihomo.pid")
                try? FileManager.default.removeItem(at: pidFile)
                pidFileURL = pidFile
                try launchTunHelper(config: configPath, logFile: logURL, pidFile: pidFile, useGateway: useGateway) { [weak self] code in
                    guard let self else { return }
                    if !self.stopRequested {
                        self.lastError = useGateway
                            ? "Mihomo 局域网网关模式已意外退出（退出码 \(code)）。请检查 53 端口是否被占用或查看日志。"
                            : "Mihomo TUN 模式已意外退出（退出码 \(code)）。"
                    }
                    self.logStore.appendMemoryOnly(self.stopRequested
                        ? (useGateway ? "局域网网关核心已停止。\n" : "TUN 核心已停止。\n")
                        : (useGateway ? "Mihomo 局域网网关模式已退出（退出码 \(code)）。\n" : "Mihomo TUN 模式已退出（退出码 \(code)）。\n"))
                    self.cleanup()
                }
                runningWithTun = true
                runningWithGateway = useGateway
                isTunActive = true
                isGatewayActive = useGateway
                isAttachedExternalCore = false
                logStore.appendMemoryOnly(useGateway
                    ? "内核进程已以局域网网关模式启动（TUN + 系统 DNS 接管 + DNS 0.0.0.0:53 + IP 转发）。\n"
                    : "内核进程已以 TUN 透明代理模式启动（已自动接管系统 DNS 防止泄漏）。\n")
                if let ctx = pendingSessionContext {
                    let initialSession = RuntimeCoreSession(
                        pid: 0,
                        isTun: true,
                        isGateway: useGateway,
                        controllerPort: ctx.controllerPort,
                        secret: ctx.secret,
                        trackedGroups: ctx.trackedGroups,
                        runDirectoryPath: runDirectoryPath,
                        configPath: configPath.path,
                        logFilePath: logURL.path,
                        pidFilePath: pidFile.path,
                        requiredInterfaces: interfaces,
                        startedAt: Date(),
                        runningProfile: ctx.runningProfile
                    )
                    currentSession = initialSession
                    sessionStore.save(initialSession)
                    pollTunPidFile(pidFile, token: generation)
                }
            } else {
                let launchedPid = try launchCoreProcess(binary: binary, config: configPath, logFile: logURL) { [weak self] code in
                    guard let self else { return }
                    if !self.stopRequested {
                        self.lastError = "Mihomo 已意外退出（退出码 \(code)）。"
                    }
                    self.logStore.appendMemoryOnly(self.stopRequested ? "已停止。\n" : "Mihomo 已退出（退出码 \(code)）。\n")
                    self.cleanup()
                }
                runningWithTun = false
                runningWithGateway = false
                isTunActive = false
                isGatewayActive = false
                isAttachedExternalCore = false
                logStore.appendMemoryOnly("内核进程已启动。\n")
                if let ctx = pendingSessionContext {
                    let session = RuntimeCoreSession(
                        pid: launchedPid,
                        isTun: false,
                        controllerPort: ctx.controllerPort,
                        secret: ctx.secret,
                        trackedGroups: ctx.trackedGroups,
                        runDirectoryPath: runDirectoryPath,
                        configPath: configPath.path,
                        logFilePath: logURL.path,
                        pidFilePath: nil,
                        requiredInterfaces: interfaces,
                        startedAt: Date(),
                        runningProfile: ctx.runningProfile
                    )
                    currentSession = session
                    sessionStore.save(session)
                }
            }
            pendingSessionContext = nil
            phase = .running
            startLogTail(at: logURL, token: generation)
            if !interfaces.isEmpty {
                monitor(interfaces)
            }
        } catch {
            let msg = "内核启动失败：\(error.localizedDescription)"
            lastError = msg
            append(msg + "\n")
            cleanup()
        }
    }

    // MARK: - Preflight & Monitors

    private func checkInterfaces(_ names: [String]) -> Bool {
        guard !names.isEmpty else { return true }
        let active = Set(NetworkEnvironment.interfaceNames(requireAddress: true))
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
        if let errorMessage = NetworkEnvironment.validateAvailablePorts(in: config, useTun: useTun) {
            lastError = errorMessage
            append(errorMessage + "\n")
            return false
        }
        return true
    }

    private func monitor(_ names: [String]) {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, let self, self.isRunning else { return }
                if !self.checkInterfaces(names) {
                    self.stop()
                    return
                }
            }
        }
    }

    private func monitorAttachedProcess(pid: pid_t, interfaces: [String]) {
        watchTask?.cancel()
        let token = generation
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, let self, self.generation == token, self.isRunning else { return }
                if !RuntimeSessionStore.isProcessAlive(pid) {
                    if !self.stopRequested {
                        self.logStore.appendMemoryOnly("后台 Mihomo 核心已退出。\n")
                    }
                    self.cleanup()
                    return
                }
                if !interfaces.isEmpty && !self.checkInterfaces(interfaces) {
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

    private func pollTunPidFile(_ pidFile: URL, token: UUID) {
        pidPollTask?.cancel()
        pidPollTask = Task { [weak self] in
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                if let pid = RuntimeSessionStore.readPidFile(at: pidFile), pid > 1 {
                    if var session = self.currentSession {
                        session.pid = pid
                        self.currentSession = session
                        self.sessionStore.save(session)
                    }
                    return
                }
            }
        }
    }

    // MARK: - Process Spawning

    private func launch(
        binary: URL, config: URL, test: Bool, argumentsOverride: [String]? = nil,
        captureOutput: FileHandle? = nil, finished: @escaping @MainActor (Int32) -> Void
    ) throws {
        let p = Process()
        let pipe = Pipe()
        let token = UUID()
        generation = token
        p.executableURL = binary
        p.currentDirectoryURL = workDir
        p.arguments = argumentsOverride ?? ((test ? ["-t"] : []) + ["-d", workDir.path, "-f", config.path])
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": workDir.path]
        p.standardInput = FileHandle.nullDevice
        if let captureOutput {
            p.standardOutput = captureOutput
        } else {
            p.standardOutput = pipe
        }
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.append(chunk)
            }
        }
        p.terminationHandler = { [weak self] exited in
            let code = exited.terminationStatus
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.timeoutTask?.cancel()
                self.output?.fileHandleForReading.readabilityHandler = nil
                self.output = nil
                self.process = nil
                finished(code)
            }
        }
        do {
            try p.run()
            process = p
            output = pipe
            if test {
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: argumentsOverride == nil ? 90_000_000_000 : 5_000_000_000)
                    guard !Task.isCancelled, let self, self.generation == token, p.isRunning else { return }
                    self.append(argumentsOverride == nil
                        ? "90 秒内未完成校验，已请求停止。请检查配置数据下载和网络。\n"
                        : "读取内核版本超时，已请求停止。\n")
                    self.stop()
                }
            }
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
    }

    private func launchCoreProcess(
        binary: URL,
        config: URL,
        logFile: URL,
        finished: @escaping @MainActor (Int32) -> Void
    ) throws -> pid_t {
        let token = UUID()
        generation = token

        // Spawn Mihomo in its own process group (POSIX_SPAWN_SETPGROUP) with stdout/stderr
        // redirected to the log file, so restarting or stopping RouteWeaver never kills Mihomo.
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, logFile.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&fileActions, STDOUT_FILENO, STDERR_FILENO)

        var spawnAttr: posix_spawnattr_t?
        posix_spawnattr_init(&spawnAttr)
        defer { posix_spawnattr_destroy(&spawnAttr) }
        posix_spawnattr_setpgroup(&spawnAttr, 0)
        posix_spawnattr_setflags(&spawnAttr, Int16(POSIX_SPAWN_SETPGROUP))

        let argvStrings = [binary.path, "-d", workDir.path, "-f", config.path]
        let envStrings = [
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME=\(workDir.path)",
        ]
        let cArgv: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) } + [nil]
        let cEnv: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
        defer {
            for ptr in cArgv { free(ptr) }
            for ptr in cEnv { free(ptr) }
        }

        var childPid: pid_t = 0
        let spawnErr = posix_spawn(&childPid, binary.path, &fileActions, &spawnAttr, cArgv, cEnv)
        guard spawnErr == 0, childPid > 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(spawnErr))
        }

        spawnedCorePid = childPid
        processExitSource?.cancel()
        let source = DispatchSource.makeProcessSource(identifier: childPid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            var waitStatus: Int32 = 0
            _ = waitpid(childPid, &waitStatus, WNOHANG)
            let sig = waitStatus & 0x7f
            let code: Int32 = (sig == 0) ? ((waitStatus >> 8) & 0xff) : (128 + sig)
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.processExitSource?.cancel()
                self.processExitSource = nil
                self.spawnedCorePid = nil
                self.timeoutTask?.cancel()
                finished(code)
            }
        }
        source.resume()
        processExitSource = source
        return childPid
    }

    private func launchTunHelper(
        config: URL,
        logFile: URL,
        pidFile: URL,
        useGateway: Bool,
        finished: @escaping @MainActor (Int32) -> Void
    ) throws {
        let p = Process()
        let outPipe = Pipe()
        let inPipe = Pipe()
        let token = UUID()
        generation = token
        p.executableURL = TunHelperManager.installedHelperURL
        p.currentDirectoryURL = tunWorkDir
        var helperArgs = [
            "--work-dir", tunWorkDir.path,
            "--config", config.path,
            "--log-file", logFile.path,
            "--pid-file", pidFile.path,
        ]
        if useGateway {
            helperArgs.append("--gateway")
        }
        p.arguments = helperArgs
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": tunWorkDir.path]
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = outPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.logStore.appendMemoryOnly(chunk)
            }
        }
        p.terminationHandler = { [weak self] exited in
            let code = exited.terminationStatus
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.timeoutTask?.cancel()
                self.output?.fileHandleForReading.readabilityHandler = nil
                self.output = nil
                if let pipe = self.inputPipe {
                    try? pipe.fileHandleForWriting.close()
                    self.inputPipe = nil
                }
                self.process = nil
                finished(code)
            }
        }
        do {
            try p.run()
            process = p
            output = outPipe
            inputPipe = inPipe
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            try? inPipe.fileHandleForWriting.close()
            throw error
        }
    }

    private func cleanup(removeRunDir: Bool = true, clearSession: Bool = true) {
        watchTask?.cancel()
        watchTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        preloadTask?.cancel()
        preloadTask = nil
        logStore.stopTailing()
        pidPollTask?.cancel()
        pidPollTask = nil
        processExitSource?.cancel()
        processExitSource = nil
        if let pipe = inputPipe {
            try? pipe.fileHandleForWriting.close()
            inputPipe = nil
        }
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
        attachedPid = nil
        spawnedCorePid = nil
        pendingSessionContext = nil
        runningWithTun = false
        runningWithGateway = false
        isTunActive = false
        isGatewayActive = false
        isAttachedExternalCore = false
        stopRequested = false
        phase = .idle
    }

    private func append(_ text: String) {
        logStore.append(text, persistTo: lastRunLogURL, stateDir: stateDir)
    }
}
