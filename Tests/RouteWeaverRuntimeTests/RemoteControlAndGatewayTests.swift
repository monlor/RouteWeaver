import Foundation
@testable import RouteWeaverRuntime
@testable import RoutingCore
import XCTest

private final class MockGatewayInspector: GatewayDeviceInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: @Sendable ([MonitoredConnection], Set<String>, Bool) async -> [GatewayClientDevice]

    init(handler: @escaping @Sendable ([MonitoredConnection], Set<String>, Bool) async -> [GatewayClientDevice]) {
        self.handler = handler
    }

    private func currentHandler() -> (@Sendable ([MonitoredConnection], Set<String>, Bool) async -> [GatewayClientDevice]) {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }

    func currentDevices(
        records: [MonitoredConnection],
        localIPs: Set<String>,
        includeARPOnly: Bool
    ) async -> [GatewayClientDevice] {
        let fn = currentHandler()
        return await fn(records, localIPs, includeARPOnly)
    }
}

@MainActor
private final class MockRemoteHostBackend: RemoteHostBackend {
    var localLANIPAddresses: [String] = ["192.168.1.10"]
    var cachedGatewayDevices: [GatewayClientDevice] = [
        GatewayClientDevice(ip: "192.168.1.42", macAddress: "aa:bb:cc:dd:ee:ff", hostname: "iPhone", activeConnectionCount: 1)
    ]
    var gatewayRefreshTriggerCount = 0

    var profile = RoutingProfile(name: "HostProfile")
    var statusRunning = true
    var connections: [RemoteConnectionDTO] = [
        RemoteConnectionDTO(
            id: "conn-1",
            host: "example.com",
            network: "tcp",
            sourceIP: "192.168.1.42",
            destinationIP: "93.184.216.34",
            sourcePort: "54321",
            destinationPort: "443",
            process: "Safari",
            type: "HTTP",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            rule: "MATCH",
            matchedRuleSet: nil,
            chain: "Proxy → HK-01",
            upload: 120,
            download: 480,
            uploadSpeed: 10,
            downloadSpeed: 40,
            isActive: true
        )
    ]
    var dnsLogs: [RemoteDNSLogDTO] = [
        RemoteDNSLogDTO(
            id: UUID().uuidString,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            domain: "example.com",
            queryType: "A",
            status: DNSQueryStatus.resolved.rawValue,
            result: "93.184.216.34",
            upstream: "https://dns.alidns.com/dns-query",
            elapsedMs: 12
        )
    ]
    var subscriptionUsages: [RemoteSubscriptionUsageDTO] = [
        RemoteSubscriptionUsageDTO(
            subscriptionId: UUID().uuidString,
            nodeCount: 2,
            nodes: [
                SubscriptionNode(name: "🇭🇰 香港 01", type: "trojan", server: "hk1.example.com", port: 443),
                SubscriptionNode(name: "🇯🇵 日本 01", type: "vless", server: "jp1.example.com", port: 443)
            ],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            usage: SubscriptionUsage(upload: 100, download: 200, total: 1000, expireTimestamp: nil),
            fetchError: nil
        )
    ]

    func triggerGatewayDevicesRefreshIfNeeded() {
        gatewayRefreshTriggerCount += 1
    }

    func buildStatusSnapshot(hostDeviceId: String, hostName: String) -> RemoteStatusSnapshot {
        RemoteStatusSnapshot(
            hostDeviceId: hostDeviceId,
            hostName: hostName,
            phaseTitle: statusRunning ? "运行中" : "已停止",
            isRunning: statusRunning,
            isBusy: false,
            isTunActive: true,
            isGatewayActive: true,
            isLaunchdManaged: false,
            killSwitchActive: false,
            isIPForwardingEnabled: true,
            tunEnabled: true,
            gatewayModeEnabled: true,
            allowLAN: true,
            mixedPort: 7890,
            ipv6Enabled: false,
            lanIPAddresses: localLANIPAddresses,
            coreVersion: "1.19.0",
            configValidationError: nil,
            lastError: nil,
            uploadSpeed: 10,
            downloadSpeed: 40,
            uploadTotal: 120,
            downloadTotal: 480,
            activeConnectionCount: connections.count,
            totalConnectionCount: connections.count,
            gatewayDeviceCount: cachedGatewayDevices.count,
            canStart: !statusRunning,
            hasPendingHotReload: false
        )
    }

    func buildProxyGroups() -> [RemoteProxyGroupDTO] {
        [RemoteProxyGroupDTO(name: "Proxy", type: "Selector", now: "HK-01", all: ["HK-01", "DIRECT"], delays: ["HK-01": 45])]
    }

    func buildConnections(limit: Int) -> [RemoteConnectionDTO] {
        Array(connections.prefix(limit))
    }

    func buildDNSLogs(limit: Int) -> [RemoteDNSLogDTO] {
        Array(dnsLogs.prefix(limit))
    }

    func buildLogsText(maxChars: Int) -> String {
        String("core ready\n".suffix(maxChars))
    }

    func buildFullStateDTO() -> RemoteFullStateDTO {
        RemoteFullStateDTO(
            profile: profile,
            interfaces: [],
            systemSettings: RemoteSystemSettingsDTO(
                controllerPort: 19090,
                autoStartCoreOnLaunch: true,
                systemKeepAliveEnabled: false,
                launchAtLoginEnabled: false,
                killSwitchActive: false,
                killSwitchAllowLAN: true,
                killSwitchPersistOnBoot: false,
                tunPermissionTitle: "已授权",
                tunPermissionReady: true,
                coreVersion: "1.19.0",
                coreSourceTitle: "内置",
                hasNewerCoreVersion: false,
                latestCoreTag: nil,
                geoUpdateMessage: nil,
                coreUpdateMessage: nil
            ),
            subscriptionUsages: subscriptionUsages,
            trafficHistory: TrafficHistoryAccumulator(),
            trafficRanking: TrafficRankingAccumulator()
        )
    }

    func updateProfile(_ updated: RoutingProfile) -> RemoteActionResult {
        profile = updated
        return RemoteActionResult(ok: true, message: "配置已更新")
    }
    func updateSystemSettings(_ req: RemoteSystemSettingsUpdateRequest) -> RemoteActionResult { RemoteActionResult(ok: true, message: "ok") }
    func startEngine() -> RemoteActionResult { statusRunning = true; return RemoteActionResult(ok: true, message: "started") }
    func stopEngine() -> RemoteActionResult { statusRunning = false; return RemoteActionResult(ok: true, message: "stopped") }
    func hotReload() async -> RemoteActionResult { RemoteActionResult(ok: true, message: "reloaded") }
    func selectProxy(group: String, node: String) -> RemoteActionResult { RemoteActionResult(ok: true, message: "selected") }
    func testDelay(group: String) -> RemoteActionResult { RemoteActionResult(ok: true, message: "tested") }
    func closeConnection(id: String) async -> RemoteActionResult { RemoteActionResult(ok: true, message: "closed") }
    func closeAllConnections() async -> RemoteActionResult { RemoteActionResult(ok: true, message: "closed all") }
    func flushDNS(includeFakeIP: Bool) async -> RemoteActionResult { RemoteActionResult(ok: true, message: "flushed") }
    func refreshSubscription(id: String?) -> RemoteActionResult { RemoteActionResult(ok: true, message: "refreshed") }
    func refreshHostModule(id: String?) -> RemoteActionResult { RemoteActionResult(ok: true, message: "refreshed") }
    func updateOnlineRuleProviders() -> RemoteActionResult { RemoteActionResult(ok: true, message: "updated") }
    func updateGeoResources() -> RemoteActionResult { RemoteActionResult(ok: true, message: "updated") }
    func checkForCoreUpdate() -> RemoteActionResult { RemoteActionResult(ok: true, message: "checked") }
    func installCoreUpdate() -> RemoteActionResult { RemoteActionResult(ok: true, message: "installing") }
    func validateConfig() -> RemoteActionResult { RemoteActionResult(ok: true, message: "validated") }
    func clearLogs() -> RemoteActionResult { RemoteActionResult(ok: true, message: "cleared") }
    func updateMode(_ req: RemoteModeUpdateRequest) -> RemoteActionResult { RemoteActionResult(ok: true, message: "updated") }
}

private final class InMemoryRemoteHTTPTransport: RemoteHTTPTransport, @unchecked Sendable {
    private let handler: RemoteAPIHandler
    private let lock = NSLock()
    private var _recordedPaths: [String] = []

    var recordedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _recordedPaths
    }

    func resetRecordedPaths() {
        lock.lock()
        _recordedPaths.removeAll()
        lock.unlock()
    }

    init(handler: RemoteAPIHandler) {
        self.handler = handler
    }

    private func recordPath(_ entry: String) {
        lock.lock()
        _recordedPaths.append(entry)
        lock.unlock()
    }

    func send(
        host: String,
        port: UInt16,
        method: String,
        path: String,
        token: String?,
        body: Data?
    ) async throws -> RemoteHTTPTransportResponse {
        recordPath("\(method) \(path)")

        var headers: [String: String] = [:]
        if let token {
            headers["authorization"] = "Bearer \(token)"
        }
        let req = RemoteHTTPRequest(method: method, path: path, headers: headers, body: body ?? Data())
        let payload = await MainActor.run {
            // Hop to MainActor to invoke handler
            req
        }
        let responsePayload = await invokeHandler(payload)
        return RemoteHTTPTransportResponse(statusCode: responsePayload.status, data: responsePayload.body)
    }

    @MainActor
    private func invokeHandler(_ req: RemoteHTTPRequest) async -> RemoteHTTPPayload {
        await handler.handle(req)
    }
}

final class RemoteControlAndGatewayTests: XCTestCase {
    private func makeIsolatedDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "RouteWeaverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, suiteName)
    }

    @MainActor
    func testRemoteClientAndAPIHandlerPairingRevisionGatedSyncAndRevocation() async throws {
        let (serverDefaults, serverSuite) = makeIsolatedDefaults()
        let (clientDefaults, clientSuite) = makeIsolatedDefaults()
        defer {
            serverDefaults.removePersistentDomain(forName: serverSuite)
            clientDefaults.removePersistentDomain(forName: clientSuite)
        }

        let backend = MockRemoteHostBackend()
        var currentNow = Date(timeIntervalSince1970: 1_700_000_000)
        let handler = RemoteAPIHandler(
            deviceId: "host-1",
            hostNameProvider: { "MacMini-Host" },
            userDefaults: serverDefaults,
            pairedClientsDefaultsKey: "test.pairedClients",
            lastSeenPersistInterval: 30,
            nowProvider: { currentNow }
        )
        handler.backend = backend

        let transport = InMemoryRemoteHTTPTransport(handler: handler)
        let client = RemoteClientService(
            localDeviceId: "client-1",
            localDeviceName: "MacBook-Client",
            transport: transport,
            userDefaults: clientDefaults
        )

        // 1. Wrong pairing code fails
        let badPair = await client.pairManual(host: "127.0.0.1", port: 19098, pairingCode: "000000")
        XCTAssertFalse(badPair)
        XCTAssertNotNil(client.lastError)

        // 2. Correct pairing code succeeds and rotates code
        let code = handler.activePairingCode
        transport.resetRecordedPaths()
        let okPair = await client.pairManual(host: "127.0.0.1", port: 19098, pairingCode: code)
        XCTAssertTrue(okPair)
        XCTAssertNotEqual(handler.activePairingCode, code)
        XCTAssertEqual(client.savedHosts.count, 1)

        // Let the initial refresh triggered by activeHostId.didSet settle
        for _ in 0..<20 where client.remoteFullState == nil || client.isRefreshing {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(client.remoteFullState)

        transport.resetRecordedPaths()
        await client.refreshAll()
        // Subsequent refreshAll with unchanged stateRevision only fetches /api/v1/snapshot (1 request)
        XCTAssertEqual(transport.recordedPaths, ["GET /api/v1/snapshot"])
        XCTAssertEqual(client.remoteConnections.first?.process, "Safari")
        XCTAssertEqual(client.remoteConnections.first?.destinationPort, "443")
        XCTAssertEqual(client.remoteGatewayDevices.count, 1)
        XCTAssertGreaterThanOrEqual(backend.gatewayRefreshTriggerCount, 1)

        // 3. Mutate backend profile -> stateRevision changes -> refreshAll fetches snapshot + state (2 requests)
        backend.profile.name = "UpdatedProfile"
        transport.resetRecordedPaths()
        await client.refreshAll()
        XCTAssertEqual(transport.recordedPaths, ["GET /api/v1/snapshot", "GET /api/v1/state"])
        XCTAssertEqual(client.remoteFullState?.profile.name, "UpdatedProfile")

        // 4. Subsequent refresh without state change -> only 1 request
        transport.resetRecordedPaths()
        await client.refreshAll()
        XCTAssertEqual(transport.recordedPaths, ["GET /api/v1/snapshot"])

        // 5. Verify lastSeenAt persistence throttling (within 30s -> not persisted; after 30s -> persisted)
        currentNow = currentNow.addingTimeInterval(10)
        await client.refreshAll()
        let persistedBefore30s = try XCTUnwrap(serverDefaults.data(forKey: "test.pairedClients"))
        let decodedBefore = try JSONDecoder().decode([RemotePairedClientRecord].self, from: persistedBefore30s)
        XCTAssertEqual(decodedBefore.first?.lastSeenAt, Date(timeIntervalSince1970: 1_700_000_000))

        currentNow = currentNow.addingTimeInterval(25) // total +35s >= 30s
        await client.refreshAll()
        let persistedAfter30s = try XCTUnwrap(serverDefaults.data(forKey: "test.pairedClients"))
        let decodedAfter = try JSONDecoder().decode([RemotePairedClientRecord].self, from: persistedAfter30s)
        XCTAssertEqual(decodedAfter.first?.lastSeenAt, currentNow)

        // 6. Removed /api/v1/traffic-stats returns 404
        let deadResp = await handler.handle(RemoteHTTPRequest(
            method: "GET",
            path: "/api/v1/traffic-stats",
            headers: ["authorization": "Bearer \(client.savedHosts[0].token)"]
        ))
        XCTAssertEqual(deadResp.status, 404)

        // 7. Revoke client -> subsequent refresh fails with 401
        handler.revokeClient("client-1")
        await client.refreshAll()
        XCTAssertNotNil(client.lastError)
    }

    @MainActor
    func testRemoteFidelityInConnectionMonitorAndSubscriptionStore() {
        let monitor = ConnectionMonitorService()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let dto = RemoteConnectionDTO(
            id: "c-1",
            host: "api.github.com",
            network: "tcp",
            sourceIP: "192.168.1.42",
            destinationIP: "140.82.113.6",
            sourcePort: "55000",
            destinationPort: "443",
            process: "curl",
            type: "SOCKS5",
            startDate: start,
            rule: "DOMAIN-SUFFIX",
            matchedRuleSet: "github.com",
            chain: "Proxy → JP-01",
            upload: 200,
            download: 800,
            uploadSpeed: 20,
            downloadSpeed: 80,
            isActive: true
        )
        let dns = RemoteDNSLogDTO(
            id: UUID().uuidString,
            timestamp: start,
            domain: "api.github.com",
            queryType: "A",
            status: DNSQueryStatus.resolved.rawValue,
            result: "140.82.113.6",
            upstream: "https://1.1.1.1/dns-query",
            elapsedMs: 10
        )

        monitor.applyRemoteData(
            status: nil,
            connections: [dto],
            dnsLogs: [dns],
            trafficHistory: nil,
            trafficRanking: nil
        )

        let record = monitor.tracker.allRecords.first
        XCTAssertEqual(record?.metadata.sourcePort, "55000")
        XCTAssertEqual(record?.metadata.destinationPort, "443")
        XCTAssertEqual(record?.metadata.process, "curl")
        XCTAssertEqual(record?.metadata.type, "SOCKS5")
        XCTAssertEqual(record?.startDate, start)
        XCTAssertEqual(monitor.dnsLogs.first?.upstream, "https://1.1.1.1/dns-query")

        let subStore = SubscriptionStore()
        let subID = UUID()
        let realNodes = [
            SubscriptionNode(name: "🇭🇰 HK-01", type: "trojan", server: "hk.example.com", port: 443),
            SubscriptionNode(name: "🇸🇬 SG-01", type: "vless", server: "sg.example.com", port: 443),
        ]
        subStore.applyRemoteUsages([
            RemoteSubscriptionUsageDTO(
                subscriptionId: subID.uuidString,
                nodeCount: 2,
                nodes: realNodes,
                updatedAt: start,
                usage: nil,
                fetchError: nil
            )
        ])
        XCTAssertEqual(subStore.nodes(forSubscriptionID: subID), realNodes)
    }

    @MainActor
    func testSubscriptionStoreLegacyRemoteMetadataAndPayloadHydration() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("rw-sub-hydrate-\(UUID().uuidString)", isDirectory: true)
        let tunWorkDir = tempDir.appendingPathComponent("work-tun", isDirectory: true)
        try FileManager.default.createDirectory(at: tunWorkDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let subURL = "https://sub.example.com/api/v1/client/subscribe?token=abc"
        let sub = ProxySubscription(name: "LinkVPN", url: subURL, role: .exit)
        let hkGroup = NodeGroup(
            name: "香港出口节点组",
            kind: .exit,
            subscriptionID: sub.id,
            filterPattern: "(?i)(🇭🇰|香港|\\bHK\\b)",
            autoTest: true
        )

        // 1. Metadata-only remote DTO (e.g. older remote host without `nodes` field and no local cache yet)
        //    must NOT fabricate fake "节点 #1" entries that trigger false "匹配 0 个节点" warnings.
        let remoteStore = SubscriptionStore()
        remoteStore.applyRemoteUsages(
            [
                RemoteSubscriptionUsageDTO(
                    subscriptionId: sub.id.uuidString,
                    nodeCount: 18,
                    nodes: nil,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    usage: nil,
                    fetchError: nil
                )
            ],
            subscriptions: [sub],
            fallbackCacheDirectory: tempDir,
            enableNetworkFallbackFetch: false
        )
        XCTAssertEqual(remoteStore.cache[sub.id]?.effectiveNodeCount, 18)
        XCTAssertEqual(remoteStore.cache[sub.id]?.hasNodeDetails, false)
        XCTAssertTrue(remoteStore.nodes(forSubscriptionID: sub.id).isEmpty)
        XCTAssertNil(remoteStore.matchedNodes(for: hkGroup))

        // 2. Once validated payload exists in fallbackCacheDirectory, applyRemoteUsages hydrates real nodes immediately.
        let sampleYAML = Data("""
        proxies:
          - { name: "🇭🇰 香港 IEPL 01", type: trojan, server: hk1.example.com, port: 443 }
          - { name: "🇸🇬 新加坡 01", type: vless, server: sg1.example.com, port: 443 }
        """.utf8)
        _ = try SubscriptionStore.saveValidatedPayload(sampleYAML, for: subURL, in: tempDir)

        remoteStore.applyRemoteUsages(
            [
                RemoteSubscriptionUsageDTO(
                    subscriptionId: sub.id.uuidString,
                    nodeCount: 2,
                    nodes: nil,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    usage: nil,
                    fetchError: nil
                )
            ],
            subscriptions: [sub],
            fallbackCacheDirectory: tempDir,
            enableNetworkFallbackFetch: false
        )
        XCTAssertEqual(remoteStore.cache[sub.id]?.hasNodeDetails, true)
        XCTAssertEqual(remoteStore.matchedNodes(for: hkGroup)?.map(\.name), ["🇭🇰 香港 IEPL 01"])

        // 3. Server-side hydration from Mihomo `work-tun/providers-cache/` when `subscription-cache.json` & `subscription-payloads` are absent.
        let hostCacheDir = tempDir.appendingPathComponent("host-profile", isDirectory: true)
        try FileManager.default.createDirectory(at: hostCacheDir, withIntermediateDirectories: true)
        var profile = RoutingProfile(
            name: "HostGateway",
            subscriptions: [sub],
            nodeGroups: [hkGroup],
            targets: [NetworkTarget(name: "ProxyOut", mode: .proxy, exitGroupID: hkGroup.id)]
        )
        profile.fallbackTarget = .target(profile.targets[0].id)
        let rendered = try MihomoConfig.renderDetailed(profile)
        let providerRel = try XCTUnwrap(rendered.preloadResources.first(where: { $0.kind == .proxyProvider })?.relativePath)
        let providerFile = tunWorkDir.appendingPathComponent(ResourcePreloader.cleanRelativePath(providerRel))
        try FileManager.default.createDirectory(at: providerFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sampleYAML.write(to: providerFile)

        let hostStore = SubscriptionStore()
        hostStore.hydrateMissingCacheEntries(for: profile, in: hostCacheDir, mihomoWorkDirectories: [tunWorkDir])
        XCTAssertEqual(hostStore.nodes(forSubscriptionID: sub.id).count, 2)
        XCTAssertEqual(hostStore.matchedNodes(for: hkGroup)?.map(\.name), ["🇭🇰 香港 IEPL 01"])
    }

    @MainActor
    func testGatewayDeviceStoreAsyncRefreshCachingAndLabelFormatting() async {
        let inspector = MockGatewayInspector { _, _, includeARPOnly in
            var result = [
                GatewayClientDevice(ip: "192.168.1.42", macAddress: "04:0a:1c:00:9f:02", hostname: "iPhone", activeConnectionCount: 2)
            ]
            if includeARPOnly {
                result.append(GatewayClientDevice(ip: "192.168.1.88", macAddress: "11:22:33:44:55:66", hostname: nil))
            }
            return result
        }

        let store = GatewayDeviceStore(inspector: inspector, includeARPOnly: false)
        await store.refresh(connections: [], localIPs: ["192.168.1.10"])
        XCTAssertEqual(store.devices.count, 1)
        XCTAssertEqual(store.lanDeviceNamesByIP, ["192.168.1.42": "iPhone"])
        XCTAssertEqual(store.clientDisplayLabel(for: "192.168.1.42"), "iPhone (192.168.1.42)")
        XCTAssertEqual(store.clientShortLabel(for: "192.168.1.42"), "iPhone")
        XCTAssertEqual(store.clientDisplayLabel(for: TrafficAttribution.localDeviceLabel), TrafficAttribution.localDeviceLabel)

        let lanConn = MonitoredConnection(
            id: "c1",
            metadata: MihomoConnectionMetadata(sourceIP: "192.168.1.42", host: "apple.com"),
            upload: 10,
            download: 20,
            uploadSpeed: 1,
            downloadSpeed: 2,
            startRaw: "",
            startDate: nil,
            firstSeenAt: Date(),
            lastSeenAt: Date(),
            closedAt: nil,
            chains: ["DIRECT"],
            rule: "MATCH",
            rulePayload: "",
            isActive: true
        )
        XCTAssertEqual(store.connectionLANClientLabel(for: lanConn, localIPs: ["192.168.1.10"]), "iPhone")

        let localConn = MonitoredConnection(
            id: "c2",
            metadata: MihomoConnectionMetadata(sourceIP: "192.168.1.10", host: "apple.com"),
            upload: 10,
            download: 20,
            uploadSpeed: 1,
            downloadSpeed: 2,
            startRaw: "",
            startDate: nil,
            firstSeenAt: Date(),
            lastSeenAt: Date(),
            closedAt: nil,
            chains: ["DIRECT"],
            rule: "MATCH",
            rulePayload: "",
            isActive: true
        )
        XCTAssertNil(store.connectionLANClientLabel(for: localConn, localIPs: ["192.168.1.10"]))

        await store.refresh(connections: [], localIPs: ["192.168.1.10"], includeARPOnly: true)
        XCTAssertEqual(store.devices.count, 2)
    }

    func testConnectionMonitorGenericArchiveSaveLoadAndFallback() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("rw-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var history = TrafficHistoryAccumulator()
        history.recordDelta(uploadDelta: 1024, downloadDelta: 2048, targetDeltas: ["Proxy": TrafficBytes(upload: 1024, download: 2048)], at: Date())
        ConnectionMonitorService.saveArchive(history, fileName: "traffic-history.json", in: tempDir)

        let loadedHistory = ConnectionMonitorService.loadArchive(
            TrafficHistoryAccumulator.self,
            fileName: "traffic-history.json",
            in: tempDir,
            defaultValue: TrafficHistoryAccumulator()
        )
        XCTAssertEqual(loadedHistory.dailyRecords.values.first?.upload, 1024)
        XCTAssertEqual(loadedHistory.dailyRecords.values.first?.download, 2048)

        // Corrupted file falls back cleanly to defaultValue
        let corruptURL = tempDir.appendingPathComponent("traffic-ranking.json")
        try Data("not-json".utf8).write(to: corruptURL)
        let fallbackRanking = ConnectionMonitorService.loadArchive(
            TrafficRankingAccumulator.self,
            fileName: "traffic-ranking.json",
            in: tempDir,
            defaultValue: TrafficRankingAccumulator()
        )
        XCTAssertTrue(fallbackRanking.dailyBuckets.isEmpty)
    }

    @MainActor
    func testRemoteInstallCoreUpdateEndpointRoutesThroughClient() async throws {
        let (serverDefaults, serverSuite) = makeIsolatedDefaults()
        let (clientDefaults, clientSuite) = makeIsolatedDefaults()
        defer {
            serverDefaults.removePersistentDomain(forName: serverSuite)
            clientDefaults.removePersistentDomain(forName: clientSuite)
        }

        let backend = MockRemoteHostBackend()
        let handler = RemoteAPIHandler(
            deviceId: "host-core-update",
            hostNameProvider: { "MacMini-Host" },
            userDefaults: serverDefaults,
            pairedClientsDefaultsKey: "test.pairedClients"
        )
        handler.backend = backend

        let transport = InMemoryRemoteHTTPTransport(handler: handler)
        let client = RemoteClientService(
            localDeviceId: "client-core-update",
            localDeviceName: "MacBook-Client",
            transport: transport,
            userDefaults: clientDefaults
        )

        let code = handler.activePairingCode
        let paired = await client.pairManual(host: "127.0.0.1", port: 19098, pairingCode: code)
        XCTAssertTrue(paired)
        for _ in 0..<20 where client.isRefreshing {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        transport.resetRecordedPaths()

        await client.installCoreUpdate()
        XCTAssertTrue(transport.recordedPaths.contains("POST /api/v1/core/install-update"))
        XCTAssertEqual(client.actionFeedback, "installing")
    }
}
