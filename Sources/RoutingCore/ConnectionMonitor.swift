import Darwin
import Foundation

public struct MihomoConnectionMetadata: Decodable, Equatable, Sendable {
    public let network: String
    public let type: String
    public let sourceIP: String
    public let destinationIP: String
    public let sourcePort: String
    public let destinationPort: String
    public let host: String
    public let dnsMode: String
    public let process: String
    public let processPath: String
    public let remoteDestination: String

    public init(
        network: String = "",
        type: String = "",
        sourceIP: String = "",
        destinationIP: String = "",
        sourcePort: String = "",
        destinationPort: String = "",
        host: String = "",
        dnsMode: String = "",
        process: String = "",
        processPath: String = "",
        remoteDestination: String = ""
    ) {
        self.network = network
        self.type = type
        self.sourceIP = sourceIP
        self.destinationIP = destinationIP
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.host = host
        self.dnsMode = dnsMode
        self.process = process
        self.processPath = processPath
        self.remoteDestination = remoteDestination
    }

    private enum CodingKeys: String, CodingKey {
        case network, type, sourceIP, destinationIP, sourcePort, destinationPort
        case host, dnsMode, process, processPath, remoteDestination
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        network = try c.decodeIfPresent(String.self, forKey: .network) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        sourceIP = try c.decodeIfPresent(String.self, forKey: .sourceIP) ?? ""
        destinationIP = try c.decodeIfPresent(String.self, forKey: .destinationIP) ?? ""
        sourcePort = try c.decodeIfPresent(String.self, forKey: .sourcePort) ?? ""
        destinationPort = try c.decodeIfPresent(String.self, forKey: .destinationPort) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        dnsMode = try c.decodeIfPresent(String.self, forKey: .dnsMode) ?? ""
        process = try c.decodeIfPresent(String.self, forKey: .process) ?? ""
        processPath = try c.decodeIfPresent(String.self, forKey: .processPath) ?? ""
        remoteDestination = try c.decodeIfPresent(String.self, forKey: .remoteDestination) ?? ""
    }
}

public struct MihomoConnection: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let metadata: MihomoConnectionMetadata
    public let upload: Int64
    public let download: Int64
    public let start: String
    public let chains: [String]
    public let rule: String
    public let rulePayload: String

    public init(
        id: String,
        metadata: MihomoConnectionMetadata,
        upload: Int64,
        download: Int64,
        start: String,
        chains: [String],
        rule: String,
        rulePayload: String
    ) {
        self.id = id
        self.metadata = metadata
        self.upload = upload
        self.download = download
        self.start = start
        self.chains = chains
        self.rule = rule
        self.rulePayload = rulePayload
    }

    private enum CodingKeys: String, CodingKey {
        case id, metadata, upload, download, start, chains, rule, rulePayload
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        metadata = try c.decodeIfPresent(MihomoConnectionMetadata.self, forKey: .metadata) ?? MihomoConnectionMetadata()
        upload = try c.decodeIfPresent(Int64.self, forKey: .upload) ?? 0
        download = try c.decodeIfPresent(Int64.self, forKey: .download) ?? 0
        start = try c.decodeIfPresent(String.self, forKey: .start) ?? ""
        chains = try c.decodeIfPresent([String].self, forKey: .chains) ?? []
        rule = try c.decodeIfPresent(String.self, forKey: .rule) ?? ""
        rulePayload = try c.decodeIfPresent(String.self, forKey: .rulePayload) ?? ""
    }
}

public struct MihomoConnectionsSnapshot: Decodable, Equatable, Sendable {
    public let downloadTotal: Int64
    public let uploadTotal: Int64
    public let memory: Int64
    public let connections: [MihomoConnection]

    public init(
        downloadTotal: Int64 = 0,
        uploadTotal: Int64 = 0,
        memory: Int64 = 0,
        connections: [MihomoConnection] = []
    ) {
        self.downloadTotal = downloadTotal
        self.uploadTotal = uploadTotal
        self.memory = memory
        self.connections = connections
    }

    private enum CodingKeys: String, CodingKey {
        case downloadTotal, uploadTotal, memory, connections
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        downloadTotal = try c.decodeIfPresent(Int64.self, forKey: .downloadTotal) ?? 0
        uploadTotal = try c.decodeIfPresent(Int64.self, forKey: .uploadTotal) ?? 0
        memory = try c.decodeIfPresent(Int64.self, forKey: .memory) ?? 0
        connections = try c.decodeIfPresent([MihomoConnection].self, forKey: .connections) ?? []
    }
}

public struct MonitoredConnection: Identifiable, Equatable, Sendable {
    public let id: String
    public var metadata: MihomoConnectionMetadata
    public var upload: Int64
    public var download: Int64
    public var uploadSpeed: Int64
    public var downloadSpeed: Int64
    public let startRaw: String
    public let startDate: Date?
    public let firstSeenAt: Date
    public var lastSeenAt: Date
    public var closedAt: Date?
    public var chains: [String]
    public var rule: String
    public var rulePayload: String
    public var isActive: Bool

    public var totalBytes: Int64 { upload + download }

    public var hostOnly: String {
        if !metadata.host.isEmpty { return metadata.host }
        if !metadata.destinationIP.isEmpty { return metadata.destinationIP }
        if !metadata.remoteDestination.isEmpty { return metadata.remoteDestination }
        return "未知目标"
    }

    public var displayAddress: String {
        let base = hostOnly
        if !metadata.destinationPort.isEmpty {
            if base.contains(":") && !base.hasPrefix("[") {
                return "[\(base)]:\(metadata.destinationPort)"
            }
            return "\(base):\(metadata.destinationPort)"
        }
        return base
    }

    public var sourceAddress: String {
        guard !metadata.sourceIP.isEmpty else { return "—" }
        return metadata.sourcePort.isEmpty ? metadata.sourceIP : "\(metadata.sourceIP):\(metadata.sourcePort)"
    }

    public var destinationIPAddress: String {
        let ip = !metadata.destinationIP.isEmpty ? metadata.destinationIP : metadata.remoteDestination
        guard !ip.isEmpty else { return "—" }
        return metadata.destinationPort.isEmpty ? ip : "\(ip):\(metadata.destinationPort)"
    }

    public var processDisplayName: String {
        if !metadata.process.isEmpty { return metadata.process }
        if !metadata.processPath.isEmpty {
            return URL(fileURLWithPath: metadata.processPath).lastPathComponent
        }
        return ""
    }

    /// Mihomo returns chains innermost-node first (`[ExitNode, TargetGroup]`).
    /// Reversing displays the routing flow left-to-right (`TargetGroup → ExitNode`).
    public var displayChain: [String] {
        chains.reversed()
    }

    public var primaryTarget: String {
        chains.last ?? "DIRECT"
    }

    public var finalNode: String {
        chains.first ?? primaryTarget
    }

    /// Removes RouteWeaver's generated `"[<TargetName>] "` prefix from chained exit nodes for compact UI display.
    public var compactFinalNode: String {
        let prefix = "[\(primaryTarget)] "
        if finalNode.hasPrefix(prefix) {
            let trimmed = String(finalNode.dropFirst(prefix.count))
            if !trimmed.isEmpty { return trimmed }
        }
        return finalNode
    }

    /// Whether this connection is an internal Mihomo dialer/tunnel connection (e.g. `dialer-proxy` relay).
    public var isInner: Bool {
        metadata.type.caseInsensitiveCompare("Inner") == .orderedSame
    }

    public var isDirect: Bool {
        let upper = primaryTarget.uppercased()
        return upper == "DIRECT" || upper.contains("直连")
    }

    public var isRejected: Bool {
        let upper = primaryTarget.uppercased()
        return upper == "REJECT" || upper == "REJECT-DROP"
    }

    public var ruleSummary: String {
        if rule.isEmpty { return "—" }
        if rulePayload.isEmpty { return rule }
        return "\(rule) · \(rulePayload)"
    }

    public var protocolLabel: String {
        let net = metadata.network.uppercased()
        if net.isEmpty && metadata.type.isEmpty { return "—" }
        if net.isEmpty { return metadata.type }
        if metadata.type.isEmpty { return net }
        return "\(net) · \(metadata.type)"
    }

    public var sortTimestamp: Date {
        startDate ?? firstSeenAt
    }

    public func duration(referenceNow: Date = Date()) -> TimeInterval {
        let origin = startDate ?? firstSeenAt
        let end = isActive ? referenceNow : (closedAt ?? lastSeenAt)
        return max(0, end.timeIntervalSince(origin))
    }

    public func exportSummary() -> String {
        var lines: [String] = [
            "目标地址: \(displayAddress)",
            "状态: \(isActive ? "活跃" : "已结束")",
            "协议: \(protocolLabel)",
            "命中规则: \(ruleSummary)",
            "代理链路: \(displayChain.joined(separator: " → "))",
            "上传: \(TrafficFormatter.bytes(upload))  下载: \(TrafficFormatter.bytes(download))",
            "来源地址: \(sourceAddress)",
            "目标 IP: \(destinationIPAddress)",
        ]
        if !processDisplayName.isEmpty {
            lines.append("进程: \(processDisplayName)")
        }
        if !metadata.processPath.isEmpty {
            lines.append("进程路径: \(metadata.processPath)")
        }
        if !startRaw.isEmpty {
            lines.append("开始时间: \(startRaw)")
        }
        lines.append("连接 ID: \(id)")
        return lines.joined(separator: "\n")
    }
}

public enum ConnectionFilterScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case active
    case closed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "全部"
        case .active: return "活跃"
        case .closed: return "已结束"
        }
    }
}

public enum ConnectionSortOrder: String, CaseIterable, Identifiable, Sendable {
    case newest
    case totalTraffic
    case download
    case upload
    case host

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .newest: return "最新请求"
        case .totalTraffic: return "总流量"
        case .download: return "下载流量"
        case .upload: return "上传流量"
        case .host: return "域名排序"
        }
    }
}

public struct ConnectionTracker: Sendable {
    public private(set) var recordsByID: [String: MonitoredConnection] = [:]
    public private(set) var uploadTotal: Int64 = 0
    public private(set) var downloadTotal: Int64 = 0
    public private(set) var uploadSpeed: Int64 = 0
    public private(set) var downloadSpeed: Int64 = 0
    public private(set) var lastUploadDelta: Int64 = 0
    public private(set) var lastDownloadDelta: Int64 = 0
    public private(set) var memoryUsage: Int64 = 0
    public private(set) var lastSnapshotAt: Date?
    public private(set) var speedHistory: [TrafficSpeedSample] = []
    public let maxClosedHistory: Int
    public let maxSpeedSamples: Int
    private var nextSampleID: Int64 = 1

    public init(maxClosedHistory: Int = 500, maxSpeedSamples: Int = 60) {
        self.maxClosedHistory = max(10, maxClosedHistory)
        self.maxSpeedSamples = max(10, maxSpeedSamples)
    }

    public var allRecords: [MonitoredConnection] {
        Array(recordsByID.values)
    }

    public var activeCount: Int {
        recordsByID.values.reduce(into: 0) { count, item in
            if item.isActive { count += 1 }
        }
    }

    public var closedCount: Int {
        recordsByID.count - activeCount
    }

    public var innerCount: Int {
        recordsByID.values.reduce(into: 0) { count, item in
            if item.isInner { count += 1 }
        }
    }

    public var activeInnerCount: Int {
        recordsByID.values.reduce(into: 0) { count, item in
            if item.isActive && item.isInner { count += 1 }
        }
    }

    public var businessActiveCount: Int {
        activeCount - activeInnerCount
    }

    public var businessClosedCount: Int {
        (recordsByID.count - innerCount) - businessActiveCount
    }

    public var availableTargets: [String] {
        availableTargets(includeInner: true)
    }

    public func availableTargets(includeInner: Bool) -> [String] {
        let targets = recordsByID.values.compactMap { item -> String? in
            if !includeInner && item.isInner { return nil }
            return item.primaryTarget
        }
        return Set(targets).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    /// Aggregates traffic volume and connection count by primary routing target, sorted by total traffic descending.
    public var targetTrafficStats: [TargetTrafficStat] {
        struct Accumulator {
            var upload: Int64 = 0
            var download: Int64 = 0
            var count: Int = 0
            var isDirect: Bool = false
            var isRejected: Bool = false
        }
        var grouped: [String: Accumulator] = [:]
        for item in recordsByID.values {
            var acc = grouped[item.primaryTarget] ?? Accumulator()
            acc.upload += item.upload
            acc.download += item.download
            acc.count += 1
            if item.isDirect { acc.isDirect = true }
            if item.isRejected { acc.isRejected = true }
            grouped[item.primaryTarget] = acc
        }
        return grouped.map { key, acc in
            TargetTrafficStat(
                target: key,
                upload: acc.upload,
                download: acc.download,
                connectionCount: acc.count,
                isDirect: acc.isDirect,
                isRejected: acc.isRejected
            )
        }
        .sorted { lhs, rhs in
            if lhs.total != rhs.total { return lhs.total > rhs.total }
            return lhs.target.localizedStandardCompare(rhs.target) == .orderedAscending
        }
    }

    public mutating func ingest(_ snapshot: MihomoConnectionsSnapshot, at now: Date = Date()) {
        let hadPrevious = (lastSnapshotAt != nil)
        let elapsed: TimeInterval?
        if let previous = lastSnapshotAt {
            let dt = now.timeIntervalSince(previous)
            elapsed = dt > 0.05 ? dt : nil
        } else {
            elapsed = nil
        }

        // Compute traffic deltas safely, including first snapshot or Mihomo counter resets.
        let upDelta: Int64
        let downDelta: Int64
        if hadPrevious {
            upDelta = snapshot.uploadTotal >= uploadTotal
                ? (snapshot.uploadTotal - uploadTotal)
                : max(0, snapshot.uploadTotal)
            downDelta = snapshot.downloadTotal >= downloadTotal
                ? (snapshot.downloadTotal - downloadTotal)
                : max(0, snapshot.downloadTotal)
        } else {
            upDelta = max(0, snapshot.uploadTotal)
            downDelta = max(0, snapshot.downloadTotal)
        }
        lastUploadDelta = upDelta
        lastDownloadDelta = downDelta

        if let dt = elapsed {
            uploadSpeed = Int64(Double(upDelta) / dt)
            downloadSpeed = Int64(Double(downDelta) / dt)
        } else {
            uploadSpeed = 0
            downloadSpeed = 0
        }

        uploadTotal = snapshot.uploadTotal
        downloadTotal = snapshot.downloadTotal
        memoryUsage = snapshot.memory
        lastSnapshotAt = now

        let sample = TrafficSpeedSample(
            id: nextSampleID,
            timestamp: now,
            uploadSpeed: uploadSpeed,
            downloadSpeed: downloadSpeed
        )
        nextSampleID += 1
        speedHistory.append(sample)
        if speedHistory.count > maxSpeedSamples {
            speedHistory.removeFirst(speedHistory.count - maxSpeedSamples)
        }

        var seenActiveIDs = Set<String>()
        seenActiveIDs.reserveCapacity(snapshot.connections.count)

        for conn in snapshot.connections {
            seenActiveIDs.insert(conn.id)
            if var existing = recordsByID[conn.id] {
                let dt = now.timeIntervalSince(existing.lastSeenAt)
                if dt > 0.05 {
                    existing.uploadSpeed = Int64(Double(max(0, conn.upload - existing.upload)) / dt)
                    existing.downloadSpeed = Int64(Double(max(0, conn.download - existing.download)) / dt)
                } else {
                    existing.uploadSpeed = 0
                    existing.downloadSpeed = 0
                }
                existing.metadata = conn.metadata
                existing.upload = conn.upload
                existing.download = conn.download
                existing.chains = conn.chains
                existing.rule = conn.rule
                existing.rulePayload = conn.rulePayload
                existing.lastSeenAt = now
                existing.isActive = true
                existing.closedAt = nil
                recordsByID[conn.id] = existing
            } else {
                recordsByID[conn.id] = MonitoredConnection(
                    id: conn.id,
                    metadata: conn.metadata,
                    upload: conn.upload,
                    download: conn.download,
                    uploadSpeed: 0,
                    downloadSpeed: 0,
                    startRaw: conn.start,
                    startDate: Self.parseISO8601(conn.start),
                    firstSeenAt: now,
                    lastSeenAt: now,
                    closedAt: nil,
                    chains: conn.chains,
                    rule: conn.rule,
                    rulePayload: conn.rulePayload,
                    isActive: true
                )
            }
        }

        for id in recordsByID.keys where !seenActiveIDs.contains(id) {
            if var item = recordsByID[id], item.isActive {
                item.isActive = false
                item.closedAt = now
                item.uploadSpeed = 0
                item.downloadSpeed = 0
                recordsByID[id] = item
            }
        }

        trimClosedHistoryIfNeeded()
    }

    public mutating func markAllClosed(at now: Date = Date()) {
        uploadSpeed = 0
        downloadSpeed = 0
        for id in recordsByID.keys {
            if var item = recordsByID[id], item.isActive {
                item.isActive = false
                item.closedAt = now
                item.uploadSpeed = 0
                item.downloadSpeed = 0
                recordsByID[id] = item
            }
        }
        trimClosedHistoryIfNeeded()
    }

    public mutating func clearClosed() {
        recordsByID = recordsByID.filter { $0.value.isActive }
    }

    public mutating func reset() {
        recordsByID.removeAll()
        uploadTotal = 0
        downloadTotal = 0
        uploadSpeed = 0
        downloadSpeed = 0
        lastUploadDelta = 0
        lastDownloadDelta = 0
        memoryUsage = 0
        lastSnapshotAt = nil
        speedHistory.removeAll()
    }

    public func filtered(
        scope: ConnectionFilterScope = .all,
        searchText: String = "",
        targetFilter: String? = nil,
        sortOrder: ConnectionSortOrder = .newest,
        ruleIndex: RuleMatchDisplayIndex? = nil,
        includeInner: Bool = true
    ) -> [MonitoredConnection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let matched = recordsByID.values.filter { item in
            if !includeInner && item.isInner {
                return false
            }

            switch scope {
            case .all: break
            case .active: if !item.isActive { return false }
            case .closed: if item.isActive { return false }
            }

            if let targetFilter, !targetFilter.isEmpty, item.primaryTarget != targetFilter {
                return false
            }

            if !query.isEmpty {
                let resolved = ruleIndex?.resolve(rule: item.rule, payload: item.rulePayload)
                let haystacks = [
                    item.displayAddress,
                    item.metadata.destinationIP,
                    item.metadata.sourceIP,
                    item.processDisplayName,
                    item.metadata.processPath,
                    item.rule,
                    item.rulePayload,
                    resolved?.groupName ?? "",
                    resolved?.ruleNote ?? "",
                    item.metadata.network,
                    item.metadata.type,
                    item.chains.joined(separator: " "),
                ]
                if !haystacks.contains(where: { $0.lowercased().contains(query) }) {
                    return false
                }
            }
            return true
        }

        return matched.sorted { lhs, rhs in
            switch sortOrder {
            case .newest:
                if lhs.isActive != rhs.isActive { return lhs.isActive }
                if lhs.sortTimestamp != rhs.sortTimestamp { return lhs.sortTimestamp > rhs.sortTimestamp }
                return lhs.id > rhs.id
            case .totalTraffic:
                if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
                return lhs.sortTimestamp > rhs.sortTimestamp
            case .download:
                if lhs.download != rhs.download { return lhs.download > rhs.download }
                return lhs.sortTimestamp > rhs.sortTimestamp
            case .upload:
                if lhs.upload != rhs.upload { return lhs.upload > rhs.upload }
                return lhs.sortTimestamp > rhs.sortTimestamp
            case .host:
                let cmp = lhs.displayAddress.localizedStandardCompare(rhs.displayAddress)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return lhs.sortTimestamp > rhs.sortTimestamp
            }
        }
    }

    private mutating func trimClosedHistoryIfNeeded() {
        let closed = recordsByID.values.filter { !$0.isActive }
        guard closed.count > maxClosedHistory else { return }
        let sortedOldestFirst = closed.sorted { lhs, rhs in
            let lt = lhs.closedAt ?? lhs.lastSeenAt
            let rt = rhs.closedAt ?? rhs.lastSeenAt
            if lt != rt { return lt < rt }
            return lhs.id < rhs.id
        }
        let excess = closed.count - maxClosedHistory
        for item in sortedOldestFirst.prefix(excess) {
            recordsByID.removeValue(forKey: item.id)
        }
    }

    public static func parseISO8601(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: raw)
    }
}

public enum TrafficFormatter {
    public static func bytes(_ count: Int64) -> String {
        let value = Double(max(0, count))
        let kb = 1024.0
        let mb = kb * 1024.0
        let gb = mb * 1024.0
        let tb = gb * 1024.0
        if value < kb {
            return "\(Int64(value)) B"
        } else if value < mb {
            return String(format: "%.1f KB", value / kb)
        } else if value < gb {
            return String(format: "%.2f MB", value / mb)
        } else if value < tb {
            return String(format: "%.2f GB", value / gb)
        } else {
            return String(format: "%.2f TB", value / tb)
        }
    }

    public static func shortBytes(_ count: Int64) -> String {
        let value = Double(max(0, count))
        let kb = 1024.0
        let mb = kb * 1024.0
        let gb = mb * 1024.0
        let tb = gb * 1024.0
        if value < kb {
            return "\(Int64(value))B"
        } else if value < mb {
            return String(format: "%.0fK", value / kb)
        } else if value < gb {
            return String(format: "%.1fM", value / mb)
        } else if value < tb {
            return String(format: "%.1fG", value / gb)
        } else {
            return String(format: "%.1fT", value / tb)
        }
    }

    public static func speed(_ bytesPerSecond: Int64) -> String {
        "\(bytes(bytesPerSecond))/s"
    }

    public static func shortSpeed(_ bytesPerSecond: Int64) -> String {
        "\(shortBytes(bytesPerSecond))/s"
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        if clamped < 1 {
            return String(format: "%.0f ms", clamped * 1000)
        } else if clamped < 60 {
            return String(format: "%.1fs", clamped)
        } else if clamped < 3600 {
            let mins = Int(clamped) / 60
            let secs = Int(clamped) % 60
            return "\(mins)m \(secs)s"
        } else {
            let hrs = Int(clamped) / 3600
            let mins = (Int(clamped) % 3600) / 60
            return "\(hrs)h \(mins)m"
        }
    }
}

// MARK: - DNS Query Log Parsing & Tracking

public enum DNSQueryStatus: String, Equatable, Sendable {
    case resolved
    case failed
}

public enum DNSUpstreamKind: String, Equatable, Sendable {
    case upstream
    case cache
    case fakeIP
    case local
}

public enum DNSLogFilterScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case resolved
    case failed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "全部"
        case .resolved: return "成功"
        case .failed: return "失败"
        }
    }
}

public enum DNSLogSourceFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case upstream
    case cache
    case localOrFakeIP

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "全部来源"
        case .upstream: return "上游 DNS"
        case .cache: return "缓存命中"
        case .localOrFakeIP: return "本地 / Fake-IP"
        }
    }
}

public struct DNSLogRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let domain: String
    public let recordType: String
    public let answers: [String]
    public let upstream: String
    public let cacheExpireAt: String?
    public let status: DNSQueryStatus
    public let errorMessage: String?
    public let rawPayload: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        domain: String,
        recordType: String,
        answers: [String] = [],
        upstream: String = "",
        cacheExpireAt: String? = nil,
        status: DNSQueryStatus,
        errorMessage: String? = nil,
        rawPayload: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.domain = domain
        self.recordType = recordType
        self.answers = answers
        self.upstream = upstream
        self.cacheExpireAt = cacheExpireAt
        self.status = status
        self.errorMessage = errorMessage
        self.rawPayload = rawPayload
    }

    public var hasAnswers: Bool {
        status == .resolved && !answers.isEmpty
    }

    public var upstreamKind: DNSUpstreamKind {
        let lower = upstream.lowercased()
        if lower == "cache" { return .cache }
        if lower == "fake-ip" { return .fakeIP }
        if lower.isEmpty || lower == "local" { return .local }
        return .upstream
    }

    /// Extracts the `HH:mm:ss` portion from `cacheExpireAt` (e.g. `"2026-11-22 10:51:23"` -> `"10:51:23"`).
    public var shortExpireTime: String? {
        guard let cacheExpireAt, !cacheExpireAt.isEmpty else { return nil }
        if let spaceIdx = cacheExpireAt.lastIndex(of: " ") {
            let tail = String(cacheExpireAt[cacheExpireAt.index(after: spaceIdx)...])
            if !tail.isEmpty { return tail }
        }
        return cacheExpireAt
    }

    /// Splits an upstream URI like `udp://192.168.0.1:53` or `https://1.1.1.1:443/dns-query` into a compact protocol badge and host display.
    public var upstreamDisplayParts: (schemeBadge: String?, endpoint: String) {
        let trimmed = upstream.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeRange = trimmed.range(of: "://") else {
            return (nil, trimmed)
        }
        let rawScheme = String(trimmed[..<schemeRange.lowerBound]).lowercased()
        let rest = String(trimmed[schemeRange.upperBound...])
        let badge: String
        switch rawScheme {
        case "https": badge = "DoH"
        case "tls": badge = "DoT"
        case "quic": badge = "DoQ"
        case "h3": badge = "DoH3"
        case "udp": badge = "UDP"
        case "tcp": badge = "TCP"
        case "dhcp": badge = "DHCP"
        case "system": badge = "SYS"
        case "rcode": badge = "RCODE"
        default: badge = rawScheme.uppercased()
        }
        return (badge, rest)
    }

    public var answerSummary: String {
        if status == .failed {
            return errorMessage ?? "解析失败"
        }
        return answers.isEmpty ? "无记录" : answers.joined(separator: ", ")
    }

    public var isSuspiciousLoopback: Bool {
        status == .resolved && answers.contains { $0 == "127.0.0.1" || $0 == "0.0.0.0" || $0 == "::1" }
    }

    public func exportSummary() -> String {
        var lines: [String] = [
            "域名: \(domain)",
            "类型: \(recordType)",
            "状态: \(status == .failed ? "解析失败" : (isSuspiciousLoopback ? "疑似回环" : (answers.isEmpty ? "无记录" : "解析成功")))",
            "结果: \(answerSummary)",
            "来源: \(upstream)",
        ]
        if let cacheExpireAt, !cacheExpireAt.isEmpty {
            lines.append("缓存过期: \(cacheExpireAt)")
        }
        lines.append("原始日志: \(rawPayload)")
        return lines.joined(separator: "\n")
    }
}

public enum DNSLogParser {
    /// Parses Mihomo debug log payloads for DNS results and failures.
    /// Returns `nil` for non-DNS logs or intermediate `resolve ... from ...` lines.
    public static func parse(payload: String, at timestamp: Date = Date()) -> DNSLogRecord? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. `[DNS] <domain> --> [<ips>] <type> from <upstream>`
        //    or `[DNS] cache hit <domain> --> [<ips>] <type>, expire at <datetime>`
        //    or `[DNS] <domain> --> <ip>` (local / hosts / fake-ip without brackets)
        if trimmed.hasPrefix("[DNS] "), let arrowRange = trimmed.range(of: " --> ") {
            var left = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 6)..<arrowRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            var isCacheHit = false
            if left.hasPrefix("cache hit ") {
                isCacheHit = true
                left = String(left.dropFirst("cache hit ".count)).trimmingCharacters(in: .whitespaces)
            }
            let domain = left.hasSuffix(".") ? String(left.dropLast()) : left
            guard !domain.isEmpty else { return nil }

            let right = String(trimmed[arrowRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            var answers: [String] = []
            var remainder = right
            var inferredType: String? = nil

            if right.hasPrefix("["), let closeBracket = right.firstIndex(of: "]") {
                let inside = String(right[right.index(after: right.startIndex)..<closeBracket])
                answers = inside
                    .split { $0 == " " || $0 == "," }
                    .map(String.init)
                    .filter { !$0.isEmpty }
                remainder = String(right[right.index(after: closeBracket)...]).trimmingCharacters(in: .whitespaces)
            } else {
                // Handle unbracketed single-IP responses like `[DNS] play.googleapis.com --> 172.217.115.4`
                let firstSpace = right.firstIndex(where: \.isWhitespace)
                let rawFirst = firstSpace.map { String(right[..<$0]) } ?? right
                let candidateIP = rawFirst.trimmingCharacters(in: CharacterSet(charactersIn: ","))
                if isIPAddress(candidateIP) {
                    answers = [candidateIP]
                    inferredType = candidateIP.contains(":") ? "AAAA" : "A"
                    if let firstSpace {
                        remainder = String(right[firstSpace...]).trimmingCharacters(in: .whitespaces)
                    } else {
                        remainder = ""
                    }
                }
            }

            var upstream = isCacheHit ? "cache" : ""
            var typeAndMeta = remainder
            if let fromRange = remainder.range(of: " from ") {
                typeAndMeta = String(remainder[..<fromRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                upstream = String(remainder[fromRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            }

            // Separate optional `, expire at <datetime>` suffix from the record type
            var cacheExpireAt: String? = nil
            var rawType = typeAndMeta
            if let expireRange = typeAndMeta.range(of: "expire at ", options: .caseInsensitive) {
                let expireVal = String(typeAndMeta[expireRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !expireVal.isEmpty {
                    cacheExpireAt = expireVal
                }
                rawType = String(typeAndMeta[..<expireRange.lowerBound])
                    .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",")))
            } else {
                rawType = rawType.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",")))
            }

            let recordType: String
            if !rawType.isEmpty {
                recordType = rawType
            } else if let inferredType {
                recordType = inferredType
            } else if answers.contains(where: { $0.contains(":") }) {
                recordType = "AAAA"
            } else {
                recordType = "A"
            }

            if upstream.isEmpty && answers.contains(where: { $0.hasPrefix("198.18.") }) {
                upstream = "fake-ip"
            }

            return DNSLogRecord(
                timestamp: timestamp,
                domain: domain,
                recordType: recordType,
                answers: answers,
                upstream: upstream.isEmpty ? "local" : upstream,
                cacheExpireAt: cacheExpireAt,
                status: .resolved,
                errorMessage: nil,
                rawPayload: trimmed
            )
        }

        // 2. `[DNS Server] Exchange ;<domain>.\tIN\t <type> failed: <reason>`
        if trimmed.hasPrefix("[DNS Server] Exchange "), let failedRange = trimmed.range(of: " failed: ") {
            let header = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: "[DNS Server] Exchange ".count)..<failedRange.lowerBound])
            let reason = String(trimmed[failedRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            let tokens = header
                .replacingOccurrences(of: ";", with: "")
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
            let rawDomain = tokens.first ?? "未知域名"
            let domain = rawDomain.hasSuffix(".") ? String(rawDomain.dropLast()) : rawDomain
            let recordType = tokens.count >= 3 ? tokens[2] : (tokens.last ?? "A")

            return DNSLogRecord(
                timestamp: timestamp,
                domain: domain,
                recordType: recordType,
                answers: [],
                upstream: "DNS Server",
                cacheExpireAt: nil,
                status: .failed,
                errorMessage: reason,
                rawPayload: trimmed
            )
        }

        return nil
    }

    private static func isIPAddress(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return true
        }
        var ipv6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            return true
        }
        return false
    }
}

// MARK: - Rule Group Match Display Index

public struct RuleMatchDisplayInfo: Equatable, Sendable {
    public let groupName: String
    public let ruleNote: String?

    public init(groupName: String, ruleNote: String? = nil) {
        self.groupName = groupName
        self.ruleNote = ruleNote
    }
}

public struct RuleMatchDisplayIndex: Sendable {
    private let entries: [String: RuleMatchDisplayInfo]

    public init(profile: RoutingProfile) {
        var map: [String: RuleMatchDisplayInfo] = [:]
        for group in profile.ruleGroups where group.isEnabled {
            for rule in group.rules where rule.isEnabled {
                let rawValue = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawValue.isEmpty else { continue }
                let note = rule.note.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanNote: String?
                if !note.isEmpty {
                    cleanNote = note
                } else if rule.type == .ruleSet, let url = URL(string: rawValue) {
                    cleanNote = url.lastPathComponent
                } else {
                    cleanNote = nil
                }

                let payloadKey: String
                if rule.type == .ruleSet {
                    payloadKey = MihomoConfig.ruleSetProviderKey(for: rawValue).lowercased()
                } else {
                    payloadKey = rawValue.lowercased()
                }
                let lookupKey = "\(Self.normalizeRuleType(rule.type.rawValue))|\(payloadKey)"
                if map[lookupKey] == nil {
                    map[lookupKey] = RuleMatchDisplayInfo(groupName: group.name, ruleNote: cleanNote)
                }
            }
        }
        self.entries = map
    }

    public func resolve(rule: String, payload: String) -> RuleMatchDisplayInfo? {
        let normalizedType = Self.normalizeRuleType(rule)
        if normalizedType == "match" {
            return RuleMatchDisplayInfo(groupName: "默认兜底 (MATCH)", ruleNote: nil)
        }
        let normalizedPayload = payload.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries["\(normalizedType)|\(normalizedPayload)"]
    }

    private static func normalizeRuleType(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
