import AppKit
import Foundation
import RoutingCore
@testable import RouteWeaverRuntime
import SwiftUI
import XCTest

// MARK: - Test Adapters

final class FakeRuntimeHandle: CoreRuntimeHandle, @unchecked Sendable {
    let initialPid: pid_t?
    let isLaunchdManaged: Bool
    let events: AsyncStream<CoreRuntimeEvent>

    private let continuation: AsyncStream<CoreRuntimeEvent>.Continuation
    var stopAsyncResult = true
    private(set) var stopAsyncCalls = 0
    private(set) var stopSyncCalls = 0
    private(set) var detachCalls = 0

    init(initialPid: pid_t? = 4242, isLaunchdManaged: Bool = false) {
        self.initialPid = initialPid
        self.isLaunchdManaged = isLaunchdManaged
        var cont: AsyncStream<CoreRuntimeEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    func emit(_ event: CoreRuntimeEvent) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }

    func stopAsync() async -> Bool {
        stopAsyncCalls += 1
        if stopAsyncResult {
            continuation.finish()
        }
        return stopAsyncResult
    }

    func stopSyncForExit() {
        stopSyncCalls += 1
        continuation.finish()
    }

    func detachForExit() {
        detachCalls += 1
        continuation.finish()
    }
}

final class FakeRuntimeDriver: CoreRuntimeDriver, @unchecked Sendable {
    var tunStatus: TunPermissionStatus = .ready
    var interfaces: Set<String> = ["en0"]
    var portError: String?
    var versionOutput = "Mihomo Meta v1.19.27 darwin arm64\n"
    var versionExitCode: Int32 = 0
    var validateExitCode: Int32 = 0
    var probeResult: CoreSessionProbeResult = .stale
    var nextHandle: FakeRuntimeHandle = FakeRuntimeHandle()
    private(set) var lastLaunchRequest: CoreLaunchRequest?

    func checkTunPermission(for binary: URL) -> TunPermissionStatus { tunStatus }
    func activeInterfaces() -> Set<String> { interfaces }
    func validatePorts(in config: Data, useTun: Bool) -> String? { portError }

    func runShortCommand(
        binary: URL,
        workDir: URL,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> (exitCode: Int32, capturedStdout: Data) {
        if arguments == ["-v"] {
            onOutput(versionOutput)
            return (versionExitCode, Data(versionOutput.utf8))
        }
        return (validateExitCode, Data())
    }

    func startCore(_ request: CoreLaunchRequest) throws -> any CoreRuntimeHandle {
        lastLaunchRequest = request
        return nextHandle
    }

    func attachToSession(_ session: RuntimeCoreSession) -> any CoreRuntimeHandle {
        nextHandle
    }

    func probeExistingSession(_ session: RuntimeCoreSession) async -> CoreSessionProbeResult {
        probeResult
    }
}

final class FakeMihomoControlClient: MihomoControlClient, @unchecked Sendable {
    let sessionID: UUID
    let port: Int
    let secret: String
    let trackedGroups: [String]

    var versionResult: Result<String, Error> = .success("v1.19.27")
    var groupsMap: [String: LocalController.ProxyGroup] = [:]
    var delayResult: [String: Int] = [:]
    var ruleProviderCount = 2
    var httpSnapshot = MihomoConnectionsSnapshot(downloadTotal: 100, uploadTotal: 50, connections: [])
    var streamSnapshots: [MihomoConnectionsSnapshot] = []
    var failSnapshotStream = false
    var streamDNSRecords: [DNSLogRecord] = []

    private(set) var selectedHistory: [(group: String, node: String)] = []
    private(set) var testedGroups: [String] = []
    private(set) var httpConnectionsCalls = 0

    init(port: Int = 19090, secret: String = "test", trackedGroups: [String] = ["Proxy"], sessionID: UUID = UUID()) {
        self.sessionID = sessionID
        self.port = port
        self.secret = secret
        self.trackedGroups = trackedGroups
    }

    func version(timeout: TimeInterval) async throws -> String {
        try versionResult.get()
    }

    func groups() async throws -> [String: LocalController.ProxyGroup] {
        groupsMap
    }

    func select(group: String, node: String) async throws {
        selectedHistory.append((group, node))
        if let existing = groupsMap[group] {
            groupsMap[group] = LocalController.ProxyGroup(
                type: existing.type,
                now: node,
                all: existing.all,
                delays: existing.delays
            )
        }
    }

    func testGroupDelay(group: String, url: String, timeoutMs: Int) async throws -> [String: Int] {
        testedGroups.append(group)
        return delayResult
    }

    func reloadConfig(payload: Data) async throws {}
    func updateAllRuleProviders() async throws -> Int { ruleProviderCount }

    func connections() async throws -> MihomoConnectionsSnapshot {
        httpConnectionsCalls += 1
        return httpSnapshot
    }

    func closeConnection(id: String) async throws {}
    func closeAllConnections() async throws {}
    func flushDNSCache() async throws {}
    func flushFakeIPCache() async throws {}

    func connectionSnapshots() -> AsyncThrowingStream<MihomoConnectionsSnapshot, Error> {
        let shouldFail = failSnapshotStream
        let snapshots = streamSnapshots
        return AsyncThrowingStream { continuation in
            if shouldFail {
                continuation.finish(throwing: URLError(.networkConnectionLost))
                return
            }
            for s in snapshots {
                continuation.yield(s)
            }
        }
    }

    func dnsLogRecords(level: String) -> AsyncThrowingStream<DNSLogRecord, Error> {
        let records = streamDNSRecords
        return AsyncThrowingStream { continuation in
            for r in records {
                continuation.yield(r)
            }
        }
    }
}

// MARK: - Tests

@MainActor
final class RouteWeaverRuntimeTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-runtime-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeFakeBinary(in dir: URL) throws -> URL {
        let bin = dir.appendingPathComponent("mihomo")
        FileManager.default.createFile(atPath: bin.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        return bin
    }

    private func waitUntil(timeoutSeconds: TimeInterval = 2.0, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    func testEngineControllerStartRestartEventAndStopLifecycle() async throws {
        let dir = try makeTempDir()
        let bin = try makeFakeBinary(in: dir)
        let handle = FakeRuntimeHandle(initialPid: 5001, isLaunchdManaged: true)
        let driver = FakeRuntimeDriver()
        driver.nextHandle = handle

        let engine = EngineController(stateDir: dir, driver: driver)
        engine.start(
            config: Data("mixed-port: 7890\n".utf8),
            binary: bin,
            interfaces: ["en0"],
            useTun: false,
            useGateway: false,
            useSystemKeepAlive: true
        )

        let reachedRunning = await waitUntil { engine.phase == .running }
        XCTAssertTrue(reachedRunning)
        XCTAssertTrue(engine.isLaunchdManaged)
        XCTAssertEqual(driver.lastLaunchRequest?.mode, .launchAgent)

        let oldToken = engine.lastCoreRestartToken
        handle.emit(.launchdRestarted(pid: 5002))
        let restarted = await waitUntil { engine.launchdRestartCount == 1 }
        XCTAssertTrue(restarted)
        XCTAssertNotEqual(engine.lastCoreRestartToken, oldToken)

        engine.stop()
        let stopped = await waitUntil { engine.phase == .idle }
        XCTAssertTrue(stopped)
        XCTAssertEqual(handle.stopAsyncCalls, 1)
    }

    func testEngineControllerRejectsOutdatedCoreVersion() async throws {
        let dir = try makeTempDir()
        let bin = try makeFakeBinary(in: dir)
        let driver = FakeRuntimeDriver()
        driver.versionOutput = "Mihomo Meta v1.18.0 darwin arm64\n"

        let engine = EngineController(stateDir: dir, driver: driver)
        engine.validate(config: Data("mixed-port: 7890\n".utf8), binary: bin)

        let finished = await waitUntil { engine.phase == .idle && engine.lastError != nil }
        XCTAssertTrue(finished)
        XCTAssertTrue(engine.lastError?.contains("v1.19.27") == true)
    }

    func testEngineControllerReattachPersistedSession() async throws {
        let dir = try makeTempDir()
        let store = RuntimeSessionStore(stateDir: dir)
        let logFile = dir.appendingPathComponent("last-run.log")
        FileManager.default.createFile(atPath: logFile.path, contents: Data("booted\n".utf8))

        let session = RuntimeCoreSession(
            pid: 9001,
            isTun: false,
            isGateway: false,
            isLaunchdManaged: true,
            controllerPort: 19090,
            secret: "abc",
            trackedGroups: ["Proxy"],
            runDirectoryPath: dir.path,
            configPath: dir.appendingPathComponent("config.yaml").path,
            logFilePath: logFile.path,
            pidFilePath: nil,
            requiredInterfaces: [],
            startedAt: Date(),
            runningProfile: nil
        )
        store.save(session)

        let driver = FakeRuntimeDriver()
        driver.probeResult = .alive(pid: 9002)
        driver.nextHandle = FakeRuntimeHandle(initialPid: 9002, isLaunchdManaged: true)

        let fakeClient = FakeMihomoControlClient(port: 19090, secret: "abc", trackedGroups: ["Proxy"])
        let engine = EngineController(stateDir: dir, driver: driver)

        let result = await engine.reattachRunningCore { _, _, _ in fakeClient }
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.session.pid, 9002)
        XCTAssertTrue(engine.isRunning)
        XCTAssertTrue(engine.isAttachedExternalCore)

        engine.detachForAppExit()
        XCTAssertEqual(driver.nextHandle.detachCalls, 1)
    }

    func testConnectionMonitorStreamsAndFallsBackToHTTPPoll() async throws {
        let client = FakeMihomoControlClient()
        client.failSnapshotStream = true
        client.httpSnapshot = MihomoConnectionsSnapshot(downloadTotal: 4096, uploadTotal: 1024, connections: [])
        client.streamDNSRecords = [
            DNSLogRecord(
                id: UUID(),
                timestamp: Date(),
                domain: "example.com",
                recordType: "A",
                answers: ["93.184.216.34"],
                upstream: "https://dns.google/dns-query",
                status: .resolved,
                rawPayload: "example.com -> 93.184.216.34"
            )
        ]

        let monitor = ConnectionMonitorService(initialConnectDelayNs: 0, reconnectDelayNs: 20_000_000)
        monitor.start(controller: client)

        let polled = await waitUntil {
            client.httpConnectionsCalls >= 1 && monitor.tracker.downloadTotal == 4096
        }
        XCTAssertTrue(polled)

        let dnsReceived = await waitUntil {
            monitor.dnsLogs.first?.domain == "example.com"
        }
        XCTAssertTrue(dnsReceived)
        monitor.stop()
    }

    func testLiveProxyStoreReloadSelectAndDelayTest() async throws {
        let client = FakeMihomoControlClient(trackedGroups: ["HK"])
        client.groupsMap = [
            "HK": LocalController.ProxyGroup(
                type: "Selector",
                now: "HK-01",
                all: ["HK-01", "HK-02"],
                delays: ["HK-01": 45, "HK-02": 32]
            )
        ]
        client.delayResult = ["HK-01": 40, "HK-02": 28]

        let store = LiveProxyStore { _, _, _ in client }
        store.activate(controller: client, trackedGroups: ["HK"])

        try await store.reloadGroups(client, isEngineRunning: { true })
        XCTAssertEqual(store.groupSelection["HK"], "HK-01")

        var lastFeedback: String?
        store.selectNode(
            group: "HK",
            node: "HK-02",
            isEngineRunning: { true },
            onFeedback: { lastFeedback = $0 },
            onError: { XCTFail($0) }
        )
        let switched = await waitUntil { store.groupSelection["HK"] == "HK-02" && lastFeedback != nil }
        XCTAssertTrue(switched)
        XCTAssertEqual(client.selectedHistory.first?.node, "HK-02")

        store.testGroupDelay(
            group: "HK",
            isEngineRunning: { true },
            onFeedback: { lastFeedback = $0 }
        )
        let tested = await waitUntil { client.testedGroups == ["HK"] && !store.testingGroups.contains("HK") }
        XCTAssertTrue(tested)
    }

    func testConnectionMonitorPersistsTrafficRankingAndTrafficStatsViewRenders() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-ranking-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let client = FakeMihomoControlClient()
        client.streamSnapshots = [
            MihomoConnectionsSnapshot(
                downloadTotal: 4096,
                uploadTotal: 1024,
                memory: 2048,
                connections: [
                    MihomoConnection(
                        id: "r-1",
                        metadata: MihomoConnectionMetadata(
                            network: "tcp",
                            type: "HTTP Connect",
                            destinationIP: "140.82.114.4",
                            destinationPort: "443",
                            host: "github.com",
                            process: "git"
                        ),
                        upload: 1024,
                        download: 4096,
                        start: "2026-11-25T12:00:00Z",
                        chains: ["DIRECT"],
                        rule: "DOMAIN",
                        rulePayload: "github.com"
                    )
                ]
            )
        ]

        let monitor = ConnectionMonitorService(initialConnectDelayNs: 0, reconnectDelayNs: 50_000_000)
        monitor.configureHistory(directory: dir)
        monitor.start(controller: client)

        let recorded = await waitUntil {
            !monitor.trafficRanking.report(dimension: .domain, window: .today).items.isEmpty
        }
        XCTAssertTrue(recorded)
        monitor.stop()

        let rankingFile = dir.appendingPathComponent("traffic-ranking.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rankingFile.path))

        // Reload into a fresh ConnectionMonitorService instance
        let reloaded = ConnectionMonitorService(initialConnectDelayNs: 0, reconnectDelayNs: 50_000_000)
        reloaded.configureHistory(directory: dir)
        let domainReport = reloaded.trafficRanking.report(dimension: .domain, window: .today)
        XCTAssertEqual(domainReport.items.first?.key, "github.com")
        XCTAssertEqual(domainReport.items.first?.total, 5120)

        // Render TrafficStatsView in NSHostingView to verify SwiftUI layout builds cleanly
        let appState = AppState()
        let statsView = TrafficStatsView(state: appState, monitor: reloaded)
        let hosting = NSHostingView(rootView: statsView)
        hosting.frame = NSRect(x: 0, y: 0, width: 960, height: 640)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosting.fittingSize.width, 0)

        reloaded.clearTrafficRanking()
        XCTAssertTrue(reloaded.trafficRanking.report(dimension: .domain, window: .today).items.isEmpty)
    }
}
