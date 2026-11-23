import Combine
import Foundation
import RoutingCore

struct SubscriptionNodeCacheEntry: Codable, Equatable {
    let nodes: [SubscriptionNode]
    let updatedAt: Date
    let usage: SubscriptionUsage?

    init(nodes: [SubscriptionNode], updatedAt: Date, usage: SubscriptionUsage? = nil) {
        self.nodes = nodes
        self.updatedAt = updatedAt
        self.usage = usage
    }
}

enum SubscriptionFetchError: LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case emptyOrUnsupportedFormat

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "订阅地址无效，仅支持 HTTPS 链接。"
        case .httpStatus(let code):
            return "拉取订阅失败（HTTP \(code)）。"
        case .emptyOrUnsupportedFormat:
            return "未在订阅响应中解析出可用节点（支持 Clash YAML 与 Base64/URI 节点列表）。"
        }
    }
}

@MainActor
final class SubscriptionStore: ObservableObject {
    @Published var cache: [UUID: SubscriptionNodeCacheEntry] = [:]
    @Published var fetchingIDs: Set<UUID> = []
    @Published var fetchErrors: [UUID: String] = [:]
    @Published var updatingHostModuleIDs: Set<UUID> = []

    func loadCache(in directory: URL) {
        cache = Self.loadCacheFromDisk(in: directory)
    }

    func saveCache(in directory: URL) {
        Self.saveCacheToDisk(cache, in: directory)
    }

    func migrateCache(urls: [String], from oldDir: URL, to newDir: URL) {
        Self.saveCacheToDisk(cache, in: newDir)
        Self.copyPayloads(for: urls, from: oldDir, to: newDir)
    }

    func removeSubscription(
        id: UUID,
        removedURL: String?,
        remainingURLs: [String],
        in directory: URL
    ) {
        cache.removeValue(forKey: id)
        fetchErrors.removeValue(forKey: id)
        Self.saveCacheToDisk(cache, in: directory)
        if let removedURL {
            let trimmedRemoved = removedURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainingURLs.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedRemoved }) {
                Self.removePayload(for: removedURL, in: directory)
            }
        }
    }

    func nodes(forSubscriptionID id: UUID?) -> [SubscriptionNode] {
        guard let id else { return [] }
        return cache[id]?.nodes ?? []
    }

    func matchedNodes(for group: NodeGroup) -> [SubscriptionNode]? {
        guard let subID = group.subscriptionID, let entry = cache[subID] else {
            return nil
        }
        return SubscriptionParser.matchingNodes(
            entry.nodes,
            pattern: group.filterPattern,
            excludePattern: group.excludeFilterPattern
        )
    }

    func fetchSubscriptionNodes(
        _ sub: ProxySubscription,
        fallbackProxyPort: Int?,
        cacheDirectory: URL,
        onSuccess: @escaping @MainActor (String) -> Void
    ) {
        guard !fetchingIDs.contains(sub.id) else { return }
        fetchingIDs.insert(sub.id)
        fetchErrors.removeValue(forKey: sub.id)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.fetchingIDs.remove(sub.id) }
            do {
                let fetched = try await Self.fetchValidatedPayload(
                    from: sub.url,
                    fallbackProxyPort: fallbackProxyPort,
                    cacheDirectory: cacheDirectory
                )
                self.cache[sub.id] = SubscriptionNodeCacheEntry(
                    nodes: fetched.nodes,
                    updatedAt: Date(),
                    usage: fetched.usage
                )
                Self.saveCacheToDisk(self.cache, in: cacheDirectory)
                if let usage = fetched.usage, usage.total > 0 {
                    onSuccess("已更新「\(sub.name)」：\(fetched.nodes.count) 个节点 · 剩余 \(TrafficFormatter.bytes(usage.remaining))")
                } else {
                    onSuccess("已下载并缓存「\(sub.name)」共 \(fetched.nodes.count) 个节点")
                }
            } catch {
                if let existing = self.cache[sub.id], !existing.nodes.isEmpty {
                    self.fetchErrors[sub.id] = "\(error.localizedDescription)（已保留本地缓存的 \(existing.nodes.count) 个节点，未覆盖）"
                } else {
                    self.fetchErrors[sub.id] = error.localizedDescription
                }
            }
        }
    }

    func refreshHostModule(
        id: UUID,
        rawURL: String,
        onParsed: @escaping @MainActor ((name: String?, hosts: [String: String]), URL) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https" else {
            onError("模块地址必须为有效的 HTTPS 链接。")
            return
        }
        updatingHostModuleIDs.insert(id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.updatingHostModuleIDs.remove(id) }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 20
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    onError("拉取模块失败，服务器返回非 200 状态码。")
                    return
                }
                let text = String(decoding: data, as: UTF8.self)
                let parsed = HostModuleParser.parse(text)
                onParsed(parsed, url)
            } catch {
                onError("拉取 Host 模块失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Payload Cache & HTTP Fetch Internals

    private nonisolated static var defaultDirectory: URL {
        ProfileStore().defaultDirectory
    }

    private nonisolated static func cacheURL(in directory: URL) -> URL {
        directory.standardizedFileURL.appendingPathComponent("subscription-cache.json")
    }

    private nonisolated static func payloadCacheDirectory(in directory: URL) -> URL {
        directory.standardizedFileURL.appendingPathComponent("subscription-payloads", isDirectory: true)
    }

    private nonisolated static func normalizedURLString(_ rawURL: String) -> String {
        rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func urlHash(_ input: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in input.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    nonisolated static func payloadURL(for rawURL: String, in directory: URL) -> URL {
        let key = urlHash(normalizedURLString(rawURL))
        return payloadCacheDirectory(in: directory).appendingPathComponent("sub-\(key).yaml")
    }

    nonisolated static func cachedPayloadData(for rawURL: String, in directory: URL) -> Data? {
        let primary = payloadURL(for: rawURL, in: directory)
        if let data = try? Data(contentsOf: primary),
           !data.isEmpty,
           !SubscriptionParser.parse(data).isEmpty {
            return data
        }
        if directory.standardizedFileURL != defaultDirectory.standardizedFileURL {
            let fallback = payloadURL(for: rawURL, in: defaultDirectory)
            if let data = try? Data(contentsOf: fallback),
               !data.isEmpty,
               !SubscriptionParser.parse(data).isEmpty {
                return data
            }
        }
        return nil
    }

    nonisolated static func cachedPayloadDate(for rawURL: String, in directory: URL) -> Date? {
        let primary = payloadURL(for: rawURL, in: directory)
        if let date = (try? FileManager.default.attributesOfItem(atPath: primary.path)[.modificationDate]) as? Date {
            return date
        }
        if directory.standardizedFileURL != defaultDirectory.standardizedFileURL {
            let fallback = payloadURL(for: rawURL, in: defaultDirectory)
            return (try? FileManager.default.attributesOfItem(atPath: fallback.path)[.modificationDate]) as? Date
        }
        return nil
    }

    @discardableResult
    nonisolated static func saveValidatedPayload(_ data: Data, for rawURL: String, in directory: URL) throws -> [SubscriptionNode] {
        let trimmed = normalizedURLString(rawURL)
        guard !data.isEmpty else {
            throw SubscriptionFetchError.emptyOrUnsupportedFormat
        }
        let nodes = SubscriptionParser.parse(data)
        guard !nodes.isEmpty else {
            throw SubscriptionFetchError.emptyOrUnsupportedFormat
        }
        let fm = FileManager.default
        let payloadDir = payloadCacheDirectory(in: directory)
        let isDefault = directory.standardizedFileURL == defaultDirectory.standardizedFileURL
        if !fm.fileExists(atPath: payloadDir.path) {
            let attrs: [FileAttributeKey: Any]? = isDefault ? [.posixPermissions: 0o700] : nil
            try fm.createDirectory(at: payloadDir, withIntermediateDirectories: true, attributes: attrs)
        }
        let dest = payloadURL(for: trimmed, in: directory)
        try ProfileStore.writePrivateFile(data, to: dest, tempName: dest.lastPathComponent)
        return nodes
    }

    private nonisolated static func removePayload(for rawURL: String, in directory: URL) {
        try? FileManager.default.removeItem(at: payloadURL(for: rawURL, in: directory))
    }

    private nonisolated static func copyPayloads(for urls: [String], from sourceDirectory: URL, to destinationDirectory: URL) {
        guard sourceDirectory.standardizedFileURL != destinationDirectory.standardizedFileURL else { return }
        for rawURL in urls {
            if let data = cachedPayloadData(for: rawURL, in: sourceDirectory) {
                _ = try? saveValidatedPayload(data, for: rawURL, in: destinationDirectory)
            }
        }
    }

    private nonisolated static func loadCacheFromDisk(in directory: URL) -> [UUID: SubscriptionNodeCacheEntry] {
        let primary = cacheURL(in: directory)
        if let decoded = decodeCache(at: primary) {
            return decoded
        }
        if directory.standardizedFileURL != defaultDirectory.standardizedFileURL,
           let fallback = decodeCache(at: cacheURL(in: defaultDirectory)) {
            return fallback
        }
        return [:]
    }

    private nonisolated static func decodeCache(at url: URL) -> [UUID: SubscriptionNodeCacheEntry]? {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: SubscriptionNodeCacheEntry].self, from: data) else {
            return nil
        }
        var result: [UUID: SubscriptionNodeCacheEntry] = [:]
        for (key, entry) in raw {
            if let id = UUID(uuidString: key) {
                result[id] = entry
            }
        }
        return result
    }

    private nonisolated static func saveCacheToDisk(_ entries: [UUID: SubscriptionNodeCacheEntry], in directory: URL) {
        var raw: [String: SubscriptionNodeCacheEntry] = [:]
        for (id, entry) in entries {
            raw[id.uuidString] = entry
        }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        let targetURL = cacheURL(in: directory)
        let dir = targetURL.deletingLastPathComponent()
        let isDefault = directory.standardizedFileURL == defaultDirectory.standardizedFileURL
        let attrs: [FileAttributeKey: Any]? = isDefault ? [.posixPermissions: 0o700] : nil
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: attrs)
        try? ProfileStore.writePrivateFile(data, to: targetURL, tempName: "subscription-cache.json")
    }

    private nonisolated static func fetchValidatedPayload(
        from rawURL: String,
        fallbackProxyPort: Int?,
        cacheDirectory: URL
    ) async throws -> (data: Data, nodes: [SubscriptionNode], usage: SubscriptionUsage?) {
        let trimmed = normalizedURLString(rawURL)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host != nil else {
            throw SubscriptionFetchError.invalidURL
        }

        let downloaded: (data: Data, usage: SubscriptionUsage?)
        do {
            downloaded = try await download(url: url, proxyPort: nil)
        } catch {
            if let proxyPort = fallbackProxyPort {
                downloaded = try await download(url: url, proxyPort: proxyPort)
            } else {
                throw error
            }
        }

        let nodes = try saveValidatedPayload(downloaded.data, for: trimmed, in: cacheDirectory)
        return (downloaded.data, nodes, downloaded.usage)
    }

    private nonisolated static func download(url: URL, proxyPort: Int?) async throws -> (data: Data, usage: SubscriptionUsage?) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        if let proxyPort {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPPort as String: proxyPort,
                kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPSPort as String: proxyPort,
            ]
        } else {
            config.connectionProxyDictionary = [
                "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
                "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0,
            ]
        }

        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.setValue("clash.meta/1.19.27", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SubscriptionFetchError.httpStatus(0)
        }
        guard (200...299).contains(http.statusCode) else {
            throw SubscriptionFetchError.httpStatus(http.statusCode)
        }
        let usage = SubscriptionUsage.parse(
            headerValue: http.value(forHTTPHeaderField: "subscription-userinfo"),
            webPageURL: http.value(forHTTPHeaderField: "profile-web-page-url"),
            updateInterval: http.value(forHTTPHeaderField: "profile-update-interval")
        )
        return (data, usage)
    }
}
