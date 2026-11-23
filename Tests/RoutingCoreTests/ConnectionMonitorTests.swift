import Foundation
import XCTest
@testable import RoutingCore

final class ConnectionMonitorTests: XCTestCase {
    func testDecodesMihomoSnapshotWithNullConnectionsAndMissingFields() throws {
        let json = """
        {
          "downloadTotal": 4096,
          "uploadTotal": 1024,
          "connections": null,
          "memory": 52428800
        }
        """
        let snapshot = try JSONDecoder().decode(MihomoConnectionsSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.downloadTotal, 4096)
        XCTAssertEqual(snapshot.uploadTotal, 1024)
        XCTAssertEqual(snapshot.memory, 52_428_800)
        XCTAssertTrue(snapshot.connections.isEmpty)
    }

    func testDecodesConnectionMetadataAndDisplayProperties() throws {
        let json = """
        {
          "downloadTotal": 20480,
          "uploadTotal": 2048,
          "memory": 31457280,
          "connections": [
            {
              "id": "conn-1",
              "metadata": {
                "network": "tcp",
                "type": "HTTP Connect",
                "sourceIP": "127.0.0.1",
                "destinationIP": "104.18.7.192",
                "sourcePort": "52341",
                "destinationPort": "443",
                "host": "api.openai.com",
                "dnsMode": "normal",
                "process": "Cursor",
                "processPath": "/Applications/Cursor.app/Contents/MacOS/Cursor"
              },
              "upload": 2048,
              "download": 20480,
              "start": "2026-11-22T00:46:51.123456+08:00",
              "chains": ["US-01", "美国"],
              "rule": "DOMAIN-SUFFIX",
              "rulePayload": "openai.com"
            }
          ]
        }
        """
        let snapshot = try JSONDecoder().decode(MihomoConnectionsSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.connections.count, 1)

        var tracker = ConnectionTracker()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        tracker.ingest(snapshot, at: now)

        let record = try XCTUnwrap(tracker.recordsByID["conn-1"])
        XCTAssertTrue(record.isActive)
        XCTAssertEqual(record.displayAddress, "api.openai.com:443")
        XCTAssertEqual(record.displayChain, ["美国", "US-01"])
        XCTAssertEqual(record.primaryTarget, "美国")
        XCTAssertEqual(record.finalNode, "US-01")
        XCTAssertEqual(record.processDisplayName, "Cursor")
        XCTAssertEqual(record.ruleSummary, "DOMAIN-SUFFIX · openai.com")
        XCTAssertEqual(record.protocolLabel, "TCP · HTTP Connect")
        XCTAssertNotNil(record.startDate)
    }

    func testTracksSpeedsActiveToClosedTransitionsAndHistoryLimit() throws {
        var tracker = ConnectionTracker(maxClosedHistory: 10)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        func makeConn(id: String, host: String, up: Int64, down: Int64, target: String = "香港") -> MihomoConnection {
            MihomoConnection(
                id: id,
                metadata: MihomoConnectionMetadata(
                    network: "tcp",
                    type: "HTTP Connect",
                    destinationPort: "443",
                    host: host
                ),
                upload: up,
                download: down,
                start: "2026-11-22T00:00:00Z",
                chains: ["Node-A", target],
                rule: "MATCH",
                rulePayload: ""
            )
        }

        // Snapshot 1: conn-1 active
        tracker.ingest(
            MihomoConnectionsSnapshot(
                downloadTotal: 1_000,
                uploadTotal: 500,
                memory: 10_000,
                connections: [makeConn(id: "c1", host: "a.example.com", up: 500, down: 1_000)]
            ),
            at: t0
        )
        XCTAssertEqual(tracker.activeCount, 1)
        XCTAssertEqual(tracker.closedCount, 0)

        // Snapshot 2 (+2s): c1 grows, c2 joins
        let t1 = t0.addingTimeInterval(2.0)
        tracker.ingest(
            MihomoConnectionsSnapshot(
                downloadTotal: 5_000,
                uploadTotal: 1_500,
                memory: 12_000,
                connections: [
                    makeConn(id: "c1", host: "a.example.com", up: 1_500, down: 5_000),
                    makeConn(id: "c2", host: "b.example.com", up: 100, down: 200, target: "DIRECT"),
                ]
            ),
            at: t1
        )
        XCTAssertEqual(tracker.uploadSpeed, 500)
        XCTAssertEqual(tracker.downloadSpeed, 2_000)
        XCTAssertEqual(tracker.recordsByID["c1"]?.uploadSpeed, 500)
        XCTAssertEqual(tracker.recordsByID["c1"]?.downloadSpeed, 2_000)
        XCTAssertEqual(tracker.activeCount, 2)

        // Snapshot 3 (+1s): c1 disappears -> marked closed, c2 stays active
        let t2 = t1.addingTimeInterval(1.0)
        tracker.ingest(
            MihomoConnectionsSnapshot(
                downloadTotal: 5_200,
                uploadTotal: 1_600,
                memory: 11_000,
                connections: [
                    makeConn(id: "c2", host: "b.example.com", up: 200, down: 400, target: "DIRECT")
                ]
            ),
            at: t2
        )
        XCTAssertEqual(tracker.activeCount, 1)
        XCTAssertEqual(tracker.closedCount, 1)
        XCTAssertEqual(tracker.recordsByID["c1"]?.isActive, false)
        XCTAssertEqual(tracker.recordsByID["c1"]?.closedAt, t2)
        XCTAssertEqual(tracker.recordsByID["c1"]?.downloadSpeed, 0)

        // Filtering & sorting
        XCTAssertEqual(tracker.filtered(scope: .active).map(\.id), ["c2"])
        XCTAssertEqual(tracker.filtered(scope: .closed).map(\.id), ["c1"])
        XCTAssertEqual(tracker.filtered(targetFilter: "DIRECT").map(\.id), ["c2"])
        XCTAssertEqual(tracker.filtered(searchText: "a.example").map(\.id), ["c1"])
        XCTAssertEqual(tracker.filtered(sortOrder: .download).map(\.id), ["c1", "c2"])

        // Clear closed
        tracker.clearClosed()
        XCTAssertEqual(tracker.closedCount, 0)
        XCTAssertEqual(tracker.activeCount, 1)

        // Overflow closed history beyond cap (10)
        for idx in 1...15 {
            let ti = t2.addingTimeInterval(Double(idx))
            tracker.ingest(
                MihomoConnectionsSnapshot(
                    downloadTotal: 6_000,
                    uploadTotal: 2_000,
                    connections: [makeConn(id: "hist-\(idx)", host: "h\(idx).example.com", up: 10, down: 20)]
                ),
                at: ti
            )
        }
        tracker.markAllClosed(at: t2.addingTimeInterval(20))
        XCTAssertEqual(tracker.activeCount, 0)
        XCTAssertEqual(tracker.closedCount, 10)
        XCTAssertNil(tracker.recordsByID["hist-1"])
        XCTAssertNotNil(tracker.recordsByID["hist-15"])
    }

    func testTrafficFormatter() {
        XCTAssertEqual(TrafficFormatter.bytes(512), "512 B")
        XCTAssertEqual(TrafficFormatter.bytes(1_536), "1.5 KB")
        XCTAssertEqual(TrafficFormatter.bytes(2_621_440), "2.50 MB")
        XCTAssertEqual(TrafficFormatter.speed(2_048), "2.0 KB/s")
        XCTAssertEqual(TrafficFormatter.duration(0.25), "250 ms")
        XCTAssertEqual(TrafficFormatter.duration(12.4), "12.4s")
        XCTAssertEqual(TrafficFormatter.duration(125), "2m 5s")
    }

    func testDNSLogParserExtractsResolvedCacheAndFailedQueries() throws {
        let resolved = try XCTUnwrap(
            DNSLogParser.parse(payload: "[DNS] openai.com --> [104.18.33.45 172.64.154.211] A from https://1.1.1.1:443/dns-query")
        )
        XCTAssertEqual(resolved.domain, "openai.com")
        XCTAssertEqual(resolved.recordType, "A")
        XCTAssertEqual(resolved.answers, ["104.18.33.45", "172.64.154.211"])
        XCTAssertEqual(resolved.upstream, "https://1.1.1.1:443/dns-query")
        XCTAssertEqual(resolved.status, .resolved)
        XCTAssertFalse(resolved.isSuspiciousLoopback)

        let loopback = try XCTUnwrap(
            DNSLogParser.parse(payload: "[DNS] www.okx.com --> [127.0.0.1] A from udp://192.168.100.1:53")
        )
        XCTAssertEqual(loopback.domain, "www.okx.com")
        XCTAssertTrue(loopback.isSuspiciousLoopback)

        let cacheHit = try XCTUnwrap(
            DNSLogParser.parse(payload: "[DNS] cache hit grok.com --> [104.18.29.234] A")
        )
        XCTAssertEqual(cacheHit.domain, "grok.com")
        XCTAssertEqual(cacheHit.recordType, "A")
        XCTAssertEqual(cacheHit.upstream, "cache")
        XCTAssertEqual(cacheHit.upstreamKind, .cache)
        XCTAssertNil(cacheHit.cacheExpireAt)

        let cacheHitWithExpire = try XCTUnwrap(
            DNSLogParser.parse(payload: "[DNS] cache hit play.googleapis.com --> [172.217.115.4 172.217.114.4] A, expire at 2026-11-22 10:52:26")
        )
        XCTAssertEqual(cacheHitWithExpire.domain, "play.googleapis.com")
        XCTAssertEqual(cacheHitWithExpire.recordType, "A")
        XCTAssertEqual(cacheHitWithExpire.answers, ["172.217.115.4", "172.217.114.4"])
        XCTAssertEqual(cacheHitWithExpire.upstream, "cache")
        XCTAssertEqual(cacheHitWithExpire.cacheExpireAt, "2026-11-22 10:52:26")
        XCTAssertEqual(cacheHitWithExpire.shortExpireTime, "10:52:26")

        let cacheHitEmptyAAAA = try XCTUnwrap(
            DNSLogParser.parse(payload: "[DNS] cache hit e46a98ed.example.com --> [] AAAA, expire at 2026-11-22 10:51:23")
        )
        XCTAssertEqual(cacheHitEmptyAAAA.domain, "e46a98ed.example.com")
        XCTAssertEqual(cacheHitEmptyAAAA.recordType, "AAAA")
        XCTAssertTrue(cacheHitEmptyAAAA.answers.isEmpty)
        XCTAssertFalse(cacheHitEmptyAAAA.hasAnswers)
        XCTAssertEqual(cacheHitEmptyAAAA.cacheExpireAt, "2026-11-22 10:51:23")

        let unbracketedLocal = try XCTUnwrap(
            DNSLogParser.parse(payload: "[DNS] play.googleapis.com --> 172.217.115.4")
        )
        XCTAssertEqual(unbracketedLocal.domain, "play.googleapis.com")
        XCTAssertEqual(unbracketedLocal.recordType, "A")
        XCTAssertEqual(unbracketedLocal.answers, ["172.217.115.4"])
        XCTAssertEqual(unbracketedLocal.upstream, "local")
        XCTAssertEqual(unbracketedLocal.upstreamKind, .local)

        let unbracketedIPv6 = try XCTUnwrap(
            DNSLogParser.parse(payload: "[DNS] ipv6.google.com --> 2001:4860:4841:400::")
        )
        XCTAssertEqual(unbracketedIPv6.recordType, "AAAA")
        XCTAssertEqual(unbracketedIPv6.answers, ["2001:4860:4841:400::"])

        let unbracketedFakeIP = try XCTUnwrap(
            DNSLogParser.parse(payload: "[DNS] github.com --> 198.18.0.12")
        )
        XCTAssertEqual(unbracketedFakeIP.recordType, "A")
        XCTAssertEqual(unbracketedFakeIP.answers, ["198.18.0.12"])
        XCTAssertEqual(unbracketedFakeIP.upstream, "fake-ip")
        XCTAssertEqual(unbracketedFakeIP.upstreamKind, .fakeIP)

        XCTAssertEqual(resolved.upstreamDisplayParts.schemeBadge, "DoH")
        XCTAssertEqual(resolved.upstreamDisplayParts.endpoint, "1.1.1.1:443/dns-query")
        XCTAssertEqual(loopback.upstreamDisplayParts.schemeBadge, "UDP")
        XCTAssertEqual(loopback.upstreamDisplayParts.endpoint, "192.168.100.1:53")

        let failed = try XCTUnwrap(
            DNSLogParser.parse(payload: "[DNS Server] Exchange ;www.okx.com.\tIN\t A failed: all DNS requests failed")
        )
        XCTAssertEqual(failed.domain, "www.okx.com")
        XCTAssertEqual(failed.recordType, "A")
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.errorMessage, "all DNS requests failed")

        // Intermediate resolve line or unrelated logs should return nil
        XCTAssertNil(DNSLogParser.parse(payload: "[DNS] resolve openai.com A from udp://192.168.0.1:53"))
        XCTAssertNil(DNSLogParser.parse(payload: "[TCP] 198.18.0.1:1234 --> google.com:443 match Match using HK"))
    }

    func testTrafficFormatterTerabytesAndShortFormats() {
        XCTAssertEqual(TrafficFormatter.bytes(1_099_511_627_776), "1.00 TB")
        XCTAssertEqual(TrafficFormatter.shortBytes(2_048), "2K")
        XCTAssertEqual(TrafficFormatter.shortSpeed(1_048_576), "1.0M/s")
    }

    func testSubscriptionUsageParsingAndMetrics() throws {
        let header = "upload=1073741824; download=2147483648; total=10737418240; expire=1800000000"
        let usage = try XCTUnwrap(SubscriptionUsage.parse(
            headerValue: header,
            webPageURL: "https://panel.example.com",
            updateInterval: "24"
        ))
        XCTAssertEqual(usage.upload, 1_073_741_824)
        XCTAssertEqual(usage.download, 2_147_483_648)
        XCTAssertEqual(usage.used, 3_221_225_472)
        XCTAssertEqual(usage.total, 10_737_418_240)
        XCTAssertEqual(usage.remaining, 7_516_192_768)
        XCTAssertEqual(usage.usageFraction, 0.3, accuracy: 0.0001)
        XCTAssertFalse(usage.isOverLimit)
        XCTAssertEqual(usage.webPageURL, "https://panel.example.com")
        XCTAssertEqual(usage.updateIntervalHours, 24)

        let beforeExpire = Date(timeIntervalSince1970: 1_800_000_000 - 86_400 * 3)
        XCTAssertFalse(usage.isExpired(referenceNow: beforeExpire))
        XCTAssertEqual(usage.daysUntilExpire(referenceNow: beforeExpire), 3)

        let afterExpire = Date(timeIntervalSince1970: 1_800_000_000 + 3_600)
        XCTAssertTrue(usage.isExpired(referenceNow: afterExpire))

        // Scientific notation & expire=0 (permanent)
        let sci = try XCTUnwrap(SubscriptionUsage.parse(headerValue: "upload=0; download=5e9; total=1e11; expire=0"))
        XCTAssertEqual(sci.download, 5_000_000_000)
        XCTAssertEqual(sci.total, 100_000_000_000)
        XCTAssertNil(sci.expireDate)
        XCTAssertFalse(sci.isExpired())

        // Invalid / empty headers
        XCTAssertNil(SubscriptionUsage.parse(headerValue: nil))
        XCTAssertNil(SubscriptionUsage.parse(headerValue: "   "))
        XCTAssertNil(SubscriptionUsage.parse(headerValue: "foo=bar"))
    }

    func testTrafficHistoryAccumulatorAndTargetStats() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let day1 = Date(timeIntervalSince1970: 1_795_000_000)
        let day1Hour = cal.component(.hour, from: day1)
        let day2 = cal.date(byAdding: .day, value: 1, to: day1)!

        var acc = TrafficHistoryAccumulator()
        acc.recordDelta(uploadDelta: 1_000, downloadDelta: 4_000, at: day1, calendar: cal)
        acc.recordDelta(uploadDelta: 500, downloadDelta: 1_500, at: day1, calendar: cal)

        let today1 = acc.todayRecord(at: day1, calendar: cal)
        XCTAssertEqual(today1.upload, 1_500)
        XCTAssertEqual(today1.download, 5_500)
        XCTAssertEqual(today1.total, 7_000)

        let hourly1 = acc.todayHourlyBuckets(at: day1, calendar: cal)
        XCTAssertEqual(hourly1.count, 24)
        XCTAssertEqual(hourly1[day1Hour].total, 7_000)

        // Roll over to next day
        acc.recordDelta(uploadDelta: 200, downloadDelta: 800, at: day2, calendar: cal)
        let last7 = acc.lastNDays(7, at: day2, calendar: cal)
        XCTAssertEqual(last7.count, 7)
        XCTAssertEqual(last7[5].total, 7_000)
        XCTAssertEqual(last7[6].total, 1_000)
        let totals = acc.totalBytes(lastNDays: 7, at: day2, calendar: cal)
        XCTAssertEqual(totals.upload, 1_700)
        XCTAssertEqual(totals.download, 6_300)

        // Codable round-trip
        let encoded = try JSONEncoder().encode(acc)
        let decoded = try JSONDecoder().decode(TrafficHistoryAccumulator.self, from: encoded)
        XCTAssertEqual(decoded, acc)

        // ConnectionTracker speedHistory & targetTrafficStats
        var tracker = ConnectionTracker(maxClosedHistory: 10, maxSpeedSamples: 10)
        let connA = MihomoConnection(
            id: "a",
            metadata: MihomoConnectionMetadata(host: "a.com"),
            upload: 100,
            download: 900,
            start: "",
            chains: ["US-1", "美国"],
            rule: "MATCH",
            rulePayload: ""
        )
        let connB = MihomoConnection(
            id: "b",
            metadata: MihomoConnectionMetadata(host: "b.com"),
            upload: 50,
            download: 150,
            start: "",
            chains: ["DIRECT"],
            rule: "GEOIP",
            rulePayload: "CN"
        )
        tracker.ingest(MihomoConnectionsSnapshot(downloadTotal: 1_050, uploadTotal: 150, connections: [connA, connB]), at: day1)
        XCTAssertEqual(tracker.speedHistory.count, 1)
        XCTAssertEqual(tracker.lastUploadDelta, 150)
        XCTAssertEqual(tracker.lastDownloadDelta, 1_050)

        let stats = tracker.targetTrafficStats
        XCTAssertEqual(stats.count, 2)
        XCTAssertEqual(stats[0].target, "美国")
        XCTAssertEqual(stats[0].total, 1_000)
        XCTAssertEqual(stats[1].target, "DIRECT")
        XCTAssertTrue(stats[1].isDirect)
    }

    func testRuleMatchDisplayIndexResolvesRuleSetDomainAndMatch() throws {
        let direct = NetworkTarget(name: "国内直连", mode: .direct)
        let okxURL = "https://fastly.jsdelivr.net/gh/ACL4SSR/ACL4SSR@master/Clash/Ruleset/Crypto.list"
        let profile = RoutingProfile(
            targets: [direct],
            ruleGroups: [
                RuleGroup(
                    name: "加密货币与交易所",
                    target: .target(direct.id),
                    rules: [
                        RuleItem(type: .ruleSet, value: okxURL, note: "ACL4SSR · Crypto"),
                        RuleItem(type: .domainSuffix, value: "okx.com", note: "OKX"),
                    ]
                ),
            ],
            fallbackTarget: .target(direct.id)
        )
        let index = RuleMatchDisplayIndex(profile: profile)
        let rsKey = MihomoConfig.ruleSetProviderKey(for: okxURL)

        let rsMatch = try XCTUnwrap(index.resolve(rule: "RuleSet", payload: rsKey))
        XCTAssertEqual(rsMatch.groupName, "加密货币与交易所")
        XCTAssertEqual(rsMatch.ruleNote, "ACL4SSR · Crypto")

        let domainMatch = try XCTUnwrap(index.resolve(rule: "DomainSuffix", payload: "okx.com"))
        XCTAssertEqual(domainMatch.groupName, "加密货币与交易所")
        XCTAssertEqual(domainMatch.ruleNote, "OKX")

        let fallbackMatch = try XCTUnwrap(index.resolve(rule: "Match", payload: ""))
        XCTAssertEqual(fallbackMatch.groupName, "默认兜底 (MATCH)")
    }

    func testInnerConnectionFilteringCompactNodeAndBusinessCounts() throws {
        var tracker = ConnectionTracker()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        let businessConn = MihomoConnection(
            id: "biz-1",
            metadata: MihomoConnectionMetadata(
                network: "udp",
                type: "Tun",
                destinationPort: "443",
                host: "gateway.icloud.com",
                process: "nsurlsessiond"
            ),
            upload: 2_300,
            download: 5_300,
            start: "2026-11-22T02:30:00Z",
            chains: ["[香港节点] [vless] 香港 A01", "香港节点"],
            rule: "Match",
            rulePayload: ""
        )
        let innerConn = MihomoConnection(
            id: "inner-1",
            metadata: MihomoConnectionMetadata(
                network: "tcp",
                type: "Inner",
                destinationPort: "443",
                host: "hk-a01.linkss.dev"
            ),
            upload: 3_100,
            download: 11_500,
            start: "2026-11-22T02:30:00Z",
            chains: ["香港 02 | 1x HK", "香港节点·链式"],
            rule: "",
            rulePayload: ""
        )

        tracker.ingest(
            MihomoConnectionsSnapshot(
                downloadTotal: 16_800,
                uploadTotal: 5_400,
                connections: [businessConn, innerConn]
            ),
            at: t0
        )

        let bizRecord = try XCTUnwrap(tracker.recordsByID["biz-1"])
        let innerRecord = try XCTUnwrap(tracker.recordsByID["inner-1"])

        XCTAssertFalse(bizRecord.isInner)
        XCTAssertTrue(innerRecord.isInner)
        XCTAssertEqual(bizRecord.compactFinalNode, "[vless] 香港 A01")
        XCTAssertEqual(innerRecord.compactFinalNode, "香港 02 | 1x HK")

        XCTAssertEqual(tracker.activeCount, 2)
        XCTAssertEqual(tracker.innerCount, 1)
        XCTAssertEqual(tracker.activeInnerCount, 1)
        XCTAssertEqual(tracker.businessActiveCount, 1)
        XCTAssertEqual(tracker.businessClosedCount, 0)

        XCTAssertEqual(tracker.availableTargets(includeInner: false), ["香港节点"])
        XCTAssertEqual(tracker.availableTargets(includeInner: true), ["香港节点", "香港节点·链式"])

        XCTAssertEqual(tracker.filtered(includeInner: false).map(\.id), ["biz-1"])
        XCTAssertEqual(tracker.filtered(includeInner: true).count, 2)
    }

    func testPerTargetTrafficHistoryPersistenceRenameAndInnerExclusion() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let day1 = Date(timeIntervalSince1970: 1_795_000_000)
        let day1T1 = day1.addingTimeInterval(2)
        let day1Hour = cal.component(.hour, from: day1)
        let day2 = cal.date(byAdding: .day, value: 1, to: day1)!

        // 1. ConnectionTracker excludes Inner connections and retains totals past maxClosedHistory
        var tracker = ConnectionTracker(maxClosedHistory: 10, maxSpeedSamples: 10)
        var acc = TrafficHistoryAccumulator()

        let bizHK = MihomoConnection(
            id: "hk-1",
            metadata: MihomoConnectionMetadata(type: "Tun", host: "hk.example.com"),
            upload: 1_000,
            download: 3_000,
            start: "",
            chains: ["HK-Node", "香港出口"],
            rule: "MATCH",
            rulePayload: ""
        )
        let innerHK = MihomoConnection(
            id: "hk-inner",
            metadata: MihomoConnectionMetadata(type: "Inner", host: "relay.example.com"),
            upload: 1_100,
            download: 3_200,
            start: "",
            chains: ["Relay-Node", "香港出口·链式"],
            rule: "",
            rulePayload: ""
        )
        tracker.ingest(
            MihomoConnectionsSnapshot(downloadTotal: 3_000, uploadTotal: 1_000, connections: [bizHK, innerHK]),
            at: day1
        )
        XCTAssertEqual(tracker.lastTargetDeltas.keys.sorted(), ["香港出口"])
        XCTAssertEqual(tracker.lastTargetDeltas["香港出口"], TrafficBytes(upload: 1_000, download: 3_000))
        acc.recordDelta(
            uploadDelta: tracker.lastUploadDelta,
            downloadDelta: tracker.lastDownloadDelta,
            targetDeltas: tracker.lastTargetDeltas,
            at: day1,
            calendar: cal
        )

        // Second snapshot 2 seconds later: hk-1 grows, us-1 appears
        let bizHK2 = MihomoConnection(
            id: "hk-1",
            metadata: MihomoConnectionMetadata(type: "Tun", host: "hk.example.com"),
            upload: 1_400,
            download: 5_000,
            start: "",
            chains: ["HK-Node", "香港出口"],
            rule: "MATCH",
            rulePayload: ""
        )
        let bizUS = MihomoConnection(
            id: "us-1",
            metadata: MihomoConnectionMetadata(type: "Tun", host: "us.example.com"),
            upload: 200,
            download: 800,
            start: "",
            chains: ["US-Node", "美国出口"],
            rule: "MATCH",
            rulePayload: ""
        )
        tracker.ingest(
            MihomoConnectionsSnapshot(downloadTotal: 5_800, uploadTotal: 1_600, connections: [bizHK2, bizUS]),
            at: day1T1
        )
        XCTAssertEqual(tracker.lastTargetDeltas["香港出口"], TrafficBytes(upload: 400, download: 2_000))
        XCTAssertEqual(tracker.lastTargetDeltas["美国出口"], TrafficBytes(upload: 200, download: 800))
        XCTAssertEqual(tracker.liveSpeed(for: "香港出口"), TrafficBytes(upload: 200, download: 1_000))
        XCTAssertEqual(tracker.speedHistory(for: "香港出口").count, 2)
        XCTAssertEqual(tracker.speedHistory(for: "香港出口").last?.downloadSpeed, 1_000)

        acc.recordDelta(
            uploadDelta: tracker.lastUploadDelta,
            downloadDelta: tracker.lastDownloadDelta,
            targetDeltas: tracker.lastTargetDeltas,
            at: day1T1,
            calendar: cal
        )

        // Even after clearing closed connections, session target totals remain intact
        tracker.ingest(MihomoConnectionsSnapshot(downloadTotal: 5_800, uploadTotal: 1_600, connections: []), at: day1T1.addingTimeInterval(1))
        tracker.clearClosed()
        XCTAssertEqual(tracker.sessionTraffic(for: "香港出口"), TrafficBytes(upload: 1_400, download: 5_000))
        XCTAssertEqual(tracker.targetTrafficStats.map(\.target), ["香港出口", "美国出口"])

        // 2. Per-target queries on TrafficHistoryAccumulator
        XCTAssertEqual(acc.todayRecord(target: "香港出口", at: day1, calendar: cal).total, 6_400)
        XCTAssertEqual(acc.todayHourlyBuckets(target: "香港出口", at: day1, calendar: cal)[day1Hour].download, 5_000)
        XCTAssertEqual(acc.todayRecord(target: "美国出口", at: day1, calendar: cal).total, 1_000)

        // Day 2 traffic on US
        acc.recordDelta(
            uploadDelta: 500,
            downloadDelta: 1_500,
            targetDeltas: ["美国出口": TrafficBytes(upload: 500, download: 1_500)],
            at: day2,
            calendar: cal
        )
        let weekStats = acc.targetTrafficStats(lastNDays: 7, at: day2, calendar: cal)
        XCTAssertEqual(weekStats.count, 2)
        XCTAssertEqual(weekStats[0].target, "香港出口")
        XCTAssertEqual(weekStats[0].total, 6_400)
        XCTAssertEqual(weekStats[1].target, "美国出口")
        XCTAssertEqual(weekStats[1].total, 3_000)

        // 3. Rename target migrates daily and hourly buckets
        acc.renameTarget(from: "香港出口", to: "香港专线")
        XCTAssertEqual(acc.totalBytes(lastNDays: 7, target: "香港出口", at: day2, calendar: cal).download, 0)
        XCTAssertEqual(acc.totalBytes(lastNDays: 7, target: "香港专线", at: day2, calendar: cal).download, 5_000)

        // 4. Backward compatibility decoding legacy JSON without `byTarget`
        let legacyJSON = """
        {
          "dailyRecords": {
            "2026-11-22": { "dayKey": "2026-11-22", "upload": 123, "download": 456 }
          },
          "hourlyDayKey": "2026-11-22",
          "hourlyBuckets": {
            "10": { "hour": 10, "upload": 123, "download": 456 }
          }
        }
        """
        let decodedLegacy = try JSONDecoder().decode(TrafficHistoryAccumulator.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decodedLegacy.dailyRecords["2026-11-22"]?.download, 456)
        XCTAssertEqual(decodedLegacy.dailyRecords["2026-11-22"]?.byTarget, [:])
        XCTAssertEqual(decodedLegacy.hourlyBuckets[10]?.byTarget, [:])
    }

    func testDNSLogTrackerFilteringCountingAndRingLimit() {
        var tracker = DNSLogTracker(maxRecords: 3)
        let ok = DNSLogRecord(
            domain: "apple.com",
            recordType: "A",
            answers: ["17.253.144.10"],
            upstream: "https://dns.google/dns-query",
            status: .resolved,
            rawPayload: "apple.com"
        )
        let cached = DNSLogRecord(
            domain: "cache.example.com",
            recordType: "A",
            answers: ["1.2.3.4"],
            upstream: "cache",
            cacheExpireAt: "12:00:00",
            status: .resolved,
            rawPayload: "cache.example.com"
        )
        let emptyAAAA = DNSLogRecord(
            domain: "ipv4only.example.com",
            recordType: "AAAA",
            answers: [],
            upstream: "https://1.1.1.1/dns-query",
            status: .resolved,
            rawPayload: "ipv4only"
        )
        let failed = DNSLogRecord(
            domain: "broken.test",
            recordType: "A",
            answers: [],
            upstream: "DNS Server",
            status: .failed,
            errorMessage: "i/o timeout",
            rawPayload: "broken.test failed"
        )

        tracker.appendBatch([ok, cached, emptyAAAA, failed])
        XCTAssertEqual(tracker.records.count, 3)
        XCTAssertEqual(tracker.records.first?.domain, "broken.test")
        XCTAssertEqual(tracker.failedCount, 1)
        XCTAssertEqual(tracker.cacheHitCount, 1)

        XCTAssertEqual(tracker.filtered(scope: .failed).map(\.domain), ["broken.test"])
        XCTAssertEqual(tracker.filtered(sourceFilter: .cache).map(\.domain), ["cache.example.com"])
        XCTAssertEqual(tracker.filtered(hideEmptyAnswers: true).map(\.domain), ["broken.test", "cache.example.com"])
        XCTAssertEqual(tracker.filtered(searchText: "timeout").map(\.domain), ["broken.test"])
    }

    func testRelayChainResolverUsesMihomoConfigNaming() throws {
        let exitGroup = NodeGroup(name: "US", kind: .exit)
        let relayGroup = NodeGroup(name: "HK", kind: .relay)
        let chainedTarget = NetworkTarget(name: "Claude出口", mode: .proxy, exitGroupID: exitGroup.id, relayGroupID: relayGroup.id)
        let profile = RoutingProfile(nodeGroups: [exitGroup, relayGroup], targets: [chainedTarget])

        var tracker = ConnectionTracker()
        tracker.ingest(
            MihomoConnectionsSnapshot(
                downloadTotal: 200,
                uploadTotal: 100,
                connections: [
                    MihomoConnection(
                        id: "c1",
                        metadata: MihomoConnectionMetadata(type: "Tun", host: "claude.ai"),
                        upload: 100,
                        download: 200,
                        start: "",
                        chains: ["US-01", "Claude出口"],
                        rule: "MATCH",
                        rulePayload: ""
                    )
                ]
            ),
            at: Date()
        )
        let conn = try XCTUnwrap(tracker.recordsByID["c1"])
        let expectedGroup = MihomoConfig.relayGroupName(for: "Claude出口")
        let resolved = RelayChainResolver.resolve(
            for: conn,
            profile: profile,
            runtimeCurrentNodes: [expectedGroup: "HK-Relay-01"],
            runtimeSelections: [:]
        )
        XCTAssertEqual(resolved, ResolvedRelayChain(relayGroupName: expectedGroup, relayNode: "HK-Relay-01"))
    }
}
