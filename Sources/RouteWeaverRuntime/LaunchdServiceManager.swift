import Darwin
import Foundation
import TunHelperProtocol

struct LaunchdJobStatus: Equatable, Sendable {
    let isLoaded: Bool
    let pid: pid_t?
}

enum LaunchdServiceError: LocalizedError {
    case helperMissing
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            return "未找到已授权的 RouteWeaverTunHelper，请先在「设置与日志」中重新授权 TUN 权限。"
        case .failed(let message):
            return message
        }
    }
}

enum LaunchdServiceManager {
    static let userAgentLabel = TunHelperPaths.userAgentLabel
    static let tunDaemonLabel = TunHelperPaths.tunDaemonLabel
    static let tunDaemonPlistPath = TunHelperPaths.tunDaemonPlistPath

    static var userAgentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(userAgentLabel).plist")
    }

    static var userDomainTarget: String {
        "gui/\(getuid())"
    }

    static var userServiceTarget: String {
        "\(userDomainTarget)/\(userAgentLabel)"
    }

    static var tunServiceTarget: String {
        TunHelperPaths.tunServiceTarget
    }

    // MARK: - User LaunchAgent (Non-TUN Mode)

    static func startUserAgent(
        binary: URL,
        workDir: URL,
        configPath: URL,
        logFile: URL
    ) throws {
        _ = runLaunchctl(["bootout", userServiceTarget])

        let data = try TunHelperPlists.userAgentPlistData(
            binaryPath: binary.path,
            workDirPath: workDir.path,
            configPath: configPath.path,
            logFilePath: logFile.path
        )
        let dir = userAgentPlistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: userAgentPlistURL, options: .atomic)

        let result = runLaunchctl(["bootstrap", userDomainTarget, userAgentPlistURL.path])
        if result.status != 0 {
            try? FileManager.default.removeItem(at: userAgentPlistURL)
            let detail = result.output.isEmpty ? "退出码 \(result.status)" : result.output
            throw LaunchdServiceError.failed("无法注册 LaunchAgent 系统级保活服务：\(detail)")
        }
    }

    static func stopUserAgentSync() {
        _ = runLaunchctl(["bootout", userServiceTarget])
        try? FileManager.default.removeItem(at: userAgentPlistURL)
    }

    static func stopUserAgentAsync() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                stopUserAgentSync()
                continuation.resume()
            }
        }
    }

    static func queryUserAgentStatus() -> LaunchdJobStatus {
        let result = runLaunchctl(["print", userServiceTarget])
        guard result.status == 0 else {
            return LaunchdJobStatus(isLoaded: false, pid: nil)
        }
        return LaunchdJobStatus(isLoaded: true, pid: parsePid(fromLaunchctlPrint: result.output))
    }

    // MARK: - Root LaunchDaemon (TUN / Gateway Mode via TunHelper)

    static func startTunDaemon(
        workDir: URL,
        configPath: URL,
        logFile: URL,
        pidFile: URL,
        useGateway: Bool
    ) throws {
        let helperURL = TunHelperManager.installedHelperURL
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw LaunchdServiceError.helperMissing
        }

        let cmd = TunHelperCommand.installDaemon(
            workDir: workDir.path,
            configPath: configPath.path,
            logFilePath: logFile.path,
            pidFilePath: pidFile.path,
            gatewayMode: useGateway
        )
        let result = runExecutable(helperURL, arguments: cmd.arguments)
        if result.status != 0 {
            let detail = result.output.isEmpty ? "退出码 \(result.status)" : result.output
            throw LaunchdServiceError.failed("无法注册 TUN LaunchDaemon 系统级保活服务：\(detail)")
        }
    }

    static func stopTunDaemonSync() -> Bool {
        let helperURL = TunHelperManager.installedHelperURL
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            return false
        }
        let result = runExecutable(helperURL, arguments: TunHelperCommand.uninstallDaemon.arguments)
        return result.status == 0
    }

    static func stopTunDaemonAsync() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = stopTunDaemonSync()
                continuation.resume(returning: ok)
            }
        }
    }

    static func queryTunDaemonStatus() -> LaunchdJobStatus {
        let result = runLaunchctl(["print", tunServiceTarget])
        guard result.status == 0 else {
            return LaunchdJobStatus(isLoaded: false, pid: nil)
        }
        return LaunchdJobStatus(isLoaded: true, pid: parsePid(fromLaunchctlPrint: result.output))
    }

    // MARK: - Parsing & Subprocess Helpers

    static func parsePid(fromLaunchctlPrint output: String) -> pid_t? {
        ProcessInspector.parseLaunchctlPid(from: output)
    }

    private static func runLaunchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        runExecutable(URL(fileURLWithPath: "/bin/launchctl"), arguments: arguments)
    }

    private static func runExecutable(_ executable: URL, arguments: [String]) -> (status: Int32, output: String) {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = executable
        proc.arguments = arguments
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return (proc.terminationStatus, text)
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}
