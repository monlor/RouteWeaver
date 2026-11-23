import Combine
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

@MainActor
final class CoreBinaryStore: ObservableObject {
    @Published private(set) var binary: URL?
    @Published private(set) var source: CoreBinarySource = .none
    @Published private(set) var version: String?
    @Published private(set) var latestRelease: MihomoRelease?
    @Published private(set) var latestAsset: MihomoReleaseAsset?
    @Published private(set) var isCheckingUpdate = false
    @Published private(set) var isUpdating = false
    @Published private(set) var updateMessage: String?
    @Published private(set) var updateError: String?
    @Published private(set) var pendingRestart = false

    private nonisolated static let latestReleaseAPI = URL(string: "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest")!

    nonisolated static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }

    var hasNewerVersion: Bool {
        guard let latest = latestRelease, latestAsset != nil else { return false }
        guard let current = version else { return binary == nil }
        return MihomoConfig.compareVersions(current, latest.tagName) == .orderedAscending
    }

    var canResetToBundled: Bool {
        Self.hasBundledBinary && source == .managed
    }

    func refresh() {
        let resolved = Self.resolveBinary()
        binary = resolved.url
        source = resolved.source
        version = nil
        guard let url = resolved.url else { return }
        Task { @MainActor [weak self] in
            let detected = await Self.readVersion(of: url)
            if self?.binary == url {
                self?.version = detected
            }
        }
    }

    func handleEngineStopped() {
        guard pendingRestart else { return }
        pendingRestart = false
        updateMessage = "新内核已就绪，点击「启动核心」即可生效。"
    }

    func resetToBundled(onSuccess: () -> Void) {
        do {
            try Self.removeManagedBinary()
            pendingRestart = false
            updateMessage = "已恢复 App 内置 Mihomo 内核。"
            updateError = nil
            refresh()
            onSuccess()
        } catch {
            updateError = "恢复内置内核失败：\(error.localizedDescription)"
        }
    }

    func checkForUpdate(proxyPort: Int?) {
        guard !isCheckingUpdate, !isUpdating else { return }
        isCheckingUpdate = true
        updateError = nil
        updateMessage = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isCheckingUpdate = false }
            do {
                let (release, asset) = try await Self.fetchLatestRelease(proxyPort: proxyPort)
                self.latestRelease = release
                self.latestAsset = asset
                if self.binary == nil {
                    self.updateMessage = "已找到最新内核 \(release.tagName)，点击「下载 \(release.tagName)」即可安装。"
                } else if self.hasNewerVersion {
                    self.updateMessage = "发现新版本 \(release.tagName)（当前 \(self.version ?? "未知")），可点击「更新到 \(release.tagName)」。"
                } else {
                    self.updateMessage = "当前内核 \(self.version ?? release.tagName) 已是最新版本。"
                }
            } catch {
                self.updateError = error.localizedDescription
            }
        }
    }

    func installUpdate(
        proxyPort: Int?,
        isEngineRunning: @escaping @MainActor () -> Bool,
        onInstalled: @escaping @MainActor (String) -> Void
    ) {
        guard !isUpdating else { return }
        isUpdating = true
        updateError = nil
        updateMessage = "正在下载并校验 Mihomo 内核…"

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isUpdating = false }
            do {
                let asset: MihomoReleaseAsset
                if let cached = self.latestAsset {
                    asset = cached
                } else {
                    let (release, fetchedAsset) = try await Self.fetchLatestRelease(proxyPort: proxyPort)
                    self.latestRelease = release
                    self.latestAsset = fetchedAsset
                    asset = fetchedAsset
                }

                let (_, installedVersion) = try await Self.installUpdateAsset(asset, proxyPort: proxyPort)
                self.refresh()
                self.version = installedVersion

                if isEngineRunning() {
                    self.pendingRestart = true
                    self.updateMessage = "已下载安装 \(installedVersion)，停止并重新启动核心后生效。"
                } else {
                    self.pendingRestart = false
                    self.updateMessage = "已更新至 Mihomo \(installedVersion)。"
                }
                onInstalled(installedVersion)
            } catch {
                self.updateMessage = nil
                self.updateError = error.localizedDescription
            }
        }
    }

    // MARK: - Binary Resolution & Update Internals

    private nonisolated static var managedDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RouteWeaver/Binaries", isDirectory: true)
    }

    private nonisolated static var managedBinaryURL: URL {
        managedDirectory.appendingPathComponent("mihomo")
    }

    private nonisolated static var bundledBinaryURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("bin/mihomo")
    }

    private nonisolated static var hasBundledBinary: Bool {
        guard let url = bundledBinaryURL else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    private nonisolated static var systemBinaryURLs: [URL] {
        [
            "/opt/homebrew/bin/mihomo",
            "/usr/local/bin/mihomo",
            "/usr/bin/mihomo",
        ]
        .map { URL(fileURLWithPath: $0) }
        .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private nonisolated static func resolveBinary() -> (url: URL?, source: CoreBinarySource) {
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

    private nonisolated static func readVersion(of binary: URL) async -> String? {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let output = runCommandOutput(executable: binary, arguments: ["-v"])
                continuation.resume(returning: output.flatMap { MihomoConfig.parseVersion(from: $0) })
            }
        }
    }

    private nonisolated static func fetchLatestRelease(proxyPort: Int?) async throws -> (release: MihomoRelease, asset: MihomoReleaseAsset) {
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

    private nonisolated static func installUpdateAsset(_ asset: MihomoReleaseAsset, proxyPort: Int?) async throws -> (url: URL, version: String) {
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

                    let ok = decompressGzip(from: tempDownloadURL, to: stagingURL)
                    guard ok, fm.fileExists(atPath: stagingURL.path) else {
                        throw CoreBinaryError.decompressionFailed
                    }

                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagingURL.path)

                    _ = runCommandStatus(executable: URL(fileURLWithPath: "/usr/bin/xattr"), arguments: ["-d", "com.apple.quarantine", stagingURL.path])
                    _ = runCommandStatus(executable: URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", stagingURL.path])

                    guard let versionOutput = runCommandOutput(executable: stagingURL, arguments: ["-v"]),
                          MihomoConfig.supportsVersionOutput(versionOutput),
                          let parsedVersion = MihomoConfig.parseVersion(from: versionOutput) else {
                        throw CoreBinaryError.invalidDownloadedBinary
                    }

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

    private nonisolated static func removeManagedBinary() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: managedBinaryURL.path) {
            try fm.removeItem(at: managedBinaryURL)
        }
    }

    private nonisolated static func makeSession(proxyPort: Int?, timeout: TimeInterval) -> URLSession {
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

    private nonisolated static func decompressGzip(from source: URL, to destination: URL) -> Bool {
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

    private nonisolated static func runCommandOutput(executable: URL, arguments: [String]) -> String? {
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

    private nonisolated static func runCommandStatus(executable: URL, arguments: [String]) -> Int32 {
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
