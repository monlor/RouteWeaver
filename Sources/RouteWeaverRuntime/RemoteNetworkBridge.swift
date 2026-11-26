import Foundation
import RoutingCore

enum RemoteLinkMode: String, Codable, Equatable, Sendable {
    case gateway
    case httpProxy
    case socks5

    var title: String {
        switch self {
        case .gateway: return "远程网关"
        case .httpProxy: return "远程 HTTP 代理"
        case .socks5: return "远程 SOCKS5 代理"
        }
    }
}

struct ActiveRemoteNetworkLink: Codable, Equatable, Sendable {
    let mode: RemoteLinkMode
    let remoteHostId: String
    let remoteHostName: String
    let remoteIP: String
    let port: Int?
    let serviceName: String
    let previousIPv4: NetworkServiceIPv4Info?
    let previousDNS: [String]
    let previousSOCKS: SOCKSProxyInfo?
    let previousHTTP: HTTPProxyInfo?
    let previousHTTPS: HTTPProxyInfo?

    init(
        mode: RemoteLinkMode,
        remoteHostId: String,
        remoteHostName: String,
        remoteIP: String,
        port: Int?,
        serviceName: String,
        previousIPv4: NetworkServiceIPv4Info?,
        previousDNS: [String],
        previousSOCKS: SOCKSProxyInfo?,
        previousHTTP: HTTPProxyInfo? = nil,
        previousHTTPS: HTTPProxyInfo? = nil
    ) {
        self.mode = mode
        self.remoteHostId = remoteHostId
        self.remoteHostName = remoteHostName
        self.remoteIP = remoteIP
        self.port = port
        self.serviceName = serviceName
        self.previousIPv4 = previousIPv4
        self.previousDNS = previousDNS
        self.previousSOCKS = previousSOCKS
        self.previousHTTP = previousHTTP
        self.previousHTTPS = previousHTTPS
    }
}

struct NetworkSetupCommandResult: Equatable, Sendable {
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String

    init(
        terminationStatus: Int32,
        standardOutput: String = "",
        standardError: String = ""
    ) {
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

protocol NetworkSetupTransport: Sendable {
    func run(_ arguments: [String]) async throws -> NetworkSetupCommandResult
}

struct SystemNetworkSetupTransport: NetworkSetupTransport {
    private let executablePath: String

    init(executablePath: String = "/usr/sbin/networksetup") {
        self.executablePath = executablePath
    }

    func run(_ arguments: [String]) async throws -> NetworkSetupCommandResult {
        try await Task.detached(priority: .userInitiated) { [executablePath] in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            return NetworkSetupCommandResult(
                terminationStatus: process.terminationStatus,
                standardOutput: String(decoding: outData, as: UTF8.self),
                standardError: String(decoding: errData, as: UTF8.self)
            )
        }.value
    }
}

protocol RemoteNetworkLinkStore: AnyObject {
    func loadActiveLink() -> ActiveRemoteNetworkLink?
    func saveActiveLink(_ link: ActiveRemoteNetworkLink?)
}

final class UserDefaultsRemoteNetworkLinkStore: RemoteNetworkLinkStore {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "RouteWeaver.remoteActiveNetworkLink"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func loadActiveLink() -> ActiveRemoteNetworkLink? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ActiveRemoteNetworkLink.self, from: data)
    }

    func saveActiveLink(_ link: ActiveRemoteNetworkLink?) {
        if let link, let data = try? JSONEncoder().encode(link) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

@MainActor
final class RemoteNetworkBridge: ObservableObject {
    @Published private(set) var activeLink: ActiveRemoteNetworkLink?
    @Published private(set) var isApplying = false
    @Published var lastError: String?
    @Published var feedback: String?

    private let transport: any NetworkSetupTransport
    private let linkStore: any RemoteNetworkLinkStore

    init(
        transport: any NetworkSetupTransport = SystemNetworkSetupTransport(),
        linkStore: any RemoteNetworkLinkStore = UserDefaultsRemoteNetworkLinkStore()
    ) {
        self.transport = transport
        self.linkStore = linkStore
        self.activeLink = linkStore.loadActiveLink()
    }

    @discardableResult
    func connectAsGateway(
        host: RemoteSavedHost,
        preferredBSDInterface: String?
    ) async -> Bool {
        await applyLink(
            failurePrefix: "设置远程网关失败",
            successFeedback: { serviceName in
                "已将「\(serviceName)」网关与 DNS 指向 \(host.hostName) (\(host.host))"
            },
            prepare: {
                let serviceName = try await self.resolveServiceName(preferredBSDInterface: preferredBSDInterface)
                let infoOut = try await self.runNetworksetup(["-getinfo", serviceName])
                let prevInfo = NetworkSetupParser.parseServiceInfo(infoOut)
                guard let ip = prevInfo.ipAddress, let mask = prevInfo.subnetMask else {
                    throw NSError(
                        domain: "RemoteNetworkBridge",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "当前网络服务「\(serviceName)」未获取到 IPv4 地址与子网掩码，无法切换网关。"]
                    )
                }

                let dnsOut = try await self.runNetworksetup(["-getdnsservers", serviceName])
                let prevDNS = NetworkSetupParser.parseDNSServers(dnsOut)

                return (
                    link: ActiveRemoteNetworkLink(
                        mode: .gateway,
                        remoteHostId: host.id,
                        remoteHostName: host.hostName,
                        remoteIP: host.host,
                        port: nil,
                        serviceName: serviceName,
                        previousIPv4: prevInfo,
                        previousDNS: prevDNS,
                        previousSOCKS: nil
                    ),
                    mutations: [
                        ["-setmanual", serviceName, ip, mask, host.host],
                        ["-setdnsservers", serviceName, host.host]
                    ]
                )
            }
        )
    }

    @discardableResult
    func connectAsHTTPProxy(
        host: RemoteSavedHost,
        port: Int,
        preferredBSDInterface: String?
    ) async -> Bool {
        guard (1...65535).contains(port) else {
            lastError = "无效的 HTTP 代理端口：\(port)"
            return false
        }

        return await applyLink(
            failurePrefix: "设置系统 HTTP 代理失败",
            successFeedback: { serviceName in
                "已开启「\(serviceName)」系统 HTTP/HTTPS 代理：\(host.host):\(port)"
            },
            prepare: {
                let serviceName = try await self.resolveServiceName(preferredBSDInterface: preferredBSDInterface)
                let httpOut = try await self.runNetworksetup(["-getwebproxy", serviceName])
                let httpsOut = try await self.runNetworksetup(["-getsecurewebproxy", serviceName])
                let prevHTTP = NetworkSetupParser.parseHTTPProxy(httpOut)
                let prevHTTPS = NetworkSetupParser.parseHTTPProxy(httpsOut)

                return (
                    link: ActiveRemoteNetworkLink(
                        mode: .httpProxy,
                        remoteHostId: host.id,
                        remoteHostName: host.hostName,
                        remoteIP: host.host,
                        port: port,
                        serviceName: serviceName,
                        previousIPv4: nil,
                        previousDNS: [],
                        previousSOCKS: nil,
                        previousHTTP: prevHTTP,
                        previousHTTPS: prevHTTPS
                    ),
                    mutations: [
                        ["-setwebproxy", serviceName, host.host, String(port)],
                        ["-setwebproxystate", serviceName, "on"],
                        ["-setsecurewebproxy", serviceName, host.host, String(port)],
                        ["-setsecurewebproxystate", serviceName, "on"]
                    ]
                )
            }
        )
    }

    @discardableResult
    func connectAsSOCKS5(
        host: RemoteSavedHost,
        port: Int,
        preferredBSDInterface: String?
    ) async -> Bool {
        guard (1...65535).contains(port) else {
            lastError = "无效的 SOCKS5 端口：\(port)"
            return false
        }

        return await applyLink(
            failurePrefix: "设置系统 SOCKS5 代理失败",
            successFeedback: { serviceName in
                "已开启「\(serviceName)」系统 SOCKS5 代理：\(host.host):\(port)"
            },
            prepare: {
                let serviceName = try await self.resolveServiceName(preferredBSDInterface: preferredBSDInterface)
                let socksOut = try await self.runNetworksetup(["-getsocksfirewallproxy", serviceName])
                let prevSOCKS = NetworkSetupParser.parseSOCKSProxy(socksOut)

                return (
                    link: ActiveRemoteNetworkLink(
                        mode: .socks5,
                        remoteHostId: host.id,
                        remoteHostName: host.hostName,
                        remoteIP: host.host,
                        port: port,
                        serviceName: serviceName,
                        previousIPv4: nil,
                        previousDNS: [],
                        previousSOCKS: prevSOCKS
                    ),
                    mutations: [
                        ["-setsocksfirewallproxy", serviceName, host.host, String(port)],
                        ["-setsocksfirewallproxystate", serviceName, "on"]
                    ]
                )
            }
        )
    }

    @discardableResult
    func disconnectAndRestore() async -> Bool {
        guard !isApplying else { return false }
        isApplying = true
        lastError = nil
        feedback = nil
        defer { isApplying = false }
        return await restoreCurrentLink()
    }

    private func applyLink(
        failurePrefix: String,
        successFeedback: (String) -> String,
        prepare: () async throws -> (link: ActiveRemoteNetworkLink, mutations: [[String]])
    ) async -> Bool {
        guard !isApplying else { return false }
        isApplying = true
        lastError = nil
        feedback = nil
        defer { isApplying = false }

        if activeLink != nil {
            guard await restoreCurrentLink() else {
                return false
            }
        }

        var didMutate = false
        var pendingLink: ActiveRemoteNetworkLink?

        do {
            let prepared = try await prepare()
            pendingLink = prepared.link
            // Persist before the first mutation so a partial failure or crash retains the rollback snapshot.
            saveActiveLink(prepared.link)

            for command in prepared.mutations {
                _ = try await runNetworksetup(command)
                didMutate = true
            }

            feedback = successFeedback(prepared.link.serviceName)
            return true
        } catch {
            if didMutate, let link = pendingLink {
                do {
                    try await performRestore(for: link)
                    saveActiveLink(nil)
                    lastError = "\(failurePrefix)：\(error.localizedDescription)（已自动恢复原网络配置）"
                } catch let rollbackError {
                    // Keep activeLink persisted so the user can retry disconnectAndRestore().
                    lastError = "\(failurePrefix)：\(error.localizedDescription)；自动恢复失败：\(rollbackError.localizedDescription)"
                }
            } else {
                if pendingLink != nil {
                    saveActiveLink(nil)
                }
                lastError = "\(failurePrefix)：\(error.localizedDescription)"
            }
            return false
        }
    }

    private func restoreCurrentLink() async -> Bool {
        guard let link = activeLink else { return true }
        do {
            try await performRestore(for: link)
            saveActiveLink(nil)
            feedback = "已断开远程连接并恢复「\(link.serviceName)」原网络配置"
            return true
        } catch {
            lastError = "恢复网络配置失败：\(error.localizedDescription)"
            return false
        }
    }

    private func performRestore(for link: ActiveRemoteNetworkLink) async throws {
        switch link.mode {
        case .gateway:
            if let prev = link.previousIPv4 {
                if prev.isDHCP {
                    _ = try await runNetworksetup(["-setdhcp", link.serviceName])
                } else if let ip = prev.ipAddress, let mask = prev.subnetMask {
                    var args = ["-setmanual", link.serviceName, ip, mask]
                    if let router = prev.router { args.append(router) }
                    _ = try await runNetworksetup(args)
                }
            } else {
                _ = try await runNetworksetup(["-setdhcp", link.serviceName])
            }

            if link.previousDNS.isEmpty {
                _ = try await runNetworksetup(["-setdnsservers", link.serviceName, "Empty"])
            } else {
                _ = try await runNetworksetup(["-setdnsservers", link.serviceName] + link.previousDNS)
            }

        case .httpProxy:
            if let prev = link.previousHTTP, prev.enabled, !prev.server.isEmpty, prev.port > 0 {
                _ = try await runNetworksetup(["-setwebproxy", link.serviceName, prev.server, String(prev.port)])
                _ = try await runNetworksetup(["-setwebproxystate", link.serviceName, "on"])
            } else {
                _ = try await runNetworksetup(["-setwebproxystate", link.serviceName, "off"])
            }
            if let prev = link.previousHTTPS, prev.enabled, !prev.server.isEmpty, prev.port > 0 {
                _ = try await runNetworksetup(["-setsecurewebproxy", link.serviceName, prev.server, String(prev.port)])
                _ = try await runNetworksetup(["-setsecurewebproxystate", link.serviceName, "on"])
            } else {
                _ = try await runNetworksetup(["-setsecurewebproxystate", link.serviceName, "off"])
            }

        case .socks5:
            if let prev = link.previousSOCKS, prev.enabled, !prev.server.isEmpty, prev.port > 0 {
                _ = try await runNetworksetup(["-setsocksfirewallproxy", link.serviceName, prev.server, String(prev.port)])
                _ = try await runNetworksetup(["-setsocksfirewallproxystate", link.serviceName, "on"])
            } else {
                _ = try await runNetworksetup(["-setsocksfirewallproxystate", link.serviceName, "off"])
            }
        }
    }

    private func resolveServiceName(preferredBSDInterface: String?) async throws -> String {
        let hwOut = try await runNetworksetup(["-listallhardwareports"])
        let map = NetworkSetupParser.parseHardwarePorts(hwOut)
        if let bsd = preferredBSDInterface, let match = map[bsd] {
            return match
        }
        if let wiFi = map["en0"] {
            return wiFi
        }
        if let first = map.values.first {
            return first
        }
        throw NSError(domain: "RemoteNetworkBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "未找到可用的 macOS 网络服务。"])
    }

    private func runNetworksetup(_ arguments: [String]) async throws -> String {
        let result = try await transport.run(arguments)
        if result.terminationStatus != 0 {
            let errText = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            let outText = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let msg = errText.isEmpty ? outText : errText
            throw NSError(
                domain: "RemoteNetworkBridge",
                code: Int(result.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? "networksetup 退出码 \(result.terminationStatus)" : msg]
            )
        }
        return result.standardOutput
    }

    private func saveActiveLink(_ link: ActiveRemoteNetworkLink?) {
        activeLink = link
        linkStore.saveActiveLink(link)
    }
}
