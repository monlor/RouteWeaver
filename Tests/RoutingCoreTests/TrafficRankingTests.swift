import Foundation
import XCTest
@testable import RoutingCore

final class TrafficRankingTests: XCTestCase {
    func testAttributionExtractsAndNormalizesWithoutReverseDNSGuessing() {
        let normal = MihomoConnectionMetadata(
            destinationIP: "104.18.7.192",
            host: "API.OpenAI.com.",
            process: "Cursor",
            processPath: "/Applications/Cursor.app/Contents/MacOS/Cursor"
        )
        let attr1 = TrafficAttribution.extract(from: normal)
        XCTAssertEqual(attr1.domain, "api.openai.com")
        XCTAssertEqual(attr1.ip, "104.18.7.192")
        XCTAssertEqual(attr1.process, "Cursor")

        // When host is an IP literal or empty, domain must fall back to "未知" (never reverse-DNS).
        let ipAsHost = MihomoConnectionMetadata(
            destinationIP: "",
            host: "1.1.1.1",
            process: "",
            processPath: "/usr/bin/curl",
            remoteDestination: "[2606:4700:4700::1111]"
        )
        let attr2 = TrafficAttribution.extract(from: ipAsHost)
        XCTAssertEqual(attr2.domain, TrafficAttribution.unknownLabel)
        XCTAssertEqual(attr2.ip, "2606:4700:4700::1111")
        XCTAssertEqual(attr2.process, "curl")

        // All metadata missing -> all dimensions map to "未知".
        let empty = MihomoConnectionMetadata(remoteDestination: "example.invalid")
        let attr3 = TrafficAttribution.extract(from: empty)
        XCTAssertEqual(attr3.domain, TrafficAttribution.unknownLabel)
        XCTAssertEqual(attr3.ip, TrafficAttribution.unknownLabel)
        XCTAssertEqual(attr3.process, TrafficAttribution.unknownLabel)
    }

    func testConnectionTrackerComputesIncrementalDeltasExcludesInnerAndHandlesResets() {
        var tracker = ConnectionTracker()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        let c1 = MihomoConnection(
            id: "c1",
            metadata: MihomoConnectionMetadata(
                type: "HTTP Connect",
                destinationIP: "140.82.114.4",
                host: "github.com",
                process: "git"
            ),
            upload: 100,
            download: 500,
            start: "",
            chains: ["香港"],
            rule: "DOMAIN",
            rulePayload: "github.com"
        )
        let inner = MihomoConnection(
            id: "inner-1",
            metadata: MihomoConnectionMetadata(
                type: "Inner",
                destinationIP: "1.2.3.4",
                host: "relay.example.com",
                process: "mihomo"
            ),
            upload: 9_000,
            download: 9_000,
            start: "",
            chains: ["DIRECT"],
            rule: "MATCH",
            rulePayload: ""
        )

        tracker.ingest(
            MihomoConnectionsSnapshot(downloadTotal: 9_500, uploadTotal: 9_100, connections: [c1, inner]),
            at: t0
        )
        XCTAssertEqual(tracker.lastDimensionDeltas.domains["github.com"], TrafficBytes(upload: 100, download: 500))
        XCTAssertNil(tracker.lastDimensionDeltas.domains["relay.example.com"])

        // Poll 2: c1 grows by +200 up / +1000 down; short-lived connection closed between polls (+50 up / +150 down).
        let t1 = t0.addingTimeInterval(1)
        let c1Updated = MihomoConnection(
            id: "c1",
            metadata: c1.metadata,
            upload: 300,
            download: 1_500,
            start: "",
            chains: ["香港"],
            rule: "DOMAIN",
            rulePayload: "github.com"
        )
        tracker.ingest(
            MihomoConnectionsSnapshot(downloadTotal: 10_650, uploadTotal: 9_350, connections: [c1Updated]),
            at: t1
        )
        XCTAssertEqual(tracker.lastDimensionDeltas.domains["github.com"], TrafficBytes(upload: 200, download: 1_000))
        XCTAssertEqual(tracker.lastDimensionDeltas.ips["140.82.114.4"], TrafficBytes(upload: 200, download: 1_000))
        XCTAssertEqual(tracker.lastDimensionDeltas.processes["git"], TrafficBytes(upload: 200, download: 1_000))
        XCTAssertEqual(
            tracker.lastDimensionDeltas.domains[TrafficAttribution.unknownLabel],
            TrafficBytes(upload: 50, download: 150)
        )

        // Poll 3: Counter decrease on c1 must clamp to 0 instead of negative.
        let t2 = t1.addingTimeInterval(1)
        let c1Reset = MihomoConnection(
            id: "c1",
            metadata: c1.metadata,
            upload: 10,
            download: 20,
            start: "",
            chains: ["香港"],
            rule: "DOMAIN",
            rulePayload: "github.com"
        )
        tracker.ingest(
            MihomoConnectionsSnapshot(downloadTotal: 10_650, uploadTotal: 9_350, connections: [c1Reset]),
            at: t2
        )
        XCTAssertTrue(tracker.lastDimensionDeltas.isEmpty)
    }

    func testAccumulatorWindowsRetentionSortingSearchAndPersistence() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!

        var acc = TrafficRankingAccumulator()
        let base = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 12, minute: 0))!

        // 8 days ago -> should be pruned when recording at `base`
        let eightDaysAgo = calendar.date(byAdding: .day, value: -8, to: base)!
        acc.record(
            TrafficDimensionDeltas(
                domains: ["old.example.com": TrafficBytes(upload: 100, download: 100)],
                ips: ["9.9.9.9": TrafficBytes(upload: 100, download: 100)],
                processes: ["OldApp": TrafficBytes(upload: 100, download: 100)]
            ),
            at: eightDaysAgo,
            calendar: calendar
        )

        // 2 hours ago today -> included in today & last7Days, excluded from lastHour
        let twoHoursAgo = calendar.date(byAdding: .hour, value: -2, to: base)!
        acc.record(
            TrafficDimensionDeltas(
                domains: ["docs.swift.org": TrafficBytes(upload: 500, download: 2_500)],
                ips: ["104.16.1.1": TrafficBytes(upload: 500, download: 2_500)],
                processes: ["Safari": TrafficBytes(upload: 500, download: 2_500)]
            ),
            at: twoHoursAgo,
            calendar: calendar
        )

        // 15 minutes ago -> included in lastHour, today, last7Days
        let fifteenMinsAgo = calendar.date(byAdding: .minute, value: -15, to: base)!
        acc.record(
            TrafficDimensionDeltas(
                domains: [
                    "api.openai.com": TrafficBytes(upload: 1_000, download: 3_000),
                    "未知": TrafficBytes(upload: 200, download: 800),
                ],
                ips: [
                    "104.18.7.192": TrafficBytes(upload: 1_000, download: 3_000),
                    "未知": TrafficBytes(upload: 200, download: 800),
                ],
                processes: [
                    "Cursor": TrafficBytes(upload: 1_000, download: 3_000),
                    "未知": TrafficBytes(upload: 200, download: 800),
                ]
            ),
            at: fifteenMinsAgo,
            calendar: calendar
        )

        // Verify 8-day-old bucket was pruned
        XCTAssertNil(acc.dailyBuckets[TrafficHistoryAccumulator.dayKey(for: eightDaysAgo, calendar: calendar)])

        // Last 1 hour report
        let hourReport = acc.report(dimension: .domain, window: .lastHour, at: base, calendar: calendar)
        XCTAssertEqual(hourReport.totalUpload, 1_200)
        XCTAssertEqual(hourReport.totalDownload, 3_800)
        XCTAssertEqual(hourReport.items.map(\.key), ["api.openai.com", "未知"])
        XCTAssertEqual(hourReport.items[0].percentage, 80.0, accuracy: 0.01)
        XCTAssertEqual(hourReport.items[1].percentage, 20.0, accuracy: 0.01)
        // trackingStartedAt is 8 days ago (< 1h windowStart), so lastHour is not partial
        XCTAssertFalse(hourReport.coverage.isPartial)

        // Today report includes docs.swift.org + api.openai.com + 未知
        let todayReport = acc.report(dimension: .domain, window: .today, at: base, calendar: calendar)
        XCTAssertEqual(todayReport.grandTotal, 8_000)
        XCTAssertEqual(todayReport.items.map(\.key), ["api.openai.com", "docs.swift.org", "未知"])

        // Search filter
        let filtered = acc.report(dimension: .domain, window: .today, searchText: "swift", at: base, calendar: calendar)
        XCTAssertEqual(filtered.items.map(\.key), ["docs.swift.org"])

        // Sort ascending by name
        let sortedByName = acc.report(dimension: .process, window: .today, sortBy: .name, ascending: true, at: base, calendar: calendar)
        XCTAssertEqual(sortedByName.items.map(\.key), ["Cursor", "Safari", "未知"])

        // Per-process target filtering (process -> domains / IPs)
        var procDeltas = TrafficDimensionDeltas()
        procDeltas.add(domain: "api.github.com", ip: "140.82.114.6", process: "Cursor", upload: 100, download: 400)
        procDeltas.add(domain: "apple.com", ip: "17.253.144.10", process: "Safari", upload: 50, download: 150)
        var procAcc = TrafficRankingAccumulator()
        procAcc.record(procDeltas, at: base, calendar: calendar)
        let cursorDomains = procAcc.report(dimension: .domain, window: .today, processFilter: "Cursor", at: base, calendar: calendar)
        XCTAssertEqual(cursorDomains.items.map(\.key), ["api.github.com"])
        XCTAssertEqual(cursorDomains.grandTotal, 500)
        let cursorIPs = procAcc.report(dimension: .ip, window: .today, processFilter: "Cursor", at: base, calendar: calendar)
        XCTAssertEqual(cursorIPs.items.map(\.key), ["140.82.114.6"])

        // Codable round-trip
        let encoded = try JSONEncoder().encode(acc)
        let decoded = try JSONDecoder().decode(TrafficRankingAccumulator.self, from: encoded)
        XCTAssertEqual(decoded, acc)
    }

    func testBucketCompactionBoundsCardinalityWhilePreservingTotalsAndUnknown() {
        var bucket = TrafficDimensionBuckets()
        var deltas = TrafficDimensionDeltas()
        for i in 1...250 {
            deltas.add(
                domain: "d\(i).example.com",
                ip: "10.0.\(i / 255).\(i % 255)",
                process: "proc-\(i)",
                upload: Int64(i),
                download: Int64(i * 2)
            )
        }
        deltas.add(domain: TrafficAttribution.unknownLabel, ip: TrafficAttribution.unknownLabel, process: TrafficAttribution.unknownLabel, upload: 50, download: 50)

        let expectedUpload = deltas.domains.values.reduce(Int64(0)) { $0 + $1.upload }
        let expectedDownload = deltas.domains.values.reduce(Int64(0)) { $0 + $1.download }

        bucket.merge(deltas, maxEntriesPerDimension: 50)

        // 50 top named + "未知" + "其他" = 52
        XCTAssertEqual(bucket.domains.count, 52)
        XCTAssertNotNil(bucket.domains[TrafficAttribution.unknownLabel])
        XCTAssertNotNil(bucket.domains[TrafficAttribution.otherLabel])

        let actualUpload = bucket.domains.values.reduce(Int64(0)) { $0 + $1.upload }
        let actualDownload = bucket.domains.values.reduce(Int64(0)) { $0 + $1.download }
        XCTAssertEqual(actualUpload, expectedUpload)
        XCTAssertEqual(actualDownload, expectedDownload)
    }

    func testClientDeviceAttributionRankingAndConnectionFilter() throws {
        let localIPs: Set<String> = ["192.168.100.73"]
        let now = Date()

        var tracker = ConnectionTracker()
        let snapshot = MihomoConnectionsSnapshot(
            downloadTotal: 5_000,
            uploadTotal: 1_500,
            memory: 0,
            connections: [
                MihomoConnection(
                    id: "local-1",
                    metadata: MihomoConnectionMetadata(
                        network: "tcp",
                        sourceIP: "192.168.100.73",
                        destinationIP: "140.82.114.6",
                        host: "github.com",
                        process: "Cursor"
                    ),
                    upload: 500,
                    download: 1_000,
                    start: "",
                    chains: ["Proxy"],
                    rule: "MATCH",
                    rulePayload: ""
                ),
                MihomoConnection(
                    id: "lan-iphone",
                    metadata: MihomoConnectionMetadata(
                        network: "tcp",
                        sourceIP: "192.168.100.42",
                        destinationIP: "17.253.144.10",
                        host: "apple.com"
                    ),
                    upload: 1_000,
                    download: 4_000,
                    start: "",
                    chains: ["Proxy"],
                    rule: "MATCH",
                    rulePayload: ""
                ),
            ]
        )

        tracker.ingest(snapshot, localIPs: localIPs, at: now)
        XCTAssertEqual(tracker.availableClients(localIPs: localIPs), [TrafficAttribution.localDeviceLabel, "192.168.100.42"])

        let filteredByLAN = tracker.filtered(clientFilter: "192.168.100.42", localIPs: localIPs)
        XCTAssertEqual(filteredByLAN.map(\.id), ["lan-iphone"])

        let filteredByAlias = tracker.filtered(
            searchText: "iphone",
            localIPs: localIPs,
            clientDisplayNames: ["192.168.100.42": "iPhone-16"]
        )
        XCTAssertEqual(filteredByAlias.map(\.id), ["lan-iphone"])

        var acc = TrafficRankingAccumulator()
        acc.record(tracker.lastDimensionDeltas, at: now)

        let clients = acc.report(dimension: .client, window: .today, at: now)
        XCTAssertEqual(clients.items.map(\.key), ["192.168.100.42", TrafficAttribution.localDeviceLabel])
        XCTAssertEqual(clients.items[0].total, 5_000)
        XCTAssertEqual(clients.items[1].total, 1_500)

        let iphoneDomains = acc.report(dimension: .domain, window: .today, clientFilter: "192.168.100.42", at: now)
        XCTAssertEqual(iphoneDomains.items.map(\.key), ["apple.com"])
        XCTAssertEqual(iphoneDomains.grandTotal, 5_000)

        let iphoneIPs = acc.report(dimension: .ip, window: .today, clientFilter: "192.168.100.42", at: now)
        XCTAssertEqual(iphoneIPs.items.map(\.key), ["17.253.144.10"])
    }
}
