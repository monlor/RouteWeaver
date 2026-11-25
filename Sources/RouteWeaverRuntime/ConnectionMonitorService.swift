import Combine
import Foundation
import RoutingCore

@MainActor
final class ConnectionMonitorService: ObservableObject {
    @Published private(set) var tracker = ConnectionTracker()
    @Published private(set) var trafficHistory = TrafficHistoryAccumulator()
    @Published private(set) var trafficRanking = TrafficRankingAccumulator()
    @Published private(set) var dnsTracker = DNSLogTracker(maxRecords: 500)
    @Published var isPaused = false
    @Published private(set) var isStreaming = false
    @Published private(set) var isClosingConnections = false
    @Published private(set) var isFlushingDNSCache = false
    @Published private(set) var lastError: String?

    var maxDNSLogs: Int { dnsTracker.maxRecords }
    var dnsLogs: [DNSLogRecord] { dnsTracker.records }
    private var internalTracker = ConnectionTracker()
    private var internalDNSTracker = DNSLogTracker(maxRecords: 500)
    private var pendingDNSLogs: [DNSLogRecord] = []
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
        trafficHistory = Self.loadHistory(in: normalized)
        trafficRanking = Self.loadRanking(in: normalized)
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
                Self.saveHistory(snapshot, in: directory)
                Self.saveRanking(rankingSnapshot, in: directory)
            }
        } else {
            historyPersistenceQueue.async {
                Self.saveHistory(snapshot, in: directory)
                Self.saveRanking(rankingSnapshot, in: directory)
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
        pendingDNSLogs.removeAll()
        dnsTracker.clear()
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
        internalTracker.ingest(snapshot, at: now)
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
    }

    private nonisolated static var defaultDirectory: URL {
        ProfileStore().defaultDirectory
    }

    private nonisolated static func historyURL(in directory: URL) -> URL {
        directory.standardizedFileURL.appendingPathComponent("traffic-history.json")
    }

    private nonisolated static func loadHistory(in directory: URL) -> TrafficHistoryAccumulator {
        let primary = historyURL(in: directory)
        if let data = try? Data(contentsOf: primary),
           let decoded = try? JSONDecoder().decode(TrafficHistoryAccumulator.self, from: data) {
            return decoded
        }
        if directory.standardizedFileURL != defaultDirectory.standardizedFileURL {
            let fallback = historyURL(in: defaultDirectory)
            if let data = try? Data(contentsOf: fallback),
               let decoded = try? JSONDecoder().decode(TrafficHistoryAccumulator.self, from: data) {
                return decoded
            }
        }
        return TrafficHistoryAccumulator()
    }

    private nonisolated static func saveHistory(_ history: TrafficHistoryAccumulator, in directory: URL) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        let targetURL = historyURL(in: directory)
        let dir = targetURL.deletingLastPathComponent()
        let isDefault = directory.standardizedFileURL == defaultDirectory.standardizedFileURL
        let attrs: [FileAttributeKey: Any]? = isDefault ? [.posixPermissions: 0o700] : nil
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: attrs)
        try? ProfileStore.writePrivateFile(data, to: targetURL, tempName: "traffic-history.json")
    }

    private nonisolated static func rankingURL(in directory: URL) -> URL {
        directory.standardizedFileURL.appendingPathComponent("traffic-ranking.json")
    }

    private nonisolated static func loadRanking(in directory: URL) -> TrafficRankingAccumulator {
        let primary = rankingURL(in: directory)
        if let data = try? Data(contentsOf: primary),
           let decoded = try? JSONDecoder().decode(TrafficRankingAccumulator.self, from: data) {
            return decoded
        }
        if directory.standardizedFileURL != defaultDirectory.standardizedFileURL {
            let fallback = rankingURL(in: defaultDirectory)
            if let data = try? Data(contentsOf: fallback),
               let decoded = try? JSONDecoder().decode(TrafficRankingAccumulator.self, from: data) {
                return decoded
            }
        }
        return TrafficRankingAccumulator()
    }

    private nonisolated static func saveRanking(_ ranking: TrafficRankingAccumulator, in directory: URL) {
        guard let data = try? JSONEncoder().encode(ranking) else { return }
        let targetURL = rankingURL(in: directory)
        let dir = targetURL.deletingLastPathComponent()
        let isDefault = directory.standardizedFileURL == defaultDirectory.standardizedFileURL
        let attrs: [FileAttributeKey: Any]? = isDefault ? [.posixPermissions: 0o700] : nil
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: attrs)
        try? ProfileStore.writePrivateFile(data, to: targetURL, tempName: "traffic-ranking.json")
    }

    private func enqueueDNS(_ record: DNSLogRecord) {
        pendingDNSLogs.append(record)
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
        guard !pendingDNSLogs.isEmpty else { return }
        let batch = pendingDNSLogs
        pendingDNSLogs.removeAll(keepingCapacity: true)
        internalDNSTracker.appendBatch(batch)
        if !isPaused {
            dnsTracker = internalDNSTracker
        }
    }

    private func runDNSLogLoop(controller: any MihomoControlClient) async {
        if initialConnectDelayNs > 0 {
            try? await Task.sleep(nanoseconds: initialConnectDelayNs + 100_000_000)
        }

        while !Task.isCancelled && activeController?.sessionID == controller.sessionID {
            do {
                for try await record in controller.dnsLogRecords(level: "debug") {
                    guard !Task.isCancelled && activeController?.sessionID == controller.sessionID else { break }
                    enqueueDNS(record)
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
