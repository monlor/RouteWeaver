import Darwin
import Foundation
import SystemConfiguration

private let authorizedMihomoPath = "/Library/Application Support/RouteWeaver/mihomo"
private let gatewayStatePath = "/Library/Application Support/RouteWeaver/gateway-sysctl.state"
private let tunDNSStatePath = "/Library/Application Support/RouteWeaver/tun-dns.state"
private let tunHijackDNSServer = "198.18.0.2"
private let helperVersion = "4"

private struct GatewaySysctlState {
    var prevForwarding: Int32
    var prevRedirect: Int32
}

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
    let fd = open(gatewayStatePath, O_RDONLY)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var buf = [UInt8](repeating: 0, count: 256)
    let n = Darwin.read(fd, &buf, buf.count)
    guard n > 0 else { return nil }
    let text = String(decoding: buf.prefix(n), as: UTF8.self)
    var prevForwarding: Int32?
    var prevRedirect: Int32?
    for line in text.split(whereSeparator: \.isNewline) {
        let parts = line.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        if parts[0] == "prev_forwarding", let v = Int32(parts[1]) {
            prevForwarding = v
        } else if parts[0] == "prev_redirect", let v = Int32(parts[1]) {
            prevRedirect = v
        }
    }
    guard let prevForwarding, let prevRedirect else { return nil }
    return GatewaySysctlState(prevForwarding: prevForwarding, prevRedirect: prevRedirect)
}

private func saveGatewaySysctlState(_ state: GatewaySysctlState) {
    let fd = open(gatewayStatePath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { return }
    let text = "prev_forwarding=\(state.prevForwarding)\nprev_redirect=\(state.prevRedirect)\n"
    let bytes = Array(text.utf8)
    _ = bytes.withUnsafeBytes { ptr in
        Darwin.write(fd, ptr.baseAddress, ptr.count)
    }
    _ = fchmod(fd, 0o644)
    close(fd)
}

private func enableGatewaySysctl() -> Bool {
    // Preserve original pre-gateway values if a previous gateway session crashed without restoring.
    let existing = loadGatewaySysctlState()
    let prevForwarding = existing?.prevForwarding ?? readSysctlInt32("net.inet.ip.forwarding") ?? 0
    let prevRedirect = existing?.prevRedirect ?? readSysctlInt32("net.inet.ip.redirect") ?? 1
    saveGatewaySysctlState(GatewaySysctlState(prevForwarding: prevForwarding, prevRedirect: prevRedirect))

    guard writeSysctlInt32("net.inet.ip.forwarding", value: 1) else {
        writeStderr("RouteWeaverTunHelper: failed to enable net.inet.ip.forwarding (errno \(errno))")
        _ = unlink(gatewayStatePath)
        return false
    }
    // Disable ICMP redirects so LAN clients on the same subnet do not bypass this gateway.
    _ = writeSysctlInt32("net.inet.ip.redirect", value: 0)
    return true
}

private func restoreGatewaySysctlIfNeeded() {
    guard let saved = loadGatewaySysctlState() else { return }
    _ = writeSysctlInt32("net.inet.ip.forwarding", value: saved.prevForwarding)
    _ = writeSysctlInt32("net.inet.ip.redirect", value: saved.prevRedirect)
    _ = unlink(gatewayStatePath)
}

// MARK: - System DNS Takeover & Restoration (Anti-DNS-Leak for TUN)

private struct SavedServiceDNS: Codable {
    var serviceID: String
    var servers: [String]?
}

private struct TunDNSState: Codable {
    var services: [SavedServiceDNS]
}

private func loadTunDNSState() -> TunDNSState? {
    guard let data = FileManager.default.contents(atPath: tunDNSStatePath) else { return nil }
    return try? JSONDecoder().decode(TunDNSState.self, from: data)
}

private func saveTunDNSState(_ state: TunDNSState) {
    guard let data = try? JSONEncoder().encode(state) else { return }
    let fd = open(tunDNSStatePath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
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

    // Preserve any previously saved pre-TUN DNS state if a prior session crashed before restoring.
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
               currentServers != [tunHijackDNSServer] {
                cleanOriginal = currentServers
            } else {
                cleanOriginal = nil
            }
            let entry = SavedServiceDNS(serviceID: serviceID, servers: cleanOriginal)
            existingByID[serviceID] = entry
            savedList.append(entry)
        }

        if currentServers != [tunHijackDNSServer] {
            config[kSCPropNetDNSServerAddresses as String] = [tunHijackDNSServer]
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
    _ = unlink(tunDNSStatePath)
}

private let procPidPathMaxSize = 4096

@_silgen_name("proc_pidpath")
private func c_proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer?, _ buffersize: UInt32) -> Int32

private func processExecutablePath(pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: procPidPathMaxSize)
    let length = buffer.withUnsafeMutableBytes { ptr in
        c_proc_pidpath(pid, ptr.baseAddress, UInt32(procPidPathMaxSize))
    }
    guard length > 0 else { return nil }
    return String(cString: buffer)
}

private func isProcessAlive(_ pid: pid_t) -> Bool {
    guard pid > 1 else { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
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
    guard verifyAuthorizedMihomo() else {
        return 77
    }
    if !isProcessAlive(pid) {
        _ = setgid(0)
        _ = setuid(0)
        restoreSystemDNSIfNeeded()
        restoreGatewaySysctlIfNeeded()
        return 0
    }
    guard let exePath = processExecutablePath(pid: pid), exePath == authorizedMihomoPath else {
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
        if !isProcessAlive(pid) {
            restoreSystemDNSIfNeeded()
            restoreGatewaySysctlIfNeeded()
            return 0
        }
        usleep(50_000)
    }

    _ = kill(pid, SIGKILL)
    for _ in 0..<20 {
        if !isProcessAlive(pid) {
            restoreSystemDNSIfNeeded()
            restoreGatewaySysctlIfNeeded()
            return 0
        }
        usleep(50_000)
    }
    if !isProcessAlive(pid) {
        restoreSystemDNSIfNeeded()
        restoreGatewaySysctlIfNeeded()
        return 0
    }
    return 71
}

private func writePidFile(_ pid: pid_t, to path: String) {
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { return }
    let text = "\(pid)\n"
    let bytes = Array(text.utf8)
    _ = bytes.withUnsafeBytes { ptr in
        Darwin.write(fd, ptr.baseAddress, ptr.count)
    }
    _ = fchmod(fd, 0o644)
    close(fd)
}

private func writeStderr(_ message: String) {
    let data = Array((message + "\n").utf8)
    _ = data.withUnsafeBytes { ptr in
        Darwin.write(STDERR_FILENO, ptr.baseAddress, ptr.count)
    }
}

private func isSafeAbsolutePath(_ path: String) -> Bool {
    guard path.hasPrefix("/"), !path.isEmpty, !path.contains("\0") else { return false }
    let components = path.split(separator: "/")
    return !components.contains("..")
}

private func verifyAuthorizedMihomo() -> Bool {
    var st = stat()
    guard lstat(authorizedMihomoPath, &st) == 0 else {
        writeStderr("RouteWeaverTunHelper: authorized mihomo binary not found at \(authorizedMihomoPath)")
        return false
    }
    guard (st.st_mode & S_IFMT) == S_IFREG else {
        writeStderr("RouteWeaverTunHelper: authorized mihomo must be a regular file (symlinks rejected)")
        return false
    }
    guard st.st_uid == 0 else {
        writeStderr("RouteWeaverTunHelper: authorized mihomo must be owned by root")
        return false
    }
    guard (st.st_mode & 0o002) == 0 else {
        writeStderr("RouteWeaverTunHelper: authorized mihomo must not be world-writable")
        return false
    }
    guard access(authorizedMihomoPath, X_OK) == 0 else {
        writeStderr("RouteWeaverTunHelper: authorized mihomo is not executable")
        return false
    }
    return true
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

private func runHelper() -> Int32 {
    let args = CommandLine.arguments
    if args.count == 2 && args[1] == "--version" {
        let out = Array("RouteWeaverTunHelper \(helperVersion)\n".utf8)
        _ = out.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
        return 0
    }

    var workDir: String?
    var configPath: String?
    var logFilePath: String?
    var pidFilePath: String?
    var stopPid: pid_t?
    var gatewayMode = false
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--work-dir":
            if i + 1 < args.count {
                workDir = args[i + 1]
                i += 2
            } else {
                writeStderr("RouteWeaverTunHelper: missing value for --work-dir")
                return 64
            }
        case "--config":
            if i + 1 < args.count {
                configPath = args[i + 1]
                i += 2
            } else {
                writeStderr("RouteWeaverTunHelper: missing value for --config")
                return 64
            }
        case "--log-file":
            if i + 1 < args.count {
                logFilePath = args[i + 1]
                i += 2
            } else {
                writeStderr("RouteWeaverTunHelper: missing value for --log-file")
                return 64
            }
        case "--pid-file":
            if i + 1 < args.count {
                pidFilePath = args[i + 1]
                i += 2
            } else {
                writeStderr("RouteWeaverTunHelper: missing value for --pid-file")
                return 64
            }
        case "--gateway":
            gatewayMode = true
            i += 1
        case "--stop-pid":
            if i + 1 < args.count, let parsed = Int32(args[i + 1]), parsed > 1 {
                stopPid = pid_t(parsed)
                i += 2
            } else {
                writeStderr("RouteWeaverTunHelper: valid pid is required for --stop-pid")
                return 64
            }
        default:
            writeStderr("RouteWeaverTunHelper: unknown argument \(args[i])")
            return 64
        }
    }

    if let stopPid {
        return stopAuthorizedPid(stopPid)
    }

    guard let workDir, let configPath,
          isSafeAbsolutePath(workDir),
          isSafeAbsolutePath(configPath) else {
        writeStderr("RouteWeaverTunHelper: valid absolute --work-dir and --config paths are required")
        return 64
    }

    if let logFilePath, !isSafeAbsolutePath(logFilePath) {
        writeStderr("RouteWeaverTunHelper: invalid --log-file path")
        return 64
    }

    if let pidFilePath, !isSafeAbsolutePath(pidFilePath) {
        writeStderr("RouteWeaverTunHelper: invalid --pid-file path")
        return 64
    }

    guard geteuid() == 0 else {
        writeStderr("RouteWeaverTunHelper: root privileges (setuid) are required")
        return 77
    }

    guard verifyAuthorizedMihomo() else {
        return 77
    }

    var cfgStat = stat()
    guard stat(configPath, &cfgStat) == 0, (cfgStat.st_mode & S_IFMT) == S_IFREG else {
        writeStderr("RouteWeaverTunHelper: config file is missing or not a regular file")
        return 66
    }

    _ = signal(SIGPIPE, SIG_IGN)
    _ = signal(SIGHUP, SIG_IGN)
    _ = setgid(0)
    _ = setuid(0)
    _ = setsid()

    if gatewayMode {
        guard enableGatewaySysctl() else {
            return 71
        }
    }
    defer {
        if gatewayMode {
            restoreGatewaySysctlIfNeeded()
        }
    }

    // Block SIGTERM/SIGINT so kqueue EVFILT_SIGNAL receives them synchronously
    var sigset = sigset_t()
    sigemptyset(&sigset)
    sigaddset(&sigset, SIGTERM)
    sigaddset(&sigset, SIGINT)
    _ = sigprocmask(SIG_BLOCK, &sigset, nil)

    // Spawn Mihomo with stdin redirected to /dev/null so this helper exclusively owns STDIN_FILENO
    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    if let logFilePath {
        // Redirect stdout/stderr to a regular log file so Mihomo survives parent UI exit without SIGPIPE
        posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, logFilePath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&fileActions, STDOUT_FILENO, STDERR_FILENO)
    }

    // Reset signal mask for child so Mihomo receives SIGTERM normally
    var spawnAttr: posix_spawnattr_t?
    posix_spawnattr_init(&spawnAttr)
    defer { posix_spawnattr_destroy(&spawnAttr) }
    var emptySet = sigset_t()
    sigemptyset(&emptySet)
    posix_spawnattr_setsigmask(&spawnAttr, &emptySet)
    posix_spawnattr_setflags(&spawnAttr, Int16(POSIX_SPAWN_SETSIGMASK))

    let argvStrings = [authorizedMihomoPath, "-d", workDir, "-f", configPath]
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
    let spawnErr = posix_spawn(&childPid, authorizedMihomoPath, &fileActions, &spawnAttr, cArgv, cEnv)
    guard spawnErr == 0, childPid > 0 else {
        writeStderr("RouteWeaverTunHelper: posix_spawn failed with errno \(spawnErr)")
        return 71
    }

    if let pidFilePath {
        writePidFile(childPid, to: pidFilePath)
    }
    defer {
        restoreSystemDNSIfNeeded()
        if let pidFilePath {
            _ = unlink(pidFilePath)
        }
    }

    // Give Mihomo a brief moment to initialize TUN; if it already exited, skip DNS takeover.
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
            ident: UInt(STDIN_FILENO),
            filter: Int16(EVFILT_READ),
            flags: UInt16(EV_ADD | EV_ENABLE),
            fflags: 0,
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

    let regResult = changes.withUnsafeMutableBufferPointer { buf in
        kevent(kq, buf.baseAddress, Int32(buf.count), nil, 0, nil)
    }
    if regResult < 0 {
        // Child may have already exited before EVFILT_PROC registration
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
                // Parent UI exited or detached; stop watching stdin and keep Mihomo running in the background.
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

exit(runHelper())
