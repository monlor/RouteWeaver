import Foundation
import TunHelperProtocol
import XCTest
@testable import RouteWeaverRuntime

private final class FakePrivilegedHelperExecutor: PrivilegedHelperExecuting, @unchecked Sendable {
    private let lock = NSLock()
    var isHelperInstalled: Bool
    private(set) var helperCommands: [TunHelperCommand] = []
    private(set) var executableCalls: [(executable: URL, arguments: [String])] = []
    var helperHandler: (TunHelperCommand) -> ProcessExecutionResult
    var executableHandler: (URL, [String]) -> ProcessExecutionResult

    init(
        isHelperInstalled: Bool = true,
        helperHandler: @escaping (TunHelperCommand) -> ProcessExecutionResult = { _ in
            ProcessExecutionResult(exitCode: 0, output: "")
        },
        executableHandler: @escaping (URL, [String]) -> ProcessExecutionResult = { _, _ in
            ProcessExecutionResult(exitCode: 0, output: "")
        }
    ) {
        self.isHelperInstalled = isHelperInstalled
        self.helperHandler = helperHandler
        self.executableHandler = executableHandler
    }

    func runHelper(_ command: TunHelperCommand) -> ProcessExecutionResult {
        lock.lock()
        helperCommands.append(command)
        let handler = helperHandler
        lock.unlock()
        return handler(command)
    }

    func runExecutable(_ executable: URL, arguments: [String]) -> ProcessExecutionResult {
        lock.lock()
        executableCalls.append((executable, arguments))
        let handler = executableHandler
        lock.unlock()
        return handler(executable, arguments)
    }
}

final class PrivilegedHelperTests: XCTestCase {
    func testKillSwitchEnableDisableAndStatus() throws {
        var isActive = false
        let fake = FakePrivilegedHelperExecutor(isHelperInstalled: true) { cmd in
            switch cmd {
            case .killSwitchEnable:
                isActive = true
                return ProcessExecutionResult(exitCode: 0, output: "")
            case .killSwitchDisable:
                isActive = false
                return ProcessExecutionResult(exitCode: 0, output: "")
            case .killSwitchStatus:
                let report = KillSwitchStatusReport(
                    isActive: isActive,
                    allowLAN: true,
                    persistOnBoot: false,
                    isPFEnabled: isActive
                )
                return ProcessExecutionResult(exitCode: 0, output: report.encodeText())
            default:
                return ProcessExecutionResult(exitCode: 1, output: "unexpected")
            }
        }
        let client = PrivilegedHelperClient(executor: fake)

        let enabledStatus = try KillSwitchManager.enableSync(allowLAN: true, persistOnBoot: false, client: client)
        XCTAssertTrue(enabledStatus.isActive)
        XCTAssertTrue(enabledStatus.isPFEnabled)
        XCTAssertTrue(enabledStatus.allowLAN)
        XCTAssertFalse(enabledStatus.persistOnBoot)

        let queriedStatus = KillSwitchManager.queryStatusSync(client: client)
        XCTAssertEqual(queriedStatus, enabledStatus)

        let disabledStatus = try KillSwitchManager.disableSync(client: client)
        XCTAssertFalse(disabledStatus.isActive)
        XCTAssertFalse(disabledStatus.isPFEnabled)

        XCTAssertEqual(
            fake.helperCommands,
            [
                .killSwitchEnable(allowLAN: true, persistOnBoot: false),
                .killSwitchStatus,
                .killSwitchStatus,
                .killSwitchDisable,
                .killSwitchStatus,
            ]
        )
    }

    func testKillSwitchMissingAndOutdatedHelperErrors() {
        let missingClient = PrivilegedHelperClient(executor: FakePrivilegedHelperExecutor(isHelperInstalled: false))
        XCTAssertThrowsError(try KillSwitchManager.enableSync(allowLAN: true, persistOnBoot: false, client: missingClient)) { error in
            XCTAssertEqual(error as? KillSwitchError, .helperNotAuthorized)
        }
        XCTAssertEqual(try KillSwitchManager.disableSync(client: missingClient), .inactive)
        XCTAssertEqual(KillSwitchManager.queryStatusSync(client: missingClient), .inactive)

        let outdatedClient = PrivilegedHelperClient(
            executor: FakePrivilegedHelperExecutor(isHelperInstalled: true) { _ in
                ProcessExecutionResult(exitCode: 64, output: "RouteWeaverTunHelper: unknown argument --killswitch-enable")
            }
        )
        XCTAssertThrowsError(try KillSwitchManager.enableSync(allowLAN: false, persistOnBoot: true, client: outdatedClient)) { error in
            XCTAssertEqual(error as? KillSwitchError, .helperOutdated)
        }
        XCTAssertThrowsError(try KillSwitchManager.disableSync(client: outdatedClient)) { error in
            XCTAssertEqual(error as? KillSwitchError, .helperOutdated)
        }

        let failedClient = PrivilegedHelperClient(
            executor: FakePrivilegedHelperExecutor(isHelperInstalled: true) { _ in
                ProcessExecutionResult(exitCode: 1, output: "pfctl failed")
            }
        )
        XCTAssertThrowsError(try KillSwitchManager.enableSync(allowLAN: true, persistOnBoot: false, client: failedClient)) { error in
            XCTAssertEqual(error as? KillSwitchError, .failed("pfctl failed"))
        }
    }

    func testLaunchdServiceManagerTunDaemonAndStatus() throws {
        let fake = FakePrivilegedHelperExecutor(
            isHelperInstalled: true,
            helperHandler: { _ in ProcessExecutionResult(exitCode: 0, output: "") },
            executableHandler: { _, args in
                if args == ["print", TunHelperPaths.tunServiceTarget] {
                    return ProcessExecutionResult(
                        exitCode: 0,
                        output: "system/local.routeweaver.mihomo-tun = {\n\tstate = running\n\tpid = 4321\n}"
                    )
                }
                return ProcessExecutionResult(exitCode: 1, output: "not loaded")
            }
        )
        let client = PrivilegedHelperClient(executor: fake)

        try LaunchdServiceManager.startTunDaemon(
            workDir: URL(fileURLWithPath: "/tmp/rw-work"),
            configPath: URL(fileURLWithPath: "/tmp/rw-work/config.yaml"),
            logFile: URL(fileURLWithPath: "/tmp/rw-work/run.log"),
            pidFile: URL(fileURLWithPath: "/tmp/rw-work/mihomo.pid"),
            useGateway: true,
            client: client
        )

        XCTAssertEqual(
            fake.helperCommands,
            [
                .installDaemon(
                    workDir: "/tmp/rw-work",
                    configPath: "/tmp/rw-work/config.yaml",
                    logFilePath: "/tmp/rw-work/run.log",
                    pidFilePath: "/tmp/rw-work/mihomo.pid",
                    gatewayMode: true
                ),
            ]
        )

        let status = LaunchdServiceManager.queryTunDaemonStatus(client: client)
        XCTAssertEqual(status, LaunchdJobStatus(isLoaded: true, pid: 4321))

        XCTAssertTrue(LaunchdServiceManager.stopTunDaemonSync(client: client))
        XCTAssertEqual(fake.helperCommands.last, .uninstallDaemon)

        let missingClient = PrivilegedHelperClient(executor: FakePrivilegedHelperExecutor(isHelperInstalled: false))
        XCTAssertThrowsError(
            try LaunchdServiceManager.startTunDaemon(
                workDir: URL(fileURLWithPath: "/tmp/rw-work"),
                configPath: URL(fileURLWithPath: "/tmp/rw-work/config.yaml"),
                logFile: URL(fileURLWithPath: "/tmp/rw-work/run.log"),
                pidFile: URL(fileURLWithPath: "/tmp/rw-work/mihomo.pid"),
                useGateway: false,
                client: missingClient
            )
        ) { error in
            XCTAssertEqual(error as? LaunchdServiceError, .helperMissing)
        }
        XCTAssertFalse(LaunchdServiceManager.stopTunDaemonSync(client: missingClient))
    }

    func testRuntimeSessionStoreStopTunPidSync() {
        let fake = FakePrivilegedHelperExecutor(isHelperInstalled: true)
        let client = PrivilegedHelperClient(executor: fake)

        XCTAssertTrue(RuntimeSessionStore.stopTunPidSync(1, client: client))
        XCTAssertTrue(RuntimeSessionStore.stopTunPidSync(0, client: client))
        XCTAssertTrue(fake.helperCommands.isEmpty)

        XCTAssertTrue(RuntimeSessionStore.stopTunPidSync(5678, client: client))
        XCTAssertEqual(fake.helperCommands, [.stopPid(5678)])

        let missingClient = PrivilegedHelperClient(executor: FakePrivilegedHelperExecutor(isHelperInstalled: false))
        XCTAssertFalse(RuntimeSessionStore.stopTunPidSync(5678, client: missingClient))

        let failingClient = PrivilegedHelperClient(
            executor: FakePrivilegedHelperExecutor(isHelperInstalled: true) { _ in
                ProcessExecutionResult(exitCode: 1, output: "permission denied")
            }
        )
        XCTAssertFalse(RuntimeSessionStore.stopTunPidSync(5678, client: failingClient))
    }

    func testTunPermissionStatusDecouplesHelperSignatureFromProtocolVersion() {
        // Matching helper protocol version + equal or newer installed Mihomo => .ready (ignores ad-hoc codesign SHA-256 drift)
        XCTAssertEqual(
            TunHelperManager.evaluateStatus(
                hasSourceHelper: true,
                installedHelperValid: true,
                installedMihomoValid: true,
                installedHelperVersion: TunHelperPaths.helperVersion,
                hasCandidateMihomo: true,
                installedMihomoVersion: "v1.19.27",
                candidateMihomoVersion: "v1.19.27",
                candidateMatchesInstalledSHA256: false
            ),
            .ready
        )
        XCTAssertEqual(
            TunHelperManager.evaluateStatus(
                hasSourceHelper: true,
                installedHelperValid: true,
                installedMihomoValid: true,
                installedHelperVersion: TunHelperPaths.helperVersion,
                hasCandidateMihomo: true,
                installedMihomoVersion: "v1.19.28",
                candidateMihomoVersion: "v1.19.27",
                candidateMatchesInstalledSHA256: false
            ),
            .ready
        )

        // Older installed helper protocol version => .needsSync, but canLaunchTun stays true so remote gateway never loses connectivity
        let outdatedHelperStatus = TunHelperManager.evaluateStatus(
            hasSourceHelper: true,
            installedHelperValid: true,
            installedMihomoValid: true,
            installedHelperVersion: "6",
            expectedHelperVersion: "7",
            hasCandidateMihomo: true,
            installedMihomoVersion: "v1.19.27",
            candidateMihomoVersion: "v1.19.27",
            candidateMatchesInstalledSHA256: true
        )
        XCTAssertEqual(outdatedHelperStatus, .needsSync)
        XCTAssertTrue(outdatedHelperStatus.canLaunchTun)

        // Candidate Mihomo strictly newer than installed copy => .needsSync, still canLaunchTun
        let newerCoreStatus = TunHelperManager.evaluateStatus(
            hasSourceHelper: true,
            installedHelperValid: true,
            installedMihomoValid: true,
            installedHelperVersion: TunHelperPaths.helperVersion,
            hasCandidateMihomo: true,
            installedMihomoVersion: "v1.19.27",
            candidateMihomoVersion: "v1.19.29",
            candidateMatchesInstalledSHA256: nil
        )
        XCTAssertEqual(newerCoreStatus, .needsSync)
        XCTAssertTrue(newerCoreStatus.canLaunchTun)

        // Uninstalled / invalid root helper => .notAuthorized and canLaunchTun == false
        let unauthStatus = TunHelperManager.evaluateStatus(
            hasSourceHelper: true,
            installedHelperValid: false,
            installedMihomoValid: true,
            installedHelperVersion: nil,
            hasCandidateMihomo: true,
            installedMihomoVersion: nil,
            candidateMihomoVersion: "v1.19.27",
            candidateMatchesInstalledSHA256: nil
        )
        XCTAssertEqual(unauthStatus, .notAuthorized)
        XCTAssertFalse(unauthStatus.canLaunchTun)
    }

    func testUpdateMihomoViaHelperParsesUpdatedVersion() async throws {
        let url = "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.29/mihomo-darwin-arm64-v1.19.29.gz"
        let sha = String(repeating: "ab", count: 32)
        let fake = FakePrivilegedHelperExecutor(isHelperInstalled: true) { cmd in
            switch cmd {
            case .updateMihomo(let dURL, let expectedSHA, let port, let restart):
                XCTAssertEqual(dURL, url)
                XCTAssertEqual(expectedSHA, sha)
                XCTAssertEqual(port, 7890)
                XCTAssertTrue(restart)
                return ProcessExecutionResult(exitCode: 0, output: "UPDATED_MIHOMO_VERSION=v1.19.29\n")
            default:
                return ProcessExecutionResult(exitCode: 1, output: "unexpected")
            }
        }
        let client = PrivilegedHelperClient(executor: fake)
        let parsed = try await TunHelperManager.updateMihomoViaHelper(
            downloadURL: url,
            expectedSHA256: sha,
            proxyPort: 7890,
            restartDaemon: true,
            client: client
        )
        XCTAssertEqual(parsed, "v1.19.29")
    }

    func testBuildAuthorizeShellCommandHandlesSameFileAndValidShellSyntax() throws {
        // Regression test for `install: .../mihomo and .../mihomo are the same file (64)`
        let sameMihomo = TunHelperPaths.installedMihomoURL
        let helperSrc = URL(fileURLWithPath: "/Applications/RouteWeaver.app/Contents/Resources/bin/RouteWeaverTunHelper")
        let scriptSame = TunHelperManager.buildAuthorizeShellCommand(
            sourceHelper: helperSrc,
            mihomoBinary: sameMihomo,
            bundlePath: "/Applications/RouteWeaver.app",
            adminUserName: "monlor"
        )
        XCTAssertFalse(scriptSame.contains("/usr/bin/install -o root -g wheel -m 0755 '\(sameMihomo.path)'"))
        XCTAssertTrue(scriptSame.contains("sync-from-bundle.sh"))
        XCTAssertTrue(scriptSame.contains("/etc/sudoers.d/routeweaver"))

        let diffMihomo = URL(fileURLWithPath: "/Applications/RouteWeaver.app/Contents/Resources/bin/mihomo")
        let scriptDiff = TunHelperManager.buildAuthorizeShellCommand(
            sourceHelper: helperSrc,
            mihomoBinary: diffMihomo,
            bundlePath: "/Applications/RouteWeaver.app",
            adminUserName: "monlor"
        )
        XCTAssertTrue(scriptDiff.contains("mihomo.new"))

        for script in [scriptSame, scriptDiff] {
            let proc = Process()
            let inPipe = Pipe()
            let errPipe = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-n"]
            proc.standardInput = inPipe
            proc.standardError = errPipe
            try proc.run()
            inPipe.fileHandleForWriting.write(Data(script.utf8))
            try inPipe.fileHandleForWriting.close()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            XCTAssertEqual(
                proc.terminationStatus,
                0,
                "Authorize shell syntax error: \(String(decoding: errData, as: UTF8.self))"
            )
        }
    }
}
