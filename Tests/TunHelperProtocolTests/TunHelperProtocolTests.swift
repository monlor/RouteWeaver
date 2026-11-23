import Foundation
import TunHelperProtocol
import XCTest

final class TunHelperProtocolTests: XCTestCase {
    func testCommandRoundTripsAllVariants() throws {
        let commands: [TunHelperCommand] = [
            .version,
            .run(
                workDir: "/tmp/work",
                configPath: "/tmp/work/config.yaml",
                logFilePath: "/tmp/work/run.log",
                pidFilePath: "/tmp/work/mihomo.pid",
                gatewayMode: true,
                daemonRunMode: true
            ),
            .run(
                workDir: "/tmp/work",
                configPath: "/tmp/work/config.yaml",
                logFilePath: nil,
                pidFilePath: nil,
                gatewayMode: false,
                daemonRunMode: false
            ),
            .installDaemon(
                workDir: "/tmp/work",
                configPath: "/tmp/work/config.yaml",
                logFilePath: "/tmp/work/run.log",
                pidFilePath: "/tmp/work/mihomo.pid",
                gatewayMode: true
            ),
            .uninstallDaemon,
            .stopPid(4242),
            .killSwitchEnable(allowLAN: true, persistOnBoot: true),
            .killSwitchEnable(allowLAN: false, persistOnBoot: false),
            .killSwitchDisable,
            .killSwitchRestore,
            .killSwitchStatus,
        ]

        for cmd in commands {
            let parsed = try TunHelperCommand.parse(cmd.arguments)
            XCTAssertEqual(parsed, cmd)
        }
    }

    func testCommandRejectsUnsafePathsAndInvalidArguments() {
        XCTAssertFalse(TunHelperPaths.isSafeAbsolutePath("relative/path"))
        XCTAssertFalse(TunHelperPaths.isSafeAbsolutePath("/tmp/../etc/passwd"))
        XCTAssertFalse(TunHelperPaths.isSafeAbsolutePath("/tmp/bad\0path"))
        XCTAssertTrue(TunHelperPaths.isSafeAbsolutePath("/Library/Application Support/RouteWeaver/config.yaml"))

        XCTAssertThrowsError(try TunHelperCommand.parse(["--work-dir", "../escape", "--config", "/tmp/c.yaml"]))
        XCTAssertThrowsError(try TunHelperCommand.parse(["--stop-pid", "1"]))
        XCTAssertThrowsError(try TunHelperCommand.parse(["--unknown-flag"]))
        XCTAssertThrowsError(try TunHelperCommand.parse(["--work-dir"]))
    }

    func testStateCodecsRoundTrip() throws {
        let gw = GatewaySysctlState(prevForwarding: 0, prevRedirect: 1)
        XCTAssertEqual(GatewaySysctlState.decodeText(gw.encodeText()), gw)
        XCTAssertNil(GatewaySysctlState.decodeText("invalid"))

        let ksState = KillSwitchPersistedState(enabled: true, allowLAN: false, persistOnBoot: true)
        XCTAssertEqual(KillSwitchPersistedState.decodeText(ksState.encodeText()), ksState)

        let report = KillSwitchStatusReport(isActive: true, allowLAN: false, persistOnBoot: true, isPFEnabled: true)
        XCTAssertEqual(KillSwitchStatusReport.parse(report.encodeText()), report)

        let dnsState = TunDNSState(services: [
            SavedServiceDNS(serviceID: "SVC-1", servers: ["1.1.1.1", "8.8.8.8"]),
            SavedServiceDNS(serviceID: "SVC-2", servers: nil),
        ])
        let encoded = try JSONEncoder().encode(dnsState)
        XCTAssertEqual(try JSONDecoder().decode(TunDNSState.self, from: encoded), dnsState)
    }

    func testPlistBuildersAndPFRules() throws {
        let daemonData = try TunHelperPlists.tunDaemonPlistData(
            workDir: "/tmp/work",
            configPath: "/tmp/work/config.yaml",
            logFilePath: "/tmp/work/run.log",
            pidFilePath: "/tmp/work/mihomo.pid",
            gatewayMode: true
        )
        let daemonPlist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: daemonData, format: nil) as? [String: Any]
        )
        XCTAssertEqual(daemonPlist["Label"] as? String, TunHelperPaths.tunDaemonLabel)
        let daemonArgs = try XCTUnwrap(daemonPlist["ProgramArguments"] as? [String])
        XCTAssertEqual(daemonArgs.first, TunHelperPaths.authorizedHelperPath)
        XCTAssertEqual(
            try TunHelperCommand.parse(Array(daemonArgs.dropFirst())),
            .run(
                workDir: "/tmp/work",
                configPath: "/tmp/work/config.yaml",
                logFilePath: "/tmp/work/run.log",
                pidFilePath: "/tmp/work/mihomo.pid",
                gatewayMode: true,
                daemonRunMode: true
            )
        )

        let ksData = try TunHelperPlists.killSwitchBootDaemonPlistData()
        let ksPlist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: ksData, format: nil) as? [String: Any]
        )
        XCTAssertEqual(ksPlist["Label"] as? String, TunHelperPaths.killSwitchDaemonLabel)

        let pfWithLAN = TunHelperPFRules.renderKillSwitchPFConfig(allowLAN: true)
        XCTAssertTrue(pfWithLAN.contains("group \(TunHelperPaths.mihomoDedicatedGid)"))
        XCTAssertTrue(pfWithLAN.contains("192.168.0.0/16"))
        XCTAssertTrue(pfWithLAN.contains("block drop out quick all"))

        let pfNoLAN = TunHelperPFRules.renderKillSwitchPFConfig(allowLAN: false)
        XCTAssertFalse(pfNoLAN.contains("192.168.0.0/16"))

        let tokenOutput = "pf enabled\nToken : 123456789012345\n"
        XCTAssertEqual(TunHelperPFRules.parsePFEnableToken(from: tokenOutput), "123456789012345")
    }

    func testProcessInspectorAndLaunchctlPidParsing() {
        let output = """
        system/local.routeweaver.mihomo-tun = {
            state = running
            pid = 9876
        }
        """
        XCTAssertEqual(ProcessInspector.parseLaunchctlPid(from: output), 9876)
        XCTAssertNil(ProcessInspector.parseLaunchctlPid(from: "state = waiting\n"))
        XCTAssertTrue(ProcessInspector.isProcessAlive(getpid()))
        XCTAssertFalse(ProcessInspector.isProcessAlive(0))
        if case .failure(.notFound) = ProcessInspector.verifyRootExecutable(at: "/nonexistent/path/routeweaver") {
            // expected
        } else {
            XCTFail("Expected .notFound failure")
        }
    }
}
