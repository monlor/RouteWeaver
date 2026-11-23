import Darwin
import Foundation
import SystemConfiguration
import TunHelperProtocol

// MARK: - Gateway Sysctl

private func readSysctlInt32(_ name: String) -> Int32? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    let rc = sysctlbyname(name, &value, &size, nil, 0)
    return rc == 0 ? value : nil
}

private func writeSysctlInt32(_ name: String, value: Int32) -> Bool {
    var newValue = value
    let rc = sysctlbyname(name, nil, nil, &newValue, MemoryLayout<Int32>.size)
    return rc == 0
}

private func loadGatewaySysctlState() -> GatewaySysctlState? {
    let fd = open(TunHelperPaths.gatewayStatePath, O_RDONLY)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var buf = [UInt8](repeating: 0, count: 256)
    let n = Darwin.read(fd, &buf, buf.count)
    guard n > 0 else { return nil }
    let text = String(decoding: buf.prefix(n), as: UTF8.self)
    return GatewaySysctlState.decodeText(text)
}

private func saveGatewaySysctlState(_ state: GatewaySysctlState) {
    let fd = open(TunHelperPaths.gatewayStatePath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { return }
    let bytes = Array(state.encodeText().utf8)
    _ = bytes.withUnsafeBytes { ptr in
        Darwin.write(fd, ptr.baseAddress, ptr.count)
    }
    _ = fchmod(fd, 0o644)
    close(fd)
}

private func enableGatewaySysctl() -> Bool {
    let existing = loadGatewaySysctlState()
    let prevForwarding = existing?.prevForwarding ?? readSysctlInt32("net.inet.ip.forwarding") ?? 0
    let prevRedirect = existing?.prevRedirect ?? readSysctlInt32("net.inet.ip.redirect") ?? 1
    saveGatewaySysctlState(GatewaySysctlState(prevForwarding: prevForwarding, prevRedirect: prevRedirect))

    guard writeSysctlInt32("net.inet.ip.forwarding", value: 1) else {
        writeStderr("RouteWeaverTunHelper: failed to enable net.inet.ip.forwarding (errno \(errno))")
        _ = unlink(TunHelperPaths.gatewayStatePath)
        return false
    }
    _ = writeSysctlInt32("net.inet.ip.redirect", value: 0)
    return true
}

private func restoreGatewaySysctlIfNeeded() {
    guard let saved = loadGatewaySysctlState() else { return }
    _ = writeSysctlInt32("net.inet.ip.forwarding", value: saved.prevForwarding)
    _ = writeSysctlInt32("net.inet.ip.redirect", value: saved.prevRedirect)
    _ = unlink(TunHelperPaths.gatewayStatePath)
}

// MARK: - System DNS Takeover & Restoration (Anti-DNS-Leak for TUN)

private func loadTunDNSState() -> TunDNSState? {
    guard let data = FileManager.default.contents(atPath: TunHelperPaths.tunDNSStatePath) else { return nil }
    return try? JSONDecoder().decode(TunDNSState.self, from: data)
}

private func saveTunDNSState(_ state: TunDNSState) {
    guard let data = try? JSONEncoder().encode(state) else { return }
    let fd = open(TunHelperPaths.tunDNSStatePath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { return }
    data.withUnsafeBytes { ptr in
        if let base = ptr.baseAddress {
            _ = Darwin.write(fd, base, ptr.count)
        }
    }
    _ = fchmod(fd, 0o644)
    close(fd)
}

private func resolveBSDName(for service: SCNetworkService) -> String? {
    var current = SCNetworkServiceGetInterface(service)
    var depth = 0
    while let iface = current, depth < 4 {
        if let bsd = SCNetworkInterfaceGetBSDName(iface) as String?, !bsd.isEmpty {
            return bsd
        }
        current = SCNetworkInterfaceGetInterface(iface)
        depth += 1
    }
    return nil
}

private func isEligibleDNSService(_ service: SCNetworkService) -> Bool {
    guard SCNetworkServiceGetEnabled(service) else { return false }
    guard let bsd = resolveBSDName(for: service) else { return false }
    return bsd.hasPrefix("en") || bsd.hasPrefix("bridge") || bsd.hasPrefix("bond")
}

private func takeoverSystemDNS() {
    guard let prefs = SCPreferencesCreate(nil, "RouteWeaverTunHelper" as CFString, nil) else {
        writeStderr("RouteWeaverTunHelper: failed to create SCPreferences for DNS takeover")
        return
    }
    guard SCPreferencesLock(prefs, true) else {
        writeStderr("RouteWeaverTunHelper: failed to lock SCPreferences for DNS takeover")
        return
    }
    defer { _ = SCPreferencesUnlock(prefs) }

    guard let networkSet = SCNetworkSetCopyCurrent(prefs),
          let services = SCNetworkSetCopyServices(networkSet) as? [SCNetworkService] else {
        return
    }

    var existingByID: [String: SavedServiceDNS] = [:]
    if let existing = loadTunDNSState() {
        for item in existing.services {
            existingByID[item.serviceID] = item
        }
    }

    var savedList: [SavedServiceDNS] = Array(existingByID.values)
    var modified = false

    for service in services where isEligibleDNSService(service) {
        guard let serviceID = SCNetworkServiceGetServiceID(service) as String?,
              let dnsProto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS) else {
            continue
        }
        var config = (SCNetworkProtocolGetConfiguration(dnsProto) as? [String: Any]) ?? [:]
        let currentServers = config[kSCPropNetDNSServerAddresses as String] as? [String]

        if existingByID[serviceID] == nil {
            let cleanOriginal: [String]?
            if let currentServers, !currentServers.isEmpty,
               currentServers != [TunHelperPaths.tunHijackDNSServer] {
                cleanOriginal = currentServers
            } else {
                cleanOriginal = nil
            }
            let entry = SavedServiceDNS(serviceID: serviceID, servers: cleanOriginal)
            existingByID[serviceID] = entry
            savedList.append(entry)
        }

        if currentServers != [TunHelperPaths.tunHijackDNSServer] {
            config[kSCPropNetDNSServerAddresses as String] = [TunHelperPaths.tunHijackDNSServer]
            if SCNetworkProtocolSetConfiguration(dnsProto, config as CFDictionary) {
                modified = true
            }
        }
    }

    guard !savedList.isEmpty else { return }
    saveTunDNSState(TunDNSState(services: savedList))

    if modified {
        if !SCPreferencesCommitChanges(prefs) || !SCPreferencesApplyChanges(prefs) {
            writeStderr("RouteWeaverTunHelper: failed to commit/apply system DNS takeover")
        }
    }
}

private func restoreSystemDNSIfNeeded() {
    guard let saved = loadTunDNSState() else { return }
    guard let prefs = SCPreferencesCreate(nil, "RouteWeaverTunHelper" as CFString, nil) else {
        writeStderr("RouteWeaverTunHelper: failed to create SCPreferences for DNS restore")
        return
    }
    guard SCPreferencesLock(prefs, true) else {
        writeStderr("RouteWeaverTunHelper: failed to lock SCPreferences for DNS restore")
        return
    }
    defer { _ = SCPreferencesUnlock(prefs) }

    var modified = false
    for item in saved.services {
        guard let service = SCNetworkServiceCopy(prefs, item.serviceID as CFString),
              let dnsProto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS) else {
            continue
        }
        var config = (SCNetworkProtocolGetConfiguration(dnsProto) as? [String: Any]) ?? [:]
        if let original = item.servers, !original.isEmpty {
            config[kSCPropNetDNSServerAddresses as String] = original
        } else {
            config.removeValue(forKey: kSCPropNetDNSServerAddresses as String)
        }
        if SCNetworkProtocolSetConfiguration(dnsProto, config as CFDictionary) {
            modified = true
        }
    }

    if modified {
        if !SCPreferencesCommitChanges(prefs) || !SCPreferencesApplyChanges(prefs) {
            writeStderr("RouteWeaverTunHelper: failed to commit/apply system DNS restore")
            return
        }
    }
    _ = unlink(TunHelperPaths.tunDNSStatePath)
}

// MARK: - Process & File Helpers

private func writeStderr(_ message: String) {
    let data = Array((message + "\n").utf8)
    _ = data.withUnsafeBytes { ptr in
        Darwin.write(STDERR_FILENO, ptr.baseAddress, ptr.count)
    }
}

private func writePidFile(_ pid: pid_t, to path: String) {
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { return }
    let bytes = Array("\(pid)\n".utf8)
    _ = bytes.withUnsafeBytes { ptr in
        Darwin.write(fd, ptr.baseAddress, ptr.count)
    }
    _ = fchmod(fd, 0o644)
    close(fd)
}

private func writeRootFileAtomically(_ data: Data, to targetPath: String) -> Bool {
    let tmpPath = targetPath + ".tmp"
    let fd = open(tmpPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { return false }
    var writtenAll = true
    data.withUnsafeBytes { ptr in
        guard let base = ptr.baseAddress else { return }
        var total = 0
        while total < ptr.count {
            let n = Darwin.write(fd, base.advanced(by: total), ptr.count - total)
            if n <= 0 {
                writtenAll = false
                break
            }
            total += n
        }
    }
    _ = fchown(fd, 0, 0)
    _ = fchmod(fd, 0o644)
    close(fd)
    guard writtenAll, rename(tmpPath, targetPath) == 0 else {
        _ = unlink(tmpPath)
        return false
    }
    return true
}

private func verifyAuthorizedMihomo() -> Bool {
    switch ProcessInspector.verifyRootExecutable(at: TunHelperPaths.authorizedMihomoPath, requireSetuid: false) {
    case .success:
        guard access(TunHelperPaths.authorizedMihomoPath, X_OK) == 0 else {
            writeStderr("RouteWeaverTunHelper: authorized mihomo is not executable")
            return false
        }
        return true
    case .failure(.notFound):
        writeStderr("RouteWeaverTunHelper: authorized mihomo binary not found at \(TunHelperPaths.authorizedMihomoPath)")
        return false
    case .failure(.notRegularFile):
        writeStderr("RouteWeaverTunHelper: authorized mihomo must be a regular file (symlinks rejected)")
        return false
    case .failure(.notOwnedByRoot):
        writeStderr("RouteWeaverTunHelper: authorized mihomo must be owned by root")
        return false
    case .failure(.worldWritable):
        writeStderr("RouteWeaverTunHelper: authorized mihomo must not be world-writable")
        return false
    case .failure(.notExecutable), .failure(.missingSetuid):
        writeStderr("RouteWeaverTunHelper: authorized mihomo is not executable")
        return false
    }
}

private func stopAuthorizedPid(_ pid: pid_t) -> Int32 {
    guard pid > 1 else {
        writeStderr("RouteWeaverTunHelper: invalid pid \(pid)")
        return 64
    }
    guard geteuid() == 0 else {
        writeStderr("RouteWeaverTunHelper: root privileges (setuid) are required")
        return 77
    }
    guard verifyAuthorizedMihomo() else { return 77 }

    if !ProcessInspector.isProcessAlive(pid) {
        _ = setgid(0)
        _ = setuid(0)
        restoreSystemDNSIfNeeded()
        restoreGatewaySysctlIfNeeded()
        return 0
    }
    guard let exePath = ProcessInspector.processExecutablePath(pid: pid),
          exePath == TunHelperPaths.authorizedMihomoPath else {
        writeStderr("RouteWeaverTunHelper: target pid \(pid) is not the authorized mihomo binary")
        return 77
    }

    _ = setgid(0)
    _ = setuid(0)

    if kill(pid, SIGTERM) != 0 {
        if errno == ESRCH {
            restoreSystemDNSIfNeeded()
            restoreGatewaySysctlIfNeeded()
            return 0
        }
        writeStderr("RouteWeaverTunHelper: failed to send SIGTERM to pid \(pid) (errno \(errno))")
        return 71
    }

    for _ in 0..<60 {
        if !ProcessInspector.isProcessAlive(pid) {
            restoreSystemDNSIfNeeded()
            restoreGatewaySysctlIfNeeded()
            return 0
        }
        usleep(50_000)
    }

    _ = kill(pid, SIGKILL)
    for _ in 0..<20 {
        if !ProcessInspector.isProcessAlive(pid) {
            restoreSystemDNSIfNeeded()
            restoreGatewaySysctlIfNeeded()
            return 0
        }
        usleep(50_000)
    }
    if !ProcessInspector.isProcessAlive(pid) {
        restoreSystemDNSIfNeeded()
        restoreGatewaySysctlIfNeeded()
        return 0
    }
    return 71
}

private func stopChild(_ pid: pid_t, kq: Int32) -> Int32 {
    _ = kill(pid, SIGTERM)
    var ev = kevent()
    var ts = timespec(tv_sec: 3, tv_nsec: 0)
    let n = kevent(kq, nil, 0, &ev, 1, &ts)
    if n <= 0 || ev.filter != EVFILT_PROC {
        _ = kill(pid, SIGKILL)
    }
    var status: Int32 = 0
    _ = waitpid(pid, &status, 0)
    return 0
}

private func exitCode(from waitStatus: Int32) -> Int32 {
    let sig = waitStatus & 0x7f
    if sig == 0 {
        return (waitStatus >> 8) & 0xff
    }
    return 128 + sig
}

private func runLaunchctl(_ arguments: [String]) -> Int32 {
    let launchctlPath = "/bin/launchctl"
    let argvStrings = [launchctlPath] + arguments
    let cArgv: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) } + [nil]
    defer { for ptr in cArgv { free(ptr) } }

    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)

    var pid: pid_t = 0
    let spawnErr = posix_spawn(&pid, launchctlPath, &fileActions, nil, cArgv, nil)
    guard spawnErr == 0, pid > 0 else { return 71 }
    var status: Int32 = 0
    _ = waitpid(pid, &status, 0)
    return exitCode(from: status)
}

// MARK: - LaunchDaemon Management

private func installTunDaemon(
    workDir: String,
    configPath: String,
    logFilePath: String,
    pidFilePath: String,
    gatewayMode: Bool
) -> Int32 {
    guard geteuid() == 0 else {
        writeStderr("RouteWeaverTunHelper: root privileges (setuid) are required")
        return 77
    }
    guard verifyAuthorizedMihomo() else { return 77 }
    var cfgStat = stat()
    guard stat(configPath, &cfgStat) == 0, (cfgStat.st_mode & S_IFMT) == S_IFREG else {
        writeStderr("RouteWeaverTunHelper: config file is missing or not a regular file")
        return 66
    }

    _ = setgid(0)
    _ = setuid(0)
    _ = runLaunchctl(["bootout", TunHelperPaths.tunServiceTarget])

    guard let data = try? TunHelperPlists.tunDaemonPlistData(
        workDir: workDir,
        configPath: configPath,
        logFilePath: logFilePath,
        pidFilePath: pidFilePath,
        gatewayMode: gatewayMode
    ) else {
        writeStderr("RouteWeaverTunHelper: failed to serialize LaunchDaemon plist")
        return 71
    }

    guard writeRootFileAtomically(data, to: TunHelperPaths.tunDaemonPlistPath) else {
        writeStderr("RouteWeaverTunHelper: failed to write LaunchDaemon plist")
        return 73
    }

    let bootstrapCode = runLaunchctl(["bootstrap", "system", TunHelperPaths.tunDaemonPlistPath])
    if bootstrapCode != 0 {
        _ = unlink(TunHelperPaths.tunDaemonPlistPath)
        writeStderr("RouteWeaverTunHelper: launchctl bootstrap failed with code \(bootstrapCode)")
        return 71
    }
    return 0
}

private func uninstallTunDaemon() -> Int32 {
    guard geteuid() == 0 else {
        writeStderr("RouteWeaverTunHelper: root privileges (setuid) are required")
        return 77
    }
    guard verifyAuthorizedMihomo() else { return 77 }
    _ = setgid(0)
    _ = setuid(0)

    _ = runLaunchctl(["bootout", TunHelperPaths.tunServiceTarget])
    _ = unlink(TunHelperPaths.tunDaemonPlistPath)
    usleep(150_000)
    restoreSystemDNSIfNeeded()
    restoreGatewaySysctlIfNeeded()
    return 0
}

// MARK: - PF Kill Switch

private func loadKillSwitchState() -> KillSwitchPersistedState? {
    let fd = open(TunHelperPaths.killSwitchStatePath, O_RDONLY)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var buf = [UInt8](repeating: 0, count: 512)
    let n = Darwin.read(fd, &buf, buf.count)
    guard n > 0 else { return nil }
    return KillSwitchPersistedState.decodeText(String(decoding: buf.prefix(n), as: UTF8.self))
}

private func saveKillSwitchState(_ state: KillSwitchPersistedState) {
    let fd = open(TunHelperPaths.killSwitchStatePath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { return }
    let bytes = Array(state.encodeText().utf8)
    _ = bytes.withUnsafeBytes { ptr in
        Darwin.write(fd, ptr.baseAddress, ptr.count)
    }
    _ = fchown(fd, 0, 0)
    _ = fchmod(fd, 0o644)
    close(fd)
}

private func readKillSwitchToken() -> String? {
    let fd = open(TunHelperPaths.killSwitchTokenPath, O_RDONLY)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var buf = [UInt8](repeating: 0, count: 256)
    let n = Darwin.read(fd, &buf, buf.count)
    guard n > 0 else { return nil }
    let token = String(decoding: buf.prefix(n), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return token.isEmpty ? nil : token
}

private func saveKillSwitchToken(_ token: String) {
    let fd = open(TunHelperPaths.killSwitchTokenPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { return }
    let bytes = Array((token + "\n").utf8)
    _ = bytes.withUnsafeBytes { ptr in
        Darwin.write(fd, ptr.baseAddress, ptr.count)
    }
    _ = fchown(fd, 0, 0)
    _ = fchmod(fd, 0o644)
    close(fd)
}

private func runPfctl(_ arguments: [String], stdin stdinText: String? = nil) -> (status: Int32, output: String) {
    let pfctlPath = "/sbin/pfctl"
    let argvStrings = [pfctlPath] + arguments
    let cArgv: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) } + [nil]
    defer { for ptr in cArgv { free(ptr) } }

    var outPipe: [Int32] = [-1, -1]
    guard pipe(&outPipe) == 0 else { return (71, "pipe failed") }

    var inPipe: [Int32] = [-1, -1]
    if stdinText != nil {
        guard pipe(&inPipe) == 0 else {
            close(outPipe[0])
            close(outPipe[1])
            return (71, "stdin pipe failed")
        }
    }

    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }

    if stdinText != nil {
        posix_spawn_file_actions_adddup2(&fileActions, inPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, inPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, inPipe[1])
    } else {
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    }
    posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], STDERR_FILENO)
    posix_spawn_file_actions_addclose(&fileActions, outPipe[0])
    posix_spawn_file_actions_addclose(&fileActions, outPipe[1])

    var pid: pid_t = 0
    let spawnErr = posix_spawn(&pid, pfctlPath, &fileActions, nil, cArgv, nil)
    close(outPipe[1])
    if stdinText != nil { close(inPipe[0]) }

    guard spawnErr == 0, pid > 0 else {
        close(outPipe[0])
        if stdinText != nil { close(inPipe[1]) }
        return (71, "posix_spawn pfctl failed (errno \(spawnErr))")
    }

    if let stdinText {
        let bytes = Array(stdinText.utf8)
        bytes.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var total = 0
            while total < ptr.count {
                let n = Darwin.write(inPipe[1], base.advanced(by: total), ptr.count - total)
                if n <= 0 { break }
                total += n
            }
        }
        close(inPipe[1])
    }

    var outputData = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = Darwin.read(outPipe[0], &buf, buf.count)
        if n > 0 {
            outputData.append(buf, count: n)
        } else if n < 0 && errno == EINTR {
            continue
        } else {
            break
        }
    }
    close(outPipe[0])

    var status: Int32 = 0
    _ = waitpid(pid, &status, 0)
    let text = String(decoding: outputData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return (exitCode(from: status), text)
}

private func isPFCurrentlyEnabled() -> Bool {
    let info = runPfctl(["-s", "info"])
    return info.status == 0 && info.output.contains("Status: Enabled")
}

private func isKillSwitchAnchorLoaded() -> Bool {
    let rules = runPfctl(["-a", TunHelperPaths.killSwitchAnchor, "-sr"])
    guard rules.status == 0 else { return false }
    return rules.output.contains("block drop out quick all")
}

private func installKillSwitchBootDaemon() -> Bool {
    guard let data = try? TunHelperPlists.killSwitchBootDaemonPlistData() else { return false }
    return writeRootFileAtomically(data, to: TunHelperPaths.killSwitchDaemonPlistPath)
}

private func removeKillSwitchBootDaemon() {
    _ = runLaunchctl(["bootout", TunHelperPaths.killSwitchServiceTarget])
    _ = unlink(TunHelperPaths.killSwitchDaemonPlistPath)
}

private func enableKillSwitch(allowLAN: Bool, persistOnBoot: Bool) -> Int32 {
    guard geteuid() == 0 else {
        writeStderr("RouteWeaverTunHelper: root privileges (setuid) are required")
        return 77
    }
    guard verifyAuthorizedMihomo() else { return 77 }
    _ = setgid(0)
    _ = setuid(0)

    let rules = TunHelperPFRules.renderKillSwitchPFConfig(allowLAN: allowLAN)
    let loadRes = runPfctl(["-a", TunHelperPaths.killSwitchAnchor, "-f", "-"], stdin: rules)
    guard loadRes.status == 0 else {
        writeStderr("RouteWeaverTunHelper: failed to load PF kill switch anchor: \(loadRes.output)")
        return 71
    }

    let pfAlreadyEnabled = isPFCurrentlyEnabled()
    let hasSavedToken = readKillSwitchToken() != nil
    if !pfAlreadyEnabled || !hasSavedToken {
        let enableRes = runPfctl(["-E"])
        guard enableRes.status == 0 else {
            _ = runPfctl(["-a", TunHelperPaths.killSwitchAnchor, "-F", "all"])
            writeStderr("RouteWeaverTunHelper: failed to enable PF: \(enableRes.output)")
            return 71
        }
        if let token = TunHelperPFRules.parsePFEnableToken(from: enableRes.output) {
            saveKillSwitchToken(token)
        }
    }

    saveKillSwitchState(KillSwitchPersistedState(enabled: true, allowLAN: allowLAN, persistOnBoot: persistOnBoot))
    if persistOnBoot {
        _ = installKillSwitchBootDaemon()
    } else {
        removeKillSwitchBootDaemon()
    }
    return 0
}

private func disableKillSwitch() -> Int32 {
    guard geteuid() == 0 else {
        writeStderr("RouteWeaverTunHelper: root privileges (setuid) are required")
        return 77
    }
    guard verifyAuthorizedMihomo() else { return 77 }
    _ = setgid(0)
    _ = setuid(0)

    _ = runPfctl(["-a", TunHelperPaths.killSwitchAnchor, "-F", "all"])
    if let token = readKillSwitchToken() {
        _ = runPfctl(["-X", token])
        _ = unlink(TunHelperPaths.killSwitchTokenPath)
    }
    removeKillSwitchBootDaemon()
    _ = unlink(TunHelperPaths.killSwitchStatePath)
    return 0
}

private func restoreKillSwitchOnBoot() -> Int32 {
    guard geteuid() == 0 else { return 77 }
    guard let state = loadKillSwitchState(), state.enabled, state.persistOnBoot else {
        return 0
    }
    _ = unlink(TunHelperPaths.killSwitchTokenPath)
    return enableKillSwitch(allowLAN: state.allowLAN, persistOnBoot: true)
}

private func queryKillSwitchStatus() -> Int32 {
    guard geteuid() == 0 else {
        writeStderr("RouteWeaverTunHelper: root privileges (setuid) are required")
        return 77
    }
    _ = setgid(0)
    _ = setuid(0)

    let pfEnabled = isPFCurrentlyEnabled()
    let anchorLoaded = isKillSwitchAnchorLoaded()
    let persisted = loadKillSwitchState()
    let report = KillSwitchStatusReport(
        isActive: pfEnabled && anchorLoaded,
        allowLAN: persisted?.allowLAN ?? true,
        persistOnBoot: persisted?.persistOnBoot ?? false,
        isPFEnabled: pfEnabled
    )
    let bytes = Array((report.encodeText() + "\n").utf8)
    _ = bytes.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
    return 0
}

// MARK: - Main Entrypoint

private func runMihomo(
    workDir: String,
    configPath: String,
    logFilePath: String?,
    pidFilePath: String?,
    gatewayMode: Bool,
    daemonRunMode: Bool
) -> Int32 {
    guard geteuid() == 0 else {
        writeStderr("RouteWeaverTunHelper: root privileges (setuid) are required")
        return 77
    }
    guard verifyAuthorizedMihomo() else { return 77 }

    var cfgStat = stat()
    guard stat(configPath, &cfgStat) == 0, (cfgStat.st_mode & S_IFMT) == S_IFREG else {
        writeStderr("RouteWeaverTunHelper: config file is missing or not a regular file")
        return 66
    }

    _ = signal(SIGPIPE, SIG_IGN)
    _ = signal(SIGHUP, SIG_IGN)
    var dedicatedGroups: [gid_t] = [TunHelperPaths.mihomoDedicatedGid]
    _ = setgroups(1, &dedicatedGroups)
    _ = setgid(TunHelperPaths.mihomoDedicatedGid)
    _ = setuid(0)
    if !daemonRunMode {
        _ = setsid()
    }

    if gatewayMode {
        guard enableGatewaySysctl() else { return 71 }
    }
    defer {
        if gatewayMode { restoreGatewaySysctlIfNeeded() }
    }

    var sigset = sigset_t()
    sigemptyset(&sigset)
    sigaddset(&sigset, SIGTERM)
    sigaddset(&sigset, SIGINT)
    _ = sigprocmask(SIG_BLOCK, &sigset, nil)

    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    if let logFilePath {
        posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, logFilePath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&fileActions, STDOUT_FILENO, STDERR_FILENO)
    }

    var spawnAttr: posix_spawnattr_t?
    posix_spawnattr_init(&spawnAttr)
    defer { posix_spawnattr_destroy(&spawnAttr) }
    var emptySet = sigset_t()
    sigemptyset(&emptySet)
    posix_spawnattr_setsigmask(&spawnAttr, &emptySet)
    posix_spawnattr_setflags(&spawnAttr, Int16(POSIX_SPAWN_SETSIGMASK))

    let argvStrings = [TunHelperPaths.authorizedMihomoPath, "-d", workDir, "-f", configPath]
    let envStrings = [
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME=\(workDir)",
    ]
    let cArgv: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) } + [nil]
    let cEnv: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
    defer {
        for ptr in cArgv { free(ptr) }
        for ptr in cEnv { free(ptr) }
    }

    var childPid: pid_t = 0
    let spawnErr = posix_spawn(&childPid, TunHelperPaths.authorizedMihomoPath, &fileActions, &spawnAttr, cArgv, cEnv)
    guard spawnErr == 0, childPid > 0 else {
        writeStderr("RouteWeaverTunHelper: posix_spawn failed with errno \(spawnErr)")
        return 71
    }

    if let pidFilePath {
        writePidFile(childPid, to: pidFilePath)
    }
    defer {
        restoreSystemDNSIfNeeded()
        if let pidFilePath { _ = unlink(pidFilePath) }
    }

    usleep(250_000)
    var earlyStatus: Int32 = 0
    if waitpid(childPid, &earlyStatus, WNOHANG) == childPid {
        return exitCode(from: earlyStatus)
    }
    takeoverSystemDNS()

    let kq = kqueue()
    guard kq >= 0 else {
        _ = kill(childPid, SIGTERM)
        var status: Int32 = 0
        _ = waitpid(childPid, &status, 0)
        return 71
    }
    defer { close(kq) }

    var changes: [kevent] = [
        kevent(
            ident: UInt(childPid),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT),
            data: 0,
            udata: nil
        ),
        kevent(
            ident: UInt(SIGTERM),
            filter: Int16(EVFILT_SIGNAL),
            flags: UInt16(EV_ADD | EV_ENABLE),
            fflags: 0,
            data: 0,
            udata: nil
        ),
        kevent(
            ident: UInt(SIGINT),
            filter: Int16(EVFILT_SIGNAL),
            flags: UInt16(EV_ADD | EV_ENABLE),
            fflags: 0,
            data: 0,
            udata: nil
        ),
    ]
    if !daemonRunMode {
        changes.append(
            kevent(
                ident: UInt(STDIN_FILENO),
                filter: Int16(EVFILT_READ),
                flags: UInt16(EV_ADD | EV_ENABLE),
                fflags: 0,
                data: 0,
                udata: nil
            )
        )
    }

    let regResult = changes.withUnsafeMutableBufferPointer { buf in
        kevent(kq, buf.baseAddress, Int32(buf.count), nil, 0, nil)
    }
    if regResult < 0 {
        var status: Int32 = 0
        if waitpid(childPid, &status, WNOHANG) == childPid {
            return exitCode(from: status)
        }
        return stopChild(childPid, kq: kq)
    }

    while true {
        var ev = kevent()
        let n = kevent(kq, nil, 0, &ev, 1, nil)
        if n < 0 {
            if errno == EINTR { continue }
            return stopChild(childPid, kq: kq)
        }
        if n == 0 { continue }

        switch Int32(ev.filter) {
        case EVFILT_PROC:
            var status: Int32 = 0
            _ = waitpid(childPid, &status, 0)
            return exitCode(from: status)

        case EVFILT_READ:
            var buf = [UInt8](repeating: 0, count: 64)
            let bytesRead = Darwin.read(STDIN_FILENO, &buf, buf.count)
            if bytesRead <= 0 {
                var removeStdin = kevent(
                    ident: UInt(STDIN_FILENO),
                    filter: Int16(EVFILT_READ),
                    flags: UInt16(EV_DELETE),
                    fflags: 0,
                    data: 0,
                    udata: nil
                )
                _ = kevent(kq, &removeStdin, 1, nil, 0, nil)
                continue
            }
            let text = String(decoding: buf.prefix(bytesRead), as: UTF8.self)
            if text.contains("stop") {
                return stopChild(childPid, kq: kq)
            }

        case EVFILT_SIGNAL:
            return stopChild(childPid, kq: kq)

        default:
            break
        }
    }
}

private func runHelper() -> Int32 {
    let command: TunHelperCommand
    do {
        command = try TunHelperCommand.parse(Array(CommandLine.arguments.dropFirst()))
    } catch let error as TunHelperCommandError {
        writeStderr(error.message)
        return 64
    } catch {
        writeStderr("RouteWeaverTunHelper: \(error.localizedDescription)")
        return 64
    }

    switch command {
    case .version:
        let out = Array("RouteWeaverTunHelper \(TunHelperPaths.helperVersion)\n".utf8)
        _ = out.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
        return 0
    case .killSwitchStatus:
        return queryKillSwitchStatus()
    case .killSwitchEnable(let allowLAN, let persistOnBoot):
        return enableKillSwitch(allowLAN: allowLAN, persistOnBoot: persistOnBoot)
    case .killSwitchDisable:
        return disableKillSwitch()
    case .killSwitchRestore:
        return restoreKillSwitchOnBoot()
    case .uninstallDaemon:
        return uninstallTunDaemon()
    case .installDaemon(let workDir, let configPath, let logFilePath, let pidFilePath, let gatewayMode):
        return installTunDaemon(
            workDir: workDir,
            configPath: configPath,
            logFilePath: logFilePath,
            pidFilePath: pidFilePath,
            gatewayMode: gatewayMode
        )
    case .stopPid(let pid):
        return stopAuthorizedPid(pid)
    case .run(let workDir, let configPath, let logFilePath, let pidFilePath, let gatewayMode, let daemonRunMode):
        return runMihomo(
            workDir: workDir,
            configPath: configPath,
            logFilePath: logFilePath,
            pidFilePath: pidFilePath,
            gatewayMode: gatewayMode,
            daemonRunMode: daemonRunMode
        )
    }
}

exit(runHelper())
