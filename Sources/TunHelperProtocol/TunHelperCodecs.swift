import Foundation

public struct GatewaySysctlState: Equatable, Sendable {
    public var prevForwarding: Int32
    public var prevRedirect: Int32

    public init(prevForwarding: Int32, prevRedirect: Int32) {
        self.prevForwarding = prevForwarding
        self.prevRedirect = prevRedirect
    }

    public func encodeText() -> String {
        "prev_forwarding=\(prevForwarding)\nprev_redirect=\(prevRedirect)\n"
    }

    public static func decodeText(_ text: String) -> GatewaySysctlState? {
        var prevForwarding: Int32?
        var prevRedirect: Int32?
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0] == "prev_forwarding", let v = Int32(parts[1]) {
                prevForwarding = v
            } else if parts[0] == "prev_redirect", let v = Int32(parts[1]) {
                prevRedirect = v
            }
        }
        guard let prevForwarding, let prevRedirect else { return nil }
        return GatewaySysctlState(prevForwarding: prevForwarding, prevRedirect: prevRedirect)
    }
}

public struct SavedServiceDNS: Codable, Equatable, Sendable {
    public var serviceID: String
    public var servers: [String]?

    public init(serviceID: String, servers: [String]?) {
        self.serviceID = serviceID
        self.servers = servers
    }
}

public struct TunDNSState: Codable, Equatable, Sendable {
    public var services: [SavedServiceDNS]

    public init(services: [SavedServiceDNS]) {
        self.services = services
    }
}

public struct KillSwitchPersistedState: Equatable, Sendable {
    public var enabled: Bool
    public var allowLAN: Bool
    public var persistOnBoot: Bool

    public init(enabled: Bool, allowLAN: Bool, persistOnBoot: Bool) {
        self.enabled = enabled
        self.allowLAN = allowLAN
        self.persistOnBoot = persistOnBoot
    }

    public func encodeText() -> String {
        "enabled=\(enabled ? 1 : 0)\nallow_lan=\(allowLAN ? 1 : 0)\npersist_on_boot=\(persistOnBoot ? 1 : 0)\n"
    }

    public static func decodeText(_ text: String) -> KillSwitchPersistedState {
        var enabled = false
        var allowLAN = true
        var persistOnBoot = false
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "enabled": enabled = (parts[1] == "1")
            case "allow_lan": allowLAN = (parts[1] == "1")
            case "persist_on_boot": persistOnBoot = (parts[1] == "1")
            default: break
            }
        }
        return KillSwitchPersistedState(enabled: enabled, allowLAN: allowLAN, persistOnBoot: persistOnBoot)
    }
}

public struct KillSwitchStatusReport: Equatable, Sendable {
    public let isActive: Bool
    public let allowLAN: Bool
    public let persistOnBoot: Bool
    public let isPFEnabled: Bool

    public static let inactive = KillSwitchStatusReport(
        isActive: false,
        allowLAN: true,
        persistOnBoot: false,
        isPFEnabled: false
    )

    public init(isActive: Bool, allowLAN: Bool, persistOnBoot: Bool, isPFEnabled: Bool) {
        self.isActive = isActive
        self.allowLAN = allowLAN
        self.persistOnBoot = persistOnBoot
        self.isPFEnabled = isPFEnabled
    }

    public func encodeText() -> String {
        """
        active=\(isActive ? 1 : 0)
        allow_lan=\(allowLAN ? 1 : 0)
        persist_on_boot=\(persistOnBoot ? 1 : 0)
        pf_enabled=\(isPFEnabled ? 1 : 0)
        """
    }

    public static func parse(_ output: String) -> KillSwitchStatusReport {
        var active = false
        var allowLAN = true
        var persistOnBoot = false
        var pfEnabled = false
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let parts = rawLine.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "active": active = (value == "1")
            case "allow_lan": allowLAN = (value == "1")
            case "persist_on_boot": persistOnBoot = (value == "1")
            case "pf_enabled": pfEnabled = (value == "1")
            default: break
            }
        }
        return KillSwitchStatusReport(
            isActive: active,
            allowLAN: allowLAN,
            persistOnBoot: persistOnBoot,
            isPFEnabled: pfEnabled
        )
    }
}

public enum TunHelperPlists {
    public static func tunDaemonPlistData(
        workDir: String,
        configPath: String,
        logFilePath: String,
        pidFilePath: String,
        gatewayMode: Bool
    ) throws -> Data {
        let cmd = TunHelperCommand.run(
            workDir: workDir,
            configPath: configPath,
            logFilePath: logFilePath,
            pidFilePath: pidFilePath,
            gatewayMode: gatewayMode,
            daemonRunMode: true
        )
        let plist: [String: Any] = [
            "Label": TunHelperPaths.tunDaemonLabel,
            "ProgramArguments": [TunHelperPaths.authorizedHelperPath] + cmd.arguments,
            "WorkingDirectory": workDir,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 3,
            "ProcessType": "Background",
            "StandardErrorPath": logFilePath,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    public static func killSwitchBootDaemonPlistData() throws -> Data {
        let plist: [String: Any] = [
            "Label": TunHelperPaths.killSwitchDaemonLabel,
            "ProgramArguments": [TunHelperPaths.authorizedHelperPath] + TunHelperCommand.killSwitchRestore.arguments,
            "RunAtLoad": true,
            "ProcessType": "Background",
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    public static func userAgentPlistData(
        binaryPath: String,
        workDirPath: String,
        configPath: String,
        logFilePath: String
    ) throws -> Data {
        let plist: [String: Any] = [
            "Label": TunHelperPaths.userAgentLabel,
            "ProgramArguments": [binaryPath, "-d", workDirPath, "-f", configPath],
            "WorkingDirectory": workDirPath,
            "EnvironmentVariables": [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": workDirPath,
            ],
            "StandardOutPath": logFilePath,
            "StandardErrorPath": logFilePath,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 3,
            "ProcessType": "Background",
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}

public enum TunHelperPFRules {
    /// macOS `/etc/pf.conf` automatically evaluates `anchor "com.apple/*"`, so using a sub-anchor
    /// under `com.apple/` activates rules without modifying `/etc/pf.conf`.
    public static let anchorName = TunHelperPaths.killSwitchAnchor

    /// Dedicated unused GID assigned to the authorized Mihomo process so PF can allow outbound
    /// traffic exclusively from Mihomo itself (blocking even unrelated root daemons).
    public static let dedicatedGID: gid_t = TunHelperPaths.mihomoDedicatedGid

    /// Terminal fallback command users can run to immediately remove Kill Switch rules.
    public static let emergencyResetCommand = TunHelperPaths.killSwitchEmergencyResetCommand

    /// Maximum utun index included in the PF interface allowlist (`utun0` ... `utun31`).
    public static let maxUtunIndex = 31

    public static func renderKillSwitchPFConfig(allowLAN: Bool) -> String {
        let utunList = (0...maxUtunIndex).map { "utun\($0)" }.joined(separator: ", ")
        var lines: [String] = [
            "# RouteWeaver Kill Switch PF Anchor (\(anchorName))",
            "pass quick on lo0 all",
            "pass quick on { \(utunList) } all",
            "pass out quick proto { tcp, udp, icmp, icmp6 } from any to any user 0 group \(dedicatedGID) keep state",
            "block drop out quick proto { tcp, udp } from any to any port 53",
            "pass out quick inet proto udp from any port 68 to any port 67",
            "pass out quick inet6 proto udp from any port 546 to any port 547",
        ]
        if allowLAN {
            lines.append("pass in quick inet from { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } to any flags any keep state")
            lines.append("pass out quick inet to { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255/32 } flags any keep state")
            lines.append("pass in quick inet6 from { fe80::/10, fc00::/7 } to any flags any keep state")
            lines.append("pass out quick inet6 to { fe80::/10, fc00::/7, ff00::/8 } flags any keep state")
        }
        lines.append("block drop out quick all")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public static func parsePFEnableToken(from output: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("token"),
                  let colon = line.firstIndex(of: ":") else { continue }
            let token = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                return token
            }
        }
        return nil
    }
}
