import Foundation

public enum TunHelperPaths {
    public static let installDirectoryPath = "/Library/Application Support/RouteWeaver"
    public static let authorizedHelperPath = "\(installDirectoryPath)/tun-helper"
    public static let authorizedMihomoPath = "\(installDirectoryPath)/mihomo"
    public static let gatewayStatePath = "\(installDirectoryPath)/gateway-sysctl.state"
    public static let tunDNSStatePath = "\(installDirectoryPath)/tun-dns.state"
    public static let tunHijackDNSServer = "198.18.0.2"

    public static let killSwitchAnchor = "com.apple/routeweaver.killswitch"
    public static let killSwitchStatePath = "\(installDirectoryPath)/killswitch.state"
    public static let killSwitchTokenPath = "\(installDirectoryPath)/killswitch-pf.token"

    public static let userAgentLabel = "local.routeweaver.mihomo"
    public static let tunDaemonLabel = "local.routeweaver.mihomo-tun"
    public static let tunDaemonPlistPath = "/Library/LaunchDaemons/\(tunDaemonLabel).plist"
    public static let tunServiceTarget = "system/\(tunDaemonLabel)"

    public static let killSwitchDaemonLabel = "local.routeweaver.killswitch"
    public static let killSwitchDaemonPlistPath = "/Library/LaunchDaemons/\(killSwitchDaemonLabel).plist"
    public static let killSwitchServiceTarget = "system/\(killSwitchDaemonLabel)"

    public static let mihomoDedicatedGid: gid_t = 47_921
    public static let helperVersion = "6"
    public static let stdinStopCommand = "stop\n"

    public static var installDirectoryURL: URL {
        URL(fileURLWithPath: installDirectoryPath, isDirectory: true)
    }

    public static var installedHelperURL: URL {
        URL(fileURLWithPath: authorizedHelperPath)
    }

    public static var installedMihomoURL: URL {
        URL(fileURLWithPath: authorizedMihomoPath)
    }

    public static func isSafeAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.isEmpty, !path.contains("\0") else { return false }
        let components = path.split(separator: "/")
        return !components.contains("..")
    }
}
