import Foundation

public struct TrafficSpeedSample: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let timestamp: Date
    public let uploadSpeed: Int64
    public let downloadSpeed: Int64

    public init(id: Int64, timestamp: Date, uploadSpeed: Int64, downloadSpeed: Int64) {
        self.id = id
        self.timestamp = timestamp
        self.uploadSpeed = max(0, uploadSpeed)
        self.downloadSpeed = max(0, downloadSpeed)
    }

    public var totalSpeed: Int64 {
        uploadSpeed + downloadSpeed
    }
}

public struct TrafficBytes: Codable, Equatable, Sendable {
    public var upload: Int64
    public var download: Int64

    public var total: Int64 { upload + download }

    public init(upload: Int64 = 0, download: Int64 = 0) {
        self.upload = max(0, upload)
        self.download = max(0, download)
    }

    public mutating func add(upload: Int64, download: Int64) {
        self.upload += max(0, upload)
        self.download += max(0, download)
    }

    public static let zero = TrafficBytes(upload: 0, download: 0)
}

public struct HourlyTrafficBucket: Codable, Equatable, Identifiable, Sendable {
    public let hour: Int
    public var upload: Int64
    public var download: Int64
    public var byTarget: [String: TrafficBytes]

    public var id: Int { hour }
    public var total: Int64 { upload + download }

    public var label: String {
        String(format: "%02d:00", hour)
    }

    public var shortLabel: String {
        String(format: "%02d", hour)
    }

    public init(
        hour: Int,
        upload: Int64 = 0,
        download: Int64 = 0,
        byTarget: [String: TrafficBytes] = [:]
    ) {
        self.hour = max(0, min(23, hour))
        self.upload = max(0, upload)
        self.download = max(0, download)
        self.byTarget = byTarget
    }

    private enum CodingKeys: String, CodingKey {
        case hour, upload, download, byTarget
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hour = max(0, min(23, try c.decode(Int.self, forKey: .hour)))
        upload = max(0, try c.decodeIfPresent(Int64.self, forKey: .upload) ?? 0)
        download = max(0, try c.decodeIfPresent(Int64.self, forKey: .download) ?? 0)
        byTarget = try c.decodeIfPresent([String: TrafficBytes].self, forKey: .byTarget) ?? [:]
    }
}

public struct DailyTrafficRecord: Codable, Equatable, Identifiable, Sendable {
    /// Local calendar day key in `yyyy-MM-dd` format.
    public let dayKey: String
    public var upload: Int64
    public var download: Int64
    public var byTarget: [String: TrafficBytes]

    public var id: String { dayKey }
    public var total: Int64 { upload + download }

    /// Short display label `MM-dd`.
    public var shortLabel: String {
        if dayKey.count >= 10 {
            return String(dayKey.dropFirst(5))
        }
        return dayKey
    }

    public init(
        dayKey: String,
        upload: Int64 = 0,
        download: Int64 = 0,
        byTarget: [String: TrafficBytes] = [:]
    ) {
        self.dayKey = dayKey
        self.upload = max(0, upload)
        self.download = max(0, download)
        self.byTarget = byTarget
    }

    private enum CodingKeys: String, CodingKey {
        case dayKey, upload, download, byTarget
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dayKey = try c.decode(String.self, forKey: .dayKey)
        upload = max(0, try c.decodeIfPresent(Int64.self, forKey: .upload) ?? 0)
        download = max(0, try c.decodeIfPresent(Int64.self, forKey: .download) ?? 0)
        byTarget = try c.decodeIfPresent([String: TrafficBytes].self, forKey: .byTarget) ?? [:]
    }
}

public struct TargetTrafficStat: Identifiable, Equatable, Sendable {
    public let target: String
    public let upload: Int64
    public let download: Int64
    public let connectionCount: Int
    public let isDirect: Bool
    public let isRejected: Bool

    public var id: String { target }
    public var total: Int64 { upload + download }

    public init(
        target: String,
        upload: Int64,
        download: Int64,
        connectionCount: Int,
        isDirect: Bool = false,
        isRejected: Bool = false
    ) {
        self.target = target
        self.upload = max(0, upload)
        self.download = max(0, download)
        self.connectionCount = max(0, connectionCount)
        self.isDirect = isDirect
        self.isRejected = isRejected
    }
}

/// Persistent cumulative traffic accumulator keeping up to 30 days of daily totals
/// and 24 hourly buckets for the current day.
public struct TrafficHistoryAccumulator: Codable, Equatable, Sendable {
    public static let maxRetainedDays = 30

    public private(set) var dailyRecords: [String: DailyTrafficRecord]
    public private(set) var hourlyDayKey: String
    public private(set) var hourlyBuckets: [Int: HourlyTrafficBucket]

    public init(
        dailyRecords: [String: DailyTrafficRecord] = [:],
        hourlyDayKey: String = "",
        hourlyBuckets: [Int: HourlyTrafficBucket] = [:]
    ) {
        self.dailyRecords = dailyRecords
        self.hourlyDayKey = hourlyDayKey
        self.hourlyBuckets = hourlyBuckets
    }

    public mutating func recordDelta(
        uploadDelta: Int64,
        downloadDelta: Int64,
        targetDeltas: [String: TrafficBytes] = [:],
        at now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let up = max(0, uploadDelta)
        let down = max(0, downloadDelta)
        let nonZeroTargets = targetDeltas.filter { $0.value.total > 0 }
        guard up > 0 || down > 0 || !nonZeroTargets.isEmpty else { return }

        let key = Self.dayKey(for: now, calendar: calendar)
        if hourlyDayKey != key {
            hourlyDayKey = key
            hourlyBuckets = [:]
        }

        var day = dailyRecords[key] ?? DailyTrafficRecord(dayKey: key)
        day.upload += up
        day.download += down
        for (target, delta) in nonZeroTargets {
            var entry = day.byTarget[target] ?? .zero
            entry.add(upload: delta.upload, download: delta.download)
            day.byTarget[target] = entry
        }
        dailyRecords[key] = day

        let hour = calendar.component(.hour, from: now)
        var bucket = hourlyBuckets[hour] ?? HourlyTrafficBucket(hour: hour)
        bucket.upload += up
        bucket.download += down
        for (target, delta) in nonZeroTargets {
            var entry = bucket.byTarget[target] ?? .zero
            entry.add(upload: delta.upload, download: delta.download)
            bucket.byTarget[target] = entry
        }
        hourlyBuckets[hour] = bucket

        pruneOldDays(referenceNow: now, calendar: calendar)
    }

    public mutating func renameTarget(from oldName: String, to newName: String) {
        let oldTrimmed = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTrimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldTrimmed.isEmpty, !newTrimmed.isEmpty, oldTrimmed != newTrimmed else { return }

        for key in dailyRecords.keys {
            guard var record = dailyRecords[key],
                  let moved = record.byTarget.removeValue(forKey: oldTrimmed) else { continue }
            var merged = record.byTarget[newTrimmed] ?? .zero
            merged.add(upload: moved.upload, download: moved.download)
            record.byTarget[newTrimmed] = merged
            dailyRecords[key] = record
        }

        for hour in hourlyBuckets.keys {
            guard var bucket = hourlyBuckets[hour],
                  let moved = bucket.byTarget.removeValue(forKey: oldTrimmed) else { continue }
            var merged = bucket.byTarget[newTrimmed] ?? .zero
            merged.add(upload: moved.upload, download: moved.download)
            bucket.byTarget[newTrimmed] = merged
            hourlyBuckets[hour] = bucket
        }
    }

    public mutating func reset() {
        dailyRecords.removeAll()
        hourlyDayKey = ""
        hourlyBuckets.removeAll()
    }

    public func todayRecord(
        target: String? = nil,
        at now: Date = Date(),
        calendar: Calendar = .current
    ) -> DailyTrafficRecord {
        let key = Self.dayKey(for: now, calendar: calendar)
        let record = dailyRecords[key] ?? DailyTrafficRecord(dayKey: key)
        guard let target, !target.isEmpty else { return record }
        let bytes = record.byTarget[target] ?? .zero
        return DailyTrafficRecord(dayKey: key, upload: bytes.upload, download: bytes.download)
    }

    /// Returns a contiguous chronological array of the last `count` days ending at `now`.
    public func lastNDays(
        _ count: Int,
        target: String? = nil,
        at now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DailyTrafficRecord] {
        let clamped = max(1, min(Self.maxRetainedDays, count))
        let todayStart = calendar.startOfDay(for: now)
        return (0..<clamped).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: todayStart) else { return nil }
            let key = Self.dayKey(for: date, calendar: calendar)
            let record = dailyRecords[key] ?? DailyTrafficRecord(dayKey: key)
            guard let target, !target.isEmpty else { return record }
            let bytes = record.byTarget[target] ?? .zero
            return DailyTrafficRecord(dayKey: key, upload: bytes.upload, download: bytes.download)
        }
    }

    /// Returns all 24 hourly buckets (`0...23`) for `now`'s local calendar day.
    public func todayHourlyBuckets(
        target: String? = nil,
        at now: Date = Date(),
        calendar: Calendar = .current
    ) -> [HourlyTrafficBucket] {
        let key = Self.dayKey(for: now, calendar: calendar)
        let activeBuckets = (hourlyDayKey == key) ? hourlyBuckets : [:]
        return (0..<24).map { hour in
            let bucket = activeBuckets[hour] ?? HourlyTrafficBucket(hour: hour)
            guard let target, !target.isEmpty else { return bucket }
            let bytes = bucket.byTarget[target] ?? .zero
            return HourlyTrafficBucket(hour: hour, upload: bytes.upload, download: bytes.download)
        }
    }

    public func totalBytes(
        lastNDays count: Int,
        target: String? = nil,
        at now: Date = Date(),
        calendar: Calendar = .current
    ) -> (upload: Int64, download: Int64) {
        let records = lastNDays(count, target: target, at: now, calendar: calendar)
        let up = records.reduce(Int64(0)) { $0 + $1.upload }
        let down = records.reduce(Int64(0)) { $0 + $1.download }
        return (up, down)
    }

    /// Aggregates per-target traffic over the last `count` days (e.g. 1 = today, 7 = last 7 days, 30 = last 30 days).
    public func targetTrafficStats(
        lastNDays count: Int,
        directTargetNames: Set<String> = [],
        at now: Date = Date(),
        calendar: Calendar = .current
    ) -> [TargetTrafficStat] {
        let records = lastNDays(count, at: now, calendar: calendar)
        var totals: [String: TrafficBytes] = [:]
        for record in records {
            for (target, bytes) in record.byTarget where bytes.total > 0 {
                var acc = totals[target] ?? .zero
                acc.add(upload: bytes.upload, download: bytes.download)
                totals[target] = acc
            }
        }
        return totals.map { key, bytes in
            let upper = key.uppercased()
            let isDirect = directTargetNames.contains(key) || upper == "DIRECT" || upper.contains("直连")
            let isRejected = upper == "REJECT" || upper == "REJECT-DROP"
            return TargetTrafficStat(
                target: key,
                upload: bytes.upload,
                download: bytes.download,
                connectionCount: 0,
                isDirect: isDirect,
                isRejected: isRejected
            )
        }
        .sorted { lhs, rhs in
            if lhs.total != rhs.total { return lhs.total > rhs.total }
            return lhs.target.localizedStandardCompare(rhs.target) == .orderedAscending
        }
    }

    public func availableTargets(
        lastNDays count: Int = maxRetainedDays,
        at now: Date = Date(),
        calendar: Calendar = .current
    ) -> [String] {
        let records = lastNDays(count, at: now, calendar: calendar)
        var names = Set<String>()
        for record in records {
            for (target, bytes) in record.byTarget where bytes.total > 0 {
                names.insert(target)
            }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private mutating func pruneOldDays(referenceNow: Date, calendar: Calendar) {
        guard dailyRecords.count > Self.maxRetainedDays else { return }
        let todayStart = calendar.startOfDay(for: referenceNow)
        guard let cutoffDate = calendar.date(byAdding: .day, value: -(Self.maxRetainedDays - 1), to: todayStart) else {
            return
        }
        let cutoffKey = Self.dayKey(for: cutoffDate, calendar: calendar)
        dailyRecords = dailyRecords.filter { $0.key >= cutoffKey }
    }

    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }
}
