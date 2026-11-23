import Foundation
import TunHelperProtocol

typealias KillSwitchStatus = KillSwitchStatusReport

enum KillSwitchError: LocalizedError {
    case helperNotAuthorized
    case helperOutdated
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .helperNotAuthorized:
            return "断网保护需要管理员权限，请先在「设置与日志」中完成 TUN 权限授权。"
        case .helperOutdated:
            return "已安装的辅助组件版本较旧，请先在「设置与日志」中点击「重新授权」以同步最新组件。"
        case .failed(let message):
            return "断网保护操作失败：\(message)"
        }
    }
}

enum KillSwitchManager {
    static func queryStatusAsync() async -> KillSwitchStatus {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: queryStatusSync())
            }
        }
    }

    static func queryStatusSync() -> KillSwitchStatus {
        let helperURL = TunHelperManager.installedHelperURL
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            return .inactive
        }
        let result = runHelper(TunHelperCommand.killSwitchStatus.arguments)
        guard result.status == 0 else {
            return .inactive
        }
        return KillSwitchStatusReport.parse(result.output)
    }

    static func enableAsync(allowLAN: Bool, persistOnBoot: Bool) async throws -> KillSwitchStatus {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let status = try enableSync(allowLAN: allowLAN, persistOnBoot: persistOnBoot)
                    continuation.resume(returning: status)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func disableAsync() async throws -> KillSwitchStatus {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let status = try disableSync()
                    continuation.resume(returning: status)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func enableSync(allowLAN: Bool, persistOnBoot: Bool) throws -> KillSwitchStatus {
        let helperURL = TunHelperManager.installedHelperURL
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw KillSwitchError.helperNotAuthorized
        }
        let cmd = TunHelperCommand.killSwitchEnable(allowLAN: allowLAN, persistOnBoot: persistOnBoot)
        let result = runHelper(cmd.arguments)
        if result.status != 0 {
            if result.output.contains("unknown argument") {
                throw KillSwitchError.helperOutdated
            }
            let detail = result.output.isEmpty ? "退出码 \(result.status)" : result.output
            throw KillSwitchError.failed(detail)
        }
        return queryStatusSync()
    }

    static func disableSync() throws -> KillSwitchStatus {
        let helperURL = TunHelperManager.installedHelperURL
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            return .inactive
        }
        let result = runHelper(TunHelperCommand.killSwitchDisable.arguments)
        if result.status != 0 {
            if result.output.contains("unknown argument") {
                throw KillSwitchError.helperOutdated
            }
            let detail = result.output.isEmpty ? "退出码 \(result.status)" : result.output
            throw KillSwitchError.failed(detail)
        }
        return queryStatusSync()
    }

    private static func runHelper(_ arguments: [String]) -> (status: Int32, output: String) {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = TunHelperManager.installedHelperURL
        proc.arguments = arguments
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return (proc.terminationStatus, text)
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}
