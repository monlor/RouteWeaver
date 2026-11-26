import Darwin
import Foundation

public enum TunHelperCommandError: Error, Equatable, Sendable {
    case missingValue(flag: String)
    case invalidPid
    case unknownArgument(String)
    case invalidPaths(String)
    case invalidUpdateArguments(String)

    public var message: String {
        switch self {
        case .missingValue(let flag):
            return "RouteWeaverTunHelper: missing value for \(flag)"
        case .invalidPid:
            return "RouteWeaverTunHelper: valid pid is required for --stop-pid"
        case .unknownArgument(let arg):
            return "RouteWeaverTunHelper: unknown argument \(arg)"
        case .invalidPaths(let detail):
            return "RouteWeaverTunHelper: \(detail)"
        case .invalidUpdateArguments(let detail):
            return "RouteWeaverTunHelper: \(detail)"
        }
    }
}

public enum TunHelperCommand: Equatable, Sendable {
    case version
    case run(
        workDir: String,
        configPath: String,
        logFilePath: String?,
        pidFilePath: String?,
        gatewayMode: Bool,
        daemonRunMode: Bool
    )
    case installDaemon(
        workDir: String,
        configPath: String,
        logFilePath: String,
        pidFilePath: String,
        gatewayMode: Bool
    )
    case uninstallDaemon
    case stopPid(pid_t)
    case killSwitchEnable(allowLAN: Bool, persistOnBoot: Bool)
    case killSwitchDisable
    case killSwitchRestore
    case killSwitchStatus
    case updateMihomo(
        downloadURL: String,
        expectedSHA256: String?,
        proxyPort: Int?,
        restartDaemon: Bool
    )

    public var arguments: [String] {
        switch self {
        case .version:
            return ["--version"]
        case .run(let workDir, let configPath, let logFilePath, let pidFilePath, let gatewayMode, let daemonRunMode):
            var args: [String] = []
            if daemonRunMode {
                args.append("--daemon-run")
            }
            args.append(contentsOf: ["--work-dir", workDir, "--config", configPath])
            if let logFilePath {
                args.append(contentsOf: ["--log-file", logFilePath])
            }
            if let pidFilePath {
                args.append(contentsOf: ["--pid-file", pidFilePath])
            }
            if gatewayMode {
                args.append("--gateway")
            }
            return args
        case .installDaemon(let workDir, let configPath, let logFilePath, let pidFilePath, let gatewayMode):
            var args = [
                "--install-daemon",
                "--work-dir", workDir,
                "--config", configPath,
                "--log-file", logFilePath,
                "--pid-file", pidFilePath,
            ]
            if gatewayMode {
                args.append("--gateway")
            }
            return args
        case .uninstallDaemon:
            return ["--uninstall-daemon"]
        case .stopPid(let pid):
            return ["--stop-pid", "\(pid)"]
        case .killSwitchEnable(let allowLAN, let persistOnBoot):
            var args = ["--killswitch-enable"]
            if allowLAN {
                args.append("--allow-lan")
            }
            if persistOnBoot {
                args.append("--persist-on-boot")
            }
            return args
        case .killSwitchDisable:
            return ["--killswitch-disable"]
        case .killSwitchRestore:
            return ["--killswitch-restore"]
        case .killSwitchStatus:
            return ["--killswitch-status"]
        case .updateMihomo(let downloadURL, let expectedSHA256, let proxyPort, let restartDaemon):
            var args = ["--update-mihomo-url", downloadURL]
            if let expectedSHA256 {
                args.append(contentsOf: ["--sha256", expectedSHA256.lowercased()])
            }
            if let proxyPort {
                args.append(contentsOf: ["--proxy-port", "\(proxyPort)"])
            }
            if restartDaemon {
                args.append("--restart-daemon")
            }
            return args
        }
    }

    /// Parses CLI arguments (excluding `argv[0]`).
    public static func parse(_ args: [String]) throws -> TunHelperCommand {
        if args.count == 1 && args[0] == "--version" {
            return .version
        }

        var workDir: String?
        var configPath: String?
        var logFilePath: String?
        var pidFilePath: String?
        var stopPid: pid_t?
        var gatewayMode = false
        var installDaemonMode = false
        var uninstallDaemonMode = false
        var daemonRunMode = false
        var killSwitchEnableMode = false
        var killSwitchDisableMode = false
        var killSwitchRestoreMode = false
        var killSwitchStatusMode = false
        var killSwitchAllowLAN = false
        var killSwitchPersistOnBoot = false
        var updateMihomoURL: String?
        var expectedSHA256: String?
        var proxyPort: Int?
        var restartDaemon = false

        var i = 0
        while i < args.count {
            let flag = args[i]
            switch flag {
            case "--work-dir":
                guard i + 1 < args.count else { throw TunHelperCommandError.missingValue(flag: flag) }
                workDir = args[i + 1]
                i += 2
            case "--config":
                guard i + 1 < args.count else { throw TunHelperCommandError.missingValue(flag: flag) }
                configPath = args[i + 1]
                i += 2
            case "--log-file":
                guard i + 1 < args.count else { throw TunHelperCommandError.missingValue(flag: flag) }
                logFilePath = args[i + 1]
                i += 2
            case "--pid-file":
                guard i + 1 < args.count else { throw TunHelperCommandError.missingValue(flag: flag) }
                pidFilePath = args[i + 1]
                i += 2
            case "--gateway":
                gatewayMode = true
                i += 1
            case "--install-daemon":
                installDaemonMode = true
                i += 1
            case "--uninstall-daemon":
                uninstallDaemonMode = true
                i += 1
            case "--daemon-run":
                daemonRunMode = true
                i += 1
            case "--killswitch-enable":
                killSwitchEnableMode = true
                i += 1
            case "--killswitch-disable":
                killSwitchDisableMode = true
                i += 1
            case "--killswitch-restore":
                killSwitchRestoreMode = true
                i += 1
            case "--killswitch-status":
                killSwitchStatusMode = true
                i += 1
            case "--allow-lan":
                killSwitchAllowLAN = true
                i += 1
            case "--persist-on-boot":
                killSwitchPersistOnBoot = true
                i += 1
            case "--stop-pid":
                guard i + 1 < args.count, let parsed = Int32(args[i + 1]), parsed > 1 else {
                    throw TunHelperCommandError.invalidPid
                }
                stopPid = pid_t(parsed)
                i += 2
            case "--update-mihomo-url":
                guard i + 1 < args.count else { throw TunHelperCommandError.missingValue(flag: flag) }
                updateMihomoURL = args[i + 1]
                i += 2
            case "--sha256":
                guard i + 1 < args.count else { throw TunHelperCommandError.missingValue(flag: flag) }
                expectedSHA256 = args[i + 1]
                i += 2
            case "--proxy-port":
                guard i + 1 < args.count else { throw TunHelperCommandError.missingValue(flag: flag) }
                guard let parsed = Int(args[i + 1]), (1...65535).contains(parsed) else {
                    throw TunHelperCommandError.invalidUpdateArguments("invalid --proxy-port (expected 1...65535)")
                }
                proxyPort = parsed
                i += 2
            case "--restart-daemon":
                restartDaemon = true
                i += 1
            default:
                throw TunHelperCommandError.unknownArgument(flag)
            }
        }

        if let updateMihomoURL {
            guard TunHelperPaths.isTrustedMihomoReleaseURL(updateMihomoURL) else {
                throw TunHelperCommandError.invalidUpdateArguments("untrusted Mihomo release URL")
            }
            let normalizedHash: String?
            if let expectedSHA256 {
                guard TunHelperPaths.isValidSHA256Hex(expectedSHA256) else {
                    throw TunHelperCommandError.invalidUpdateArguments("invalid --sha256 hex digest")
                }
                normalizedHash = expectedSHA256.lowercased()
            } else {
                normalizedHash = nil
            }
            return .updateMihomo(
                downloadURL: updateMihomoURL,
                expectedSHA256: normalizedHash,
                proxyPort: proxyPort,
                restartDaemon: restartDaemon
            )
        }

        if killSwitchStatusMode { return .killSwitchStatus }
        if killSwitchEnableMode {
            return .killSwitchEnable(allowLAN: killSwitchAllowLAN, persistOnBoot: killSwitchPersistOnBoot)
        }
        if killSwitchDisableMode { return .killSwitchDisable }
        if killSwitchRestoreMode { return .killSwitchRestore }
        if uninstallDaemonMode { return .uninstallDaemon }

        if installDaemonMode {
            guard let workDir, let configPath, let logFilePath, let pidFilePath,
                  TunHelperPaths.isSafeAbsolutePath(workDir),
                  TunHelperPaths.isSafeAbsolutePath(configPath),
                  TunHelperPaths.isSafeAbsolutePath(logFilePath),
                  TunHelperPaths.isSafeAbsolutePath(pidFilePath) else {
                throw TunHelperCommandError.invalidPaths(
                    "valid absolute --work-dir, --config, --log-file and --pid-file paths are required for --install-daemon"
                )
            }
            return .installDaemon(
                workDir: workDir,
                configPath: configPath,
                logFilePath: logFilePath,
                pidFilePath: pidFilePath,
                gatewayMode: gatewayMode
            )
        }

        if let stopPid {
            return .stopPid(stopPid)
        }

        guard let workDir, let configPath,
              TunHelperPaths.isSafeAbsolutePath(workDir),
              TunHelperPaths.isSafeAbsolutePath(configPath) else {
            throw TunHelperCommandError.invalidPaths("valid absolute --work-dir and --config paths are required")
        }

        if let logFilePath, !TunHelperPaths.isSafeAbsolutePath(logFilePath) {
            throw TunHelperCommandError.invalidPaths("invalid --log-file path")
        }

        if let pidFilePath, !TunHelperPaths.isSafeAbsolutePath(pidFilePath) {
            throw TunHelperCommandError.invalidPaths("invalid --pid-file path")
        }

        return .run(
            workDir: workDir,
            configPath: configPath,
            logFilePath: logFilePath,
            pidFilePath: pidFilePath,
            gatewayMode: gatewayMode,
            daemonRunMode: daemonRunMode
        )
    }
}
