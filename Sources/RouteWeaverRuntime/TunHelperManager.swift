import CryptoKit
import Darwin
import Foundation
import RoutingCore
import TunHelperProtocol

enum TunPermissionStatus: Equatable, Sendable {
    case ready
    case needsSync
    case notAuthorized
    case helperMissing

    var title: String {
        switch self {
        case .ready: return "已授权"
        case .needsSync: return "可用（待同步新版）"
        case .notAuthorized: return "未授权"
        case .helperMissing: return "缺少授权组件"
        }
    }

    var detail: String {
        switch self {
        case .ready:
            return "已安装并同步 root 权限组件，启停 TUN、局域网网关与在线更新 Mihomo 内核均无需重复输入密码。"
        case .needsSync:
            return "已授权的旧版受信任组件仍可正常启停 TUN 与网关（不会断网）；同步一次后即可启用新版组件与免密内核热更新。"
        case .notAuthorized:
            return "TUN 与局域网网关模式需要一次性管理员授权（安装受保护的辅助启动器），以创建 utun 虚拟网卡、监听 DNS 53 端口及开启 IP 转发。"
        case .helperMissing:
            return "未在应用包中找到 RouteWeaverTunHelper，请重新构建应用。"
        }
    }

    var isReady: Bool { self == .ready }

    /// Whether TUN / Gateway mode can safely launch right now using the installed root-owned helper and Mihomo binary.
    var canLaunchTun: Bool {
        switch self {
        case .ready, .needsSync:
            return true
        case .notAuthorized, .helperMissing:
            return false
        }
    }
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
    static let syncScriptURL = TunHelperPaths.installDirectoryURL.appendingPathComponent("sync-from-bundle.sh")
    static let sudoersFilePath = "/etc/sudoers.d/routeweaver"

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
        let hasSourceHelper = sourceHelperURL != nil
        let helperValid = isInstalledHelperValid()
        let mihomoValid = isInstalledMihomoValid()
        guard hasSourceHelper else { return .helperMissing }
        guard helperValid, mihomoValid else { return .notAuthorized }

        let installedHelperVer = cachedHelperVersion(at: installedHelperURL)
        let candidateExists = mihomoBinary.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
        let installedCoreVer = candidateExists ? cachedMihomoVersion(at: installedMihomoURL) : nil
        let candidateCoreVer = (candidateExists ? mihomoBinary : nil).flatMap { cachedMihomoVersion(at: $0) }
        let sameCoreHash: Bool? = {
            guard candidateExists, let mihomoBinary else { return nil }
            if mihomoBinary.standardizedFileURL == installedMihomoURL.standardizedFileURL {
                return true
            }
            if installedCoreVer != nil && candidateCoreVer != nil {
                return nil
            }
            return filesHaveSameSHA256(mihomoBinary, installedMihomoURL)
        }()

        return evaluateStatus(
            hasSourceHelper: hasSourceHelper,
            installedHelperValid: helperValid,
            installedMihomoValid: mihomoValid,
            installedHelperVersion: installedHelperVer,
            expectedHelperVersion: TunHelperPaths.helperVersion,
            hasCandidateMihomo: candidateExists,
            installedMihomoVersion: installedCoreVer,
            candidateMihomoVersion: candidateCoreVer,
            candidateMatchesInstalledSHA256: sameCoreHash
        )
    }

    /// Pure status evaluation used by `status(for:)` and unit tests.
    /// Decouples helper compatibility (checked by `helperVersion` rather than ad-hoc signature SHA-256)
    /// from core version progression (only flags `.needsSync` when candidate Mihomo is strictly newer).
    static func evaluateStatus(
        hasSourceHelper: Bool,
        installedHelperValid: Bool,
        installedMihomoValid: Bool,
        installedHelperVersion: String?,
        expectedHelperVersion: String = TunHelperPaths.helperVersion,
        hasCandidateMihomo: Bool,
        installedMihomoVersion: String?,
        candidateMihomoVersion: String?,
        candidateMatchesInstalledSHA256: Bool?
    ) -> TunPermissionStatus {
        guard hasSourceHelper else { return .helperMissing }
        guard installedHelperValid, installedMihomoValid else { return .notAuthorized }
        guard installedHelperVersion == expectedHelperVersion else {
            return .needsSync
        }
        if hasCandidateMihomo {
            if let installedVer = installedMihomoVersion, let candidateVer = candidateMihomoVersion {
                if MihomoConfig.compareVersions(installedVer, candidateVer) == .orderedAscending {
                    return .needsSync
                }
                return .ready
            }
            if let sameHash = candidateMatchesInstalledSHA256, !sameHash {
                return .needsSync
            }
        }
        return .ready
    }

    /// Returns true if the installed setuid helper matches the current protocol version and can perform
    /// passwordless root-side Mihomo release updates.
    static func canSelfUpdateMihomo(client: PrivilegedHelperClient = .live) -> Bool {
        guard client.isHelperInstalled, isInstalledHelperValid() else { return false }
        let res = client.executor.runHelper(.version)
        guard res.isSuccess,
              let ver = TunHelperPaths.parseHelperVersion(from: res.output) else {
            return false
        }
        return ver == TunHelperPaths.helperVersion
    }

    /// Updates `/Library/Application Support/RouteWeaver/mihomo` directly as root via `RouteWeaverTunHelper`
    /// without prompting for an administrator password, optionally kickstarting the active LaunchDaemon.
    static func updateMihomoViaHelper(
        downloadURL: String,
        expectedSHA256: String?,
        proxyPort: Int?,
        restartDaemon: Bool,
        client: PrivilegedHelperClient = .live
    ) async throws -> String? {
        let cmd = TunHelperCommand.updateMihomo(
            downloadURL: downloadURL,
            expectedSHA256: expectedSHA256,
            proxyPort: proxyPort,
            restartDaemon: restartDaemon
        )
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let res = try client.execute(cmd)
                    invalidateMetadataCache()
                    let parsed = parseUpdatedMihomoVersion(from: res.output)
                    continuation.resume(returning: parsed)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func parseUpdatedMihomoVersion(from output: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix(TunHelperPaths.updatedVersionOutputPrefix) {
                let ver = String(line.dropFirst(TunHelperPaths.updatedVersionOutputPrefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !ver.isEmpty { return ver }
            }
        }
        return nil
    }

    static func authorize(mihomoBinary: URL?) async throws {
        guard let sourceHelper = sourceHelperURL else {
            throw TunAuthorizationError.helperMissing
        }
        guard let mihomoBinary, FileManager.default.isExecutableFile(atPath: mihomoBinary.path) else {
            throw TunAuthorizationError.mihomoMissing
        }

        let shellCommand = buildAuthorizeShellCommand(
            sourceHelper: sourceHelper,
            mihomoBinary: mihomoBinary,
            bundlePath: Bundle.main.bundleURL.standardizedFileURL.path,
            adminUserName: NSUserName()
        )

        try await runPrivilegedShell(shellCommand, prompt: "RouteWeaver 需要一次性管理员权限以初始化 TUN 网关组件及后续自动免密更新配置。")
        invalidateMetadataCache()
    }

    /// Builds the root initialization script executed during one-time TUN authorization (or passwordless startup bootstrap).
    /// Handles `mihomoBinary == installedMihomoURL` safely without triggering `install: ... are the same file (64)`,
    /// uses atomic `.new` + `mv -f` swaps so a live Mihomo daemon never drops packets, and installs `sync-from-bundle.sh`
    /// plus `/etc/sudoers.d/routeweaver` so future app launches and updates sync silently without password prompts.
    static func buildAuthorizeShellCommand(
        sourceHelper: URL,
        mihomoBinary: URL,
        bundlePath: String,
        adminUserName: String
    ) -> String {
        let dir = shellQuote(installDirectory.path)
        let helperSrc = shellQuote(sourceHelper.standardizedFileURL.path)
        let helperDst = shellQuote(installedHelperURL.standardizedFileURL.path)
        let helperTmp = shellQuote(installedHelperURL.standardizedFileURL.path + ".new")
        let mihomoSrcPath = mihomoBinary.standardizedFileURL.path
        let mihomoDstPath = installedMihomoURL.standardizedFileURL.path
        let mihomoSrc = shellQuote(mihomoSrcPath)
        let mihomoDst = shellQuote(mihomoDstPath)
        let mihomoTmp = shellQuote(mihomoDstPath + ".new")
        let syncScript = shellQuote(syncScriptURL.path)
        let syncScriptTmp = shellQuote(syncScriptURL.path + ".tmp")
        let sudoersDst = shellQuote(sudoersFilePath)
        let bundleQuoted = shellQuote(bundlePath)
        let validSudoUser = adminUserName.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
                || $0 == "_" || $0 == "-" || $0 == "."
        } ? adminUserName : ""

        let mihomoInstallStep: String
        if mihomoSrcPath == mihomoDstPath {
            mihomoInstallStep = """
            /usr/sbin/chown root:wheel \(mihomoDst)
            /bin/chmod 0755 \(mihomoDst)
            /usr/bin/xattr -d com.apple.quarantine \(mihomoDst) 2>/dev/null || true
            """
        } else {
            mihomoInstallStep = """
            if [ \(mihomoSrc) != \(mihomoDst) ]; then
                /usr/bin/install -o root -g wheel -m 0755 \(mihomoSrc) \(mihomoTmp)
                /usr/bin/xattr -d com.apple.quarantine \(mihomoTmp) 2>/dev/null || true
                /bin/mv -f \(mihomoTmp) \(mihomoDst)
            else
                /usr/sbin/chown root:wheel \(mihomoDst)
                /bin/chmod 0755 \(mihomoDst)
                /usr/bin/xattr -d com.apple.quarantine \(mihomoDst) 2>/dev/null || true
            fi
            """
        }

        let sudoersStep: String
        if validSudoUser.isEmpty {
            sudoersStep = ""
        } else {
            sudoersStep = """
            SUDOERS_TMP="/tmp/routeweaver-sudoers.$$"
            /usr/bin/printf '%s ALL=(root) NOPASSWD: /Library/Application\\\\ Support/RouteWeaver/sync-from-bundle.sh\\n' \(shellQuote(validSudoUser)) > "$SUDOERS_TMP"
            if /usr/sbin/visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
                /usr/bin/install -o root -g wheel -m 0440 "$SUDOERS_TMP" \(sudoersDst)
            fi
            /bin/rm -f "$SUDOERS_TMP"
            """
        }

        return """
        set -e
        /bin/mkdir -p \(dir)
        /usr/sbin/chown root:wheel \(dir)
        /bin/chmod 0755 \(dir)
        \(mihomoInstallStep)
        if [ \(helperSrc) != \(helperDst) ]; then
            /usr/bin/install -o root -g wheel -m 4755 \(helperSrc) \(helperTmp)
            /usr/bin/xattr -d com.apple.quarantine \(helperTmp) 2>/dev/null || true
            /bin/mv -f \(helperTmp) \(helperDst)
        else
            /usr/sbin/chown root:wheel \(helperDst)
            /bin/chmod 4755 \(helperDst)
        fi
        /bin/cat > \(syncScriptTmp) <<'RW_SYNC_EOF'
        #!/bin/sh
        set -eu
        DIR="/Library/Application Support/RouteWeaver"
        PRIMARY_APP=\(bundleQuoted)
        FALLBACK_APP="/Applications/RouteWeaver.app"
        APP=""
        if [ -d "$PRIMARY_APP/Contents/Resources/bin" ]; then
            APP="$PRIMARY_APP"
        elif [ -d "$FALLBACK_APP/Contents/Resources/bin" ]; then
            APP="$FALLBACK_APP"
        else
            exit 0
        fi
        HELPER_SRC="$APP/Contents/Resources/bin/RouteWeaverTunHelper"
        MIHOMO_SRC="$APP/Contents/Resources/bin/mihomo"
        UPDATED=0

        /bin/mkdir -p "$DIR"
        /usr/sbin/chown root:wheel "$DIR"
        /bin/chmod 0755 "$DIR"

        if [ -f "$MIHOMO_SRC" ] && [ ! -L "$MIHOMO_SRC" ]; then
            NEED_MIHOMO=0
            if [ ! -x "$DIR/mihomo" ]; then
                NEED_MIHOMO=1
            else
                CUR_VER=$("$DIR/mihomo" -v 2>/dev/null | /usr/bin/awk '{for(i=1;i<=NF;i++) if($i ~ /^v[0-9]+\\./){print $i; exit}}' || true)
                NEW_VER=$("$MIHOMO_SRC" -v 2>/dev/null | /usr/bin/awk '{for(i=1;i<=NF;i++) if($i ~ /^v[0-9]+\\./){print $i; exit}}' || true)
                if [ -n "$CUR_VER" ] && [ -n "$NEW_VER" ] && [ "$CUR_VER" != "$NEW_VER" ]; then
                    HIGHEST=$(/usr/bin/printf '%s\\n%s\\n' "$CUR_VER" "$NEW_VER" | /usr/bin/sort -V | /usr/bin/tail -n 1)
                    if [ "$HIGHEST" = "$NEW_VER" ]; then
                        NEED_MIHOMO=1
                    fi
                fi
            fi
            if [ "$NEED_MIHOMO" = "1" ]; then
                /usr/bin/install -o root -g wheel -m 0755 "$MIHOMO_SRC" "$DIR/mihomo.new"
                /usr/bin/xattr -d com.apple.quarantine "$DIR/mihomo.new" 2>/dev/null || true
                /bin/mv -f "$DIR/mihomo.new" "$DIR/mihomo"
                UPDATED=1
            fi
        fi

        if [ -f "$HELPER_SRC" ] && [ ! -L "$HELPER_SRC" ]; then
            CUR_HELPER_VER=$("$DIR/tun-helper" --version 2>/dev/null || true)
            NEW_HELPER_VER=$("$HELPER_SRC" --version 2>/dev/null || true)
            if [ ! -u "$DIR/tun-helper" ] || [ "$CUR_HELPER_VER" != "$NEW_HELPER_VER" ]; then
                /usr/bin/install -o root -g wheel -m 4755 "$HELPER_SRC" "$DIR/tun-helper.new"
                /usr/bin/xattr -d com.apple.quarantine "$DIR/tun-helper.new" 2>/dev/null || true
                /bin/mv -f "$DIR/tun-helper.new" "$DIR/tun-helper"
                UPDATED=1
            fi
        fi

        if [ "$UPDATED" = "1" ] && /bin/launchctl print system/local.routeweaver.mihomo-tun >/dev/null 2>&1; then
            /bin/launchctl kickstart -k system/local.routeweaver.mihomo-tun >/dev/null 2>&1 || true
        fi
        RW_SYNC_EOF
        /usr/sbin/chown root:wheel \(syncScriptTmp)
        /bin/chmod 0755 \(syncScriptTmp)
        /bin/mv -f \(syncScriptTmp) \(syncScript)
        \(sudoersStep)
        """
    }

    /// Automatically checks and silently syncs TUN helper / Mihomo on app launch without any GUI prompt
    /// whenever passwordless sudo (`sync-from-bundle.sh` or `sudo -n`) is available.
    static func autoSyncOnLaunchIfPossible(mihomoBinary: URL?) async -> Bool {
        guard status(for: mihomoBinary) == .needsSync else { return false }
        let currentSourceHelper = sourceHelperURL
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        let userName = NSUserName()

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let executor = SystemPrivilegedHelperExecutor()
                if FileManager.default.isExecutableFile(atPath: syncScriptURL.path) {
                    let syncRes = executor.runExecutable(
                        URL(fileURLWithPath: "/usr/bin/sudo"),
                        arguments: ["-n", syncScriptURL.path]
                    )
                    if syncRes.isSuccess {
                        invalidateMetadataCache()
                        continuation.resume(returning: true)
                        return
                    }
                }

                // Fallback for headless Macs where general passwordless sudo is already configured:
                // bootstrap `sync-from-bundle.sh` + `/etc/sudoers.d/routeweaver` silently on launch.
                if let currentSourceHelper,
                   let mihomoBinary,
                   FileManager.default.isExecutableFile(atPath: mihomoBinary.path) {
                    let canSudo = executor.runExecutable(
                        URL(fileURLWithPath: "/usr/bin/sudo"),
                        arguments: ["-n", "true"]
                    )
                    if canSudo.isSuccess {
                        let cmd = buildAuthorizeShellCommand(
                            sourceHelper: currentSourceHelper,
                            mihomoBinary: mihomoBinary,
                            bundlePath: bundlePath,
                            adminUserName: userName
                        )
                        let bootstrapRes = executor.runExecutable(
                            URL(fileURLWithPath: "/usr/bin/sudo"),
                            arguments: ["-n", "/bin/sh", "-c", cmd]
                        )
                        if bootstrapRes.isSuccess {
                            invalidateMetadataCache()
                            continuation.resume(returning: true)
                            return
                        }
                    }
                }

                continuation.resume(returning: false)
            }
        }
    }

    /// Seamlessly restarts the running TUN LaunchDaemon via `launchctl kickstart -k` if loaded.
    static func kickstartTunDaemonIfLoaded() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let executor = SystemPrivilegedHelperExecutor()
                if FileManager.default.isExecutableFile(atPath: syncScriptURL.path) {
                    _ = executor.runExecutable(
                        URL(fileURLWithPath: "/usr/bin/sudo"),
                        arguments: ["-n", syncScriptURL.path]
                    )
                }
                continuation.resume()
            }
        }
    }

    static func revoke() async throws {
        let dir = shellQuote(installDirectory.path)
        let sudoersDst = shellQuote(sudoersFilePath)
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
        /bin/rm -f \(sudoersDst)
        /bin/rm -rf \(dir)
        """
        try await runPrivilegedShell(shellCommand, prompt: "RouteWeaver 需要管理员权限以移除 TUN 授权组件并清理断网保护规则。")
        invalidateMetadataCache()
    }

    // MARK: - Stat-Keyed Binary Version Cache & Validation Helpers

    private struct FileStatKey: Hashable, Sendable {
        let path: String
        let dev: dev_t
        let ino: ino_t
        let size: off_t
        let mtimeSec: Int
        let mtimeNsec: Int
    }

    private static let cacheLock = NSLock()
    private static var helperVersionCache: [FileStatKey: String] = [:]
    private static var mihomoVersionCache: [FileStatKey: String] = [:]

    static func invalidateMetadataCache() {
        cacheLock.lock()
        helperVersionCache.removeAll()
        mihomoVersionCache.removeAll()
        cacheLock.unlock()
    }

    private static func statKey(for url: URL) -> FileStatKey? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return FileStatKey(
            path: url.path,
            dev: st.st_dev,
            ino: st.st_ino,
            size: st.st_size,
            mtimeSec: st.st_mtimespec.tv_sec,
            mtimeNsec: st.st_mtimespec.tv_nsec
        )
    }

    private static func cachedHelperVersion(at url: URL) -> String? {
        guard let key = statKey(for: url) else { return nil }
        cacheLock.lock()
        if let hit = helperVersionCache[key] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        let res = SystemPrivilegedHelperExecutor(helperURL: url).runHelper(.version)
        guard res.isSuccess, let ver = TunHelperPaths.parseHelperVersion(from: res.output) else {
            return nil
        }
        cacheLock.lock()
        if helperVersionCache.count > 16 { helperVersionCache.removeAll() }
        helperVersionCache[key] = ver
        cacheLock.unlock()
        return ver
    }

    static func cachedMihomoVersion(at url: URL) -> String? {
        guard let key = statKey(for: url) else { return nil }
        cacheLock.lock()
        if let hit = mihomoVersionCache[key] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        let res = SystemPrivilegedHelperExecutor().runExecutable(url, arguments: ["-v"])
        guard res.isSuccess, let ver = MihomoConfig.parseVersion(from: res.output) else {
            return nil
        }
        cacheLock.lock()
        if mihomoVersionCache.count > 32 { mihomoVersionCache.removeAll() }
        mihomoVersionCache[key] = ver
        cacheLock.unlock()
        return ver
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
