import CryptoKit
import Darwin
import Foundation
import TunHelperProtocol

enum TunPermissionStatus: Equatable, Sendable {
    case ready
    case needsSync
    case notAuthorized
    case helperMissing

    var title: String {
        switch self {
        case .ready: return "已授权"
        case .needsSync: return "需要重新授权"
        case .notAuthorized: return "未授权"
        case .helperMissing: return "缺少授权组件"
        }
    }

    var detail: String {
        switch self {
        case .ready:
            return "已安装并同步 root 权限组件，启停 TUN 与局域网网关模式无需重复输入密码。"
        case .needsSync:
            return "检测到应用或 Mihomo 内核已更新，请重新授权以同步受信任的内核副本。"
        case .notAuthorized:
            return "TUN 与局域网网关模式需要一次性管理员授权（安装受保护的辅助启动器），以创建 utun 虚拟网卡、监听 DNS 53 端口及开启 IP 转发。"
        case .helperMissing:
            return "未在应用包中找到 RouteWeaverTunHelper，请重新构建应用。"
        }
    }

    var isReady: Bool { self == .ready }
}

enum TunAuthorizationError: LocalizedError {
    case helperMissing
    case mihomoMissing
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            return "未找到 RouteWeaverTunHelper 组件，请通过打包脚本重新构建应用。"
        case .mihomoMissing:
            return "请先安装 Mihomo 内核后再授权 TUN 权限。"
        case .cancelled:
            return "已取消管理员授权。"
        case .failed(let message):
            return "TUN 权限操作失败：\(message)"
        }
    }
}

enum TunHelperManager {
    static let installDirectory = TunHelperPaths.installDirectoryURL
    static let installedHelperURL = TunHelperPaths.installedHelperURL
    static let installedMihomoURL = TunHelperPaths.installedMihomoURL

    static var sourceHelperURL: URL? {
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/RouteWeaverTunHelper"),
           fm.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let sibling = execDir.appendingPathComponent("RouteWeaverTunHelper")
            if fm.isExecutableFile(atPath: sibling.path) {
                return sibling
            }
        }
        return nil
    }

    static func status(for mihomoBinary: URL?) -> TunPermissionStatus {
        guard let sourceHelper = sourceHelperURL else {
            return .helperMissing
        }
        guard isInstalledHelperValid(), isInstalledMihomoValid() else {
            return .notAuthorized
        }
        guard let helperMatch = filesHaveSameSHA256(sourceHelper, installedHelperURL), helperMatch else {
            return .needsSync
        }
        if let mihomoBinary, FileManager.default.isExecutableFile(atPath: mihomoBinary.path) {
            guard let coreMatch = filesHaveSameSHA256(mihomoBinary, installedMihomoURL), coreMatch else {
                return .needsSync
            }
        }
        return .ready
    }

    static func authorize(mihomoBinary: URL?) async throws {
        guard let sourceHelper = sourceHelperURL else {
            throw TunAuthorizationError.helperMissing
        }
        guard let mihomoBinary, FileManager.default.isExecutableFile(atPath: mihomoBinary.path) else {
            throw TunAuthorizationError.mihomoMissing
        }

        let dir = shellQuote(installDirectory.path)
        let helperSrc = shellQuote(sourceHelper.path)
        let helperDst = shellQuote(installedHelperURL.path)
        let mihomoSrc = shellQuote(mihomoBinary.path)
        let mihomoDst = shellQuote(installedMihomoURL.path)

        let shellCommand = """
        set -e
        /bin/mkdir -p \(dir)
        /usr/sbin/chown root:wheel \(dir)
        /bin/chmod 0755 \(dir)
        /usr/bin/install -o root -g wheel -m 0755 \(mihomoSrc) \(mihomoDst)
        /usr/bin/xattr -d com.apple.quarantine \(mihomoDst) 2>/dev/null || true
        /usr/bin/install -o root -g wheel -m 4755 \(helperSrc) \(helperDst)
        /usr/bin/xattr -d com.apple.quarantine \(helperDst) 2>/dev/null || true
        """

        try await runPrivilegedShell(shellCommand, prompt: "RouteWeaver 需要管理员权限以启用 TUN 透明代理与局域网网关模式。")
    }

    static func revoke() async throws {
        let dir = shellQuote(installDirectory.path)
        let daemonPlist = shellQuote(TunHelperPaths.tunDaemonPlistPath)
        let daemonTarget = shellQuote(TunHelperPaths.tunServiceTarget)
        let ksDaemonPlist = shellQuote(TunHelperPaths.killSwitchDaemonPlistPath)
        let ksDaemonTarget = shellQuote(TunHelperPaths.killSwitchServiceTarget)
        let ksTokenPath = shellQuote(TunHelperPaths.killSwitchTokenPath)
        let ksAnchor = shellQuote(TunHelperPaths.killSwitchAnchor)
        let shellCommand = """
        /bin/launchctl bootout \(daemonTarget) 2>/dev/null || true
        /bin/rm -f \(daemonPlist)
        /bin/launchctl bootout \(ksDaemonTarget) 2>/dev/null || true
        /bin/rm -f \(ksDaemonPlist)
        /sbin/pfctl -a \(ksAnchor) -F all 2>/dev/null || true
        if [ -f \(ksTokenPath) ]; then
            KS_TOKEN=$(/bin/cat \(ksTokenPath) 2>/dev/null || true)
            if [ -n "$KS_TOKEN" ]; then
                /sbin/pfctl -X "$KS_TOKEN" 2>/dev/null || true
            fi
        fi
        /bin/rm -rf \(dir)
        """
        try await runPrivilegedShell(shellCommand, prompt: "RouteWeaver 需要管理员权限以移除 TUN 授权组件并清理断网保护规则。")
    }

    // MARK: - Validation Helpers

    private static func isInstalledHelperValid() -> Bool {
        if case .success = ProcessInspector.verifyRootExecutable(at: installedHelperURL.path, requireSetuid: true) {
            return true
        }
        return false
    }

    private static func isInstalledMihomoValid() -> Bool {
        if case .success = ProcessInspector.verifyRootExecutable(at: installedMihomoURL.path, requireSetuid: false) {
            return true
        }
        return false
    }

    private static func filesHaveSameSHA256(_ lhs: URL, _ rhs: URL) -> Bool? {
        guard let a = sha256(of: lhs), let b = sha256(of: rhs) else { return nil }
        return a == b
    }

    private static func sha256(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            do {
                guard let chunk = try handle.read(upToCount: 262_144), !chunk.isEmpty else {
                    break
                }
                hasher.update(data: chunk)
            } catch {
                return nil
            }
        }
        return Data(hasher.finalize())
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func appleScriptEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func runPrivilegedShell(_ command: String, prompt: String) async throws {
        let script = "do shell script \"\(appleScriptEscape(command))\" with prompt \"\(appleScriptEscape(prompt))\" with administrator privileges"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                let errPipe = Pipe()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                proc.arguments = ["-e", script]
                proc.standardInput = FileHandle.nullDevice
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = errPipe

                do {
                    try proc.run()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    if proc.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let errText = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        if errText.contains("-128") || errText.localizedCaseInsensitiveContains("User canceled") {
                            continuation.resume(throwing: TunAuthorizationError.cancelled)
                        } else {
                            continuation.resume(throwing: TunAuthorizationError.failed(errText.isEmpty ? "退出码 \(proc.terminationStatus)" : errText))
                        }
                    }
                } catch {
                    continuation.resume(throwing: TunAuthorizationError.failed(error.localizedDescription))
                }
            }
        }
    }
}
