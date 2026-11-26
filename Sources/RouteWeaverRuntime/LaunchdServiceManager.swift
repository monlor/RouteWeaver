import Darwin
import Foundation
import TunHelperProtocol

struct LaunchdJobStatus: Equatable, Sendable {
    let isLoaded: Bool
    let pid: pid_t?
}

enum LaunchdServiceError: LocalizedError, Equatable {
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
        logFile: URL,
        client: PrivilegedHelperClient = .live
    ) throws {
        _ = client.runLaunchctl(["bootout", userServiceTarget])

        let data = try TunHelperPlists.userAgentPlistData(
            binaryPath: binary.path,
            workDirPath: workDir.path,
            configPath: configPath.path,
            logFilePath: logFile.path
        )
        let dir = userAgentPlistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: userAgentPlistURL, options: .atomic)

        let result = client.runLaunchctl(["bootstrap", userDomainTarget, userAgentPlistURL.path])
        if !result.isSuccess {
            try? FileManager.default.removeItem(at: userAgentPlistURL)
            throw LaunchdServiceError.failed("无法注册 LaunchAgent 系统级保活服务：\(result.failureDetail)")
        }
    }

    static func stopUserAgentSync(client: PrivilegedHelperClient = .live) {
        _ = client.runLaunchctl(["bootout", userServiceTarget])
        try? FileManager.default.removeItem(at: userAgentPlistURL)
    }

    static func stopUserAgentAsync(client: PrivilegedHelperClient = .live) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                stopUserAgentSync(client: client)
                continuation.resume()
            }
        }
    }

    static func queryUserAgentStatus(client: PrivilegedHelperClient = .live) -> LaunchdJobStatus {
        let result = client.runLaunchctl(["print", userServiceTarget])
        guard result.isSuccess else {
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
        useGateway: Bool,
        client: PrivilegedHelperClient = .live
    ) throws {
        let cmd = TunHelperCommand.installDaemon(
            workDir: workDir.path,
            configPath: configPath.path,
            logFilePath: logFile.path,
            pidFilePath: pidFile.path,
            gatewayMode: useGateway
        )
        do {
            _ = try client.execute(cmd)
        } catch PrivilegedHelperError.helperMissing {
            throw LaunchdServiceError.helperMissing
        } catch PrivilegedHelperError.helperOutdated {
            throw LaunchdServiceError.failed("无法注册 TUN LaunchDaemon 系统级保活服务：已安装的辅助组件版本较旧，请重新授权")
        } catch PrivilegedHelperError.executionFailed(_, let detail) {
            throw LaunchdServiceError.failed("无法注册 TUN LaunchDaemon 系统级保活服务：\(detail)")
        }
    }

    static func stopTunDaemonSync(client: PrivilegedHelperClient = .live) -> Bool {
        (try? client.execute(.uninstallDaemon)) != nil
    }

    static func stopTunDaemonAsync(client: PrivilegedHelperClient = .live) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = stopTunDaemonSync(client: client)
                continuation.resume(returning: ok)
            }
        }
    }

    static func queryTunDaemonStatus(client: PrivilegedHelperClient = .live) -> LaunchdJobStatus {
        let result = client.runLaunchctl(["print", tunServiceTarget])
        guard result.isSuccess else {
            return LaunchdJobStatus(isLoaded: false, pid: nil)
        }
        return LaunchdJobStatus(isLoaded: true, pid: parsePid(fromLaunchctlPrint: result.output))
    }

    // MARK: - Parsing

    static func parsePid(fromLaunchctlPrint output: String) -> pid_t? {
        ProcessInspector.parseLaunchctlPid(from: output)
    }
}
