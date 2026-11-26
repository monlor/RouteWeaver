import Foundation
import TunHelperProtocol

typealias KillSwitchStatus = KillSwitchStatusReport

enum KillSwitchError: LocalizedError, Equatable {
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
    static func queryStatusAsync(client: PrivilegedHelperClient = .live) async -> KillSwitchStatus {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: queryStatusSync(client: client))
            }
        }
    }

    static func queryStatusSync(client: PrivilegedHelperClient = .live) -> KillSwitchStatus {
        guard let result = try? client.execute(.killSwitchStatus) else {
            return .inactive
        }
        return KillSwitchStatusReport.parse(result.output)
    }

    static func enableAsync(
        allowLAN: Bool,
        persistOnBoot: Bool,
        client: PrivilegedHelperClient = .live
    ) async throws -> KillSwitchStatus {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let status = try enableSync(allowLAN: allowLAN, persistOnBoot: persistOnBoot, client: client)
                    continuation.resume(returning: status)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func disableAsync(client: PrivilegedHelperClient = .live) async throws -> KillSwitchStatus {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let status = try disableSync(client: client)
                    continuation.resume(returning: status)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func enableSync(
        allowLAN: Bool,
        persistOnBoot: Bool,
        client: PrivilegedHelperClient = .live
    ) throws -> KillSwitchStatus {
        do {
            _ = try client.execute(.killSwitchEnable(allowLAN: allowLAN, persistOnBoot: persistOnBoot))
        } catch let error as PrivilegedHelperError {
            throw mapHelperError(error)
        }
        return queryStatusSync(client: client)
    }

    static func disableSync(client: PrivilegedHelperClient = .live) throws -> KillSwitchStatus {
        guard client.isHelperInstalled else {
            return .inactive
        }
        do {
            _ = try client.execute(.killSwitchDisable)
        } catch let error as PrivilegedHelperError {
            throw mapHelperError(error)
        }
        return queryStatusSync(client: client)
    }

    private static func mapHelperError(_ error: PrivilegedHelperError) -> KillSwitchError {
        switch error {
        case .helperMissing:
            return .helperNotAuthorized
        case .helperOutdated:
            return .helperOutdated
        case .executionFailed(_, let detail):
            return .failed(detail)
        }
    }
}
