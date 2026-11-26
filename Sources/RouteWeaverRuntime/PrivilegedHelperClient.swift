import Foundation
import TunHelperProtocol

struct ProcessExecutionResult: Equatable, Sendable {
    let exitCode: Int32
    let output: String

    var isSuccess: Bool { exitCode == 0 }

    var failureDetail: String {
        output.isEmpty ? "退出码 \(exitCode)" : output
    }
}

enum PrivilegedHelperError: Error, Equatable, Sendable {
    case helperMissing
    case helperOutdated
    case executionFailed(exitCode: Int32, detail: String)
}

protocol PrivilegedHelperExecuting: Sendable {
    var isHelperInstalled: Bool { get }
    func runHelper(_ command: TunHelperCommand) -> ProcessExecutionResult
    func runExecutable(_ executable: URL, arguments: [String]) -> ProcessExecutionResult
}

struct SystemPrivilegedHelperExecutor: PrivilegedHelperExecuting {
    let helperURL: URL

    init(helperURL: URL = TunHelperManager.installedHelperURL) {
        self.helperURL = helperURL
    }

    var isHelperInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: helperURL.path)
    }

    func runHelper(_ command: TunHelperCommand) -> ProcessExecutionResult {
        runExecutable(helperURL, arguments: command.arguments)
    }

    func runExecutable(_ executable: URL, arguments: [String]) -> ProcessExecutionResult {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = executable
        proc.arguments = arguments
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return ProcessExecutionResult(exitCode: proc.terminationStatus, output: text)
        } catch {
            return ProcessExecutionResult(exitCode: -1, output: error.localizedDescription)
        }
    }
}

struct PrivilegedHelperClient: Sendable {
    static let live = PrivilegedHelperClient(executor: SystemPrivilegedHelperExecutor())

    let executor: any PrivilegedHelperExecuting

    init(executor: any PrivilegedHelperExecuting) {
        self.executor = executor
    }

    var isHelperInstalled: Bool {
        executor.isHelperInstalled
    }

    func execute(_ command: TunHelperCommand) throws -> ProcessExecutionResult {
        guard executor.isHelperInstalled else {
            throw PrivilegedHelperError.helperMissing
        }
        let result = executor.runHelper(command)
        guard result.isSuccess else {
            if result.output.contains("unknown argument") {
                throw PrivilegedHelperError.helperOutdated
            }
            throw PrivilegedHelperError.executionFailed(
                exitCode: result.exitCode,
                detail: result.failureDetail
            )
        }
        return result
    }

    func runLaunchctl(_ arguments: [String]) -> ProcessExecutionResult {
        executor.runExecutable(URL(fileURLWithPath: "/bin/launchctl"), arguments: arguments)
    }
}
