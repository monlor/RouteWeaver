import Combine
import Foundation
import RoutingCore

@MainActor
final class ConnectionMonitorService: ObservableObject {
    @Published private(set) var tracker = ConnectionTracker()
    @Published private(set) var trafficHistory = TrafficHistoryAccumulator()
    @Published private(set) var trafficRanking = TrafficRankingAccumulator()
    @Published private(set) var dnsTracker = DNSLogTracker(maxRecords: 500)
    @Published private(set) var outboundErrorTracker = OutboundErrorTracker(maxRecords: 300)
    @Published var isPaused = false
    @Published private(set) var isStreaming = false
    @Published private(set) var isClosingConnections = false
    @Published private(set) var isFlushingDNSCache = false
    @Published private(set) var lastError: String?
    var localIPs: Set<String> = []
    /// Invoked when an outbound dial failure or repeated zero-byte proxy blackhole is observed for a target.
    var onTargetAnomalyDetected: (@MainActor (String) -> Void)?

    var maxDNSLogs: Int { dnsTracker.maxRecords }
    var dnsLogs: [DNSLogRecord] { dnsTracker.records }
    var outboundErrors: [OutboundErrorRecord] { outboundErrorTracker.records }
    private var internalTracker = ConnectionTracker()
    private var internalDNSTracker = DNSLogTracker(maxRecords: 500)
    private var internalOutboundErrorTracker = OutboundErrorTracker(maxRecords: 300)
    private var pendingDNSLogs: [DNSLogRecord] = []
    private var pendingOutboundErrors: [OutboundErrorRecord] = []
    private var zeroResponseCountByTarget: [String: [Date]] = [:]
    private var activeController: (any MihomoControlClient)?
    private var streamTask: Task<Void, Never>?
    private var dnsLogTask: Task<Void, Never>?
    private var dnsFlushTask: Task<Void, Never>?
    private var historyDirectory: URL = ProfileStore().defaultDirectory
    private var hasUnsavedHistory = false
    private var lastHistorySaveAt: Date = .distantPast
    private let historyPersistenceQueue = DispatchQueue(label: "local.routeweaver.traffic-history-io", qos: .utility)

    /// Configurable delays so unit tests can exercise reconnect & fallback paths without real sleeps.
    let initialConnectDelayNs: UInt64
    let reconnectDelayNs: UInt64

    init(initialConnectDelayNs: UInt64 = 350_000_000, reconnectDelayNs: UInt64 = 1_000_000_000) {
        self.initialConnectDelayNs = initialConnectDelayNs
        self.reconnectDelayNs = reconnectDelayNs
    }

    func configureHistory(directory: URL) {
        let normalized = directory.standardizedFileURL
        if hasUnsavedHistory && normalized != historyDirectory {
            flushHistory(sync: true)
        }
        historyDirectory = normalized
        trafficHistory = Self.loadArchive(
            TrafficHistoryAccumulator.self,
            fileName: Self.historyFileName,
            in: normalized,
            defaultValue: TrafficHistoryAccumulator()
        )
        trafficRanking = Self.loadArchive(
            TrafficRankingAccumulator.self,
            fileName: Self.rankingFileName,
            in: normalized,
            defaultValue: TrafficRankingAccumulator()
        )
        hasUnsavedHistory = false
    }

    func clearTrafficHistory() {
        trafficHistory.reset()
        hasUnsavedHistory = true
        flushHistory()
    }

    func clearTrafficRanking() {
        trafficRanking.reset()
        hasUnsavedHistory = true
        flushHistory()
    }

    func renameTrafficHistoryTarget(from oldName: String, to newName: String) {
        guard oldName != newName else { return }
        trafficHistory.renameTarget(from: oldName, to: newName)
        hasUnsavedHistory = true
        flushHistory()
    }

    func flushHistory(sync: Bool = false) {
        guard hasUnsavedHistory else { return }
        let snapshot = trafficHistory
        let rankingSnapshot = trafficRanking
        let directory = historyDirectory
        hasUnsavedHistory = false
        lastHistorySaveAt = Date()
        if sync {
            historyPersistenceQueue.sync {
                Self.saveArchive(snapshot, fileName: Self.historyFileName, in: directory)
                Self.saveArchive(rankingSnapshot, fileName: Self.rankingFileName, in: directory)
            }
        } else {
            historyPersistenceQueue.async {
                Self.saveArchive(snapshot, fileName: Self.historyFileName, in: directory)
                Self.saveArchive(rankingSnapshot, fileName: Self.rankingFileName, in: directory)
            }
        }
    }

    var failedDNSCount: Int {
        dnsTracker.failedCount
    }

    var cacheHitDNSCount: Int {
        dnsTracker.cacheHitCount
    }

    func start(controller: any MihomoControlClient) {
        stopStreamOnly()
        activeController = controller
        internalTracker.reset()
        tracker.reset()
        internalDNSTracker.clear()
        internalOutboundErrorTracker.clear()
        pendingDNSLogs.removeAll()
        pendingOutboundErrors.removeAll()
        zeroResponseCountByTarget.removeAll()
        dnsTracker.clear()
        outboundErrorTracker.clear()
        isPaused = false
        lastError = nil

        streamTask = Task { [weak self] in
            await self?.runMonitorLoop(controller: controller)
        }
        dnsLogTask = Task { [weak self] in
            await self?.runDNSLogLoop(controller: controller)
        }
    }

    func stop() {
        stopStreamOnly()
        flushPendingDNSLogs()
        activeController = nil
        internalTracker.markAllClosed()
        tracker.markAllClosed()
        isStreaming = false
        flushHistory(sync: true)
    }

    func togglePause() {
        isPaused.toggle()
        if !isPaused {
            flushPendingDNSLogs()
            tracker = internalTracker
            dnsTracker = internalDNSTracker
            outboundErrorTracker = internalOutboundErrorTracker
        }
    }

    func clearClosed() {
        internalTracker.clearClosed()
        tracker.clearClosed()
    }

    func clearDNSLogs() {
        internalDNSTracker.clear()
        pendingDNSLogs.removeAll()
        dnsTracker.clear()
    }

    func clearOutboundErrors() {
        internalOutboundErrorTracker.clear()
        pendingOutboundErrors.removeAll()
        zeroResponseCountByTarget.removeAll()
        outboundErrorTracker.clear()
    }

    func seedOutboundErrorsFromLogText(_ rawLogs: String) {
        let parsed = OutboundErrorParser.parseLogBuffer(rawLogs)
        guard !parsed.isEmpty else { return }
        internalOutboundErrorTracker.replaceAll(parsed)
        if !isPaused {
            outboundErrorTracker = internalOutboundErrorTracker
        }
    }

    func applyRemoteData(
        status: RemoteStatusSnapshot?,
        connections: [RemoteConnectionDTO],
        dnsLogs: [RemoteDNSLogDTO],
        trafficHistory remoteHistory: TrafficHistoryAccumulator?,
        trafficRanking remoteRanking: TrafficRankingAccumulator?,
        rawLogs: String = "",
        outboundErrors: [OutboundErrorRecord]? = nil,
        targetSessionTotals: [String: TrafficBytes]? = nil,
        targetConnectionCounts: [String: Int]? = nil,
        targetSpeeds: [String: TrafficBytes]? = nil,
        ruleSessionTotals: [String: TrafficBytes]? = nil
    ) {
        let now = Date()
        let mappedConnections: [MonitoredConnection] = connections.map { dto in
            let rawChains: [String]
            if let explicitChains = dto.chains, !explicitChains.isEmpty {
                rawChains = explicitChains
            } else {
                let chainParts = dto.chain
                    .components(separatedBy: " → ")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                rawChains = Array(chainParts.reversed())
            }
            let resolvedClosedAt: Date?
            if dto.isActive {
                resolvedClosedAt = nil
            } else if let explicitClosedAt = dto.closedAt {
                resolvedClosedAt = explicitClosedAt
            } else if let previous = internalTracker.recordsByID[dto.id] {
                resolvedClosedAt = previous.isActive ? now : previous.closedAt
            } else {
                resolvedClosedAt = dto.startDate ?? .distantPast
            }
            let meta = MihomoConnectionMetadata(
                network: dto.network,
                type: dto.type ?? "",
                sourceIP: dto.sourceIP,
                destinationIP: dto.destinationIP,
                sourcePort: dto.sourcePort ?? "",
                destinationPort: dto.destinationPort ?? "",
                host: dto.host,
                dnsMode: "",
                process: dto.process ?? "",
                processPath: "",
                remoteDestination: dto.destinationIP
            )
            return MonitoredConnection(
                id: dto.id,
                metadata: meta,
                upload: dto.upload,
                download: dto.download,
                uploadSpeed: dto.uploadSpeed,
                downloadSpeed: dto.downloadSpeed,
                startRaw: "",
                startDate: dto.startDate,
                firstSeenAt: dto.startDate ?? now,
                lastSeenAt: now,
                closedAt: resolvedClosedAt,
                chains: rawChains.isEmpty ? ["DIRECT"] : rawChains,
                rule: dto.rule,
                rulePayload: dto.matchedRuleSet ?? "",
                isActive: dto.isActive
            )
        }

        internalTracker.applyRemoteSnapshot(
            records: mappedConnections,
            uploadSpeed: status?.uploadSpeed ?? 0,
            downloadSpeed: status?.downloadSpeed ?? 0,
            uploadTotal: status?.uploadTotal ?? 0,
            downloadTotal: status?.downloadTotal ?? 0,
            memoryUsage: 0,
            targetSessionTotals: targetSessionTotals,
            targetConnectionCounts: targetConnectionCounts,
            targetSpeeds: targetSpeeds,
            ruleSessionTotals: ruleSessionTotals,
            at: now
        )

        let mappedDNS: [DNSLogRecord] = dnsLogs.map { dto in
            let statusEnum: DNSQueryStatus = dto.status == DNSQueryStatus.failed.rawValue ? .failed : .resolved
            let answers: [String]
            let errorMessage: String?
            if statusEnum == .failed {
                answers = []
                errorMessage = dto.result
            } else {
                answers = dto.result
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                errorMessage = nil
            }
            let resolvedUpstream = dto.upstream?.trimmingCharacters(in: .whitespacesAndNewlines)
            let upstream = (resolvedUpstream?.isEmpty == false)
                ? resolvedUpstream!
                : (statusEnum == .failed ? "DNS Server" : "remote")
            return DNSLogRecord(
                id: UUID(uuidString: dto.id) ?? UUID(),
                timestamp: dto.timestamp,
                domain: dto.domain,
                recordType: dto.queryType,
                answers: answers,
                upstream: upstream,
                cacheExpireAt: nil,
                status: statusEnum,
                errorMessage: errorMessage,
                rawPayload: dto.rawPayload ?? "\(dto.domain) (\(dto.queryType)) -> \(dto.result)"
            )
        }
        internalDNSTracker.replaceAll(mappedDNS)
        if let outboundErrors {
            internalOutboundErrorTracker.replaceAll(outboundErrors)
        } else {
            internalOutboundErrorTracker.replaceAll(OutboundErrorParser.parseLogBuffer(rawLogs))
        }

        if let remoteHistory {
            trafficHistory = remoteHistory
        }
        if let remoteRanking {
            trafficRanking = remoteRanking
        }
        isStreaming = status?.isRunning ?? false
        if !isPaused {
            tracker = internalTracker
            dnsTracker = internalDNSTracker
            outboundErrorTracker = internalOutboundErrorTracker
        }
        lastError = nil
    }

    func resetRemoteData() {
        internalTracker.reset()
        tracker.reset()
        internalDNSTracker.clear()
        internalOutboundErrorTracker.clear()
        dnsTracker.clear()
        outboundErrorTracker.clear()
        zeroResponseCountByTarget.removeAll()
        trafficHistory = TrafficHistoryAccumulator()
        trafficRanking = TrafficRankingAccumulator()
        isStreaming = false
        lastError = nil
    }

    func filteredDNSLogs(
        scope: DNSLogFilterScope,
        sourceFilter: DNSLogSourceFilter = .all,
        hideEmptyAnswers: Bool = false,
        searchText: String
    ) -> [DNSLogRecord] {
        dnsTracker.filtered(
            scope: scope,
            sourceFilter: sourceFilter,
            hideEmptyAnswers: hideEmptyAnswers,
            searchText: searchText
        )
    }

    func closeConnection(id: String) async throws {
        guard let controller = activeController else { return }
        try await controller.closeConnection(id: id)
        if let snapshot = try? await controller.connections() {
            ingest(snapshot)
        }
    }

    func closeAllConnections() async throws {
        guard let controller = activeController, !isClosingConnections else { return }
        isClosingConnections = true
        defer { isClosingConnections = false }
        try await controller.closeAllConnections()
        if let snapshot = try? await controller.connections() {
            ingest(snapshot)
        }
    }

    func flushDNSCache(includeFakeIP: Bool = false) async throws {
        guard let controller = activeController, !isFlushingDNSCache else { return }
        isFlushingDNSCache = true
        defer { isFlushingDNSCache = false }
        try await controller.flushDNSCache()
        if includeFakeIP {
            try await controller.flushFakeIPCache()
        }
    }

    private func stopStreamOnly() {
        streamTask?.cancel()
        streamTask = nil
        dnsLogTask?.cancel()
        dnsLogTask = nil
        dnsFlushTask?.cancel()
        dnsFlushTask = nil
    }

    private func ingest(_ snapshot: MihomoConnectionsSnapshot) {
        let now = Date()
        let activeIDsInSnapshot = Set(snapshot.connections.map(\.id))
        var newlyBlackholedTargets = Set<String>()
        var targetsWithFreshDownload = Set<String>()

        for conn in snapshot.connections where !conn.metadata.type.localizedCaseInsensitiveContains("Inner") {
            let prevDown = internalTracker.recordsByID[conn.id]?.download ?? 0
            if conn.download > prevDown {
                targetsWithFreshDownload.insert(conn.chains.last ?? "DIRECT")
            }
        }
        for (id, existing) in internalTracker.recordsByID where existing.isActive && !activeIDsInSnapshot.contains(id) {
            if !existing.isInner && !existing.isDirect && !existing.isRejected,
               existing.upload > 0 && existing.download == 0 {
                let target = existing.primaryTarget
                var timestamps = (zeroResponseCountByTarget[target] ?? []).filter { now.timeIntervalSince($0) <= 60 }
                timestamps.append(now)
                zeroResponseCountByTarget[target] = timestamps
                if timestamps.count >= 2 {
                    newlyBlackholedTargets.insert(target)
                }
            }
        }
        for healthyTarget in targetsWithFreshDownload {
            zeroResponseCountByTarget.removeValue(forKey: healthyTarget)
        }

        internalTracker.ingest(snapshot, localIPs: localIPs, at: now)
        if internalTracker.lastUploadDelta > 0
            || internalTracker.lastDownloadDelta > 0
            || !internalTracker.lastTargetDeltas.isEmpty {
            trafficHistory.recordDelta(
                uploadDelta: internalTracker.lastUploadDelta,
                downloadDelta: internalTracker.lastDownloadDelta,
                targetDeltas: internalTracker.lastTargetDeltas,
                at: now
            )
            hasUnsavedHistory = true
        }
        if !internalTracker.lastDimensionDeltas.isEmpty {
            trafficRanking.record(internalTracker.lastDimensionDeltas, at: now)
            hasUnsavedHistory = true
        }
        if hasUnsavedHistory && now.timeIntervalSince(lastHistorySaveAt) >= 15 {
            flushHistory()
        }
        if !isPaused {
            tracker = internalTracker
        }
        lastError = nil

        for target in newlyBlackholedTargets {
            onTargetAnomalyDetected?(target)
        }
    }

    private nonisolated static let historyFileName = "traffic-history.json"
    private nonisolated static let rankingFileName = "traffic-ranking.json"

    private nonisolated static var defaultDirectory: URL {
        ProfileStore().defaultDirectory
    }

    nonisolated static func loadArchive<T: Decodable>(
        _ type: T.Type,
        fileName: String,
        in directory: URL,
        defaultValue: @autoclosure () -> T
    ) -> T {
        let primary = directory.standardizedFileURL.appendingPathComponent(fileName)
        if let data = try? Data(contentsOf: primary),
           let decoded = try? JSONDecoder().decode(T.self, from: data) {
            return decoded
        }
        if directory.standardizedFileURL != defaultDirectory.standardizedFileURL {
            let fallback = defaultDirectory.standardizedFileURL.appendingPathComponent(fileName)
            if let data = try? Data(contentsOf: fallback),
               let decoded = try? JSONDecoder().decode(T.self, from: data) {
                return decoded
            }
        }
        return defaultValue()
    }

    nonisolated static func saveArchive<T: Encodable>(_ value: T, fileName: String, in directory: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let targetURL = directory.standardizedFileURL.appendingPathComponent(fileName)
        let dir = targetURL.deletingLastPathComponent()
        let isDefault = directory.standardizedFileURL == defaultDirectory.standardizedFileURL
        let attrs: [FileAttributeKey: Any]? = isDefault ? [.posixPermissions: 0o700] : nil
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: attrs)
        try? ProfileStore.writePrivateFile(data, to: targetURL, tempName: fileName)
    }

    private func enqueueDNS(_ record: DNSLogRecord) {
        pendingDNSLogs.append(record)
        scheduleLogBatchFlushIfNeeded()
    }

    private func enqueueOutboundError(_ record: OutboundErrorRecord) {
        pendingOutboundErrors.append(record)
        scheduleLogBatchFlushIfNeeded()
        if record.category != .rejected {
            onTargetAnomalyDetected?(record.primaryTarget)
        }
    }

    private func scheduleLogBatchFlushIfNeeded() {
        guard dnsFlushTask == nil else { return }
        dnsFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.flushPendingDNSLogs()
        }
    }

    private func flushPendingDNSLogs() {
        dnsFlushTask?.cancel()
        dnsFlushTask = nil
        if !pendingDNSLogs.isEmpty {
            let batch = pendingDNSLogs
            pendingDNSLogs.removeAll(keepingCapacity: true)
            internalDNSTracker.appendBatch(batch)
            if !isPaused {
                dnsTracker = internalDNSTracker
            }
        }
        if !pendingOutboundErrors.isEmpty {
            let errBatch = pendingOutboundErrors
            pendingOutboundErrors.removeAll(keepingCapacity: true)
            internalOutboundErrorTracker.appendBatch(errBatch)
            if !isPaused {
                outboundErrorTracker = internalOutboundErrorTracker
            }
        }
    }

    private func runDNSLogLoop(controller: any MihomoControlClient) async {
        if initialConnectDelayNs > 0 {
            try? await Task.sleep(nanoseconds: initialConnectDelayNs + 100_000_000)
        }

        while !Task.isCancelled && activeController?.sessionID == controller.sessionID {
            do {
                for try await event in controller.logEvents(level: "debug") {
                    guard !Task.isCancelled && activeController?.sessionID == controller.sessionID else { break }
                    switch event {
                    case .dns(let record):
                        enqueueDNS(record)
                    case .outboundError(let errorRecord):
                        enqueueOutboundError(errorRecord)
                    }
                }
                guard !Task.isCancelled && activeController?.sessionID == controller.sessionID else { break }
                if reconnectDelayNs > 0 {
                    try? await Task.sleep(nanoseconds: reconnectDelayNs)
                }
            } catch {
                guard !Task.isCancelled && activeController?.sessionID == controller.sessionID else { break }
                if reconnectDelayNs > 0 {
                    try? await Task.sleep(nanoseconds: reconnectDelayNs)
                }
            }
        }
    }

    private func runMonitorLoop(controller: any MihomoControlClient) async {
        if initialConnectDelayNs > 0 {
            try? await Task.sleep(nanoseconds: initialConnectDelayNs)
        }

        while !Task.isCancelled && activeController?.sessionID == controller.sessionID {
            do {
                isStreaming = true
                for try await snapshot in controller.connectionSnapshots() {
                    guard !Task.isCancelled && activeController?.sessionID == controller.sessionID else { break }
                    ingest(snapshot)
                }
                guard !Task.isCancelled && activeController?.sessionID == controller.sessionID else { break }
                isStreaming = false
                if reconnectDelayNs > 0 {
                    try? await Task.sleep(nanoseconds: reconnectDelayNs)
                }
            } catch {
                guard !Task.isCancelled && activeController?.sessionID == controller.sessionID else { break }
                isStreaming = false
                do {
                    let snapshot = try await controller.connections()
                    ingest(snapshot)
                } catch {
                    lastError = "等待本机 Mihomo 控制接口响应…"
                }
                if reconnectDelayNs > 0 {
                    try? await Task.sleep(nanoseconds: reconnectDelayNs)
                }
            }
        }

        isStreaming = false
    }
}
