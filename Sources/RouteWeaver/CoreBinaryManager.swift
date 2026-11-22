import Foundation
import RoutingCore

enum CoreBinarySource: Equatable, Sendable {
    case managed
    case bundled
    case system
    case none

    var title: String {
        switch self {
        case .managed: return "已更新内核"
        case .bundled: return "内置内核"
        case .system: return "系统内核"
        case .none: return "未安装"
        }
    }
}

enum CoreBinaryError: LocalizedError {
    case invalidReleaseResponse
    case noMatchingAsset(String)
    case downloadFailed(Int)
    case decompressionFailed
    case invalidDownloadedBinary
    case fileOperationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidReleaseResponse:
            return "无法解析 GitHub Releases 响应，请稍后重试。"
        case .noMatchingAsset(let arch):
            return "未在最新发布中找到适用于 macOS (\(arch)) 的 Mihomo 安装包。"
        case .downloadFailed(let code):
            return "下载内核失败（HTTP \(code)）。若当前网络访问 GitHub 受限，可先启动核心再重试。"
        case .decompressionFailed:
            return "解压内核压缩包失败，下载文件可能不完整。"
        case .invalidDownloadedBinary:
            return "下载的内核版本校验未通过（需官方 Mihomo v\(MihomoConfig.minimumVersion) 或更新稳定版）。"
        case .fileOperationFailed(let detail):
            return "安装内核文件失败：\(detail)"
        }
    }
}

enum CoreBinaryManager {
    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest")!

    static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }

    static var managedDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RouteWeaver/Binaries", isDirectory: true)
    }

    static var managedBinaryURL: URL {
        managedDirectory.appendingPathComponent("mihomo")
    }

    static var bundledBinaryURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("bin/mihomo")
    }

    static var hasBundledBinary: Bool {
        guard let url = bundledBinaryURL else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    static var hasManagedBinary: Bool {
        FileManager.default.isExecutableFile(atPath: managedBinaryURL.path)
    }

    static var systemBinaryURLs: [URL] {
        [
            "/opt/homebrew/bin/mihomo",
            "/usr/local/bin/mihomo",
            "/usr/bin/mihomo",
        ]
        .map { URL(fileURLWithPath: $0) }
        .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func resolveBinary() -> (url: URL?, source: CoreBinarySource) {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: managedBinaryURL.path) {
            return (managedBinaryURL, .managed)
        }
        if let bundled = bundledBinaryURL, fm.isExecutableFile(atPath: bundled.path) {
            return (bundled, .bundled)
        }
        if let system = systemBinaryURLs.first {
            return (system, .system)
        }
        return (nil, .none)
    }

    static func readVersion(of binary: URL) async -> String? {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let output = runCommandOutput(executable: binary, arguments: ["-v"])
                continuation.resume(returning: output.flatMap { MihomoConfig.parseVersion(from: $0) })
            }
        }
    }

    static func fetchLatestRelease(proxyPort: Int?) async throws -> (release: MihomoRelease, asset: MihomoReleaseAsset) {
        let session = makeSession(proxyPort: proxyPort, timeout: 20)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("RouteWeaver/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CoreBinaryError.downloadFailed(code)
        }

        struct RawAsset: Decodable {
            let name: String
            let browser_download_url: String
            let size: Int64?
        }
        struct RawRelease: Decodable {
            let tag_name: String
            let html_url: String?
            let published_at: String?
            let assets: [RawAsset]
        }

        guard let decoded = try? JSONDecoder().decode(RawRelease.self, from: data) else {
            throw CoreBinaryError.invalidReleaseResponse
        }

        let assets = decoded.assets.compactMap { raw -> MihomoReleaseAsset? in
            guard let url = URL(string: raw.browser_download_url), url.scheme?.lowercased() == "https" else {
                return nil
            }
            return MihomoReleaseAsset(name: raw.name, downloadURL: url, size: raw.size ?? 0)
        }

        let release = MihomoRelease(
            tagName: decoded.tag_name,
            htmlURL: decoded.html_url.flatMap(URL.init(string:)),
            publishedAt: decoded.published_at,
            assets: assets
        )

        guard let asset = MihomoReleaseSelector.selectMacOSAsset(from: assets, arch: currentArchitecture) else {
            throw CoreBinaryError.noMatchingAsset(currentArchitecture)
        }
        return (release, asset)
    }

    static func installUpdate(asset: MihomoReleaseAsset, proxyPort: Int?) async throws -> (url: URL, version: String) {
        let session = makeSession(proxyPort: proxyPort, timeout: 120)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: asset.downloadURL)
        request.setValue("RouteWeaver/1.0", forHTTPHeaderField: "User-Agent")

        let (tempDownloadURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tempDownloadURL)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CoreBinaryError.downloadFailed(code)
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                defer { try? fm.removeItem(at: tempDownloadURL) }

                do {
                    try fm.createDirectory(at: managedDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let stagingURL = managedDirectory.appendingPathComponent("mihomo.staging-\(UUID().uuidString)")
                    defer { try? fm.removeItem(at: stagingURL) }

                    // Decompress .gz -> stagingURL
                    let ok = decompressGzip(from: tempDownloadURL, to: stagingURL)
                    guard ok, fm.fileExists(atPath: stagingURL.path) else {
                        throw CoreBinaryError.decompressionFailed
                    }

                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagingURL.path)

                    // Strip quarantine attribute if present and ad-hoc sign for Apple Silicon compatibility
                    _ = runCommandStatus(executable: URL(fileURLWithPath: "/usr/bin/xattr"), arguments: ["-d", "com.apple.quarantine", stagingURL.path])
                    _ = runCommandStatus(executable: URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", stagingURL.path])

                    // Verify binary version before installing
                    guard let versionOutput = runCommandOutput(executable: stagingURL, arguments: ["-v"]),
                          MihomoConfig.supportsVersionOutput(versionOutput),
                          let parsedVersion = MihomoConfig.parseVersion(from: versionOutput) else {
                        throw CoreBinaryError.invalidDownloadedBinary
                    }

                    // Atomically replace managed binary
                    if fm.fileExists(atPath: managedBinaryURL.path) {
                        _ = try fm.replaceItemAt(managedBinaryURL, withItemAt: stagingURL)
                    } else {
                        try fm.moveItem(at: stagingURL, to: managedBinaryURL)
                    }
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: managedBinaryURL.path)

                    continuation.resume(returning: (managedBinaryURL, parsedVersion))
                } catch let error as CoreBinaryError {
                    continuation.resume(throwing: error)
                } catch {
                    continuation.resume(throwing: CoreBinaryError.fileOperationFailed(error.localizedDescription))
                }
            }
        }
    }

    static func removeManagedBinary() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: managedBinaryURL.path) {
            try fm.removeItem(at: managedBinaryURL)
        }
    }

    // MARK: - Helpers

    private static func makeSession(proxyPort: Int?, timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = max(timeout, 120)
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

    private static func decompressGzip(from source: URL, to destination: URL) -> Bool {
        let fm = FileManager.default
        guard fm.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o700]),
              let outHandle = try? FileHandle(forWritingTo: destination) else {
            return false
        }
        defer { try? outHandle.close() }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        proc.arguments = ["-dc", source.path]
        proc.standardOutput = outHandle
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func runCommandOutput(executable: URL, arguments: [String]) -> String? {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = executable
        proc.arguments = arguments
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.standardInput = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    private static func runCommandStatus(executable: URL, arguments: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            return -1
        }
    }
}
