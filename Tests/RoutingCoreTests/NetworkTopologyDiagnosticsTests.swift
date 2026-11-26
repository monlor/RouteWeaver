import Foundation
@testable import RoutingCore
import XCTest

final class NetworkTopologyDiagnosticsTests: XCTestCase {
    func testOutboundErrorParserExtractsTargetRuleAndCategories() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // 1. Standard proxy outbound timeout
        let line1 = "[TCP] dial 美国 (match DomainSuffix/openai.com) 198.18.0.1:51234 --> api.openai.com:443 error: connect failed: i/o timeout"
        let rec1 = OutboundErrorParser.parse(payload: line1, level: "warning", at: now)
        XCTAssertNotNil(rec1)
        XCTAssertEqual(rec1?.network, "TCP")
        XCTAssertEqual(rec1?.primaryTarget, "美国")
        XCTAssertEqual(rec1?.outboundGroup, "美国")
        XCTAssertEqual(rec1?.destination, "api.openai.com:443")
        XCTAssertEqual(rec1?.matchedRuleType, "DomainSuffix")
        XCTAssertEqual(rec1?.matchedRulePayload, "openai.com")
        XCTAssertEqual(rec1?.category, .timeout)
        XCTAssertNil(rec1?.suspectedHop)

        // 2. Dialer-proxy relay failure explicitly mentioning `<Target>·链式`
        let line2 = "[TCP] dial 美国 (match DomainSuffix/claude.ai) 127.0.0.1:51235 --> claude.ai:443 error: dialer-proxy [美国·链式]: dial tcp 203.0.113.9:443: connect: connection refused"
        let rec2 = OutboundErrorParser.parse(payload: line2, level: "warning", at: now)
        XCTAssertNotNil(rec2)
        XCTAssertEqual(rec2?.primaryTarget, "美国")
        XCTAssertEqual(rec2?.outboundGroup, "美国·链式")
        XCTAssertEqual(rec2?.suspectedHop, .relay)
        XCTAssertEqual(rec2?.category, .connectionRefused)

        // 3. Chained exit node prefix `[Target] Node` TLS / EOF failure
        let line3 = "[TCP] dial [香港] HK-Exit-02 (match GeoSite/github) 127.0.0.1:54321 --> github.com:443 error: remote error: tls: bad record MAC"
        let rec3 = OutboundErrorParser.parse(payload: line3, level: "error", at: now)
        XCTAssertNotNil(rec3)
        XCTAssertEqual(rec3?.primaryTarget, "香港")
        XCTAssertEqual(rec3?.nodeName, "HK-Exit-02")
        XCTAssertEqual(rec3?.category, .tlsOrProtocol)

        // 4. Ignores DNS lines and normal info connection logs
        XCTAssertNil(OutboundErrorParser.parse(payload: "[DNS] openai.com --> [198.18.0.5] A from fake-ip", level: "debug", at: now))
        XCTAssertNil(OutboundErrorParser.parse(payload: "[TCP] 127.0.0.1:51234 --> api.openai.com:443 match DomainSuffix(openai.com) using 美国[[美国] US-01]", level: "info", at: now))
    }

    func testParseLogBufferReadsStructuredMihomoLogLines() {
        let logText = """
        time="2026-11-26T12:15:00Z" level=info msg="[TCP] 127.0.0.1:50001 --> example.com:443 using 香港[HK-01]"
        time="2026-11-26T12:15:05Z" level=warning msg="[TCP] dial 美国·链式 192.168.1.5:50002 --> 1.2.3.4:8388 error: i/o timeout"
        """
        let parsed = OutboundErrorParser.parseLogBuffer(logText)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.primaryTarget, "美国")
        XCTAssertEqual(parsed.first?.outboundGroup, "美国·链式")
        XCTAssertEqual(parsed.first?.suspectedHop, .relay)
    }

    func testTopologySnapshotIsolatesRelayHopVsExitHopAndInterfaceFailures() {
        let sub = ProxySubscription(name: "主订阅", url: "https://sub.example.com/v1")
        let relayGroup = NodeGroup(name: "香港专线入口", kind: .relay, subscriptionID: sub.id, filterPattern: "HK", autoTest: false)
        let exitGroup = NodeGroup(name: "美国落地出口", kind: .exit, subscriptionID: sub.id, filterPattern: "US", autoTest: true)

        let usTarget = NetworkTarget(
            name: "美国",
            mode: .proxy,
            exitGroupID: exitGroup.id,
            relayGroupID: relayGroup.id,
            interfaceName: "en0"
        )
        let directUSBTarget = NetworkTarget(
            name: "USB直连",
            mode: .direct,
            interfaceName: "en9"
        )

        let aiRules = [RuleItem(type: .domainSuffix, value: "openai.com")]
        let aiGroup = RuleGroup(name: "AI 服务", icon: "sparkles", target: .target(usTarget.id), isEnabled: true, rules: aiRules)
        let usbGroup = RuleGroup(name: "内网设备", icon: "cable.connector", target: .target(directUSBTarget.id), isEnabled: true, rules: [RuleItem(type: .domainSuffix, value: "corp.internal")])

        let profile = RoutingProfile(
            name: "测试方案",
            subscriptions: [sub],
            nodeGroups: [relayGroup, exitGroup],
            targets: [usTarget, directUSBTarget],
            ruleGroups: [aiGroup, usbGroup],
            fallbackTarget: .target(usTarget.id)
        )

        let now = Date(timeIntervalSince1970: 1_700_001_000)

        // Scenario A: Hop 1 (`美国·链式`) healthy (36ms), Hop 2 (`美国`) timed out!
        let statusesHop2Broken: [String: ProxyGroupHealthSnapshot] = [
            "美国·链式": ProxyGroupHealthSnapshot(
                name: "美国·链式",
                type: "Selector",
                now: "HK-Relay-01",
                all: ["HK-Relay-01", "HK-Relay-02"],
                delays: ["HK-Relay-01": 36],
                timedOutNodes: []
            ),
            "美国": ProxyGroupHealthSnapshot(
                name: "美国",
                type: "URLTest",
                now: "[美国] US-LA-01",
                all: ["[美国] US-LA-01"],
                delays: [:],
                timedOutNodes: ["[美国] US-LA-01"]
            ),
        ]

        let snapA = TopologySnapshotBuilder.build(
            profile: profile,
            isCoreRunning: true,
            activeInterfaceNames: ["en0"],
            interfaceLabels: ["en0": "有线网卡 (en0)", "en9": "USB 网卡 (en9)"],
            groupStatuses: statusesHop2Broken,
            tracker: ConnectionTracker(),
            dnsRecords: [],
            outboundErrorTracker: OutboundErrorTracker(),
            now: now
        )

        guard let usLaneA = snapA.lanes.first(where: { $0.id == "美国" }),
              let usbLaneA = snapA.lanes.first(where: { $0.id == "USB直连" }) else {
            XCTFail("Expected both target lanes")
            return
        }

        // Hop 1 is healthy, Hop 2 is broken!
        XCTAssertEqual(usLaneA.health, .error)
        XCTAssertEqual(usLaneA.diagnosis?.brokenHop, .exit)
        XCTAssertTrue(usLaneA.diagnosis?.headline.contains("第二跳") == true)
        XCTAssertTrue(usLaneA.diagnosis?.detail.contains("36 ms") == true)
        XCTAssertEqual(usLaneA.hops[0].kind, .relay)
        XCTAssertEqual(usLaneA.hops[0].health, .healthy)
        XCTAssertEqual(usLaneA.hops[1].kind, .exit)
        XCTAssertEqual(usLaneA.hops[1].health, .error)

        // `en9` is missing from `activeInterfaceNames` -> interface offline error!
        XCTAssertEqual(usbLaneA.health, .error)
        XCTAssertEqual(usbLaneA.diagnosis?.brokenHop, .interface)

        // Scenario B: Hop 1 (`美国·链式`) itself timed out -> blames Hop 1 (not Hop 2)!
        let statusesHop1Broken: [String: ProxyGroupHealthSnapshot] = [
            "美国·链式": ProxyGroupHealthSnapshot(
                name: "美国·链式",
                type: "Selector",
                now: "HK-Relay-01",
                all: ["HK-Relay-01"],
                delays: [:],
                timedOutNodes: ["HK-Relay-01"]
            ),
            "美国": ProxyGroupHealthSnapshot(
                name: "美国",
                type: "URLTest",
                now: "[美国] US-LA-01",
                all: ["[美国] US-LA-01"],
                delays: [:],
                timedOutNodes: ["[美国] US-LA-01"]
            ),
        ]

        let snapB = TopologySnapshotBuilder.build(
            profile: profile,
            isCoreRunning: true,
            activeInterfaceNames: ["en0", "en9"],
            interfaceLabels: ["en0": "有线网卡 (en0)", "en9": "USB 网卡 (en9)"],
            groupStatuses: statusesHop1Broken,
            tracker: ConnectionTracker(),
            dnsRecords: [],
            outboundErrorTracker: OutboundErrorTracker(),
            now: now
        )
        let usLaneB = snapB.lanes.first { $0.id == "美国" }
        XCTAssertEqual(usLaneB?.diagnosis?.brokenHop, .relay)
        XCTAssertTrue(usLaneB?.diagnosis?.headline.contains("第一跳") == true)
        XCTAssertEqual(usLaneB?.hops[0].health, .error)
        // Downstream exit hop is marked `.warning` (blocked by Hop 1) rather than duplicate `.error`
        XCTAssertEqual(usLaneB?.hops[1].health, .warning)
    }

    func testTopologySnapshotFlagsSilentZeroByteDrops() {
        let sub = ProxySubscription(name: "Sub", url: "https://sub.example.com/s")
        let exitGroup = NodeGroup(name: "US", kind: .exit, subscriptionID: sub.id)
        let usTarget = NetworkTarget(name: "美国", mode: .proxy, exitGroupID: exitGroup.id)
        let profile = RoutingProfile(
            subscriptions: [sub],
            nodeGroups: [exitGroup],
            targets: [usTarget],
            ruleGroups: [],
            fallbackTarget: .target(usTarget.id)
        )

        let t0 = Date(timeIntervalSince1970: 1_700_002_000)
        var tracker = ConnectionTracker()
        // Two active connections sending ClientHello (`upload: 512, download: 0`)
        let snap1 = MihomoConnectionsSnapshot(
            downloadTotal: 0,
            uploadTotal: 1024,
            connections: [
                MihomoConnection(
                    id: "c1",
                    metadata: MihomoConnectionMetadata(network: "tcp", destinationPort: "443", host: "openai.com"),
                    upload: 512,
                    download: 0,
                    start: "",
                    chains: ["US-01", "美国"],
                    rule: "MATCH",
                    rulePayload: ""
                ),
                MihomoConnection(
                    id: "c2",
                    metadata: MihomoConnectionMetadata(network: "tcp", destinationPort: "443", host: "claude.ai"),
                    upload: 512,
                    download: 0,
                    start: "",
                    chains: ["US-01", "美国"],
                    rule: "MATCH",
                    rulePayload: ""
                ),
            ]
        )
        tracker.ingest(snap1, at: t0)
        // Both close with 0 bytes downloaded
        tracker.ingest(MihomoConnectionsSnapshot(downloadTotal: 0, uploadTotal: 1024, connections: []), at: t0.addingTimeInterval(3))

        let topo = TopologySnapshotBuilder.build(
            profile: profile,
            isCoreRunning: true,
            activeInterfaceNames: ["en0"],
            interfaceLabels: [:],
            groupStatuses: [
                "美国": ProxyGroupHealthSnapshot(name: "美国", type: "Selector", now: "US-01", all: ["US-01"], delays: ["US-01": 120])
            ],
            tracker: tracker,
            dnsRecords: [],
            outboundErrorTracker: OutboundErrorTracker(),
            now: t0.addingTimeInterval(5)
        )

        let usLane = topo.lanes.first { $0.id == "美国" }
        XCTAssertEqual(usLane?.health, .warning)
        XCTAssertEqual(usLane?.diagnosis?.kind, .silentZeroByteDrops(count: 2))
    }
}
