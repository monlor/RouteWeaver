import Foundation
import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
    case enabled
    case enabledViaLaunchAgent
    case requiresApproval
    case disabled

    var isEnabled: Bool {
        switch self {
        case .enabled, .enabledViaLaunchAgent, .requiresApproval:
            return true
        case .disabled:
            return false
        }
    }

    var title: String {
        switch self {
        case .enabled:
            return "已开启"
        case .enabledViaLaunchAgent:
            return "已开启（LaunchAgent）"
        case .requiresApproval:
            return "需在系统设置允许"
        case .disabled:
            return "未开启"
        }
    }

    var detail: String {
        switch self {
        case .enabled:
            return "登录 macOS 后会自动启动 RouteWeaver。"
        case .enabledViaLaunchAgent:
            return "已通过当前用户 LaunchAgent 配置开机自启动。"
        case .requiresApproval:
            return "已注册登录项，请在「系统设置 → 通用 → 登录项与扩展」中允许 RouteWeaver。"
        case .disabled:
            return "开启后登录 macOS 时自动运行 RouteWeaver。"
        }
    }
}

enum LaunchAtLoginManager {
    private static let launchAgentLabel = "local.routeweaver.mac.autostart"

    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist")
    }

    static func currentStatus() -> LaunchAtLoginStatus {
        let smStatus = SMAppService.mainApp.status
        switch smStatus {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            if FileManager.default.fileExists(atPath: launchAgentURL.path) {
                return .enabledViaLaunchAgent
            }
            return .disabled
        @unknown default:
            return FileManager.default.fileExists(atPath: launchAgentURL.path) ? .enabledViaLaunchAgent : .disabled
        }
    }

    static func setEnabled(_ enabled: Bool) throws -> LaunchAtLoginStatus {
        if enabled {
            do {
                try SMAppService.mainApp.register()
                // Remove any legacy LaunchAgent fallback if SMAppService succeeded.
                try? FileManager.default.removeItem(at: launchAgentURL)
                return currentStatus()
            } catch {
                // Fallback to per-user LaunchAgent for unsigned / non-/Applications bundles.
                try installLaunchAgent()
                return .enabledViaLaunchAgent
            }
        } else {
            var smError: Error?
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                do {
                    try SMAppService.mainApp.unregister()
                } catch {
                    smError = error
                }
            }
            if FileManager.default.fileExists(atPath: launchAgentURL.path) {
                try FileManager.default.removeItem(at: launchAgentURL)
            }
            if let smError, SMAppService.mainApp.status == .enabled {
                throw smError
            }
            return currentStatus()
        }
    }

    static func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func installLaunchAgent() throws {
        let bundlePath = Bundle.main.bundleURL.path
        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": ["/usr/bin/open", "-a", bundlePath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "LimitLoadToSessionType": "Aqua",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let dir = launchAgentURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: launchAgentURL, options: .atomic)
    }
}
