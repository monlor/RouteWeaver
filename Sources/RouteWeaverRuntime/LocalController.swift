import Foundation
import RoutingCore

protocol MihomoControlClient: Sendable {
    var sessionID: UUID { get }
    var port: Int { get }
    var secret: String { get }
    var trackedGroups: [String] { get }

    func version(timeout: TimeInterval) async throws -> String
    func groups() async throws -> [String: LocalController.ProxyGroup]
    func select(group: String, node: String) async throws
    func testGroupDelay(group: String, url: String, timeoutMs: Int) async throws -> [String: Int]
    func reloadConfig(payload: Data) async throws
    func updateAllRuleProviders() async throws -> Int
    func connections() async throws -> MihomoConnectionsSnapshot
    func closeConnection(id: String) async throws
    func closeAllConnections() async throws
    func flushDNSCache() async throws
    func flushFakeIPCache() async throws
    func connectionSnapshots() -> AsyncThrowingStream<MihomoConnectionsSnapshot, Error>
    func dnsLogRecords(level: String) -> AsyncThrowingStream<DNSLogRecord, Error>
}

extension MihomoControlClient {
    func version() async throws -> String {
        try await version(timeout: 3)
    }

    func testGroupDelay(group: String) async throws -> [String: Int] {
        try await testGroupDelay(group: group, url: MihomoConfig.healthCheckURL, timeoutMs: 5_000)
    }

    func dnsLogRecords() -> AsyncThrowingStream<DNSLogRecord, Error> {
        dnsLogRecords(level: "debug")
    }
}

struct LocalController: Equatable, Sendable, MihomoControlClient {
    let sessionID: UUID
    let port: Int
    let secret: String
    let trackedGroups: [String]

    init(port: Int, secret: String, trackedGroups: [String], sessionID: UUID = UUID()) {
        self.sessionID = sessionID
        self.port = port
        self.secret = secret
        self.trackedGroups = trackedGroups
    }

    struct ProxyGroup: Equatable, Sendable {
        let type: String
        let now: String
        let all: [String]
        let delays: [String: Int]

        var isAutoTest: Bool {
            let lower = type.lowercased()
            return lower == "urltest" || lower == "fallback" || lower == "load-balance"
        }

        var currentDelay: Int? {
            guard !now.isEmpty else { return nil }
            return delays[now]
        }
    }

    private struct DelayHistoryEntry: Decodable {
        let delay: Int?
    }

    private struct DelayExtraEntry: Decodable {
        let history: [DelayHistoryEntry]?
    }

    private struct GroupResponse: Decodable {
        let name: String?
        let type: String?
        let now: String?
        let all: [String]?
        let history: [DelayHistoryEntry]?
        let extra: [String: DelayExtraEntry]?

        var latestDelay: Int? {
            if let extraHistory = extra?[MihomoConfig.healthCheckURL]?.history,
               let delay = extraHistory.last(where: { ($0.delay ?? 0) > 0 })?.delay {
                return delay
            }
            if let extra {
                for entry in extra.values {
                    if let delay = entry.history?.last(where: { ($0.delay ?? 0) > 0 })?.delay {
                        return delay
                    }
                }
            }
            if let delay = history?.last(where: { ($0.delay ?? 0) > 0 })?.delay {
                return delay
            }
            return nil
        }
    }

    private struct ProxyResponse: Decodable {
        let proxies: [String: GroupResponse]
    }

    private struct ProxyProviderEntry: Decodable {
        let proxies: [GroupResponse]?
    }

    private struct ProxyProvidersResponse: Decodable {
        let providers: [String: ProxyProviderEntry]
    }

    private struct Selection: Encodable {
        let name: String
    }

    private struct RuleProvidersResponse: Decodable {
        let providers: [String: EmptyObject]
    }

    private struct EmptyObject: Decodable {}

    private struct VersionResponse: Decodable {
        let version: String?
    }

    private struct MihomoLogEnvelope: Decodable {
        let type: String?
        let payload: String?
    }

    func version(timeout: TimeInterval = 3) async throws -> String {
        let data = try await request(path: "/version", timeout: timeout)
        let response = try JSONDecoder().decode(VersionResponse.self, from: data)
        guard let version = response.version, !version.isEmpty else {
            throw ControllerError.invalidAddress
        }
        return version
    }

    func groups() async throws -> [String: ProxyGroup] {
        async let proxiesDataTask = request(path: "/proxies")
        async let providersDataTask = try? request(path: "/providers/proxies")

        let data = try await proxiesDataTask
        let response = try JSONDecoder().decode(ProxyResponse.self, from: data)

        var delayByNode: [String: Int] = [:]
        for (nodeName, info) in response.proxies {
            if let delay = info.latestDelay {
                delayByNode[nodeName] = delay
            }
        }
        if let providersData = await providersDataTask,
           let providersResp = try? JSONDecoder().decode(ProxyProvidersResponse.self, from: providersData) {
            for provider in providersResp.providers.values {
                for node in provider.proxies ?? [] {
                    if let name = node.name, let delay = node.latestDelay {
                        delayByNode[name] = delay
                    }
                }
            }
        }

        var groups: [String: ProxyGroup] = [:]
        for name in trackedGroups {
            if let group = response.proxies[name], let nodes = group.all {
                var seen = Set<String>()
                let uniqueNodes = nodes.filter { seen.insert($0).inserted }
                var delays: [String: Int] = [:]
                for nodeName in uniqueNodes {
                    if let delay = delayByNode[nodeName] {
                        delays[nodeName] = delay
                    }
                }
                groups[name] = ProxyGroup(
                    type: group.type ?? "Selector",
                    now: group.now ?? "",
                    all: uniqueNodes,
                    delays: delays
                )
            }
        }
        return groups
    }

    func select(group: String, node: String) async throws {
        guard trackedGroups.contains(group) else {
            throw ControllerError.invalidGroup
        }
        _ = try await request(path: "/proxies/\(group)", body: JSONEncoder().encode(Selection(name: node)))
    }

    func testGroupDelay(
        group: String,
        url: String = MihomoConfig.healthCheckURL,
        timeoutMs: Int = 5_000
    ) async throws -> [String: Int] {
        guard trackedGroups.contains(group) else {
            throw ControllerError.invalidGroup
        }
        let data = try await request(
            path: "/group/\(group)/delay",
            queryItems: [
                URLQueryItem(name: "url", value: url),
                URLQueryItem(name: "timeout", value: String(timeoutMs)),
            ]
        )
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    private struct ReloadPayload: Encodable {
        let payload: String
    }

    func reloadConfig(payload: Data) async throws {
        let body = try JSONEncoder().encode(ReloadPayload(payload: String(decoding: payload, as: UTF8.self)))
        _ = try await request(
            path: "/configs",
            method: "PUT",
            body: body,
            queryItems: [URLQueryItem(name: "force", value: "true")]
        )
    }

    func updateAllRuleProviders() async throws -> Int {
        let data = try await request(path: "/providers/rules")
        let response = try JSONDecoder().decode(RuleProvidersResponse.self, from: data)
        let names = response.providers.keys.sorted()
        guard !names.isEmpty else { return 0 }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for name in names {
                group.addTask {
                    _ = try await self.request(path: "/providers/rules/\(name)", method: "PUT")
                }
            }
            try await group.waitForAll()
        }
        return names.count
    }

    func connections() async throws -> MihomoConnectionsSnapshot {
        let data = try await request(path: "/connections", timeout: 5)
        return try JSONDecoder().decode(MihomoConnectionsSnapshot.self, from: data)
    }

    func closeConnection(id: String) async throws {
        guard !id.isEmpty, !id.contains("/"), !id.contains("..") else {
            throw ControllerError.invalidAddress
        }
        _ = try await request(path: "/connections/\(id)", method: "DELETE")
    }

    func closeAllConnections() async throws {
        _ = try await request(path: "/connections", method: "DELETE")
    }

    func flushDNSCache() async throws {
        _ = try await request(path: "/cache/dns/flush", method: "POST")
    }

    func flushFakeIPCache() async throws {
        _ = try await request(path: "/cache/fakeip/flush", method: "POST")
    }

    func connectionSnapshots() -> AsyncThrowingStream<MihomoConnectionsSnapshot, Error> {
        webSocketStream(path: "/connections", queryItems: nil, idleTimeout: 6) { data in
            try? JSONDecoder().decode(MihomoConnectionsSnapshot.self, from: data)
        }
    }

    func dnsLogRecords(level: String = "debug") -> AsyncThrowingStream<DNSLogRecord, Error> {
        webSocketStream(path: "/logs", queryItems: [URLQueryItem(name: "level", value: level)], idleTimeout: 60) { data in
            guard let envelope = try? JSONDecoder().decode(MihomoLogEnvelope.self, from: data),
                  let payload = envelope.payload else {
                return nil
            }
            return DNSLogParser.parse(payload: payload)
        }
    }

    // MARK: - Transport Internals

    private static let webSocketMaxMessageSize = 16 * 1024 * 1024

    private func webSocketStream<Element: Sendable>(
        path: String,
        queryItems: [URLQueryItem]?,
        idleTimeout: TimeInterval? = nil,
        decode: @escaping @Sendable (Data) -> Element?
    ) -> AsyncThrowingStream<Element, Error> {
        let port = self.port
        let secret = self.secret
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                var locator = URLComponents()
                locator.scheme = "ws"
                locator.host = "127.0.0.1"
                locator.port = port
                locator.path = path
                if let queryItems, !queryItems.isEmpty {
                    locator.queryItems = queryItems
                }
                guard let url = locator.url else {
                    continuation.finish(throwing: ControllerError.invalidAddress)
                    return
                }
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")

                let session = URLSession(configuration: Self.makeDirectSessionConfiguration())
                let wsTask = session.webSocketTask(with: request)
                wsTask.maximumMessageSize = Self.webSocketMaxMessageSize
                wsTask.resume()

                defer {
                    wsTask.cancel(with: .normalClosure, reason: nil)
                    session.invalidateAndCancel()
                }

                do {
                    while !Task.isCancelled {
                        let message = try await Self.receiveMessage(
                            from: wsTask,
                            session: session,
                            idleTimeout: idleTimeout
                        )
                        let payloadData: Data
                        switch message {
                        case .data(let data):
                            payloadData = data
                        case .string(let text):
                            payloadData = Data(text.utf8)
                        @unknown default:
                            continue
                        }
                        if let element = decode(payloadData) {
                            continuation.yield(element)
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private final class WebSocketReceiveState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
        private var pendingResult: Result<URLSessionWebSocketTask.Message, Error>?
        private var timeoutTask: Task<Void, Never>?
        private var isResolved = false

        func install(continuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>) {
            lock.lock()
            if let result = pendingResult {
                pendingResult = nil
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func installTimeout(_ task: Task<Void, Never>) {
            lock.lock()
            if isResolved {
                lock.unlock()
                task.cancel()
                return
            }
            timeoutTask = task
            lock.unlock()
        }

        @discardableResult
        func resolve(with result: Result<URLSessionWebSocketTask.Message, Error>) -> Bool {
            lock.lock()
            guard !isResolved else {
                lock.unlock()
                return false
            }
            isResolved = true
            let cont = continuation
            continuation = nil
            let timer = timeoutTask
            timeoutTask = nil
            if cont != nil {
                lock.unlock()
                timer?.cancel()
                cont?.resume(with: result)
                return true
            }
            pendingResult = result
            lock.unlock()
            timer?.cancel()
            return true
        }
    }

    /// Races `wsTask.receive` against `idleTimeout` and task cancellation without waiting for
    /// a wedged `URLSessionWebSocketTask` callback before throwing `streamTimedOut`.
    private static func receiveMessage(
        from wsTask: URLSessionWebSocketTask,
        session: URLSession,
        idleTimeout: TimeInterval?
    ) async throws -> URLSessionWebSocketTask.Message {
        let state = WebSocketReceiveState()
        let cancelSocket: @Sendable (URLSessionWebSocketTask.CloseCode) -> Void = { closeCode in
            wsTask.cancel(with: closeCode, reason: nil)
            session.invalidateAndCancel()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation: continuation)

                if let idleTimeout, idleTimeout > 0 {
                    let timeoutNs = UInt64(idleTimeout * 1_000_000_000)
                    let timer = Task.detached(priority: .utility) {
                        try? await Task.sleep(nanoseconds: timeoutNs)
                        guard !Task.isCancelled else { return }
                        if state.resolve(with: .failure(ControllerError.streamTimedOut)) {
                            cancelSocket(.goingAway)
                        }
                    }
                    state.installTimeout(timer)
                }

                wsTask.receive { result in
                    state.resolve(with: result)
                }
            }
        } onCancel: {
            if state.resolve(with: .failure(CancellationError())) {
                cancelSocket(.normalClosure)
            }
        }
    }

    static func makeDirectSessionConfiguration() -> URLSessionConfiguration {
        let settings = URLSessionConfiguration.ephemeral
        settings.connectionProxyDictionary = [
            "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0, "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0
        ]
        return settings
    }

    private static let directSession: URLSession = {
        let settings = makeDirectSessionConfiguration()
        settings.httpMaximumConnectionsPerHost = 12
        return URLSession(configuration: settings, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private func request(
        path: String,
        method: String? = nil,
        body: Data? = nil,
        queryItems: [URLQueryItem]? = nil,
        timeout: TimeInterval = 15
    ) async throws -> Data {
        var locator = URLComponents()
        locator.scheme = "http"
        locator.host = "127.0.0.1"
        locator.port = port
        locator.path = path
        if let queryItems, !queryItems.isEmpty {
            locator.queryItems = queryItems
        }
        guard let url = locator.url else { throw ControllerError.invalidAddress }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = method ?? "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        } else if let method {
            request.httpMethod = method
        }
        let (data, response) = try await Self.directSession.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ControllerError.invalidAddress }
        guard (200...299).contains(response.statusCode) else { throw ControllerError.http(response.statusCode) }
        return data
    }

    private enum ControllerError: LocalizedError {
        case invalidAddress, invalidGroup, streamTimedOut, http(Int)

        var errorDescription: String? {
            switch self {
            case .invalidAddress: return "无法读取本机 Mihomo 控制接口。"
            case .invalidGroup: return "选择的节点组无效。"
            case .streamTimedOut: return "本机 Mihomo 实时数据流超时。"
            case .http(let code): return "本机 Mihomo 控制接口返回 HTTP \(code)。"
            }
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
