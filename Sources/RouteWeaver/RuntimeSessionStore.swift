import Darwin
import Foundation
import RoutingCore

@_silgen_name("proc_pidpath")
private func rw_proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer?, _ buffersize: UInt32) -> Int32

struct RuntimeCoreSession: Codable, Equatable, Sendable {
    var pid: Int32
    var isTun: Bool
    var isGateway: Bool = false
    var controllerPort: Int
    var secret: String
    var trackedGroups: [String]
    var runDirectoryPath: String
    var configPath: String
    var logFilePath: String
    var pidFilePath: String?
    var requiredInterfaces: [String]
    var startedAt: Date
    var runningProfile: RoutingProfile?

    init(
        pid: Int32,
        isTun: Bool,
        isGateway: Bool = false,
        controllerPort: Int,
        secret: String,
        trackedGroups: [String],
        runDirectoryPath: String,
        configPath: String,
        logFilePath: String,
        pidFilePath: String?,
        requiredInterfaces: [String],
        startedAt: Date,
        runningProfile: RoutingProfile?
    ) {
        self.pid = pid
        self.isTun = isTun
        self.isGateway = isGateway
        self.controllerPort = controllerPort
        self.secret = secret
        self.trackedGroups = trackedGroups
        self.runDirectoryPath = runDirectoryPath
        self.configPath = configPath
        self.logFilePath = logFilePath
        self.pidFilePath = pidFilePath
        self.requiredInterfaces = requiredInterfaces
        self.startedAt = startedAt
        self.runningProfile = runningProfile
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(Int32.self, forKey: .pid)
        isTun = try c.decode(Bool.self, forKey: .isTun)
        isGateway = try c.decodeIfPresent(Bool.self, forKey: .isGateway) ?? false
        controllerPort = try c.decode(Int.self, forKey: .controllerPort)
        secret = try c.decode(String.self, forKey: .secret)
        trackedGroups = try c.decode([String].self, forKey: .trackedGroups)
        runDirectoryPath = try c.decode(String.self, forKey: .runDirectoryPath)
        configPath = try c.decode(String.self, forKey: .configPath)
        logFilePath = try c.decode(String.self, forKey: .logFilePath)
        pidFilePath = try c.decodeIfPresent(String.self, forKey: .pidFilePath)
        requiredInterfaces = try c.decode([String].self, forKey: .requiredInterfaces)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        runningProfile = try c.decodeIfPresent(RoutingProfile.self, forKey: .runningProfile)
    }
}

struct EngineSessionContext: Sendable {
    let controllerPort: Int
    let secret: String
    let trackedGroups: [String]
    let runningProfile: RoutingProfile
}

struct RuntimeSessionStore: Sendable {
    let stateDir: URL

    var sessionFileURL: URL {
        stateDir.appendingPathComponent("runtime-session.json")
    }

    func load() -> RuntimeCoreSession? {
        guard let data = try? Data(contentsOf: sessionFileURL),
              var session = try? JSONDecoder().decode(RuntimeCoreSession.self, from: data) else {
            return nil
        }
        if session.pid <= 1, let pidPath = session.pidFilePath,
           let parsed = Self.readPidFile(at: URL(fileURLWithPath: pidPath)) {
            session.pid = parsed
        }
        return session
    }

    func save(_ session: RuntimeCoreSession) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: stateDir.path) {
            try? fm.createDirectory(at: stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(session) else { return }
        try? ProfileStore.writePrivateFile(data, to: sessionFileURL, tempName: "runtime-session.json")
    }

    func removeSessionFile() {
        try? FileManager.default.removeItem(at: sessionFileURL)
    }

    func clearStale(_ session: RuntimeCoreSession?) {
        removeSessionFile()
        if let pidPath = session?.pidFilePath {
            try? FileManager.default.removeItem(atPath: pidPath)
        }
        if let runPath = session?.runDirectoryPath, !runPath.isEmpty {
            let url = URL(fileURLWithPath: runPath)
            if url.deletingLastPathComponent().standardizedFileURL == stateDir.standardizedFileURL,
               url.lastPathComponent.hasPrefix("run-") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static func readPidFile(at url: URL) -> pid_t? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        guard let value = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value > 1 else { return nil }
        return pid_t(value)
    }

    static func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    static func processExecutablePath(pid: pid_t) -> String? {
        guard pid > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = buffer.withUnsafeMutableBytes { ptr in
            rw_proc_pidpath(pid, ptr.baseAddress, 4096)
        }
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func isMihomoProcess(pid: pid_t, expectTunAuthorized: Bool? = nil) -> Bool {
        guard isProcessAlive(pid) else { return false }
        guard let path = processExecutablePath(pid: pid) else {
            // For root-owned TUN mihomo processes, proc_pidpath may succeed or return nil depending on permissions;
            // fall back to alive check when expecting TUN authorized process (further verified by LocalController /version).
            return expectTunAuthorized == true
        }
        if expectTunAuthorized == true {
            return path == TunHelperManager.installedMihomoURL.path
        }
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return name.contains("mihomo")
    }

    static func stopUserPidAsync(_ pid: pid_t) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                stopUserPidSync(pid)
                continuation.resume()
            }
        }
    }

    static func stopUserPidSync(_ pid: pid_t) {
        guard isMihomoProcess(pid: pid, expectTunAuthorized: false) else { return }
        _ = Darwin.kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(2.5)
        while isProcessAlive(pid) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if isProcessAlive(pid) {
            _ = Darwin.kill(pid, SIGKILL)
            let killDeadline = Date().addingTimeInterval(1.0)
            while isProcessAlive(pid) && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    static func stopTunPidAsync(_ pid: pid_t) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = stopTunPidSync(pid)
                continuation.resume(returning: ok)
            }
        }
    }

    static func stopTunPidSync(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return true }
        guard FileManager.default.isExecutableFile(atPath: TunHelperManager.installedHelperURL.path) else {
            return false
        }
        let proc = Process()
        proc.executableURL = TunHelperManager.installedHelperURL
        proc.arguments = ["--stop-pid", "\(pid)"]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }
}
