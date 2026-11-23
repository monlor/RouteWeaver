import Darwin
import Foundation

@_silgen_name("proc_pidpath")
private func thp_proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer?, _ buffersize: UInt32) -> Int32

public enum RootExecutableIssue: Error, Equatable, Sendable {
    case notFound
    case notRegularFile
    case notOwnedByRoot
    case missingSetuid
    case worldWritable
    case notExecutable
}

public enum ProcessInspector {
    private static let procPidPathMaxSize = 4096

    public static func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public static func processExecutablePath(pid: pid_t) -> String? {
        guard pid > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: procPidPathMaxSize)
        let length = buffer.withUnsafeMutableBytes { ptr in
            thp_proc_pidpath(pid, ptr.baseAddress, UInt32(procPidPathMaxSize))
        }
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    public static func verifyRootExecutable(
        at path: String,
        requireSetuid: Bool = false
    ) -> Result<Void, RootExecutableIssue> {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .failure(.notFound) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .failure(.notRegularFile) }
        guard st.st_uid == 0 else { return .failure(.notOwnedByRoot) }
        if requireSetuid, (st.st_mode & S_ISUID) == 0 {
            return .failure(.missingSetuid)
        }
        guard (st.st_mode & 0o002) == 0 else { return .failure(.worldWritable) }
        guard (st.st_mode & 0o111) != 0 else { return .failure(.notExecutable) }
        return .success(())
    }

    public static func parseLaunchctlPid(from output: String) -> pid_t? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("pid =") else { continue }
            let valueStr = line.dropFirst("pid =".count).trimmingCharacters(in: .whitespaces)
            if let value = Int32(valueStr), value > 1 {
                return pid_t(value)
            }
        }
        return nil
    }
}
