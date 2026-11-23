import Foundation
import RoutingCore

struct PreloadReport: Sendable {
    var downloaded = 0
    var failed = 0
    var skippedReadOnly = 0
    var failureNotes: [String] = []
}

struct PreloadScanResult: Sendable {
    let missing: [PreloadResourceItem]
    let seededFromSubscriptionCache: Int
}

enum ResourcePreloader {
    static func cleanRelativePath(_ raw: String) -> String {
        raw.hasPrefix("./") ? String(raw.dropFirst(2)) : raw
    }

    static func syncUpdatedGeoFiles(from sourceDir: URL, to targetDir: URL) {
        let fm = FileManager.default
        for name in ["Country.mmdb", "geosite.dat"] {
            let src = sourceDir.appendingPathComponent(name)
            let dst = targetDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            let srcDate = (try? fm.attributesOfItem(atPath: src.path)[.modificationDate] as? Date) ?? .distantPast
            let dstDate = (try? fm.attributesOfItem(atPath: dst.path)[.modificationDate] as? Date) ?? .distantPast
            if !fm.fileExists(atPath: dst.path) || srcDate > dstDate {
                try? fm.removeItem(at: dst)
                try? fm.copyItem(at: src, to: dst)
            }
        }
    }

    static func scanMissing(
        _ items: [PreloadResourceItem],
        in targetDir: URL,
        syncFrom sourceDir: URL?,
        subscriptionCacheDirectory: URL
    ) -> PreloadScanResult {
        let fm = FileManager.default
        var missing: [PreloadResourceItem] = []
        var seededFromSubCache = 0

        for item in items {
            let rel = cleanRelativePath(item.relativePath)
            let dst = targetDir.appendingPathComponent(rel)
            let parent = dst.deletingLastPathComponent()
            try? fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

            // 1. For proxy-providers, prefer syncing from RouteWeaver's validated subscription payload cache
            //    whenever the destination is missing or older than the validated cache.
            if item.kind == .proxyProvider,
               let cachedData = SubscriptionStore.cachedPayloadData(for: item.url, in: subscriptionCacheDirectory) {
                let dstExistsAndValid: Bool = {
                    guard let existing = try? Data(contentsOf: dst), !existing.isEmpty else { return false }
                    return !SubscriptionParser.parse(existing).isEmpty
                }()
                let cacheDate = SubscriptionStore.cachedPayloadDate(for: item.url, in: subscriptionCacheDirectory) ?? .distantPast
                let dstDate = (try? fm.attributesOfItem(atPath: dst.path)[.modificationDate] as? Date) ?? .distantPast

                if !dstExistsAndValid || cacheDate > dstDate {
                    if fm.isWritableFile(atPath: parent.path) {
                        try? fm.removeItem(at: dst)
                        if (try? cachedData.write(to: dst, options: .atomic)) != nil {
                            seededFromSubCache += 1
                            continue
                        }
                    }
                } else {
                    continue
                }
            }

            // 2. Keep any existing non-empty (and for proxy-providers, parseable) file on disk; never overwrite.
            if let attrs = try? fm.attributesOfItem(atPath: dst.path),
               let size = attrs[.size] as? NSNumber,
               size.int64Value > 0 {
                if item.kind == .ruleProvider {
                    continue
                }
                if let existing = try? Data(contentsOf: dst), !SubscriptionParser.parse(existing).isEmpty {
                    continue
                }
            }

            // 3. Migrate from legacy directory (`providers/` or `rulesets/`) or non-TUN `workDir` if valid.
            let legacyRel = rel
                .replacingOccurrences(of: "providers-cache/", with: "providers/")
                .replacingOccurrences(of: "rulesets-cache/", with: "rulesets/")
            var candidateSources: [URL] = [targetDir.appendingPathComponent(legacyRel)]
            if let sourceDir {
                candidateSources.append(sourceDir.appendingPathComponent(rel))
                candidateSources.append(sourceDir.appendingPathComponent(legacyRel))
            }
            var migrated = false
            if fm.isWritableFile(atPath: parent.path) {
                for src in candidateSources {
                    guard let data = try? Data(contentsOf: src), !data.isEmpty else { continue }
                    if item.kind == .proxyProvider && SubscriptionParser.parse(data).isEmpty { continue }
                    try? fm.removeItem(at: dst)
                    if (try? data.write(to: dst, options: .atomic)) != nil {
                        migrated = true
                        break
                    }
                }
            }
            if migrated { continue }

            missing.append(item)
        }

        return PreloadScanResult(missing: missing, seededFromSubscriptionCache: seededFromSubCache)
    }

    static func download(
        _ items: [PreloadResourceItem],
        to targetDir: URL,
        subscriptionCacheDirectory: URL
    ) async -> PreloadReport {
        let fm = FileManager.default
        var writableItems: [PreloadResourceItem] = []
        var report = PreloadReport()

        for item in items {
            let rel = cleanRelativePath(item.relativePath)
            let dst = targetDir.appendingPathComponent(rel)
            let parent = dst.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) {
                try? fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            }
            if fm.isWritableFile(atPath: parent.path) {
                writableItems.append(item)
            } else {
                report.skippedReadOnly += 1
            }
        }

        guard !writableItems.isEmpty else { return report }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.connectionProxyDictionary = [
            "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
            "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0,
        ]
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let maxConcurrent = 6
        var index = 0
        while index < writableItems.count {
            let batchEnd = min(index + maxConcurrent, writableItems.count)
            let batch = Array(writableItems[index..<batchEnd])
            index = batchEnd

            await withTaskGroup(of: (Bool, String?).self) { group in
                for item in batch {
                    group.addTask {
                        guard let url = URL(string: item.url) else {
                            return (false, "\(item.key): 无效链接")
                        }
                        var request = URLRequest(url: url)
                        request.timeoutInterval = 12
                        request.setValue(
                            item.kind == .proxyProvider ? "clash.meta/1.19.27" : "RouteWeaver/1.0",
                            forHTTPHeaderField: "User-Agent"
                        )
                        request.setValue("*/*", forHTTPHeaderField: "Accept")
                        do {
                            let (data, response) = try await session.data(for: request)
                            guard let http = response as? HTTPURLResponse,
                                  (200...299).contains(http.statusCode),
                                  !data.isEmpty else {
                                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                                return (false, "\(item.key): HTTP \(code)")
                            }
                            if item.kind == .proxyProvider {
                                // Validate subscription content before writing; never overwrite existing cache with invalid data.
                                guard !SubscriptionParser.parse(data).isEmpty else {
                                    return (false, "\(item.key): 订阅内容无效或节点为空，未覆盖缓存")
                                }
                                _ = try? SubscriptionStore.saveValidatedPayload(data, for: item.url, in: subscriptionCacheDirectory)
                            }
                            let rel = cleanRelativePath(item.relativePath)
                            let dst = targetDir.appendingPathComponent(rel)
                            try? FileManager.default.removeItem(at: dst)
                            try data.write(to: dst, options: .atomic)
                            return (true, nil)
                        } catch {
                            return (false, "\(item.key): \(error.localizedDescription)")
                        }
                    }
                }

                for await (ok, errNote) in group {
                    if ok {
                        report.downloaded += 1
                    } else {
                        report.failed += 1
                        if let errNote { report.failureNotes.append(errNote) }
                    }
                }
            }
        }
        return report
    }
}
