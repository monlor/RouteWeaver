import Darwin
import Foundation
import RoutingCore
import TunHelperProtocol

enum CoreExecutionMode: Equatable, Sendable {
    case launchDaemon(useGateway: Bool)
    case launchAgent
    case tunHelper(useGateway: Bool)
    case directSpawn

    var isTun: Bool {
        switch self {
        case .launchDaemon, .tunHelper: return true
        case .launchAgent, .directSpawn: return false
        }
    }

    var isGateway: Bool {
        switch self {
        case .launchDaemon(let gw), .tunHelper(let gw): return gw
        case .launchAgent, .directSpawn: return false
        }
    }

    var isLaunchdManaged: Bool {
        switch self {
        case .launchDaemon, .launchAgent: return true
        case .tunHelper, .directSpawn: return false
        }
    }
}

struct CoreLaunchRequest: Sendable {
    let mode: CoreExecutionMode
    let binary: URL
    let workDir: URL
    let configPath: URL
    let logFile: URL
    let pidFile: URL?
}

enum CoreRuntimeEvent: Equatable, Sendable {
    case output(String)
    case pidUpdated(pid_t)
    case launchdRestarted(pid: pid_t)
    case exited(code: Int32)
    case detachedExited
}

enum CoreSessionProbeResult: Equatable, Sendable {
    case alive(pid: pid_t)
    case stale
    case launchdLoadedAwaitingPid
}

protocol CoreRuntimeHandle: AnyObject, Sendable {
    var initialPid: pid_t? { get }
    var isLaunchdManaged: Bool { get }
    var events: AsyncStream<CoreRuntimeEvent> { get }

    func stopAsync() async -> Bool
    func stopSyncForExit()
    func detachForExit()
}

protocol CoreRuntimeDriver: Sendable {
    func checkTunPermission(for binary: URL) -> TunPermissionStatus
    func activeInterfaces() -> Set<String>
    func validatePorts(in config: Data, useTun: Bool) -> String?

    func runShortCommand(
        binary: URL,
        workDir: URL,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> (exitCode: Int32, capturedStdout: Data)

    func startCore(_ request: CoreLaunchRequest) throws -> any CoreRuntimeHandle
    func attachToSession(_ session: RuntimeCoreSession) -> any CoreRuntimeHandle
    func probeExistingSession(_ session: RuntimeCoreSession) async -> CoreSessionProbeResult
}

// MARK: - Production macOS Adapter

struct MacOSRuntimeDriver: CoreRuntimeDriver {
    func checkTunPermission(for binary: URL) -> TunPermissionStatus {
        TunHelperManager.status(for: binary)
    }

    func activeInterfaces() -> Set<String> {
        Set(NetworkEnvironment.interfaceNames(requireAddress: true))
    }

    func validatePorts(in config: Data, useTun: Bool) -> String? {
        NetworkEnvironment.validateAvailablePorts(in: config, useTun: useTun)
    }

    func runShortCommand(
        binary: URL,
        workDir: URL,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> (exitCode: Int32, capturedStdout: Data) {
        let p = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.executableURL = binary
        p.currentDirectoryURL = workDir
        p.arguments = arguments
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": workDir.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = outPipe
        p.standardError = errPipe

        final class Collector: @unchecked Sendable {
            private let lock = NSLock()
            var stdout = Data()
            func appendStdout(_ data: Data) {
                lock.lock()
                stdout.append(data)
                lock.unlock()
            }
            func snapshot() -> Data {
                lock.lock()
                defer { lock.unlock() }
                return stdout
            }
        }
        let collector = Collector()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            collector.appendStdout(data)
            onOutput(String(decoding: data, as: UTF8.self))
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            onOutput(String(decoding: data, as: UTF8.self))
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Int32, Data), Error>) in
                final class OnceBox: @unchecked Sendable {
                    private let lock = NSLock()
                    private var done = false
                    func claim() -> Bool {
                        lock.lock()
                        defer { lock.unlock() }
                        if done { return false }
                        done = true
                        return true
                    }
                }
                let once = OnceBox()
                let timeoutWork = DispatchWorkItem {
                    if p.isRunning {
                        p.terminate()
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
                            if p.isRunning { Darwin.kill(p.processIdentifier, SIGKILL) }
                        }
                    }
                }

                p.terminationHandler = { exited in
                    timeoutWork.cancel()
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    let remOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                    if !remOut.isEmpty {
                        collector.appendStdout(remOut)
                        onOutput(String(decoding: remOut, as: UTF8.self))
                    }
                    let remErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                    if !remErr.isEmpty {
                        onOutput(String(decoding: remErr, as: UTF8.self))
                    }
                    if once.claim() {
                        continuation.resume(returning: (exited.terminationStatus, collector.snapshot()))
                    }
                }

                do {
                    try p.run()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWork)
                } catch {
                    timeoutWork.cancel()
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    if once.claim() {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            if p.isRunning {
                p.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
                    if p.isRunning { Darwin.kill(p.processIdentifier, SIGKILL) }
                }
            }
        }
    }

    func startCore(_ request: CoreLaunchRequest) throws -> any CoreRuntimeHandle {
        switch request.mode {
        case .launchDaemon(let useGateway):
            guard let pidFile = request.pidFile else {
                throw NSError(domain: "RouteWeaverRuntime", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing pid file for TUN LaunchDaemon"])
            }
            try? FileManager.default.removeItem(at: pidFile)
            try LaunchdServiceManager.startTunDaemon(
                workDir: request.workDir,
                configPath: request.configPath,
                logFile: request.logFile,
                pidFile: pidFile,
                useGateway: useGateway
            )
            return LaunchdCoreHandle(isTun: true, pidFile: pidFile, initialObservedPid: nil)

        case .launchAgent:
            try LaunchdServiceManager.startUserAgent(
                binary: request.binary,
                workDir: request.workDir,
                configPath: request.configPath,
                logFile: request.logFile
            )
            return LaunchdCoreHandle(isTun: false, pidFile: nil, initialObservedPid: nil)

        case .tunHelper(let useGateway):
            guard let pidFile = request.pidFile else {
                throw NSError(domain: "RouteWeaverRuntime", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing pid file for TUN helper"])
            }
            try? FileManager.default.removeItem(at: pidFile)
            return try TunHelperCoreHandle(
                workDir: request.workDir,
                configPath: request.configPath,
                logFile: request.logFile,
                pidFile: pidFile,
                useGateway: useGateway
            )

        case .directSpawn:
            return try DirectSpawnCoreHandle(
                binary: request.binary,
                workDir: request.workDir,
                configPath: request.configPath,
                logFile: request.logFile
            )
        }
    }

    func attachToSession(_ session: RuntimeCoreSession) -> any CoreRuntimeHandle {
        if session.isLaunchdManaged {
            let pidFile = session.pidFilePath.map { URL(fileURLWithPath: $0) }
            return LaunchdCoreHandle(
                isTun: session.isTun,
                pidFile: pidFile,
                initialObservedPid: session.pid > 1 ? session.pid : nil
            )
        }
        return AttachedCoreHandle(pid: session.pid, isTun: session.isTun)
    }

    func probeExistingSession(_ session: RuntimeCoreSession) async -> CoreSessionProbeResult {
        await Task.detached(priority: .userInitiated) {
            var resolvedPid = session.pid
            if session.isLaunchdManaged {
                let status = session.isTun
                    ? LaunchdServiceManager.queryTunDaemonStatus()
                    : LaunchdServiceManager.queryUserAgentStatus()
                guard status.isLoaded else {
                    return .stale
                }
                if session.isTun {
                    if let pidPath = session.pidFilePath,
                       let parsed = RuntimeSessionStore.readPidFile(at: URL(fileURLWithPath: pidPath)) {
                        resolvedPid = parsed
                    }
                } else if let pid = status.pid, pid > 1 {
                    resolvedPid = pid
                }
                if resolvedPid <= 1 || !RuntimeSessionStore.isMihomoProcess(pid: resolvedPid, expectTunAuthorized: session.isTun) {
                    return .launchdLoadedAwaitingPid
                }
                return .alive(pid: resolvedPid)
            }

            guard resolvedPid > 1,
                  RuntimeSessionStore.isMihomoProcess(pid: resolvedPid, expectTunAuthorized: session.isTun) else {
                return .stale
            }
            return .alive(pid: resolvedPid)
        }.value
    }
}

// MARK: - Concrete macOS Handles

private final class LaunchdCoreHandle: CoreRuntimeHandle, @unchecked Sendable {
    let initialPid: pid_t?
    let isLaunchdManaged = true
    let events: AsyncStream<CoreRuntimeEvent>

    private let isTun: Bool
    private let pidFile: URL?
    private let continuation: AsyncStream<CoreRuntimeEvent>.Continuation
    private var monitorTask: Task<Void, Never>?

    init(isTun: Bool, pidFile: URL?, initialObservedPid: pid_t?) {
        self.isTun = isTun
        self.pidFile = pidFile
        self.initialPid = initialObservedPid
        var cont: AsyncStream<CoreRuntimeEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
        startMonitoring(initialObservedPid: initialObservedPid)
    }

    private func startMonitoring(initialObservedPid: pid_t?) {
        let isTun = self.isTun
        let pidFile = self.pidFile
        let cont = self.continuation
        monitorTask = Task.detached(priority: .utility) {
            var lastPid = initialObservedPid
            var tick = 0
            while !Task.isCancelled {
                let sleepNs: UInt64 = tick < 20 ? 250_000_000 : 1_500_000_000
                try? await Task.sleep(nanoseconds: sleepNs)
                tick += 1
                guard !Task.isCancelled else { return }

                let status = isTun
                    ? LaunchdServiceManager.queryTunDaemonStatus()
                    : LaunchdServiceManager.queryUserAgentStatus()
                if !status.isLoaded {
                    cont.yield(.detachedExited)
                    cont.finish()
                    return
                }

                let candidatePid: pid_t? = isTun
                    ? pidFile.flatMap { RuntimeSessionStore.readPidFile(at: $0) }
                    : status.pid
                if let activePid = candidatePid, RuntimeSessionStore.isProcessAlive(activePid) {
                    if let prev = lastPid {
                        if prev != activePid {
                            lastPid = activePid
                            cont.yield(.launchdRestarted(pid: activePid))
                        }
                    } else {
                        lastPid = activePid
                        cont.yield(.pidUpdated(activePid))
                    }
                }
            }
        }
    }

    func stopAsync() async -> Bool {
        monitorTask?.cancel()
        monitorTask = nil
        if isTun {
            let ok = await LaunchdServiceManager.stopTunDaemonAsync()
            let stillLoaded = await Task.detached(priority: .userInitiated) {
                LaunchdServiceManager.queryTunDaemonStatus().isLoaded
            }.value
            if !ok && stillLoaded {
                startMonitoring(initialObservedPid: initialPid)
                return false
            }
            continuation.finish()
            return true
        } else {
            await LaunchdServiceManager.stopUserAgentAsync()
            continuation.finish()
            return true
        }
    }

    func stopSyncForExit() {
        monitorTask?.cancel()
        monitorTask = nil
        if isTun {
            _ = LaunchdServiceManager.stopTunDaemonSync()
        } else {
            LaunchdServiceManager.stopUserAgentSync()
        }
        continuation.finish()
    }

    func detachForExit() {
        monitorTask?.cancel()
        monitorTask = nil
        continuation.finish()
    }
}

private final class TunHelperCoreHandle: CoreRuntimeHandle, @unchecked Sendable {
    let initialPid: pid_t? = nil
    let isLaunchdManaged = false
    let events: AsyncStream<CoreRuntimeEvent>

    private let process: Process
    private let outPipe: Pipe
    private var inPipe: Pipe?
    private let pidFile: URL
    private let continuation: AsyncStream<CoreRuntimeEvent>.Continuation
    private var pidPollTask: Task<Void, Never>?

    init(workDir: URL, configPath: URL, logFile: URL, pidFile: URL, useGateway: Bool) throws {
        self.pidFile = pidFile
        let p = Process()
        let out = Pipe()
        let input = Pipe()
        var cont: AsyncStream<CoreRuntimeEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
        self.process = p
        self.outPipe = out
        self.inPipe = input

        p.executableURL = TunHelperManager.installedHelperURL
        p.currentDirectoryURL = workDir
        p.arguments = TunHelperCommand.run(
            workDir: workDir.path,
            configPath: configPath.path,
            logFilePath: logFile.path,
            pidFilePath: pidFile.path,
            gatewayMode: useGateway,
            daemonRunMode: false
        ).arguments
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": workDir.path]
        p.standardInput = input
        p.standardOutput = out
        p.standardError = out

        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            cont.yield(.output(String(decoding: data, as: UTF8.self)))
        }
        p.terminationHandler = { [weak self] exited in
            out.fileHandleForReading.readabilityHandler = nil
            self?.closeInputPipe()
            self?.pidPollTask?.cancel()
            cont.yield(.exited(code: exited.terminationStatus))
            cont.finish()
        }

        do {
            try p.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            cont.finish()
            throw error
        }

        pidPollTask = Task.detached(priority: .utility) {
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                if let pid = RuntimeSessionStore.readPidFile(at: pidFile), pid > 1 {
                    cont.yield(.pidUpdated(pid))
                    return
                }
            }
        }
    }

    private func closeInputPipe() {
        if let pipe = inPipe {
            try? pipe.fileHandleForWriting.close()
            inPipe = nil
        }
    }

    private func sendStopSignal() {
        if let pipe = inPipe {
            try? pipe.fileHandleForWriting.write(contentsOf: Data(TunHelperPaths.stdinStopCommand.utf8))
        }
    }

    func stopAsync() async -> Bool {
        pidPollTask?.cancel()
        let fallbackPid = RuntimeSessionStore.readPidFile(at: pidFile)
        sendStopSignal()
        let deadline = Date().addingTimeInterval(3.5)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            if let pid = fallbackPid, pid > 1 {
                _ = await RuntimeSessionStore.stopTunPidAsync(pid)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        return true
    }

    func stopSyncForExit() {
        pidPollTask?.cancel()
        let fallbackPid = RuntimeSessionStore.readPidFile(at: pidFile)
        sendStopSignal()
        let deadline = Date().addingTimeInterval(2.5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning, let pid = fallbackPid, pid > 1 {
            _ = RuntimeSessionStore.stopTunPidSync(pid)
        }
        continuation.finish()
    }

    func detachForExit() {
        pidPollTask?.cancel()
        process.terminationHandler = nil
        outPipe.fileHandleForReading.readabilityHandler = nil
        closeInputPipe()
        continuation.finish()
    }
}

private final class DirectSpawnCoreHandle: CoreRuntimeHandle, @unchecked Sendable {
    let initialPid: pid_t?
    let isLaunchdManaged = false
    let events: AsyncStream<CoreRuntimeEvent>

    private let childPid: pid_t
    private let continuation: AsyncStream<CoreRuntimeEvent>.Continuation
    private var exitSource: DispatchSourceProcess?

    init(binary: URL, workDir: URL, configPath: URL, logFile: URL) throws {
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

        let argvStrings = [binary.path, "-d", workDir.path, "-f", configPath.path]
        let envStrings = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=\(workDir.path)"]
        let cArgv: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) } + [nil]
        let cEnv: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
        defer {
            for ptr in cArgv { free(ptr) }
            for ptr in cEnv { free(ptr) }
        }

        var pid: pid_t = 0
        let spawnErr = posix_spawn(&pid, binary.path, &fileActions, &spawnAttr, cArgv, cEnv)
        guard spawnErr == 0, pid > 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(spawnErr))
        }

        self.childPid = pid
        self.initialPid = pid
        var cont: AsyncStream<CoreRuntimeEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            var waitStatus: Int32 = 0
            _ = waitpid(pid, &waitStatus, WNOHANG)
            let sig = waitStatus & 0x7f
            let code: Int32 = (sig == 0) ? ((waitStatus >> 8) & 0xff) : (128 + sig)
            self?.exitSource?.cancel()
            self?.exitSource = nil
            cont.yield(.exited(code: code))
            cont.finish()
        }
        source.resume()
        self.exitSource = source
    }

    func stopAsync() async -> Bool {
        await RuntimeSessionStore.stopUserPidAsync(childPid)
        exitSource?.cancel()
        exitSource = nil
        continuation.finish()
        return true
    }

    func stopSyncForExit() {
        exitSource?.cancel()
        exitSource = nil
        RuntimeSessionStore.stopUserPidSync(childPid)
        continuation.finish()
    }

    func detachForExit() {
        exitSource?.cancel()
        exitSource = nil
        continuation.finish()
    }
}

private final class AttachedCoreHandle: CoreRuntimeHandle, @unchecked Sendable {
    let initialPid: pid_t?
    let isLaunchdManaged = false
    let events: AsyncStream<CoreRuntimeEvent>

    private let pid: pid_t
    private let isTun: Bool
    private let continuation: AsyncStream<CoreRuntimeEvent>.Continuation
    private var watchTask: Task<Void, Never>?

    init(pid: pid_t, isTun: Bool) {
        self.pid = pid
        self.initialPid = pid
        self.isTun = isTun
        var cont: AsyncStream<CoreRuntimeEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
        startWatching()
    }

    private func startWatching() {
        let pid = self.pid
        let cont = self.continuation
        watchTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                if !RuntimeSessionStore.isProcessAlive(pid) {
                    cont.yield(.detachedExited)
                    cont.finish()
                    return
                }
            }
        }
    }

    func stopAsync() async -> Bool {
        watchTask?.cancel()
        watchTask = nil
        if isTun {
            let ok = await RuntimeSessionStore.stopTunPidAsync(pid)
            if !ok && RuntimeSessionStore.isProcessAlive(pid) {
                startWatching()
                return false
            }
            continuation.finish()
            return true
        } else {
            await RuntimeSessionStore.stopUserPidAsync(pid)
            continuation.finish()
            return true
        }
    }

    func stopSyncForExit() {
        watchTask?.cancel()
        watchTask = nil
        if isTun {
            _ = RuntimeSessionStore.stopTunPidSync(pid)
        } else {
            RuntimeSessionStore.stopUserPidSync(pid)
        }
        continuation.finish()
    }

    func detachForExit() {
        watchTask?.cancel()
        watchTask = nil
        continuation.finish()
    }
}
