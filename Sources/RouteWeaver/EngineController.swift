import AppKit
import Combine
import Darwin
import Foundation
import RoutingCore

@MainActor
final class EngineController: ObservableObject {
    @Published private(set) var log = ""
    @Published private(set) var isRunning = false
    @Published private(set) var isBusy = false

    private let stateDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/RouteWeaver/Mihomo", isDirectory: true)
    private var process: Process?
    private var runDir: URL?
    private var output: Pipe?
    private var watchTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var generation = UUID()
    private var stopRequested = false

    static func interfaces() -> [String] {
        interfaceNames(requireAddress: false)
    }

    private static func interfaceNames(requireAddress: Bool) -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result = Set<String>()
        var cursor = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let info = entry.pointee
            let name = String(cString: info.ifa_name)
            guard name.range(of: #"^en[0-9]+$"#, options: .regularExpression) != nil else { continue }
            if requireAddress {
                guard (info.ifa_flags & UInt32(IFF_UP | IFF_RUNNING)) == UInt32(IFF_UP | IFF_RUNNING),
                      let addr = info.ifa_addr else { continue }
                switch Int32(addr.pointee.sa_family) {
                case AF_INET:
                    let address = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                    let host = UInt32(bigEndian: address.s_addr)
                    guard host != 0 && (host & 0xffff0000) != 0xa9fe0000 else { continue }
                case AF_INET6:
                    let address = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                    let bytes = withUnsafeBytes(of: address) { Array($0) }
                    guard bytes.contains(where: { $0 != 0 }),
                          !(bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) else { continue }
                default: continue
                }
            }
            result.insert(name)
        }
        return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func validate(config: Data, binary: URL) {
        begin(config: config, binary: binary, interfaces: [], startAfterValidation: false)
    }

    func start(config: Data, binary: URL, interfaces: [String]) {
        begin(config: config, binary: binary, interfaces: interfaces, startAfterValidation: true)
    }

    func stop() {
        guard let process, process.isRunning, !stopRequested else { return }
        stopRequested = true
        append("正在停止内核…\n")
        process.terminate()
        let token = generation
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, self.generation == token,
                  self.process === process, process.isRunning, self.stopRequested else { return }
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    private func begin(config: Data, binary: URL, interfaces: [String], startAfterValidation: Bool) {
        guard process == nil, !isBusy else { return }
        guard binary.isFileURL, FileManager.default.isExecutableFile(atPath: binary.path) else {
            append("请选择可执行的本地 Mihomo 内核。\n")
            return
        }
        if startAfterValidation, !(checkInterfaces(interfaces) && checkPorts(config)) { return }
        log = ""
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDir.path)
            // Do not reuse provider caches across runs: a changed subscription
            // must not accidentally start using an earlier subscription's nodes.
            let directory = stateDir.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            runDir = directory
            let configPath = directory.appendingPathComponent("config.yaml")
            // Open with mode 0600 from the first byte; provider URLs can contain tokens.
            guard fm.createFile(atPath: configPath.path, contents: config, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            isBusy = true
            stopRequested = false
            append("正在检查 Mihomo 内核版本…\n")
            let versionPath = directory.appendingPathComponent("engine-version.txt")
            guard fm.createFile(atPath: versionPath.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let versionOutput = try FileHandle(forWritingTo: versionPath)
            defer { try? versionOutput.close() }
            try launch(
                binary: binary, config: configPath, test: true,
                argumentsOverride: ["-v"], captureOutput: versionOutput
            ) { [weak self] code in
                guard let self else { return }
                guard !self.stopRequested, code == 0, self.supportsRequiredVersion(at: versionPath) else {
                    self.append(self.stopRequested ? "已停止。\n" : "无法确认内核版本。请使用官方 Mihomo v1.19.27 或更新稳定版。\n")
                    self.cleanup()
                    return
                }
                self.append("正在用 Mihomo 校验配置…\n")
                self.runValidation(config: config, configPath: configPath, binary: binary,
                                   interfaces: interfaces, startAfterValidation: startAfterValidation)
            }
        } catch {
            append("无法校验配置：\(error.localizedDescription)\n")
            cleanup()
        }
    }

    private func supportsRequiredVersion(at path: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: path) else { return false }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: 8_192) else { return false }
        return MihomoConfig.supportsVersionOutput(String(decoding: chunk, as: UTF8.self))
    }

    private func runValidation(
        config: Data, configPath: URL, binary: URL, interfaces: [String], startAfterValidation: Bool
    ) {
        do {
            try launch(binary: binary, config: configPath, test: true) { [weak self] code in
                guard let self else { return }
                guard !self.stopRequested, code == 0 else {
                    self.append(self.stopRequested ? "已停止。\n" : "Mihomo 校验失败（退出码 \(code)）。\n")
                    self.cleanup()
                    return
                }
                self.append("Mihomo 配置校验通过。\n")
                guard startAfterValidation, self.checkInterfaces(interfaces), self.checkPorts(config) else {
                    self.cleanup()
                    return
                }
                do {
                    try self.launch(binary: binary, config: configPath, test: false) { [weak self] code in
                        guard let self else { return }
                        self.append(self.stopRequested ? "已停止。\n" : "Mihomo 已退出（退出码 \(code)）。\n")
                        self.cleanup()
                    }
                    self.append("内核进程已启动。请确认日志中的监听地址和规则加载状态。\n")
                    self.isRunning = true
                    self.isBusy = false
                    self.monitor(interfaces)
                } catch {
                    self.append("内核启动失败：\(error.localizedDescription)\n")
                    self.cleanup()
                }
            }
        } catch {
            append("无法校验配置：\(error.localizedDescription)\n")
            cleanup()
        }
    }

    private func checkInterfaces(_ names: [String]) -> Bool {
        let active = Set(Self.interfaceNames(requireAddress: true))
        let missing = Set(names).subtracting(active)
        guard missing.isEmpty else {
            append("网卡缺失或没有可用地址：\(missing.sorted().joined(separator: "、"))。不会自动换出口。\n")
            return false
        }
        return true
    }

    private func checkPorts(_ config: Data) -> Bool {
        guard let parsed = (try? JSONSerialization.jsonObject(with: config)) as? [String: Any],
              let mixed = parsed["mixed-port"] as? Int, (1...65535).contains(mixed) else {
            append("无法读取本地监听配置。\n")
            return false
        }
        var ports = [mixed]
        if let endpoint = parsed["external-controller"] as? String {
            let host = "127.0.0.1:"
            guard endpoint.hasPrefix(host), let port = Int(endpoint.dropFirst(host.count)),
                  (1...65535).contains(port), port != mixed else {
                append("控制接口必须使用独立的本机端口。\n")
                return false
            }
            ports.append(port)
        }
        for port in ports {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                append("无法检查本机端口。\n")
                return false
            }
            defer { Darwin.close(fd) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 else {
                append("本机端口 \(port) 不可用，请关闭占用该端口的应用或更换端口。\n")
                return false
            }
        }
        return true
    }

    private func monitor(_ names: [String]) {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, let self, self.isRunning else { return }
                if !self.checkInterfaces(names) {
                    self.stop()
                    return
                }
            }
        }
    }

    private func launch(
        binary: URL, config: URL, test: Bool, argumentsOverride: [String]? = nil,
        captureOutput: FileHandle? = nil, finished: @escaping @MainActor (Int32) -> Void
    ) throws {
        let p = Process()
        let pipe = Pipe()
        let token = UUID()
        generation = token
        p.executableURL = binary
        let directory = config.deletingLastPathComponent()
        p.currentDirectoryURL = directory
        p.arguments = argumentsOverride ?? ((test ? ["-t"] : []) + ["-d", directory.path, "-f", config.path])
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": directory.path]
        p.standardInput = FileHandle.nullDevice
        if let captureOutput {
            p.standardOutput = captureOutput
        } else {
            p.standardOutput = pipe
        }
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.append(chunk)
            }
        }
        p.terminationHandler = { [weak self] exited in
            let code = exited.terminationStatus
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.timeoutTask?.cancel()
                self.output?.fileHandleForReading.readabilityHandler = nil
                self.output = nil
                self.process = nil
                // Queue ordering across separate callbacks is not guaranteed, so always surface the status.
                finished(code)
            }
        }
        do {
            try p.run()
            process = p
            output = pipe
            if test {
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: argumentsOverride == nil ? 90_000_000_000 : 5_000_000_000)
                    guard !Task.isCancelled, let self, self.generation == token, p.isRunning else { return }
                    self.append(argumentsOverride == nil
                        ? "90 秒内未完成校验，已请求停止。请检查配置数据下载和网络。\n"
                        : "读取内核版本超时，已请求停止。\n")
                    self.stop()
                }
            }
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
    }

    private func cleanup() {
        watchTask?.cancel()
        timeoutTask?.cancel()
        if let directory = runDir { try? FileManager.default.removeItem(at: directory) }
        runDir = nil
        stopRequested = false
        isBusy = false
        isRunning = false
    }

    private func append(_ text: String) {
        // Hide URL paths and query parameters, which frequently contain subscription credentials.
        let safe = text.replacingOccurrences(of: #"(?i)https?://[^\s"'\)\]]+"#, with: "[URL 已隐藏]", options: .regularExpression)
        log += safe
        if log.utf8.count > 140_000 { log = String(log.suffix(45_000)) }
    }

    // When the user quits normally, do not leave our own kernel process behind.
    func terminateForAppExit() {
        if let process, process.isRunning {
            process.terminate()
            // A graceful parent quit does not change any system proxy settings.
        }
        if let directory = runDir { try? FileManager.default.removeItem(at: directory) }
    }
}
