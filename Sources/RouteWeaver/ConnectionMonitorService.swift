import Combine
import Foundation
import RoutingCore

@MainActor
final class ConnectionMonitorService: ObservableObject {
    @Published private(set) var tracker = ConnectionTracker()
    @Published private(set) var trafficHistory = TrafficHistoryAccumulator()
    @Published private(set) var dnsLogs: [DNSLogRecord] = []
    @Published var isPaused = false
    @Published private(set) var isStreaming = false
    @Published private(set) var isClosingConnections = false
    @Published private(set) var lastError: String?

    let maxDNSLogs = 500
    private var internalTracker = ConnectionTracker()
    private var internalDNSLogs: [DNSLogRecord] = []
    private var pendingDNSLogs: [DNSLogRecord] = []
    private var activeController: (any MihomoControlClient)?
    private var streamTask: Task<Void, Never>?
    private var dnsLogTask: Task<Void, Never>?
    private var historyDirectory: URL = ProfileStore().defaultDirectory
    private var hasUnsavedHistory = false
    private var lastHistorySaveAt: Date = .distantPast

    func configureHistory(directory: URL) {
        let normalized = directory.standardizedFileURL
        if hasUnsavedHistory && normalized != historyDirectory {
            flushHistory()
        }
        historyDirectory = normalized
        trafficHistory = Self.loadHistory(in: normalized)
        hasUnsavedHistory = false
    }

    func clearTrafficHistory() {
        trafficHistory.reset()
        hasUnsavedHistory = true
        flushHistory()
    }

    func flushHistory() {
        guard hasUnsavedHistory else { return }
        Self.saveHistory(trafficHistory, in: historyDirectory)
        hasUnsavedHistory = false
        lastHistorySaveAt = Date()
    }
    private var dnsFlushTask: Task<Void, Never>?

    private struct MihomoLogEnvelope: Decodable {
        let type: String?
        let payload: String?
    }

    var failedDNSCount: Int {
        dnsLogs.reduce(into: 0) { count, item in
            if item.status == .failed || item.isSuspiciousLoopback { count += 1 }
        }
    }

    var cacheHitDNSCount: Int {
        dnsLogs.reduce(into: 0) { count, item in
            if item.upstreamKind == .cache { count += 1 }
        }
    }

    func start(controller: any MihomoControlClient) {
        stopStreamOnly()
        activeController = controller
        internalTracker.reset()
        tracker.reset()
        internalDNSLogs.removeAll()
        pendingDNSLogs.removeAll()
        dnsLogs.removeAll()
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
        flushHistory()
    }

    func togglePause() {
        isPaused.toggle()
        if !isPaused {
            flushPendingDNSLogs()
            tracker = internalTracker
            dnsLogs = internalDNSLogs
        }
    }

    func clearClosed() {
        internalTracker.clearClosed()
        tracker.clearClosed()
    }

    func clearDNSLogs() {
        internalDNSLogs.removeAll()
        pendingDNSLogs.removeAll()
        dnsLogs.removeAll()
    }

    func filteredDNSLogs(
        scope: DNSLogFilterScope,
        sourceFilter: DNSLogSourceFilter = .all,
        hideEmptyAnswers: Bool = false,
        searchText: String
    ) -> [DNSLogRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return dnsLogs.filter { item in
            switch scope {
            case .all: break
            case .resolved: if item.status != .resolved { return false }
            case .failed: if item.status != .failed && !item.isSuspiciousLoopback { return false }
            }
            switch sourceFilter {
            case .all: break
            case .upstream: if item.upstreamKind != .upstream { return false }
            case .cache: if item.upstreamKind != .cache { return false }
            case .localOrFakeIP: if item.upstreamKind != .local && item.upstreamKind != .fakeIP { return false }
            }
            if hideEmptyAnswers && item.status == .resolved && item.answers.isEmpty {
                return false
            }
            if !query.isEmpty {
                let fields = [
                    item.domain,
                    item.recordType,
                    item.answerSummary,
                    item.upstream,
                    item.cacheExpireAt ?? "",
                    item.errorMessage ?? "",
                ]
                if !fields.contains(where: { $0.lowercased().contains(query) }) {
                    return false
                }
            }
            return true
        }
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
        if internalTracker.lastUploadDelta > 0 || internalTracker.lastDownloadDelta > 0 {
            trafficHistory.recordDelta(
                uploadDelta: internalTracker.lastUploadDelta,
                downloadDelta: internalTracker.lastDownloadDelta,
                at: now
            )
            hasUnsavedHistory = true
            if now.timeIntervalSince(lastHistorySaveAt) >= 15 {
                flushHistory()
            }
        }
        if !isPaused {
            tracker = internalTracker
        }
        lastError = nil
    }

    private static var defaultDirectory: URL {
        ProfileStore().defaultDirectory
    }

    private static func historyURL(in directory: URL) -> URL {
        directory.standardizedFileURL.appendingPathComponent("traffic-history.json")
    }

    private static func loadHistory(in directory: URL) -> TrafficHistoryAccumulator {
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

    private static func saveHistory(_ history: TrafficHistoryAccumulator, in directory: URL) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        let targetURL = historyURL(in: directory)
        let dir = targetURL.deletingLastPathComponent()
        let isDefault = directory.standardizedFileURL == defaultDirectory.standardizedFileURL
        let attrs: [FileAttributeKey: Any]? = isDefault ? [.posixPermissions: 0o700] : nil
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: attrs)
        try? ProfileStore.writePrivateFile(data, to: targetURL, tempName: "traffic-history.json")
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
        let batch = pendingDNSLogs.reversed()
        pendingDNSLogs.removeAll(keepingCapacity: true)
        internalDNSLogs.insert(contentsOf: batch, at: 0)
        if internalDNSLogs.count > maxDNSLogs {
            internalDNSLogs.removeLast(internalDNSLogs.count - maxDNSLogs)
        }
        if !isPaused {
            dnsLogs = internalDNSLogs
        }
    }

    private nonisolated static func decodeDNSRecord(from data: Data) -> DNSLogRecord? {
        guard let envelope = try? JSONDecoder().decode(MihomoLogEnvelope.self, from: data),
              let payload = envelope.payload else {
            return nil
        }
        return DNSLogParser.parse(payload: payload)
    }

    private nonisolated static func decodeConnectionsSnapshot(from data: Data) -> MihomoConnectionsSnapshot? {
        try? JSONDecoder().decode(MihomoConnectionsSnapshot.self, from: data)
    }

    private func runDNSLogLoop(controller: any MihomoControlClient) async {
        try? await Task.sleep(nanoseconds: 450_000_000)

        while !Task.isCancelled && activeController?.sessionID == controller.sessionID {
            do {
                let request = try controller.logsWebSocketRequest(level: "debug")
                let session = URLSession(configuration: LocalController.makeDirectSessionConfiguration())
                let task = session.webSocketTask(with: request)
                task.resume()

                defer {
                    task.cancel(with: .normalClosure, reason: nil)
                    session.invalidateAndCancel()
                }

                while !Task.isCancelled && activeController?.sessionID == controller.sessionID {
                    let message = try await withTaskCancellationHandler {
                        try await task.receive()
                    } onCancel: {
                        task.cancel(with: .normalClosure, reason: nil)
                        session.invalidateAndCancel()
                    }
                    let payloadData: Data
                    switch message {
                    case .data(let data):
                        payloadData = data
                    case .string(let text):
                        payloadData = Data(text.utf8)
                    @unknown default:
                        continue
                    }

                    let record = await Task.detached(priority: .utility) {
                        Self.decodeDNSRecord(from: payloadData)
                    }.value
                    if let record {
                        enqueueDNS(record)
                    }
                }
            } catch {
                guard !Task.isCancelled && activeController?.sessionID == controller.sessionID else { break }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private func runMonitorLoop(controller: any MihomoControlClient) async {
        // Give Mihomo a brief moment to finish binding the external-controller port.
        try? await Task.sleep(nanoseconds: 350_000_000)

        while !Task.isCancelled && activeController?.sessionID == controller.sessionID {
            do {
                let request = try controller.connectionsWebSocketRequest()
                let session = URLSession(configuration: LocalController.makeDirectSessionConfiguration())
                let task = session.webSocketTask(with: request)
                task.resume()
                isStreaming = true

                defer {
                    task.cancel(with: .normalClosure, reason: nil)
                    session.invalidateAndCancel()
                }

                while !Task.isCancelled && activeController?.sessionID == controller.sessionID {
                    let message = try await withTaskCancellationHandler {
                        try await task.receive()
                    } onCancel: {
                        task.cancel(with: .normalClosure, reason: nil)
                        session.invalidateAndCancel()
                    }
                    let payloadData: Data
                    switch message {
                    case .data(let data):
                        payloadData = data
                    case .string(let text):
                        payloadData = Data(text.utf8)
                    @unknown default:
                        continue
                    }

                    let snapshot = await Task.detached(priority: .utility) {
                        Self.decodeConnectionsSnapshot(from: payloadData)
                    }.value
                    if let snapshot {
                        ingest(snapshot)
                    }
                }
            } catch {
                guard !Task.isCancelled && activeController?.sessionID == controller.sessionID else { break }
                isStreaming = false
                // Fallback to one HTTP snapshot poll before reconnecting WebSocket.
                do {
                    let snapshot = try await controller.connections()
                    ingest(snapshot)
                } catch {
                    lastError = "等待本机 Mihomo 控制接口响应…"
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        isStreaming = false
    }
}
