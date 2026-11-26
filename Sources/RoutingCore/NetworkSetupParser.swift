import Foundation

public struct NetworkServiceIPv4Info: Codable, Equatable, Sendable {
    public let isDHCP: Bool
    public let ipAddress: String?
    public let subnetMask: String?
    public let router: String?

    public init(isDHCP: Bool, ipAddress: String?, subnetMask: String?, router: String?) {
        self.isDHCP = isDHCP
        self.ipAddress = ipAddress
        self.subnetMask = subnetMask
        self.router = router
    }
}

public struct SOCKSProxyInfo: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let server: String
    public let port: Int

    public init(enabled: Bool, server: String, port: Int) {
        self.enabled = enabled
        self.server = server
        self.port = port
    }
}

public struct HTTPProxyInfo: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let server: String
    public let port: Int

    public init(enabled: Bool, server: String, port: Int) {
        self.enabled = enabled
        self.server = server
        self.port = port
    }
}

public enum NetworkSetupParser {
    /// Parses `networksetup -listallhardwareports` into `[bsdDevice: serviceName]`, e.g. `["en0": "Wi-Fi"]`.
    public static func parseHardwarePorts(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentPort: String?

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("Hardware Port:") {
                currentPort = String(line.dropFirst("Hardware Port:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Device:"), let portName = currentPort {
                let device = String(line.dropFirst("Device:".count)).trimmingCharacters(in: .whitespaces)
                if !device.isEmpty && !portName.isEmpty {
                    result[device] = portName
                }
                currentPort = nil
            }
        }
        return result
    }

    /// Parses `networksetup -getinfo <service>` output.
    public static func parseServiceInfo(_ output: String) -> NetworkServiceIPv4Info {
        var isDHCP = false
        var ipAddress: String?
        var subnetMask: String?
        var router: String?

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("DHCP Configuration") {
                isDHCP = true
            } else if line.hasPrefix("IP address:") {
                let val = String(line.dropFirst("IP address:".count)).trimmingCharacters(in: .whitespaces)
                if !val.isEmpty && val.lowercased() != "none" { ipAddress = val }
            } else if line.hasPrefix("Subnet mask:") {
                let val = String(line.dropFirst("Subnet mask:".count)).trimmingCharacters(in: .whitespaces)
                if !val.isEmpty && val.lowercased() != "none" { subnetMask = val }
            } else if line.hasPrefix("Router:") {
                let val = String(line.dropFirst("Router:".count)).trimmingCharacters(in: .whitespaces)
                if !val.isEmpty && val.lowercased() != "none" { router = val }
            }
        }

        return NetworkServiceIPv4Info(
            isDHCP: isDHCP,
            ipAddress: ipAddress,
            subnetMask: subnetMask,
            router: router
        )
    }

    /// Parses `networksetup -getdnsservers <service>` output.
    public static func parseDNSServers(_ output: String) -> [String] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("There aren't any DNS Servers set") {
            return []
        }
        return trimmed
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Parses `networksetup -getsocksfirewallproxy <service>` output.
    public static func parseSOCKSProxy(_ output: String) -> SOCKSProxyInfo {
        let parsed = parseProxyFields(output)
        return SOCKSProxyInfo(enabled: parsed.enabled, server: parsed.server, port: parsed.port)
    }

    /// Parses `networksetup -getwebproxy <service>` or `-getsecurewebproxy <service>` output.
    public static func parseHTTPProxy(_ output: String) -> HTTPProxyInfo {
        let parsed = parseProxyFields(output)
        return HTTPProxyInfo(enabled: parsed.enabled, server: parsed.server, port: parsed.port)
    }

    private static func parseProxyFields(_ output: String) -> (enabled: Bool, server: String, port: Int) {
        var enabled = false
        var server = ""
        var port = 0

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("Enabled:") {
                let val = String(line.dropFirst("Enabled:".count)).trimmingCharacters(in: .whitespaces).lowercased()
                enabled = (val == "yes")
            } else if line.hasPrefix("Server:") {
                server = String(line.dropFirst("Server:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Port:") {
                let val = String(line.dropFirst("Port:".count)).trimmingCharacters(in: .whitespaces)
                port = Int(val) ?? 0
            }
        }

        return (enabled, server, port)
    }
}
