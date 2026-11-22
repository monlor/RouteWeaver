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

public struct HourlyTrafficBucket: Codable, Equatable, Identifiable, Sendable {
    public let hour: Int
    public var upload: Int64
    public var download: Int64

    public var id: Int { hour }
    public var total: Int64 { upload + download }

    public var label: String {
        String(format: "%02d:00", hour)
    }

    public var shortLabel: String {
        String(format: "%02d", hour)
    }

    public init(hour: Int, upload: Int64 = 0, download: Int64 = 0) {
        self.hour = max(0, min(23, hour))
        self.upload = max(0, upload)
        self.download = max(0, download)
    }
}

public struct DailyTrafficRecord: Codable, Equatable, Identifiable, Sendable {
    /// Local calendar day key in `yyyy-MM-dd` format.
    public let dayKey: String
    public var upload: Int64
    public var download: Int64

    public var id: String { dayKey }
    public var total: Int64 { upload + download }

    /// Short display label `MM-dd`.
    public var shortLabel: String {
        if dayKey.count >= 10 {
            return String(dayKey.dropFirst(5))
        }
        return dayKey
    }

    public init(dayKey: String, upload: Int64 = 0, download: Int64 = 0) {
        self.dayKey = dayKey
        self.upload = max(0, upload)
        self.download = max(0, download)
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
        at now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let up = max(0, uploadDelta)
        let down = max(0, downloadDelta)
        guard up > 0 || down > 0 else { return }

        let key = Self.dayKey(for: now, calendar: calendar)
        if hourlyDayKey != key {
            hourlyDayKey = key
            hourlyBuckets = [:]
        }

        var day = dailyRecords[key] ?? DailyTrafficRecord(dayKey: key)
        day.upload += up
        day.download += down
        dailyRecords[key] = day

        let hour = calendar.component(.hour, from: now)
        var bucket = hourlyBuckets[hour] ?? HourlyTrafficBucket(hour: hour)
        bucket.upload += up
        bucket.download += down
        hourlyBuckets[hour] = bucket

        pruneOldDays(referenceNow: now, calendar: calendar)
    }

    public mutating func reset() {
        dailyRecords.removeAll()
        hourlyDayKey = ""
        hourlyBuckets.removeAll()
    }

    public func todayRecord(at now: Date = Date(), calendar: Calendar = .current) -> DailyTrafficRecord {
        let key = Self.dayKey(for: now, calendar: calendar)
        return dailyRecords[key] ?? DailyTrafficRecord(dayKey: key)
    }

    /// Returns a contiguous chronological array of the last `count` days ending at `now`.
    public func lastNDays(_ count: Int, at now: Date = Date(), calendar: Calendar = .current) -> [DailyTrafficRecord] {
        let clamped = max(1, min(Self.maxRetainedDays, count))
        let todayStart = calendar.startOfDay(for: now)
        return (0..<clamped).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: todayStart) else { return nil }
            let key = Self.dayKey(for: date, calendar: calendar)
            return dailyRecords[key] ?? DailyTrafficRecord(dayKey: key)
        }
    }

    /// Returns all 24 hourly buckets (`0...23`) for `now`'s local calendar day.
    public func todayHourlyBuckets(at now: Date = Date(), calendar: Calendar = .current) -> [HourlyTrafficBucket] {
        let key = Self.dayKey(for: now, calendar: calendar)
        let activeBuckets = (hourlyDayKey == key) ? hourlyBuckets : [:]
        return (0..<24).map { hour in
            activeBuckets[hour] ?? HourlyTrafficBucket(hour: hour)
        }
    }

    public func totalBytes(lastNDays count: Int, at now: Date = Date(), calendar: Calendar = .current) -> (upload: Int64, download: Int64) {
        let records = lastNDays(count, at: now, calendar: calendar)
        let up = records.reduce(Int64(0)) { $0 + $1.upload }
        let down = records.reduce(Int64(0)) { $0 + $1.download }
        return (up, down)
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
