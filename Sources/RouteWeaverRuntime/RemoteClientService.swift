import Foundation
import Network
import RoutingCore

struct RemoteHTTPTransportResponse: Sendable {
    let statusCode: Int
    let data: Data
}

protocol RemoteHTTPTransport: Sendable {
    func send(
        host: String,
        port: UInt16,
        method: String,
        path: String,
        token: String?,
        body: Data?
    ) async throws -> RemoteHTTPTransportResponse
}

final class URLSessionRemoteHTTPTransport: RemoteHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 6
            config.timeoutIntervalForResource = 10
            self.session = URLSession(configuration: config)
        }
    }

    func send(
        host: String,
        port: UInt16,
        method: String,
        path: String,
        token: String?,
        body: Data?
    ) async throws -> RemoteHTTPTransportResponse {
        let formattedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let url = URL(string: "http://\(formattedHost):\(port)\(path)") else {
            throw NSError(domain: "RemoteClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "无效的地址：\(host):\(port)"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "RemoteClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "无效的响应。"])
        }
        return RemoteHTTPTransportResponse(statusCode: httpResponse.statusCode, data: data)
    }
}

struct DiscoveredRemoteDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let port: UInt16
    let ips: [String]
    let endpoint: NWEndpoint
    let isLocalDevice: Bool
}

@MainActor
final class RemoteClientService: ObservableObject {
    @Published private(set) var discoveredDevices: [DiscoveredRemoteDevice] = []
    @Published private(set) var savedHosts: [RemoteSavedHost] = []
    @Published private(set) var isBrowsing = false
    @Published var activeHostId: String? {
        didSet {
            if activeHostId == nil {
                stopPolling()
                clearRemoteData()
            } else {
                Task { await refreshAll() }
                startPolling()
            }
        }
    }

    @Published private(set) var remoteStatus: RemoteStatusSnapshot?
    @Published private(set) var remoteProxies: [RemoteProxyGroupDTO] = []
    @Published private(set) var remoteConnections: [RemoteConnectionDTO] = []
    @Published private(set) var remoteDNSLogs: [RemoteDNSLogDTO] = []
    @Published private(set) var remoteGatewayDevices: [GatewayClientDevice] = []
    @Published private(set) var remoteLogs: String = ""
    @Published private(set) var remoteOutboundErrors: [OutboundErrorRecord]?
    @Published private(set) var remoteTargetSessionTotals: [String: TrafficBytes]?
    @Published private(set) var remoteTargetConnectionCounts: [String: Int]?
    @Published private(set) var remoteTargetSpeeds: [String: TrafficBytes]?
    @Published private(set) var remoteRuleSessionTotals: [String: TrafficBytes]?
    @Published private(set) var remoteFullState: RemoteFullStateDTO?
    @Published private(set) var snapshotSequence: UInt64 = 0
    @Published private(set) var isRefreshing = false
    @Published private(set) var isPairing = false
    @Published var lastError: String?
    @Published var actionFeedback: String?

    private let localDeviceId: String
    private let localDeviceName: String
    private let transport: any RemoteHTTPTransport
    private let userDefaults: UserDefaults
    private var browser: NWBrowser?
    private let browserQueue = DispatchQueue(label: "local.routeweaver.remote-browser", qos: .utility)
    private var pollTask: Task<Void, Never>?
    private var lastStateRevisionByHostId: [String: String] = [:]
    private var legacyHostsWithoutSnapshot: Set<String> = []
    private var legacyStatePollCounterByHostId: [String: Int] = [:]

    private enum DefaultsKey {
        static let savedHosts = "RouteWeaver.remoteSavedHosts"
    }

    var activeHost: RemoteSavedHost? {
        guard let activeHostId else { return nil }
        return savedHosts.first { $0.id == activeHostId }
    }

    init(
        localDeviceId: String,
        localDeviceName: String,
        transport: any RemoteHTTPTransport = URLSessionRemoteHTTPTransport(),
        userDefaults: UserDefaults = .standard
    ) {
        self.localDeviceId = localDeviceId
        self.localDeviceName = localDeviceName
        self.transport = transport
        self.userDefaults = userDefaults
        self.savedHosts = Self.loadSavedHosts(from: userDefaults)
    }

    func startDiscovery() {
        guard browser == nil else { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: RemoteControlProtocol.serviceType,
            domain: nil
        )
        let newBrowser = NWBrowser(for: descriptor, using: params)

        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready:
                    self?.isBrowsing = true
                case .failed(let err):
                    self?.isBrowsing = false
                    self?.lastError = "局域网设备扫描失败：\(err.localizedDescription)"
                case .cancelled:
                    self?.isBrowsing = false
                default:
                    break
                }
            }
        }

        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            let parsed: [DiscoveredRemoteDevice] = results.compactMap { result in
                var deviceId = "\(result.endpoint.hashValue)"
                var name: String
                var port = RemoteControlProtocol.defaultPort
                var ips: [String] = []

                if case let .service(serviceName, _, _, _) = result.endpoint {
                    name = serviceName
                } else {
                    name = "RouteWeaver 设备"
                }

                if case let .bonjour(txt) = result.metadata {
                    if let id = txt["deviceId"], !id.isEmpty { deviceId = id }
                    if let txtName = txt["name"], !txtName.isEmpty { name = txtName }
                    if let portStr = txt["port"], let parsedPort = UInt16(portStr) { port = parsedPort }
                    if let ipsStr = txt["ips"], !ipsStr.isEmpty {
                        ips = ipsStr.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
                }

                return DiscoveredRemoteDevice(
                    id: deviceId,
                    name: name,
                    port: port,
                    ips: ips,
                    endpoint: result.endpoint,
                    isLocalDevice: deviceId == self?.localDeviceId
                )
            }
            .filter { !$0.isLocalDevice }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            Task { @MainActor [weak self] in
                self?.discoveredDevices = parsed
            }
        }

        self.browser = newBrowser
        newBrowser.start(queue: browserQueue)
    }

    func stopDiscovery() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
    }

    func isPaired(_ deviceId: String) -> Bool {
        savedHosts.contains { $0.hostDeviceId == deviceId }
    }

    func pair(discoveredDevice: DiscoveredRemoteDevice, pairingCode: String) async -> Bool {
        isPairing = true
        lastError = nil
        defer { isPairing = false }

        if let firstIP = discoveredDevice.ips.first {
            return await pairManual(host: firstIP, port: discoveredDevice.port, pairingCode: pairingCode)
        }

        do {
            let resolvedIP = try await resolveEndpointHost(discoveredDevice.endpoint)
            return await pairManual(host: resolvedIP, port: discoveredDevice.port, pairingCode: pairingCode)
        } catch {
            lastError = "无法解析设备地址：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func pairManual(host: String, port: UInt16, pairingCode: String) async -> Bool {
        isPairing = true
        lastError = nil
        defer { isPairing = false }

        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCode = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty, !cleanCode.isEmpty else {
            lastError = "请输入设备地址和配对码。"
            return false
        }

        let body = RemotePairingRequest(
            deviceId: localDeviceId,
            deviceName: localDeviceName,
            pairingCode: cleanCode
        )

        do {
            let response: RemotePairingResponse = try await sendJSONRequest(
                host: cleanHost,
                port: port,
                method: "POST",
                path: "/api/v1/pair",
                token: nil,
                body: body
            )
            let saved = RemoteSavedHost(
                hostDeviceId: response.hostDeviceId,
                hostName: response.hostName,
                host: cleanHost,
                port: port,
                token: response.token,
                pairedAt: Date()
            )
            if let idx = savedHosts.firstIndex(where: { $0.id == saved.id }) {
                savedHosts[idx] = saved
            } else {
                savedHosts.append(saved)
            }
            persistSavedHosts()
            activeHostId = saved.id
            actionFeedback = "已成功配对 \(saved.hostName)"
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func removeSavedHost(_ id: String) {
        savedHosts.removeAll { $0.id == id }
        lastStateRevisionByHostId.removeValue(forKey: id)
        legacyHostsWithoutSnapshot.remove(id)
        legacyStatePollCounterByHostId.removeValue(forKey: id)
        persistSavedHosts()
        if activeHostId == id {
            activeHostId = savedHosts.first?.id
        }
    }

    private var activeRefreshCount = 0
    private var refreshGeneration: UInt64 = 0
    private var lastAppliedGeneration: UInt64 = 0

    func refreshAll(forceFullState: Bool = false) async {
        guard let host = activeHost else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let targetHostId = host.id
        activeRefreshCount += 1
        isRefreshing = true
        defer {
            activeRefreshCount = max(0, activeRefreshCount - 1)
            isRefreshing = activeRefreshCount > 0
        }

        do {
            if legacyHostsWithoutSnapshot.contains(host.id) {
                try await refreshLegacyEndpoints(host: host, targetHostId: targetHostId, generation: generation, forceFullState: forceFullState)
            } else {
                do {
                    let snapshot: RemoteSnapshotDTO = try await getJSON(host: host, path: "/api/v1/snapshot")
                    guard activeHostId == targetHostId, generation >= lastAppliedGeneration else { return }
                    remoteStatus = snapshot.status
                    remoteProxies = snapshot.proxies
                    remoteConnections = snapshot.connections
                    remoteDNSLogs = snapshot.dnsLogs
                    remoteGatewayDevices = snapshot.gatewayDevices
                    remoteLogs = snapshot.logs
                    remoteOutboundErrors = snapshot.outboundErrors
                    remoteTargetSessionTotals = snapshot.targetSessionTotals
                    remoteTargetConnectionCounts = snapshot.targetConnectionCounts
                    remoteTargetSpeeds = snapshot.targetSpeeds
                    remoteRuleSessionTotals = snapshot.ruleSessionTotals

                    if forceFullState || remoteFullState == nil || lastStateRevisionByHostId[host.id] != snapshot.stateRevision {
                        let fullState: RemoteFullStateDTO = try await getJSON(host: host, path: "/api/v1/state")
                        guard activeHostId == targetHostId, generation >= lastAppliedGeneration else { return }
                        remoteFullState = fullState
                        lastStateRevisionByHostId[host.id] = snapshot.stateRevision
                    }
                    lastAppliedGeneration = generation
                } catch let nsErr as NSError where nsErr.domain == "RemoteClient" && nsErr.code == 404 {
                    legacyHostsWithoutSnapshot.insert(host.id)
                    try await refreshLegacyEndpoints(host: host, targetHostId: targetHostId, generation: generation, forceFullState: true)
                }
            }
            guard activeHostId == targetHostId else { return }
            lastError = nil
            snapshotSequence &+= 1
        } catch {
            guard activeHostId == targetHostId, generation >= lastAppliedGeneration else { return }
            lastError = "连接 \(host.hostName) 失败：\(error.localizedDescription)"
            snapshotSequence &+= 1
        }
    }

    private func refreshLegacyEndpoints(
        host: RemoteSavedHost,
        targetHostId: String,
        generation: UInt64,
        forceFullState: Bool
    ) async throws {
        async let statusTask: RemoteStatusSnapshot = getJSON(host: host, path: "/api/v1/status")
        async let proxiesTask: [RemoteProxyGroupDTO]? = try? getJSON(host: host, path: "/api/v1/proxies")
        async let connectionsTask: [RemoteConnectionDTO]? = try? getJSON(host: host, path: "/api/v1/connections")
        async let dnsLogsTask: [RemoteDNSLogDTO]? = try? getJSON(host: host, path: "/api/v1/dns-logs")
        async let gatewayDevicesTask: [GatewayClientDevice]? = try? getJSON(host: host, path: "/api/v1/gateway-devices")
        async let logsTask: RemoteLogsDTO? = try? getJSON(host: host, path: "/api/v1/logs")

        let pollCount = legacyStatePollCounterByHostId[host.id, default: 0]
        legacyStatePollCounterByHostId[host.id] = pollCount + 1
        let shouldFetchFullState = forceFullState || remoteFullState == nil || (pollCount % 3 == 0)

        let status = try await statusTask
        let proxies = (await proxiesTask) ?? []
        let connections = (await connectionsTask) ?? []
        let dnsLogs = (await dnsLogsTask) ?? []
        let gatewayDevices = (await gatewayDevicesTask) ?? []
        let logsDTO = await logsTask

        var fetchedFullState: RemoteFullStateDTO?
        if shouldFetchFullState {
            fetchedFullState = try await getJSON(host: host, path: "/api/v1/state")
        }

        guard activeHostId == targetHostId, generation >= lastAppliedGeneration else { return }
        lastAppliedGeneration = generation
        remoteStatus = status
        remoteProxies = proxies
        remoteConnections = connections
        remoteDNSLogs = dnsLogs
        remoteGatewayDevices = gatewayDevices
        remoteOutboundErrors = nil
        remoteTargetSessionTotals = nil
        remoteTargetConnectionCounts = nil
        remoteTargetSpeeds = nil
        remoteRuleSessionTotals = nil
        if let logsDTO {
            remoteLogs = logsDTO.text
        }
        if let fetchedFullState {
            remoteFullState = fetchedFullState
        }
    }

    func startEngine() async { await performAction(path: "/api/v1/engine/start") }
    func stopEngine() async { await performAction(path: "/api/v1/engine/stop") }
    func hotReload() async { await performAction(path: "/api/v1/engine/hot-reload") }
    func closeAllConnections() async { await performAction(path: "/api/v1/connections/close-all") }
    func closeConnection(id: String) async {
        await performAction(path: "/api/v1/connections/close", body: RemoteCloseConnectionRequest(id: id))
    }
    func flushDNS(includeFakeIP: Bool = false) async {
        await performAction(path: "/api/v1/dns/flush", body: RemoteFlushDNSRequest(includeFakeIP: includeFakeIP))
    }
    func refreshSubscription(id: String? = nil) async {
        await performAction(path: "/api/v1/subscriptions/refresh", body: RemoteRefreshSubscriptionRequest(id: id))
    }
    func refreshHostModule(id: String? = nil) async {
        await performAction(path: "/api/v1/host-modules/refresh", body: RemoteRefreshHostModuleRequest(id: id))
    }
    func updateOnlineRuleProviders() async { await performAction(path: "/api/v1/rule-providers/update") }
    func updateGeoResources() async { await performAction(path: "/api/v1/geo/update") }
    func checkForCoreUpdate() async { await performAction(path: "/api/v1/core/check-update") }
    func installCoreUpdate() async { await performAction(path: "/api/v1/core/install-update") }
    func validateConfig() async { await performAction(path: "/api/v1/core/validate") }
    func clearLogs() async { await performAction(path: "/api/v1/logs/clear") }
    func clearOutboundErrors() async { await performAction(path: "/api/v1/outbound-errors/clear") }

    func saveProfile(_ profile: RoutingProfile) async {
        await performAction(path: "/api/v1/profile", body: profile)
    }

    func updateSystemSettings(_ req: RemoteSystemSettingsUpdateRequest) async {
        await performAction(path: "/api/v1/settings/system", body: req)
    }

    func selectProxy(group: String, node: String) async {
        await performAction(
            path: "/api/v1/proxies/select",
            body: RemoteSelectProxyRequest(group: group, node: node)
        )
    }

    func testDelay(group: String) async {
        await performAction(
            path: "/api/v1/proxies/delay",
            body: RemoteDelayTestRequest(group: group)
        )
    }

    func updateMode(tunEnabled: Bool? = nil, gatewayModeEnabled: Bool? = nil, allowLAN: Bool? = nil) async {
        await performAction(
            path: "/api/v1/settings/mode",
            body: RemoteModeUpdateRequest(
                tunEnabled: tunEnabled,
                gatewayModeEnabled: gatewayModeEnabled,
                allowLAN: allowLAN
            )
        )
    }

    private func performAction(path: String) async {
        guard let host = activeHost else { return }
        do {
            let result: RemoteActionResult = try await sendJSONRequest(
                host: host.host,
                port: host.port,
                method: "POST",
                path: path,
                token: host.token,
                body: Optional<RemoteDelayTestRequest>.none
            )
            if result.ok {
                actionFeedback = result.message
                lastError = nil
            } else {
                lastError = result.message
            }
            await refreshAll(forceFullState: true)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func performAction<B: Encodable>(path: String, body: B) async {
        guard let host = activeHost else { return }
        do {
            let result: RemoteActionResult = try await sendJSONRequest(
                host: host.host,
                port: host.port,
                method: "POST",
                path: path,
                token: host.token,
                body: body
            )
            if result.ok {
                actionFeedback = result.message
                lastError = nil
            } else {
                lastError = result.message
            }
            await refreshAll(forceFullState: true)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled, let self, self.activeHostId != nil else { return }
                await self.refreshAll()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func clearRemoteData() {
        remoteStatus = nil
        remoteProxies = []
        remoteConnections = []
        remoteDNSLogs = []
        remoteGatewayDevices = []
        remoteLogs = ""
        remoteOutboundErrors = nil
        remoteTargetSessionTotals = nil
        remoteTargetConnectionCounts = nil
        remoteTargetSpeeds = nil
        remoteRuleSessionTotals = nil
        remoteFullState = nil
        lastStateRevisionByHostId.removeAll()
        legacyStatePollCounterByHostId.removeAll()
        snapshotSequence &+= 1
    }

    private func getJSON<R: Decodable>(host: RemoteSavedHost, path: String) async throws -> R {
        try await sendJSONRequest(
            host: host.host,
            port: host.port,
            method: "GET",
            path: path,
            token: host.token,
            body: Optional<RemoteDelayTestRequest>.none
        )
    }

    private func sendJSONRequest<B: Encodable, R: Decodable>(
        host: String,
        port: UInt16,
        method: String,
        path: String,
        token: String?,
        body: B?
    ) async throws -> R {
        let bodyData: Data?
        if let body {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            bodyData = try encoder.encode(body)
        } else {
            bodyData = nil
        }

        let response = try await transport.send(
            host: host,
            port: port,
            method: method,
            path: path,
            token: token,
            body: bodyData
        )
        if !(200...299).contains(response.statusCode) {
            if let errObj = try? JSONDecoder().decode(RemoteActionResult.self, from: response.data) {
                throw NSError(domain: "RemoteClient", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: errObj.message])
            }
            throw NSError(domain: "RemoteClient", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(response.statusCode)"])
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(R.self, from: response.data)
    }

    private func resolveEndpointHost(_ endpoint: NWEndpoint) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let params = NWParameters.tcp
            if let ipOptions = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ipOptions.version = .v4
            }
            let conn = NWConnection(to: endpoint, using: params)
            let queue = DispatchQueue(label: "local.routeweaver.resolve-endpoint")
            final class ResumeOnce: @unchecked Sendable {
                private let lock = NSLock()
                private var done = false
                func claim() -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !done else { return false }
                    done = true
                    return true
                }
            }
            let gate = ResumeOnce()

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    if case let .hostPort(host, _) = conn.currentPath?.remoteEndpoint {
                        let raw: String
                        switch host {
                        case .ipv4(let addr): raw = "\(addr)"
                        case .ipv6(let addr): raw = "\(addr)"
                        case .name(let name, _): raw = name
                        @unknown default: raw = "\(host)"
                        }
                        let cleaned = raw.split(separator: "%", maxSplits: 1).first.map(String.init) ?? raw
                        conn.cancel()
                        continuation.resume(returning: cleaned)
                    } else {
                        conn.cancel()
                        continuation.resume(throwing: NSError(
                            domain: "RemoteClient",
                            code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "无法获取远程主机 IP。"]
                        ))
                    }
                case .failed(let err):
                    guard gate.claim() else { return }
                    conn.cancel()
                    continuation.resume(throwing: err)
                case .cancelled:
                    if gate.claim() {
                        continuation.resume(throwing: NSError(
                            domain: "RemoteClient",
                            code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "解析连接已取消。"]
                        ))
                    }
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    private static func loadSavedHosts(from defaults: UserDefaults) -> [RemoteSavedHost] {
        guard let data = defaults.data(forKey: DefaultsKey.savedHosts),
              let decoded = try? JSONDecoder().decode([RemoteSavedHost].self, from: data) else {
            return []
        }
        return decoded
    }

    private func persistSavedHosts() {
        if let data = try? JSONEncoder().encode(savedHosts) {
            userDefaults.set(data, forKey: DefaultsKey.savedHosts)
        }
    }
}
