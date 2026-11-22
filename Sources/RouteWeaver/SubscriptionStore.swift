import Combine
import Foundation
import RoutingCore

@MainActor
final class SubscriptionStore: ObservableObject {
    @Published var cache: [UUID: SubscriptionNodeCacheEntry] = [:]
    @Published var fetchingIDs: Set<UUID> = []
    @Published var fetchErrors: [UUID: String] = [:]
    @Published var updatingHostModuleIDs: Set<UUID> = []

    func loadCache(in directory: URL) {
        cache = SubscriptionFetcher.loadCache(in: directory)
    }

    func saveCache(in directory: URL) {
        SubscriptionFetcher.saveCache(cache, in: directory)
    }

    func migrateCache(urls: [String], from oldDir: URL, to newDir: URL) {
        SubscriptionFetcher.saveCache(cache, in: newDir)
        SubscriptionFetcher.copyPayloads(for: urls, from: oldDir, to: newDir)
    }

    func removeSubscription(
        id: UUID,
        removedURL: String?,
        remainingURLs: [String],
        in directory: URL
    ) {
        cache.removeValue(forKey: id)
        fetchErrors.removeValue(forKey: id)
        SubscriptionFetcher.saveCache(cache, in: directory)
        if let removedURL {
            let trimmedRemoved = removedURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainingURLs.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedRemoved }) {
                SubscriptionFetcher.removePayload(for: removedURL, in: directory)
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
                let fetched = try await SubscriptionFetcher.fetchSubscription(
                    from: sub.url,
                    fallbackProxyPort: fallbackProxyPort,
                    cacheDirectory: cacheDirectory
                )
                self.cache[sub.id] = SubscriptionNodeCacheEntry(
                    nodes: fetched.nodes,
                    updatedAt: Date(),
                    usage: fetched.usage
                )
                SubscriptionFetcher.saveCache(self.cache, in: cacheDirectory)
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
}
