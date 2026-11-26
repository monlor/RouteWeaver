import Combine
import Foundation
@testable import RouteWeaverRuntime
@testable import RoutingCore
import XCTest

private final class StubGatewayInspector: GatewayDeviceInspecting, @unchecked Sendable {
    var devices: [GatewayClientDevice]

    init(devices: [GatewayClientDevice] = []) {
        self.devices = devices
    }

    func currentDevices(
        records: [MonitoredConnection],
        localIPs: Set<String>,
        includeARPOnly: Bool
    ) async -> [GatewayClientDevice] {
        devices
    }
}

private final class StubRemoteTransport: RemoteHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _recordedRequests: [(method: String, path: String, body: Data?)] = []
    private var handler: @Sendable (String, String, Data?) throws -> RemoteHTTPTransportResponse

    var recordedRequests: [(method: String, path: String, body: Data?)] {
        lock.withLock { _recordedRequests }
    }

    init(handler: @escaping @Sendable (String, String, Data?) throws -> RemoteHTTPTransportResponse) {
        self.handler = handler
    }

    func setHandler(_ handler: @escaping @Sendable (String, String, Data?) throws -> RemoteHTTPTransportResponse) {
        lock.withLock { self.handler = handler }
    }

    func send(
        host: String,
        port: UInt16,
        method: String,
        path: String,
        token: String?,
        body: Data?
    ) async throws -> RemoteHTTPTransportResponse {
        let fn = lock.withLock {
            _recordedRequests.append((method, path, body))
            return handler
        }
        return try fn(method, path, body)
    }
}

private final class StubNetworkSetupTransport: NetworkSetupTransport, @unchecked Sendable {
    func run(_ arguments: [String]) async throws -> NetworkSetupCommandResult {
        NetworkSetupCommandResult(terminationStatus: 0)
    }
}

private final class StubRemoteLinkStore: RemoteNetworkLinkStore {
    var storedLink: ActiveRemoteNetworkLink?
    init(storedLink: ActiveRemoteNetworkLink? = nil) { self.storedLink = storedLink }
    func loadActiveLink() -> ActiveRemoteNetworkLink? { storedLink }
    func saveActiveLink(_ link: ActiveRemoteNetworkLink?) { storedLink = link }
}

@MainActor
final class DeviceSessionTests: XCTestCase {
    private func makeDefaults() -> (defaults: UserDefaults, suite: String) {
        let suite = "DeviceSessionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, suite)
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private func makeSnapshot(
        revision: String = "rev-1",
        isRunning: Bool = true,
        connections: [RemoteConnectionDTO] = [],
        logs: String = "",
        gatewayDevices: [GatewayClientDevice] = []
    ) -> RemoteSnapshotDTO {
        RemoteSnapshotDTO(
            status: RemoteStatusSnapshot(
                hostDeviceId: "host-1",
                hostName: "MacMini",
                phaseTitle: isRunning ? "运行中" : "已停止",
                isRunning: isRunning,
                isBusy: false,
                isTunActive: false,
                isGatewayActive: false,
                isLaunchdManaged: false,
                killSwitchActive: false,
                isIPForwardingEnabled: false,
                tunEnabled: false,
                gatewayModeEnabled: false,
                allowLAN: false,
                mixedPort: 7890,
                ipv6Enabled: false,
                lanIPAddresses: ["192.168.1.2"],
                coreVersion: "1.19.0",
                configValidationError: nil,
                lastError: nil,
                uploadSpeed: Int64(connections.count * 100),
                downloadSpeed: Int64(connections.count * 500),
                uploadTotal: 1000,
                downloadTotal: 5000,
                activeConnectionCount: connections.count,
                totalConnectionCount: connections.count,
                gatewayDeviceCount: gatewayDevices.count,
                canStart: !isRunning,
                hasPendingHotReload: false
            ),
            proxies: [],
            connections: connections,
            dnsLogs: [],
            gatewayDevices: gatewayDevices,
            logs: logs,
            stateRevision: revision
        )
    }

    private func makeFullState(profile: RoutingProfile) -> RemoteFullStateDTO {
        RemoteFullStateDTO(
            profile: profile,
            interfaces: [],
            systemSettings: RemoteSystemSettingsDTO(
                controllerPort: 19090,
                autoStartCoreOnLaunch: false,
                systemKeepAliveEnabled: true,
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
            subscriptionUsages: [],
            trafficHistory: TrafficHistoryAccumulator(),
            trafficRanking: TrafficRankingAccumulator()
        )
    }

    private func makePairedClient(
        transport: any RemoteHTTPTransport,
        defaults: UserDefaults
    ) async throws -> (client: RemoteClientService, hostId: String) {
        let client = RemoteClientService(
            localDeviceId: "local-test",
            localDeviceName: "LocalMac",
            transport: transport,
            userDefaults: defaults
        )
        let pairResp = RemotePairingResponse(
            token: "secret-token",
            hostDeviceId: "host-1",
            hostName: "MacMini"
        )
        // Pair via a temporary handler if needed; caller sets up transport.
        _ = pairResp
        return (client, "host-1")
    }

    func testSwitchingBetweenLocalAndRemoteIsolatesProfilesAndRestoresLocal() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let remoteProfile = RoutingProfile(name: "RemoteMacProfile", mixedPort: 8899)
        let snapshotData = try encodeJSON(makeSnapshot(revision: "rev-1"))
        let fullStateData = try encodeJSON(makeFullState(profile: remoteProfile))
        let pairData = try encodeJSON(RemotePairingResponse(
            token: "tok-1",
            hostDeviceId: "host-1",
            hostName: "MacMini"
        ))
        let okData = try encodeJSON(RemoteActionResult(ok: true, message: "ok"))

        let transport = StubRemoteTransport { _, path, _ in
            switch path {
            case "/api/v1/pair":
                return RemoteHTTPTransportResponse(statusCode: 200, data: pairData)
            case "/api/v1/snapshot":
                return RemoteHTTPTransportResponse(statusCode: 200, data: snapshotData)
            case "/api/v1/state":
                return RemoteHTTPTransportResponse(statusCode: 200, data: fullStateData)
            default:
                return RemoteHTTPTransportResponse(statusCode: 200, data: okData)
            }
        }

        let client = RemoteClientService(
            localDeviceId: "local-dev",
            localDeviceName: "MyMac",
            transport: transport,
            userDefaults: defaults
        )
        let paired = await client.pairManual(host: "192.168.1.50", port: 19190, pairingCode: "123456")
        XCTAssertTrue(paired)

        let appState = AppState(
            remoteClient: client,
            userDefaults: defaults,
            bootstrapOnInit: false
        )
        appState.profile = RoutingProfile(name: "LocalMacProfile", mixedPort: 7890)
        XCTAssertEqual(appState.localProfile.name, "LocalMacProfile")

        // Switch to remote
        appState.selectDevice(.remote("host-1"))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(appState.isViewingRemote)
        XCTAssertEqual(appState.profile.name, "RemoteMacProfile")
        XCTAssertEqual(appState.localProfile.name, "LocalMacProfile")

        // Edit remote profile -> must NOT clobber localProfile
        appState.profile.name = "EditedRemoteProfile"
        XCTAssertEqual(appState.localProfile.name, "LocalMacProfile")

        // Switch back to local -> restores localProfile cleanly
        appState.selectDevice(.local)
        XCTAssertFalse(appState.isViewingRemote)
        XCTAssertEqual(appState.profile.name, "LocalMacProfile")
    }

    func testHotReloadDirtyTrackingAndDeviceActionDispatch() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let driver = FakeRuntimeDriver()
        let engine = EngineController(driver: driver)
        let appState = AppState(
            engine: engine,
            userDefaults: defaults,
            bootstrapOnInit: false
        )

        let initialProfile = RoutingProfile(name: "Initial", mixedPort: 7890)
        appState.profile = initialProfile

        // Simulate running engine via FakeRuntimeHandle
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fakeBinary = tempDir.appendingPathComponent("mihomo")
        FileManager.default.createFile(atPath: fakeBinary.path, contents: Data(), attributes: [.posixPermissions: 0o755])

        let sessionContext = EngineSessionContext(
            controllerPort: 19090,
            secret: "sec",
            trackedGroups: [],
            runningProfile: initialProfile
        )
        engine.start(
            config: Data("mixed-port: 7890\n".utf8),
            binary: fakeBinary,
            interfaces: [],
            useTun: false,
            useGateway: false,
            useSystemKeepAlive: false,
            preloadResources: [],
            subscriptionCacheDirectory: tempDir,
            sessionContext: sessionContext
        )
        driver.nextHandle.emit(.pidUpdated(9001))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(appState.isCoreRunning)
        appState.localSession.markRunningProfileSnapshotForTesting(initialProfile)
        XCTAssertFalse(appState.activeHasPendingHotReload)

        // Mutate profile while running -> marks pending hot reload
        appState.profile.mixedPort = 7891
        XCTAssertTrue(appState.activeHasPendingHotReload)

        // Revert back to baseline -> clears pending hot reload
        appState.profile.mixedPort = 7890
        XCTAssertFalse(appState.activeHasPendingHotReload)

        // Stop through unified DeviceSession action
        appState.stop()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(driver.nextHandle.stopAsyncCalls, 1)
        XCTAssertFalse(appState.isCoreRunning)
        XCTAssertFalse(appState.activeHasPendingHotReload)
    }

    func testRemoteTelemetryUpdateIsolatesAppStateAndPreservesUnflushedProfileEdits() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let remoteProfile = RoutingProfile(name: "RemoteOriginal", mixedPort: 7890)
        let fullStateData = try encodeJSON(makeFullState(profile: remoteProfile))
        let pairData = try encodeJSON(RemotePairingResponse(
            token: "tok-1",
            hostDeviceId: "host-1",
            hostName: "MacMini"
        ))
        let okData = try encodeJSON(RemoteActionResult(ok: true, message: "ok"))
        let snap1 = try encodeJSON(makeSnapshot(revision: "rev-1", connections: [], logs: "boot\n"))

        let transport = StubRemoteTransport { _, path, _ in
            switch path {
            case "/api/v1/pair":
                return RemoteHTTPTransportResponse(statusCode: 200, data: pairData)
            case "/api/v1/snapshot":
                return RemoteHTTPTransportResponse(statusCode: 200, data: snap1)
            case "/api/v1/state":
                return RemoteHTTPTransportResponse(statusCode: 200, data: fullStateData)
            default:
                return RemoteHTTPTransportResponse(statusCode: 200, data: okData)
            }
        }

        let client = RemoteClientService(
            localDeviceId: "local-dev",
            localDeviceName: "MyMac",
            transport: transport,
            userDefaults: defaults
        )
        _ = await client.pairManual(host: "192.168.1.50", port: 19190, pairingCode: "123456")

        let appState = AppState(
            remoteClient: client,
            userDefaults: defaults,
            bootstrapOnInit: false
        )
        appState.profile = RoutingProfile(name: "LocalUntouched", mixedPort: 7000)
        appState.selectDevice(.remote("host-1"))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(appState.profile.name, "RemoteOriginal")

        // Count AppState.objectWillChange emissions during a telemetry-only poll
        var appStateChangeCount = 0
        let cancellable = appState.objectWillChange.sink { _ in
            appStateChangeCount += 1
        }
        defer { cancellable.cancel() }

        let conn = RemoteConnectionDTO(
            id: "c1",
            host: "example.com",
            network: "tcp",
            sourceIP: "192.168.1.20",
            destinationIP: "93.184.216.34",
            sourcePort: "50000",
            destinationPort: "443",
            process: "curl",
            type: "HTTP",
            startDate: Date(),
            rule: "MATCH",
            matchedRuleSet: nil,
            chain: "DIRECT",
            upload: 100,
            download: 200,
            uploadSpeed: 50,
            downloadSpeed: 100,
            isActive: true
        )
        let snap2 = try encodeJSON(makeSnapshot(revision: "rev-1", connections: [conn], logs: "boot\nline2\n"))
        transport.setHandler { _, path, _ in
            switch path {
            case "/api/v1/snapshot":
                return RemoteHTTPTransportResponse(statusCode: 200, data: snap2)
            case "/api/v1/state":
                return RemoteHTTPTransportResponse(statusCode: 200, data: fullStateData)
            default:
                return RemoteHTTPTransportResponse(statusCode: 200, data: okData)
            }
        }

        await client.refreshAll()
        try? await Task.sleep(nanoseconds: 30_000_000)

        // Telemetry stores updated, but AppState did NOT re-render and localProfile was untouched
        XCTAssertEqual(appState.activeConnectionMonitor.tracker.allRecords.count, 1)
        XCTAssertEqual(appState.activeLogStore.text, "boot\nline2\n")
        XCTAssertEqual(appStateChangeCount, 0)
        XCTAssertEqual(appState.localProfile.name, "LocalUntouched")

        // Edit remote profile and trigger a poll before the 450ms debounced save fires
        appState.profile.name = "UserInFlightEdit"
        await client.refreshAll()
        try? await Task.sleep(nanoseconds: 30_000_000)

        // Unflushed local edit is preserved instead of overwritten by stale remoteFullState
        XCTAssertEqual(appState.profile.name, "UserInFlightEdit")
    }

    func testGatewayDeviceStoreLabelsAndRemoteDeviceDelegation() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let localInspector = StubGatewayInspector(devices: [
            GatewayClientDevice(ip: "192.168.1.33", macAddress: "11:22:33:44:55:66", hostname: "AppleTV", activeConnectionCount: 2)
        ])
        let appState = AppState(
            gatewayInspector: localInspector,
            userDefaults: defaults,
            bootstrapOnInit: false
        )

        appState.refreshGatewayDevices()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(appState.activeGatewayDevices.count, 1)
        XCTAssertEqual(appState.lanDeviceNamesByIP["192.168.1.33"], "AppleTV")
        XCTAssertEqual(appState.clientShortLabel(for: "192.168.1.33"), "AppleTV")
        XCTAssertEqual(appState.clientDisplayLabel(for: "192.168.1.33"), "AppleTV (192.168.1.33)")
    }

    func testRemoteNetworkBridgeMutualExclusionPreventsLocalCoreStart() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let driver = FakeRuntimeDriver()
        let engine = EngineController(driver: driver)
        let activeLink = ActiveRemoteNetworkLink(
            mode: .httpProxy,
            remoteHostId: "host-1",
            remoteHostName: "MacMini",
            remoteIP: "192.168.1.50",
            port: 7890,
            serviceName: "Wi-Fi",
            previousIPv4: nil,
            previousDNS: [],
            previousSOCKS: nil
        )
        let bridge = RemoteNetworkBridge(
            transport: StubNetworkSetupTransport(),
            linkStore: StubRemoteLinkStore(storedLink: activeLink)
        )
        var emittedAlert: String?

        let localSession = LocalDeviceSession(
            engine: engine,
            userDefaults: defaults,
            bootstrapOnInit: false,
            activeRemoteBridgeDescriptionProvider: {
                guard let link = bridge.activeLink else { return nil }
                return "远程设备「\(link.remoteHostName)」的\(link.mode.title)"
            }
        )
        let delegate = ClosureSessionDelegate(onAlert: { emittedAlert = $0 })
        localSession.delegate = delegate

        XCTAssertFalse(localSession.canStart)
        localSession.start()
        XCTAssertNil(driver.lastLaunchRequest)
        XCTAssertNotNil(emittedAlert)
        XCTAssertTrue(emittedAlert?.contains("MacMini") == true)
    }

    func testAutoSwitchToActiveRemoteDeviceOnOpenFromGatewayOrBridge() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let remoteProfile = RoutingProfile(name: "MacMiniGatewayProfile", mixedPort: 7890)
        let snapshotData = try encodeJSON(makeSnapshot(revision: "rev-1"))
        let fullStateData = try encodeJSON(makeFullState(profile: remoteProfile))
        let pairData = try encodeJSON(RemotePairingResponse(
            token: "tok-mini",
            hostDeviceId: "macmini-id",
            hostName: "monlor-macmini"
        ))
        let okData = try encodeJSON(RemoteActionResult(ok: true, message: "ok"))

        let transport = StubRemoteTransport { _, path, _ in
            switch path {
            case "/api/v1/pair":
                return RemoteHTTPTransportResponse(statusCode: 200, data: pairData)
            case "/api/v1/snapshot":
                return RemoteHTTPTransportResponse(statusCode: 200, data: snapshotData)
            case "/api/v1/state":
                return RemoteHTTPTransportResponse(statusCode: 200, data: fullStateData)
            default:
                return RemoteHTTPTransportResponse(statusCode: 200, data: okData)
            }
        }

        let client = RemoteClientService(
            localDeviceId: "macbook-id",
            localDeviceName: "MacBook",
            transport: transport,
            userDefaults: defaults
        )
        _ = await client.pairManual(host: "192.168.100.5", port: 19098, pairingCode: "123456")
        client.activeHostId = nil

        // 1. System IPv4 default gateway points to monlor-macmini (even without RemoteNetworkBridge record) -> auto-switches to monlor-macmini
        var currentRouting = SystemNetworkRoutingSnapshot(defaultGatewayIPv4: "192.168.100.5")
        let stateFromSystemGateway = AppState(
            remoteClient: client,
            routingSnapshotProvider: { currentRouting },
            userDefaults: defaults,
            bootstrapOnInit: false
        )
        XCTAssertEqual(stateFromSystemGateway.selectedDevice, .remote("macmini-id"))
        XCTAssertTrue(stateFromSystemGateway.isViewingRemote)

        // 2. User manually switches to local while window stays open; reopening window when gateway switched back to normal router (192.168.100.1) stays on local
        stateFromSystemGateway.selectDevice(.local)
        XCTAssertEqual(stateFromSystemGateway.selectedDevice, .local)
        currentRouting = SystemNetworkRoutingSnapshot(defaultGatewayIPv4: "192.168.100.1")
        stateFromSystemGateway.syncSelectedDeviceOnWindowOpen()
        XCTAssertEqual(stateFromSystemGateway.selectedDevice, .local)

        // 3. Persisted RemoteNetworkBridge link when consistent with routing snapshot -> auto-switches to monlor-macmini on init
        let activeLink = ActiveRemoteNetworkLink(
            mode: .gateway,
            remoteHostId: "macmini-id",
            remoteHostName: "monlor-macmini",
            remoteIP: "192.168.100.5",
            port: nil,
            serviceName: "Wi-Fi",
            previousIPv4: nil,
            previousDNS: [],
            previousSOCKS: nil
        )
        let bridge = RemoteNetworkBridge(
            transport: StubNetworkSetupTransport(),
            linkStore: StubRemoteLinkStore(storedLink: activeLink)
        )
        let stateFromBridge = AppState(
            remoteClient: client,
            remoteBridge: bridge,
            routingSnapshotProvider: { SystemNetworkRoutingSnapshot(defaultGatewayIPv4: "192.168.100.5") },
            userDefaults: defaults,
            bootstrapOnInit: false
        )
        XCTAssertEqual(stateFromBridge.selectedDevice, .remote("macmini-id"))

        // 4. Stale bridge record while on a completely different router (e.g. mobile hotspot 172.20.10.1) falls back to local
        let stateOnHotspot = AppState(
            remoteClient: client,
            remoteBridge: bridge,
            routingSnapshotProvider: { SystemNetworkRoutingSnapshot(defaultGatewayIPv4: "172.20.10.1") },
            userDefaults: defaults,
            bootstrapOnInit: false
        )
        XCTAssertEqual(stateOnHotspot.selectedDevice, .local)
    }

    func testLegacyRemoteServerWithoutSnapshotEndpointFallsBackCleanly() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let pairData = try encodeJSON(RemotePairingResponse(
            token: "legacy-tok",
            hostDeviceId: "legacy-mini",
            hostName: "monlor-macmini"
        ))
        let notFoundData = try encodeJSON(RemoteActionResult(ok: false, message: "未知接口：GET /api/v1/snapshot"))
        let legacyStatusJSON = Data("""
        {
          "hostDeviceId": "legacy-mini",
          "hostName": "monlor-macmini",
          "phaseTitle": "运行中",
          "isRunning": true,
          "isBusy": false,
          "isTunActive": true,
          "tunEnabled": true,
          "allowLAN": true,
          "mixedPort": 7890,
          "ipv6Enabled": false
        }
        """.utf8)
        let proxiesData = try encodeJSON([
            RemoteProxyGroupDTO(name: "Proxy", type: "URLTest", now: "🇭🇰 HK-01", all: ["🇭🇰 HK-01"], delays: ["🇭🇰 HK-01": 32])
        ])
        struct MinimalLegacyStateEnvelope: Encodable {
            let profile: RoutingProfile
        }
        let legacyStateJSON = try encodeJSON(MinimalLegacyStateEnvelope(
            profile: RoutingProfile(name: "LegacyMacMiniProfile", mixedPort: 7890)
        ))

        let transport = StubRemoteTransport { _, path, _ in
            switch path {
            case "/api/v1/pair":
                return RemoteHTTPTransportResponse(statusCode: 200, data: pairData)
            case "/api/v1/snapshot":
                return RemoteHTTPTransportResponse(statusCode: 404, data: notFoundData)
            case "/api/v1/status":
                return RemoteHTTPTransportResponse(statusCode: 200, data: legacyStatusJSON)
            case "/api/v1/proxies":
                return RemoteHTTPTransportResponse(statusCode: 200, data: proxiesData)
            case "/api/v1/connections", "/api/v1/dns-logs", "/api/v1/gateway-devices":
                return RemoteHTTPTransportResponse(statusCode: 200, data: Data("[]".utf8))
            case "/api/v1/logs":
                return RemoteHTTPTransportResponse(statusCode: 200, data: Data(#"{"text":"ready"}"#.utf8))
            case "/api/v1/state":
                return RemoteHTTPTransportResponse(statusCode: 200, data: legacyStateJSON)
            default:
                return RemoteHTTPTransportResponse(statusCode: 404, data: notFoundData)
            }
        }

        let client = RemoteClientService(
            localDeviceId: "macbook",
            localDeviceName: "MacBook",
            transport: transport,
            userDefaults: defaults
        )
        _ = await client.pairManual(host: "192.168.100.5", port: 19098, pairingCode: "123456")
        await client.refreshAll()

        XCTAssertNil(client.lastError)
        XCTAssertEqual(client.remoteStatus?.isRunning, true)
        XCTAssertEqual(client.remoteProxies.first?.now, "🇭🇰 HK-01")
        XCTAssertEqual(client.remoteFullState?.profile.name, "LegacyMacMiniProfile")
    }

    func testRemoteStartWhileRunningPreservesControllerSecretAndAllowsRemoteHotReload() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fakeBinary = tempDir.appendingPathComponent("mihomo")
        FileManager.default.createFile(atPath: fakeBinary.path, contents: Data(), attributes: [.posixPermissions: 0o755])

        let driver = FakeRuntimeDriver()
        let engine = EngineController(stateDir: tempDir.appendingPathComponent("state", isDirectory: true), driver: driver)

        final class ExpectedSecretBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: String?
            func setIfNil(_ s: String) {
                lock.withLock {
                    if value == nil { value = s }
                }
            }
            func get() -> String? { lock.withLock { value } }
        }
        let launchedSecret = ExpectedSecretBox()

        let proxyStore = LiveProxyStore { port, secret, groups in
            launchedSecret.setIfNil(secret)
            let client = FakeMihomoControlClient(port: port, secret: secret, trackedGroups: groups)
            client.reloadHandler = { callerSecret, _ in
                if callerSecret != launchedSecret.get() {
                    throw LocalController.ControllerError.http(401)
                }
            }
            return client
        }

        let appState = AppState(
            engine: engine,
            liveProxyStore: proxyStore,
            userDefaults: defaults,
            bootstrapOnInit: false
        )
        appState.localSession.coreBinaryStore.setBinaryForTesting(fakeBinary)
        appState.remoteServer.attach(appState: appState)

        var initialProfile = RoutingProfile(name: "GatewayMac", mixedPort: 7890)
        initialProfile.setTunEnabled(false)
        appState.profile = initialProfile

        // Start local engine through LocalDeviceSession.start()
        appState.startLocal()
        for _ in 0..<40 where !appState.engine.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(appState.engine.isRunning)
        XCTAssertFalse(appState.localCanStart)
        let originalSecret = try XCTUnwrap(launchedSecret.get())
        XCTAssertEqual(appState.liveProxyStore.controller?.secret, originalSecret)

        // Pair a remote client against the real RemoteAPIHandler + AppStateRemoteHostBackend
        let transport = InMemoryRemoteHTTPTransportForSessionTests(handler: appState.remoteServer.apiHandler)
        let remoteClient = RemoteClientService(
            localDeviceId: "ios-client",
            localDeviceName: "iPhone",
            transport: transport,
            userDefaults: defaults
        )
        let paired = await remoteClient.pairManual(
            host: "127.0.0.1",
            port: 19098,
            pairingCode: appState.remoteServer.apiHandler.activePairingCode
        )
        XCTAssertTrue(paired)

        // Trigger remote Start while core is already running -> must NOT rotate/poison controller secret
        await remoteClient.startEngine()
        XCTAssertNil(remoteClient.lastError)
        XCTAssertEqual(appState.liveProxyStore.controller?.secret, originalSecret)

        // Trigger remote Hot Reload -> must succeed with 200 and NOT trigger HTTP 401 alert on host
        appState.alertText = nil
        await remoteClient.hotReload()
        XCTAssertNil(remoteClient.lastError)
        XCTAssertEqual(remoteClient.actionFeedback, "配置已热重载生效。")
        XCTAssertNil(appState.alertText)
    }

    func testRemoteHotReloadSelfHealsStaleControllerSecretFromPersistedEngineConfig() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fakeBinary = tempDir.appendingPathComponent("mihomo")
        FileManager.default.createFile(atPath: fakeBinary.path, contents: Data(), attributes: [.posixPermissions: 0o755])

        let driver = FakeRuntimeDriver()
        let engine = EngineController(stateDir: tempDir.appendingPathComponent("state", isDirectory: true), driver: driver)
        let realSecret = "real-persisted-mihomo-secret"

        let proxyStore = LiveProxyStore { port, secret, groups in
            let client = FakeMihomoControlClient(port: port, secret: secret, trackedGroups: groups)
            client.reloadHandler = { callerSecret, _ in
                guard callerSecret == realSecret else {
                    throw LocalController.ControllerError.http(401)
                }
            }
            return client
        }

        let appState = AppState(
            engine: engine,
            liveProxyStore: proxyStore,
            userDefaults: defaults,
            bootstrapOnInit: false
        )
        var initialProfile = RoutingProfile(name: "GatewayMac", mixedPort: 7890)
        initialProfile.setTunEnabled(false)
        appState.profile = initialProfile

        let rendered = try MihomoConfig.renderDetailed(initialProfile, controllerPort: 19090, secret: realSecret)
        engine.start(
            config: rendered.data,
            binary: fakeBinary,
            interfaces: [],
            useTun: false,
            useGateway: false,
            useSystemKeepAlive: false,
            preloadResources: [],
            subscriptionCacheDirectory: tempDir,
            sessionContext: EngineSessionContext(
                controllerPort: 19090,
                secret: realSecret,
                trackedGroups: rendered.activeProxyGroupNames,
                runningProfile: initialProfile
            )
        )
        for _ in 0..<40 where !engine.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(engine.isRunning)

        // Simulate a stale/mismatched controller secret in LiveProxyStore
        let staleClient = proxyStore.makeClient(port: 19090, secret: "stale-wrong-secret", trackedGroups: [])
        proxyStore.activate(controller: staleClient, trackedGroups: [])

        let result = await appState.hotReloadLocalFromRemote()
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.message, "配置已热重载生效。")
        XCTAssertEqual(appState.liveProxyStore.controller?.secret, realSecret)
        XCTAssertNil(appState.alertText)
    }

    func testRemoteDeviceSessionHotReloadFlushesPendingProfileEditsFirst() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let remoteProfile = RoutingProfile(name: "RemoteOriginal", mixedPort: 7890)
        let fullStateData = try encodeJSON(makeFullState(profile: remoteProfile))
        let pairData = try encodeJSON(RemotePairingResponse(
            token: "tok-1",
            hostDeviceId: "host-1",
            hostName: "MacMini"
        ))
        let okSaveData = try encodeJSON(RemoteActionResult(ok: true, message: "saved"))
        let okReloadData = try encodeJSON(RemoteActionResult(ok: true, message: "配置已热重载生效。"))
        let snapData = try encodeJSON(makeSnapshot(revision: "rev-1"))

        let transport = StubRemoteTransport { _, path, _ in
            switch path {
            case "/api/v1/pair":
                return RemoteHTTPTransportResponse(statusCode: 200, data: pairData)
            case "/api/v1/profile":
                return RemoteHTTPTransportResponse(statusCode: 200, data: okSaveData)
            case "/api/v1/engine/hot-reload":
                return RemoteHTTPTransportResponse(statusCode: 200, data: okReloadData)
            case "/api/v1/snapshot":
                return RemoteHTTPTransportResponse(statusCode: 200, data: snapData)
            case "/api/v1/state":
                return RemoteHTTPTransportResponse(statusCode: 200, data: fullStateData)
            default:
                return RemoteHTTPTransportResponse(statusCode: 200, data: okSaveData)
            }
        }

        let client = RemoteClientService(
            localDeviceId: "local-dev",
            localDeviceName: "MyMac",
            transport: transport,
            userDefaults: defaults
        )
        _ = await client.pairManual(host: "192.168.1.50", port: 19098, pairingCode: "123456")

        let appState = AppState(
            remoteClient: client,
            userDefaults: defaults,
            bootstrapOnInit: false
        )
        appState.selectDevice(.remote("host-1"))
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Mutate profile and immediately trigger hotReload before the 450ms debounce fires
        appState.profile.mixedPort = 7895
        appState.hotReload()
        try? await Task.sleep(nanoseconds: 80_000_000)

        let postPaths = transport.recordedRequests
            .filter { $0.method == "POST" && ($0.path == "/api/v1/profile" || $0.path == "/api/v1/engine/hot-reload") }
            .map(\.path)
        XCTAssertEqual(postPaths, ["/api/v1/profile", "/api/v1/engine/hot-reload"])
    }
}

private final class InMemoryRemoteHTTPTransportForSessionTests: RemoteHTTPTransport, @unchecked Sendable {
    private let handler: RemoteAPIHandler

    init(handler: RemoteAPIHandler) {
        self.handler = handler
    }

    func send(
        host: String,
        port: UInt16,
        method: String,
        path: String,
        token: String?,
        body: Data?
    ) async throws -> RemoteHTTPTransportResponse {
        var headers: [String: String] = [:]
        if let token {
            headers["authorization"] = "Bearer \(token)"
        }
        let req = RemoteHTTPRequest(method: method, path: path, headers: headers, body: body ?? Data())
        let payload = await handler.handle(req)
        return RemoteHTTPTransportResponse(statusCode: payload.status, data: payload.body)
    }
}

@MainActor
private final class ClosureSessionDelegate: DeviceSessionDelegate {
    let onAlert: (String) -> Void
    init(onAlert: @escaping (String) -> Void) { self.onAlert = onAlert }
    func deviceSession(_ session: any DeviceSession, didEmitFeedback message: String) {}
    func deviceSession(_ session: any DeviceSession, didEmitAlert message: String) { onAlert(message) }
    func deviceSessionDidChangeState(_ session: any DeviceSession) {}
    func deviceSession(_ session: any DeviceSession, didSyncProfile profile: RoutingProfile) {}
    func deviceSessionDidLoseRemoteHost(_ session: any DeviceSession) {}
}
