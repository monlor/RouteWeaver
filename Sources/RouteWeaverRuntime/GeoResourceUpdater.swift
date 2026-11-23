import Foundation
import RoutingCore

enum GeoResourceUpdater {
    static var bundledDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("bundled", isDirectory: true)
    }

    static func loadBundledManifest() -> BundledResourceManifest? {
        guard let dir = bundledDirectory else { return nil }
        let manifestURL = dir.appendingPathComponent(BundledResourceManager.manifestFileName)
        return try? BundledResourceManifest.load(from: manifestURL)
    }

    @discardableResult
    static func seedIfNeeded(to workDir: URL) -> ResourceSeedReport? {
        guard let dir = bundledDirectory, let manifest = loadBundledManifest() else {
            return nil
        }
        return try? BundledResourceManager.seedMissingResources(from: dir, to: workDir, manifest: manifest)
    }

    static func updateAll(
        in workDir: URL,
        proxyPort: Int?
    ) async -> [(entry: BundledResourceEntry, outcome: ResourceUpdateOutcome)] {
        guard let dir = bundledDirectory, let manifest = loadBundledManifest() else {
            return []
        }

        let session = makeSession(proxyPort: proxyPort, timeout: 45)
        defer { session.finishTasksAndInvalidate() }

        var results: [(entry: BundledResourceEntry, outcome: ResourceUpdateOutcome)] = []
        for entry in manifest.entries {
            let dest = workDir.appendingPathComponent(entry.relativePath)
            let bundledFallback = dir.appendingPathComponent(entry.relativePath)
            let outcome = await updateSingle(
                entry: entry,
                destination: dest,
                bundledFallback: bundledFallback,
                session: session
            )
            results.append((entry, outcome))
        }
        return results
    }

    private static func updateSingle(
        entry: BundledResourceEntry,
        destination: URL,
        bundledFallback: URL,
        session: URLSession
    ) async -> ResourceUpdateOutcome {
        var lastError = "无可用下载地址。"

        for rawURL in entry.candidateURLs {
            guard let url = URL(string: rawURL), url.scheme?.lowercased() == "https" else { continue }
            var request = URLRequest(url: url)
            request.setValue("RouteWeaver/1.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 45

            do {
                let (tempURL, response) = try await session.download(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    try? FileManager.default.removeItem(at: tempURL)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    lastError = "HTTP \(code)"
                    continue
                }

                let outcome = BundledResourceManager.installValidatedUpdate(
                    tempFile: tempURL,
                    kind: entry.kind,
                    destination: destination,
                    bundledFallback: bundledFallback,
                    bundledExpectedSHA256: entry.sha256.isEmpty ? nil : entry.sha256
                )
                if outcome == .updated {
                    return .updated
                }
                if case .keptExistingAfterFailure(let reason) = outcome {
                    lastError = reason
                } else if case .restoredBundledAfterFailure(let reason) = outcome {
                    lastError = reason
                } else if case .failedWithoutFallback(let reason) = outcome {
                    lastError = reason
                }
            } catch {
                lastError = error.localizedDescription
            }
        }

        // All candidate URLs failed: ensure existing valid cache is kept, or restore bundled if missing/corrupted.
        if (try? ResourceIntegrityValidator.validateFile(at: destination, kind: entry.kind)) != nil {
            return .keptExistingAfterFailure(lastError)
        }
        let dummyEmptyTemp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-geo-fallback-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: dummyEmptyTemp.path, contents: Data())
        return BundledResourceManager.installValidatedUpdate(
            tempFile: dummyEmptyTemp,
            kind: entry.kind,
            destination: destination,
            bundledFallback: bundledFallback,
            bundledExpectedSHA256: entry.sha256.isEmpty ? nil : entry.sha256
        )
    }

    private static func makeSession(proxyPort: Int?, timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = max(timeout, 90)
        if let proxyPort {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPPort as String: proxyPort,
                kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPSPort as String: proxyPort,
            ]
        }
        return URLSession(configuration: config)
    }
}
