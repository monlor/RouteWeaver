import Foundation

public enum TunHelperPaths {
    public static let installDirectoryPath = "/Library/Application Support/RouteWeaver"
    public static let authorizedHelperPath = "\(installDirectoryPath)/tun-helper"
    public static let authorizedMihomoPath = "\(installDirectoryPath)/mihomo"
    public static let gatewayStatePath = "\(installDirectoryPath)/gateway-sysctl.state"
    public static let tunDNSStatePath = "\(installDirectoryPath)/tun-dns.state"
    public static let tunHijackDNSServer = "198.18.0.2"

    public static let killSwitchAnchor = "com.apple/routeweaver.killswitch"
    public static let killSwitchEmergencyResetCommand = "sudo pfctl -a \(killSwitchAnchor) -F all"
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
    public static let helperVersion = "7"
    public static let stdinStopCommand = "stop\n"
    public static let updatedVersionOutputPrefix = "UPDATED_MIHOMO_VERSION="

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

    /// Extracts `<version>` from `RouteWeaverTunHelper <version>` output.
    public static func parseHelperVersion(from output: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "RouteWeaverTunHelper "
            if line.hasPrefix(prefix) {
                let ver = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !ver.isEmpty { return ver }
            }
        }
        return nil
    }

    public static func isValidSHA256Hex(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy {
            ("0"..."9").contains($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0)
        }
    }

    /// Strictly validates that a Mihomo update URL points to an official HTTPS GitHub release `.gz` asset
    /// under `MetaCubeX/mihomo/releases/download/<tag>/mihomo-darwin-(arm64|amd64)-*.gz`.
    public static func isTrustedMihomoReleaseURL(_ rawURL: String) -> Bool {
        guard !rawURL.isEmpty,
              !rawURL.contains("\0"),
              rawURL.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7f }),
              let comps = URLComponents(string: rawURL),
              comps.scheme?.lowercased() == "https",
              comps.host?.lowercased() == "github.com",
              comps.user == nil,
              comps.password == nil,
              comps.port == nil,
              comps.query == nil,
              comps.fragment == nil else {
            return false
        }

        let path = comps.percentEncodedPath
        guard !path.contains(".."), !path.contains("//"), !path.contains("%") else {
            return false
        }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        // Expected: ["", "MetaCubeX", "mihomo", "releases", "download", "<tag>", "<asset.gz>"]
        guard segments.count == 7,
              segments[0].isEmpty,
              segments[1] == "MetaCubeX",
              segments[2] == "mihomo",
              segments[3] == "releases",
              segments[4] == "download" else {
            return false
        }

        let tag = String(segments[5])
        let asset = String(segments[6])
        let safeToken: (String) -> Bool = { s in
            !s.isEmpty && s != "." && s != ".." && s.unicodeScalars.allSatisfy {
                ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
                    || $0 == "." || $0 == "_" || $0 == "-" || $0 == "+"
            }
        }
        guard safeToken(tag), safeToken(asset) else { return false }

        let lowerAsset = asset.lowercased()
        let validPrefix = lowerAsset.hasPrefix("mihomo-darwin-arm64-") || lowerAsset.hasPrefix("mihomo-darwin-amd64-")
        return validPrefix && lowerAsset.hasSuffix(".gz")
    }
}
