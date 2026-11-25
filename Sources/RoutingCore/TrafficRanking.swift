import Foundation

public enum TrafficRankingDimension: String, CaseIterable, Identifiable, Sendable {
    case domain
    case ip
    case process

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .domain: return "域名"
        case .ip: return "IP"
        case .process: return "进程"
        }
    }

    public var icon: String {
        switch self {
        case .domain: return "globe"
        case .ip: return "network"
        case .process: return "app.dashed"
        }
    }

    public var columnTitle: String {
        switch self {
        case .domain: return "域名"
        case .ip: return "目标 IP"
        case .process: return "进程"
        }
    }
}

public enum TrafficRankingWindow: String, CaseIterable, Identifiable, Sendable {
    case lastHour
    case today
    case last7Days

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .lastHour: return "最近 1 小时"
        case .today: return "今天"
        case .last7Days: return "最近 7 天"
        }
    }
}

public enum TrafficRankingSortField: String, CaseIterable, Identifiable, Sendable {
    case total
    case download
    case upload
    case name

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .total: return "总量"
        case .download: return "下载"
        case .upload: return "上传"
        case .name: return "名称"
        }
    }
}

public struct TrafficRankingItem: Identifiable, Equatable, Sendable {
    public let key: String
    public let upload: Int64
    public let download: Int64
    public let percentage: Double

    public var id: String { key }
    public var total: Int64 { upload + download }
    public var isUnknown: Bool { key == TrafficAttribution.unknownLabel }
    public var isOther: Bool { key == TrafficAttribution.otherLabel }

    public init(key: String, upload: Int64, download: Int64, percentage: Double) {
        self.key = key
        self.upload = max(0, upload)
        self.download = max(0, download)
        self.percentage = max(0, min(100, percentage))
    }
}

public struct TrafficRankingCoverage: Equatable, Sendable {
    public let trackingStartedAt: Date?
    public let windowStart: Date
    public let isPartial: Bool
    public let activeBucketCount: Int

    public init(trackingStartedAt: Date?, windowStart: Date, isPartial: Bool, activeBucketCount: Int) {
        self.trackingStartedAt = trackingStartedAt
        self.windowStart = windowStart
        self.isPartial = isPartial
        self.activeBucketCount = activeBucketCount
    }
}

public struct TrafficRankingReport: Equatable, Sendable {
    public let items: [TrafficRankingItem]
    public let totalUpload: Int64
    public let totalDownload: Int64
    public let coverage: TrafficRankingCoverage

    public var grandTotal: Int64 { totalUpload + totalDownload }

    public init(
        items: [TrafficRankingItem],
        totalUpload: Int64,
        totalDownload: Int64,
        coverage: TrafficRankingCoverage
    ) {
        self.items = items
        self.totalUpload = max(0, totalUpload)
        self.totalDownload = max(0, totalDownload)
        self.coverage = coverage
    }
}

public struct TrafficDimensionDeltas: Equatable, Sendable {
    public var domains: [String: TrafficBytes] = [:]
    public var ips: [String: TrafficBytes] = [:]
    public var processes: [String: TrafficBytes] = [:]
    public var processDomains: [String: [String: TrafficBytes]] = [:]
    public var processIPs: [String: [String: TrafficBytes]] = [:]

    public var isEmpty: Bool {
        domains.isEmpty && ips.isEmpty && processes.isEmpty
    }

    public init(
        domains: [String: TrafficBytes] = [:],
        ips: [String: TrafficBytes] = [:],
        processes: [String: TrafficBytes] = [:],
        processDomains: [String: [String: TrafficBytes]] = [:],
        processIPs: [String: [String: TrafficBytes]] = [:]
    ) {
        self.domains = domains
        self.ips = ips
        self.processes = processes
        self.processDomains = processDomains
        self.processIPs = processIPs
    }

    public mutating func add(
        domain: String,
        ip: String,
        process: String,
        upload: Int64,
        download: Int64
    ) {
        let up = max(0, upload)
        let down = max(0, download)
        guard up > 0 || down > 0 else { return }

        var domainEntry = domains[domain] ?? .zero
        domainEntry.add(upload: up, download: down)
        domains[domain] = domainEntry

        var ipEntry = ips[ip] ?? .zero
        ipEntry.add(upload: up, download: down)
        ips[ip] = ipEntry

        var processEntry = processes[process] ?? .zero
        processEntry.add(upload: up, download: down)
        processes[process] = processEntry

        var procDomainMap = processDomains[process] ?? [:]
        var procDomainEntry = procDomainMap[domain] ?? .zero
        procDomainEntry.add(upload: up, download: down)
        procDomainMap[domain] = procDomainEntry
        processDomains[process] = procDomainMap

        var procIPMap = processIPs[process] ?? [:]
        var procIPEntry = procIPMap[ip] ?? .zero
        procIPEntry.add(upload: up, download: down)
        procIPMap[ip] = procIPEntry
        processIPs[process] = procIPMap
    }
}

public enum TrafficAttribution {
    public static let unknownLabel = "未知"
    public static let otherLabel = "其他"

    public static func extract(from metadata: MihomoConnectionMetadata) -> (domain: String, ip: String, process: String) {
        (
            domain: extractDomain(from: metadata),
            ip: extractIP(from: metadata),
            process: extractProcess(from: metadata)
        )
    }

    /// Extracts observed hostname without performing any reverse DNS lookup.
    /// IP literals in `host` are treated as missing domain (`未知`).
    public static func extractDomain(from metadata: MihomoConnectionMetadata) -> String {
        let raw = metadata.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return unknownLabel }
        if CustomDNSValidator.isIPAddress(raw) {
            return unknownLabel
        }
        let normalized = raw.hasSuffix(".") ? String(raw.dropLast()) : raw
        let lower = normalized.lowercased()
        return lower.isEmpty ? unknownLabel : lower
    }

    public static func extractIP(from metadata: MihomoConnectionMetadata) -> String {
        let dest = normalizeIPCandidate(metadata.destinationIP)
        if !dest.isEmpty, CustomDNSValidator.isIPAddress(dest) {
            return dest
        }
        let remote = normalizeIPCandidate(metadata.remoteDestination)
        if !remote.isEmpty, CustomDNSValidator.isIPAddress(remote) {
            return remote
        }
        return unknownLabel
    }

    public static func extractProcess(from metadata: MihomoConnectionMetadata) -> String {
        let name = metadata.process.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            return name
        }
        let path = metadata.processPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty {
            let component = URL(fileURLWithPath: path).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !component.isEmpty && component != "/" {
                return component
            }
        }
        return unknownLabel
    }

    private static func normalizeIPCandidate(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("[") && s.hasSuffix("]") && s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }
}

public struct TrafficDimensionBuckets: Codable, Equatable, Sendable {
    public var domains: [String: TrafficBytes]
    public var ips: [String: TrafficBytes]
    public var processes: [String: TrafficBytes]
    public var processDomains: [String: [String: TrafficBytes]]
    public var processIPs: [String: [String: TrafficBytes]]

    public init(
        domains: [String: TrafficBytes] = [:],
        ips: [String: TrafficBytes] = [:],
        processes: [String: TrafficBytes] = [:],
        processDomains: [String: [String: TrafficBytes]] = [:],
        processIPs: [String: [String: TrafficBytes]] = [:]
    ) {
        self.domains = domains
        self.ips = ips
        self.processes = processes
        self.processDomains = processDomains
        self.processIPs = processIPs
    }

    private enum CodingKeys: String, CodingKey {
        case domains, ips, processes, processDomains, processIPs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        domains = try c.decodeIfPresent([String: TrafficBytes].self, forKey: .domains) ?? [:]
        ips = try c.decodeIfPresent([String: TrafficBytes].self, forKey: .ips) ?? [:]
        processes = try c.decodeIfPresent([String: TrafficBytes].self, forKey: .processes) ?? [:]
        processDomains = try c.decodeIfPresent([String: [String: TrafficBytes]].self, forKey: .processDomains) ?? [:]
        processIPs = try c.decodeIfPresent([String: [String: TrafficBytes]].self, forKey: .processIPs) ?? [:]
    }

    public func map(for dimension: TrafficRankingDimension, processFilter: String? = nil) -> [String: TrafficBytes] {
        if let processFilter, !processFilter.isEmpty {
            switch dimension {
            case .domain: return processDomains[processFilter] ?? [:]
            case .ip: return processIPs[processFilter] ?? [:]
            case .process:
                if let entry = processes[processFilter] {
                    return [processFilter: entry]
                }
                return [:]
            }
        }
        switch dimension {
        case .domain: return domains
        case .ip: return ips
        case .process: return processes
        }
    }

    public mutating func merge(_ deltas: TrafficDimensionDeltas, maxEntriesPerDimension: Int) {
        Self.mergeMap(deltas.domains, into: &domains, maxEntries: maxEntriesPerDimension)
        Self.mergeMap(deltas.ips, into: &ips, maxEntries: maxEntriesPerDimension)
        Self.mergeMap(deltas.processes, into: &processes, maxEntries: maxEntriesPerDimension)

        let maxTargetsPerProcess = max(30, maxEntriesPerDimension / 4)
        for (proc, map) in deltas.processDomains {
            var existing = processDomains[proc] ?? [:]
            Self.mergeMap(map, into: &existing, maxEntries: maxTargetsPerProcess)
            processDomains[proc] = existing
        }
        for (proc, map) in deltas.processIPs {
            var existing = processIPs[proc] ?? [:]
            Self.mergeMap(map, into: &existing, maxEntries: maxTargetsPerProcess)
            processIPs[proc] = existing
        }
    }

    private static func mergeMap(
        _ source: [String: TrafficBytes],
        into destination: inout [String: TrafficBytes],
        maxEntries: Int
    ) {
        for (key, delta) in source where delta.total > 0 {
            var acc = destination[key] ?? .zero
            acc.add(upload: delta.upload, download: delta.download)
            destination[key] = acc
        }
        guard maxEntries > 0, destination.count > maxEntries else { return }
        compactMap(&destination, maxEntries: maxEntries)
    }

    /// Keeps the top `maxEntries` named entries (plus `"未知"` and `"其他"` preserved separately)
    /// and folds overflow tail entries into `"其他"` so total bytes stay exact and storage stays bounded.
    private static func compactMap(_ map: inout [String: TrafficBytes], maxEntries: Int) {
        let unknown = map.removeValue(forKey: TrafficAttribution.unknownLabel)
        var other = map.removeValue(forKey: TrafficAttribution.otherLabel) ?? .zero

        if map.count > maxEntries {
            let sorted = map.sorted { lhs, rhs in
                if lhs.value.total != rhs.value.total { return lhs.value.total > rhs.value.total }
                return lhs.key < rhs.key
            }
            var kept: [String: TrafficBytes] = [:]
            kept.reserveCapacity(maxEntries)
            for (index, entry) in sorted.enumerated() {
                if index < maxEntries {
                    kept[entry.key] = entry.value
                } else {
                    other.add(upload: entry.value.upload, download: entry.value.download)
                }
            }
            map = kept
        }

        if let unknown, unknown.total > 0 {
            map[TrafficAttribution.unknownLabel] = unknown
        }
        if other.total > 0 {
            map[TrafficAttribution.otherLabel] = other
        }
    }
}

/// Bounded local aggregator for domain, IP, and process traffic rankings.
/// Stores 1-minute buckets for the sliding 1-hour window and daily buckets for up to 7 days.
public struct TrafficRankingAccumulator: Codable, Equatable, Sendable {
    public static let maxRetainedDays = 7
    public static let maxRetainedMinutes = 60
    public static let maxEntriesPerMinuteBucket = 200
    public static let maxEntriesPerDailyBucket = 400

    public private(set) var trackingStartedAt: Date?
    public private(set) var minuteBuckets: [Int64: TrafficDimensionBuckets]
    public private(set) var dailyBuckets: [String: TrafficDimensionBuckets]

    public init(
        trackingStartedAt: Date? = nil,
        minuteBuckets: [Int64: TrafficDimensionBuckets] = [:],
        dailyBuckets: [String: TrafficDimensionBuckets] = [:]
    ) {
        self.trackingStartedAt = trackingStartedAt
        self.minuteBuckets = minuteBuckets
        self.dailyBuckets = dailyBuckets
    }

    private enum CodingKeys: String, CodingKey {
        case trackingStartedAt, minuteBuckets, dailyBuckets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trackingStartedAt = try c.decodeIfPresent(Date.self, forKey: .trackingStartedAt)
        minuteBuckets = try c.decodeIfPresent([Int64: TrafficDimensionBuckets].self, forKey: .minuteBuckets) ?? [:]
        dailyBuckets = try c.decodeIfPresent([String: TrafficDimensionBuckets].self, forKey: .dailyBuckets) ?? [:]
    }

    public mutating func record(
        _ deltas: TrafficDimensionDeltas,
        at now: Date = Date(),
        calendar: Calendar = .current
    ) {
        guard !deltas.isEmpty else { return }

        if let existingStart = trackingStartedAt {
            if now < existingStart { trackingStartedAt = now }
        } else {
            trackingStartedAt = now
        }

        let minuteEpoch = Self.minuteEpoch(for: now)
        var minuteBucket = minuteBuckets[minuteEpoch] ?? TrafficDimensionBuckets()
        minuteBucket.merge(deltas, maxEntriesPerDimension: Self.maxEntriesPerMinuteBucket)
        minuteBuckets[minuteEpoch] = minuteBucket

        let dayKey = TrafficHistoryAccumulator.dayKey(for: now, calendar: calendar)
        var dailyBucket = dailyBuckets[dayKey] ?? TrafficDimensionBuckets()
        dailyBucket.merge(deltas, maxEntriesPerDimension: Self.maxEntriesPerDailyBucket)
        dailyBuckets[dayKey] = dailyBucket

        prune(referenceNow: now, calendar: calendar)
    }

    public mutating func reset() {
        trackingStartedAt = nil
        minuteBuckets.removeAll()
        dailyBuckets.removeAll()
    }

    public func report(
        dimension: TrafficRankingDimension,
        window: TrafficRankingWindow,
        processFilter: String? = nil,
        sortBy: TrafficRankingSortField = .total,
        ascending: Bool = false,
        searchText: String = "",
        at now: Date = Date(),
        calendar: Calendar = .current
    ) -> TrafficRankingReport {
        var totals: [String: TrafficBytes] = [:]
        let windowStart: Date
        let activeBucketCount: Int

        switch window {
        case .lastHour:
            let currentMinute = Self.minuteEpoch(for: now)
            let earliestMinute = currentMinute - Int64(Self.maxRetainedMinutes - 1)
            windowStart = Date(timeIntervalSince1970: TimeInterval(earliestMinute * 60))
            var count = 0
            for (epoch, bucket) in minuteBuckets where epoch >= earliestMinute && epoch <= currentMinute {
                count += 1
                for (key, bytes) in bucket.map(for: dimension, processFilter: processFilter) where bytes.total > 0 {
                    var acc = totals[key] ?? .zero
                    acc.add(upload: bytes.upload, download: bytes.download)
                    totals[key] = acc
                }
            }
            activeBucketCount = count

        case .today:
            let todayStart = calendar.startOfDay(for: now)
            windowStart = todayStart
            let key = TrafficHistoryAccumulator.dayKey(for: now, calendar: calendar)
            if let bucket = dailyBuckets[key] {
                activeBucketCount = 1
                for (entryKey, bytes) in bucket.map(for: dimension, processFilter: processFilter) where bytes.total > 0 {
                    var acc = totals[entryKey] ?? .zero
                    acc.add(upload: bytes.upload, download: bytes.download)
                    totals[entryKey] = acc
                }
            } else {
                activeBucketCount = 0
            }

        case .last7Days:
            let todayStart = calendar.startOfDay(for: now)
            windowStart = calendar.date(byAdding: .day, value: -(Self.maxRetainedDays - 1), to: todayStart) ?? todayStart
            var keys = Set<String>()
            for offset in 0..<Self.maxRetainedDays {
                if let date = calendar.date(byAdding: .day, value: -offset, to: todayStart) {
                    keys.insert(TrafficHistoryAccumulator.dayKey(for: date, calendar: calendar))
                }
            }
            var count = 0
            for (key, bucket) in dailyBuckets where keys.contains(key) {
                count += 1
                for (entryKey, bytes) in bucket.map(for: dimension, processFilter: processFilter) where bytes.total > 0 {
                    var acc = totals[entryKey] ?? .zero
                    acc.add(upload: bytes.upload, download: bytes.download)
                    totals[entryKey] = acc
                }
            }
            activeBucketCount = count
        }

        let totalUpload = totals.values.reduce(Int64(0)) { $0 + $1.upload }
        let totalDownload = totals.values.reduce(Int64(0)) { $0 + $1.download }
        let grandTotal = totalUpload + totalDownload

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let items: [TrafficRankingItem] = totals.compactMap { key, bytes in
            guard bytes.total > 0 else { return nil }
            if !query.isEmpty && !key.lowercased().contains(query) {
                return nil
            }
            let pct = grandTotal > 0 ? (Double(bytes.total) / Double(grandTotal) * 100.0) : 0
            return TrafficRankingItem(
                key: key,
                upload: bytes.upload,
                download: bytes.download,
                percentage: pct
            )
        }
        .sorted { lhs, rhs in
            Self.compareItems(lhs, rhs, sortBy: sortBy, ascending: ascending)
        }

        let isPartial: Bool
        if let started = trackingStartedAt {
            isPartial = started > windowStart
        } else {
            isPartial = false
        }

        return TrafficRankingReport(
            items: items,
            totalUpload: totalUpload,
            totalDownload: totalDownload,
            coverage: TrafficRankingCoverage(
                trackingStartedAt: trackingStartedAt,
                windowStart: windowStart,
                isPartial: isPartial,
                activeBucketCount: activeBucketCount
            )
        )
    }

    private static func compareItems(
        _ lhs: TrafficRankingItem,
        _ rhs: TrafficRankingItem,
        sortBy: TrafficRankingSortField,
        ascending: Bool
    ) -> Bool {
        switch sortBy {
        case .total:
            if lhs.total != rhs.total {
                return ascending ? (lhs.total < rhs.total) : (lhs.total > rhs.total)
            }
        case .download:
            if lhs.download != rhs.download {
                return ascending ? (lhs.download < rhs.download) : (lhs.download > rhs.download)
            }
        case .upload:
            if lhs.upload != rhs.upload {
                return ascending ? (lhs.upload < rhs.upload) : (lhs.upload > rhs.upload)
            }
        case .name:
            let cmp = lhs.key.localizedStandardCompare(rhs.key)
            if cmp != .orderedSame {
                return ascending ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
            }
        }
        return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
    }

    private mutating func prune(referenceNow: Date, calendar: Calendar) {
        let currentMinute = Self.minuteEpoch(for: referenceNow)
        let earliestMinute = currentMinute - Int64(Self.maxRetainedMinutes - 1)
        minuteBuckets = minuteBuckets.filter { $0.key >= earliestMinute && $0.key <= currentMinute }

        let todayStart = calendar.startOfDay(for: referenceNow)
        if let cutoffDate = calendar.date(byAdding: .day, value: -(Self.maxRetainedDays - 1), to: todayStart) {
            let cutoffKey = TrafficHistoryAccumulator.dayKey(for: cutoffDate, calendar: calendar)
            dailyBuckets = dailyBuckets.filter { $0.key >= cutoffKey }
        }
    }

    public static func minuteEpoch(for date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 / 60.0))
    }
}
