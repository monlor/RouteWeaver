import Foundation
import RoutingCore
@testable import RouteWeaverRuntime
import XCTest

private final class DualHopSpyControlClient: MihomoControlClient, @unchecked Sendable {
    let sessionID = UUID()
    let port: Int = 19090
    let secret: String = "secret"
    let trackedGroups: [String]

    private let lock = NSLock()
    private var _testedGroups: [String] = []
    var groupsMap: [String: LocalController.ProxyGroup]
    var delayByGroup: [String: [String: Int]]
    var emittedLogEvents: [MihomoLogStreamEvent]

    var testedGroups: [String] {
        lock.withLock { _testedGroups }
    }

    init(
        trackedGroups: [String],
        groupsMap: [String: LocalController.ProxyGroup],
        delayByGroup: [String: [String: Int]],
        emittedLogEvents: [MihomoLogStreamEvent] = []
    ) {
        self.trackedGroups = trackedGroups
        self.groupsMap = groupsMap
        self.delayByGroup = delayByGroup
        self.emittedLogEvents = emittedLogEvents
    }

    func version(timeout: TimeInterval) async throws -> String { "v1.19.27" }

    func groups() async throws -> [String: LocalController.ProxyGroup] {
        lock.withLock { groupsMap }
    }

    func select(group: String, node: String) async throws {}

    func testGroupDelay(group: String, url: String, timeoutMs: Int) async throws -> [String: Int] {
        lock.withLock {
            _testedGroups.append(group)
            return delayByGroup[group] ?? [:]
        }
    }

    func reloadConfig(payload: Data) async throws {}
    func updateAllRuleProviders() async throws -> Int { 0 }
    func connections() async throws -> MihomoConnectionsSnapshot { MihomoConnectionsSnapshot() }
    func closeConnection(id: String) async throws {}
    func closeAllConnections() async throws {}
    func flushDNSCache() async throws {}
    func flushFakeIPCache() async throws {}

    func connectionSnapshots() -> AsyncThrowingStream<MihomoConnectionsSnapshot, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(MihomoConnectionsSnapshot())
        }
    }

    func dnsLogRecords(level: String) -> AsyncThrowingStream<DNSLogRecord, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func logEvents(level: String) -> AsyncThrowingStream<MihomoLogStreamEvent, Error> {
        let events = emittedLogEvents
        return AsyncThrowingStream { continuation in
            for ev in events {
                continuation.yield(ev)
            }
        }
    }
}

@MainActor
final class TopologyRuntimeTests: XCTestCase {
    private func waitUntil(timeoutSeconds: TimeInterval = 2.0, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    func testOutboundDialErrorTriggersDualHopProbeAndMarksExactTimedOutHop() async throws {
        let errRecord = OutboundErrorParser.parse(
            payload: "[TCP] dial 美国 (match DomainSuffix/openai.com) 127.0.0.1:52100 --> api.openai.com:443 error: remote error: tls: handshake failure",
            level: "warning"
        )!

        let spyClient = DualHopSpyControlClient(
            trackedGroups: ["美国·链式", "美国"],
            groupsMap: [
                "美国·链式": LocalController.ProxyGroup(
                    type: "Selector",
                    now: "HK-Relay-01",
                    all: ["HK-Relay-01"],
                    delays: [:]
                ),
                "美国": LocalController.ProxyGroup(
                    type: "Selector",
                    now: "[美国] US-01",
                    all: ["[美国] US-01", "[美国] US-02"],
                    delays: [:]
                ),
            ],
            // Relay hop responds in 32ms, Exit hop times out (omitted from delay map)!
            delayByGroup: [
                "美国·链式": ["HK-Relay-01": 32],
                "美国": [:],
            ],
            emittedLogEvents: [.outboundError(errRecord)]
        )

        let liveStore = LiveProxyStore { _, _, _ in spyClient }
        liveStore.activate(controller: spyClient, trackedGroups: ["美国·链式", "美国"])
        try await liveStore.reloadGroups(spyClient, isEngineRunning: { true })

        let monitor = ConnectionMonitorService(initialConnectDelayNs: 0, reconnectDelayNs: 0)
        monitor.onTargetAnomalyDetected = { targetName in
            liveStore.autoVerifyTargetIfNeeded(targetName: targetName, isEngineRunning: { true })
        }
        monitor.start(controller: spyClient)
        defer { monitor.stop() }

        let verifiedBothHops = await waitUntil {
            Set(spyClient.testedGroups) == Set(["美国·链式", "美国"])
                && liveStore.testingGroups.isEmpty
                && !monitor.outboundErrors.isEmpty
        }
        XCTAssertTrue(verifiedBothHops)

        // Relay hop recorded 32ms healthy; Exit hop recorded timedOut!
        XCTAssertEqual(liveStore.groupStatus["美国·链式"]?.currentDelay, 32)
        XCTAssertFalse(liveStore.groupStatus["美国·链式"]?.isCurrentNodeTimedOut ?? true)
        XCTAssertTrue(liveStore.groupStatus["美国"]?.isCurrentNodeTimedOut ?? false)

        // Cooldown prevents duplicate probes when another error arrives immediately
        liveStore.autoVerifyTargetIfNeeded(targetName: "美国", isEngineRunning: { true })
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(spyClient.testedGroups.count, 2)
    }

    func testRemoteSnapshotPreservesClosedAtOutboundErrorsTestingStateAndCumulativeTotals() throws {
        let now = Date()
        let tenMinutesAgo = now.addingTimeInterval(-600)
        let tenSecondsAgo = now.addingTimeInterval(-10)

        let sub = ProxySubscription(name: "Sub", url: "https://sub.example.com/1")
        let relayGroup = NodeGroup(name: "HKRelay", kind: .relay, subscriptionID: sub.id, filterPattern: "HK", autoTest: false)
        let usExitGroup = NodeGroup(name: "USExit", kind: .exit, subscriptionID: sub.id, filterPattern: "US", autoTest: false)
        let hkExitGroup = NodeGroup(name: "HKExit", kind: .exit, subscriptionID: sub.id, filterPattern: "HK", autoTest: false)

        let usTarget = NetworkTarget(name: "美国节点", mode: .proxy, exitGroupID: usExitGroup.id, relayGroupID: relayGroup.id)
        let hkTarget = NetworkTarget(name: "香港节点", mode: .proxy, exitGroupID: hkExitGroup.id, relayGroupID: relayGroup.id)
        let googleRuleGroup = RuleGroup(
            name: "Google / YouTube",
            icon: "play.rectangle",
            target: .target(usTarget.id),
            isEnabled: true,
            rules: [RuleItem(type: .domainSuffix, value: "youtube.com")]
        )
        let netflixRuleGroup = RuleGroup(
            name: "国外流媒体",
            icon: "tv",
            target: .target(hkTarget.id),
            isEnabled: true,
            rules: [RuleItem(type: .domainSuffix, value: "netflix.com")]
        )
        let profile = RoutingProfile(
            name: "Test",
            subscriptions: [sub],
            nodeGroups: [relayGroup, usExitGroup, hkExitGroup],
            targets: [usTarget, hkTarget],
            ruleGroups: [googleRuleGroup, netflixRuleGroup],
            fallbackTarget: .target(hkTarget.id)
        )

        // 1. Two old 0-byte closed connections on 香港节点 (closed 10 minutes ago) must NOT trigger false silent-blackhole warning
        let oldClosedHK1 = RemoteConnectionDTO(
            id: "hk-old-1",
            host: "nflxvideo.net",
            network: "tcp",
            sourceIP: "192.168.100.5",
            destinationIP: "198.18.0.10",
            startDate: tenMinutesAgo.addingTimeInterval(-5),
            closedAt: tenMinutesAgo,
            rule: "DOMAIN-SUFFIX",
            matchedRuleSet: "netflix.com",
            chain: "香港节点 → [香港节点] HK-A01",
            chains: ["[香港节点] HK-A01", "香港节点"],
            upload: 512,
            download: 0,
            uploadSpeed: 0,
            downloadSpeed: 0,
            isActive: false
        )
        let oldClosedHK2 = RemoteConnectionDTO(
            id: "hk-old-2",
            host: "netflix.com",
            network: "tcp",
            sourceIP: "192.168.100.5",
            destinationIP: "198.18.0.11",
            startDate: tenMinutesAgo.addingTimeInterval(-4),
            closedAt: tenMinutesAgo,
            rule: "DOMAIN-SUFFIX",
            matchedRuleSet: "netflix.com",
            chain: "香港节点 → [香港节点] HK-A01",
            chains: ["[香港节点] HK-A01", "香港节点"],
            upload: 640,
            download: 0,
            uploadSpeed: 0,
            downloadSpeed: 0,
            isActive: false
        )

        // 2. Direct outbound error on 美国节点 synced even when rawLogs has scrolled past it (empty rawLogs)
        let usExitError = OutboundErrorRecord(
            timestamp: tenSecondsAgo,
            network: "TCP",
            primaryTarget: "美国节点",
            outboundGroup: "美国节点",
            nodeName: "美国 O01",
            destination: "www.youtube.com:443",
            matchedRuleType: "DomainSuffix",
            matchedRulePayload: "youtube.com",
            suspectedHop: .exit,
            category: .other,
            reason: "use of closed network connection",
            rawPayload: "[TCP] dial 美国节点 error: use of closed network connection"
        )

        // 3. Proxy group DTO carries live `isTesting` state
        let remoteProxies = [
            RemoteProxyGroupDTO(
                name: "美国节点·链式",
                type: "Selector",
                now: "🇭🇰 香港 01",
                all: ["🇭🇰 香港 01"],
                delays: ["🇭🇰 香港 01": 28],
                isTesting: true
            ),
            RemoteProxyGroupDTO(
                name: "美国节点",
                type: "Selector",
                now: "[美国节点] 🇺🇸 美国 O01",
                all: ["[美国节点] 🇺🇸 美国 O01"],
                delays: [:],
                isTesting: true
            ),
            RemoteProxyGroupDTO(
                name: "香港节点·链式",
                type: "Selector",
                now: "🇭🇰 香港 01",
                all: ["🇭🇰 香港 01"],
                delays: ["🇭🇰 香港 01": 28]
            ),
            RemoteProxyGroupDTO(
                name: "香港节点",
                type: "Selector",
                now: "[香港节点] 🇭🇰 香港 A01",
                all: ["[香港节点] 🇭🇰 香港 A01"],
                delays: ["[香港节点] 🇭🇰 香港 A01": 35]
            ),
        ]

        // 4. Authoritative cumulative totals exceed the truncated connections slice (21 MB on YouTube / 22.4 MB on 美国节点)
        let ruleKey = ConnectionTracker.ruleSessionKey(rule: "DomainSuffix", payload: "youtube.com")
        let remoteTargetTotals: [String: TrafficBytes] = [
            "美国节点": TrafficBytes(upload: 1_400_000, download: 21_000_000),
            "香港节点": TrafficBytes(upload: 100_000, download: 1_000_000),
        ]
        let remoteRuleTotals: [String: TrafficBytes] = [
            ruleKey: TrafficBytes(upload: 1_000_000, download: 20_000_000),
        ]

        let liveStore = LiveProxyStore()
        liveStore.applyRemoteGroups(remoteProxies)
        XCTAssertTrue(liveStore.testingGroups.contains("美国节点"))

        let monitor = ConnectionMonitorService()
        monitor.applyRemoteData(
            status: nil,
            connections: [oldClosedHK1, oldClosedHK2],
            dnsLogs: [],
            trafficHistory: nil,
            trafficRanking: nil,
            rawLogs: "[TCP] dial 香港节点 --> example.com:443 error: stale log line should be ignored when outboundErrors is present",
            outboundErrors: [usExitError],
            targetSessionTotals: remoteTargetTotals,
            targetConnectionCounts: ["美国节点": 42, "香港节点": 12],
            targetSpeeds: [:],
            ruleSessionTotals: remoteRuleTotals
        )

        let snap = TopologySnapshotBuilder.build(
            profile: profile,
            isCoreRunning: true,
            activeInterfaceNames: ["en0"],
            interfaceLabels: ["en0": "Ethernet (en0)"],
            groupStatuses: liveStore.healthSnapshots,
            tracker: monitor.tracker,
            dnsRecords: monitor.dnsLogs,
            outboundErrorTracker: monitor.outboundErrorTracker,
            now: now
        )

        let rawUSLane = snap.lanes.first(where: { $0.name == "美国节点" })
        let rawHKLane = snap.lanes.first(where: { $0.name == "香港节点" })
        let usLane = try XCTUnwrap(rawUSLane)
        let hkLane = try XCTUnwrap(rawHKLane)
        let rawGoogleBranch = usLane.branches.first(where: { $0.name == "Google / YouTube" })
        let googleBranch = try XCTUnwrap(rawGoogleBranch)

        // 美国节点 shows exact exit-hop error + 1 branch error + full 22.4M / 21.0M cumulative totals
        XCTAssertEqual(usLane.health, .error)
        XCTAssertEqual(usLane.diagnosis?.brokenHop, .exit)
        XCTAssertEqual(googleBranch.recentErrorCount, 1)
        XCTAssertEqual(googleBranch.sessionBytes, 21_000_000)
        XCTAssertEqual(usLane.sessionTotal, 22_400_000)

        // 香港节点 stays healthy (no false silent-blackhole warning from 10-minute-old closed connections!)
        XCTAssertEqual(hkLane.health, .healthy)
        XCTAssertNil(hkLane.diagnosis)
        XCTAssertEqual(hkLane.zeroByteClosedCount, 0)

        // When host clears outbound errors (`outboundErrors: []`), stale `rawLogs` does NOT resurrect errors
        monitor.applyRemoteData(
            status: nil,
            connections: [oldClosedHK1, oldClosedHK2],
            dnsLogs: [],
            trafficHistory: nil,
            trafficRanking: nil,
            rawLogs: "[TCP] dial 美国节点 --> youtube.com:443 error: use of closed network connection",
            outboundErrors: []
        )
        XCTAssertTrue(monitor.outboundErrors.isEmpty)
    }
}
