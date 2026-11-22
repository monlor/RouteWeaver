import Combine
import Foundation
import RoutingCore

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

    var hasNewerVersion: Bool {
        guard let latest = latestRelease, latestAsset != nil else { return false }
        guard let current = version else { return binary == nil }
        return MihomoConfig.compareVersions(current, latest.tagName) == .orderedAscending
    }

    var canResetToBundled: Bool {
        CoreBinaryManager.hasBundledBinary && source == .managed
    }

    func refresh() {
        let resolved = CoreBinaryManager.resolveBinary()
        binary = resolved.url
        source = resolved.source
        version = nil
        guard let url = resolved.url else { return }
        Task { @MainActor [weak self] in
            let detected = await CoreBinaryManager.readVersion(of: url)
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
            try CoreBinaryManager.removeManagedBinary()
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
                let (release, asset) = try await CoreBinaryManager.fetchLatestRelease(proxyPort: proxyPort)
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
                    let (release, fetchedAsset) = try await CoreBinaryManager.fetchLatestRelease(proxyPort: proxyPort)
                    self.latestRelease = release
                    self.latestAsset = fetchedAsset
                    asset = fetchedAsset
                }

                let (_, installedVersion) = try await CoreBinaryManager.installUpdate(asset: asset, proxyPort: proxyPort)
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
}
