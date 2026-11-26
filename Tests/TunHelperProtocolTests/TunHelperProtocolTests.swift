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
            .updateMihomo(
                downloadURL: "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.27/mihomo-darwin-arm64-v1.19.27.gz",
                expectedSHA256: String(repeating: "a1", count: 32),
                proxyPort: 7890,
                restartDaemon: true
            ),
            .updateMihomo(
                downloadURL: "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.27/mihomo-darwin-amd64-v1.19.27.gz",
                expectedSHA256: nil,
                proxyPort: nil,
                restartDaemon: false
            ),
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

        // Strict allowlist checks for root-side Mihomo release URLs (CVE-2025-50505 mitigation)
        XCTAssertTrue(
            TunHelperPaths.isTrustedMihomoReleaseURL(
                "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.28/mihomo-darwin-arm64-v1.19.28.gz"
            )
        )
        XCTAssertFalse(
            TunHelperPaths.isTrustedMihomoReleaseURL(
                "http://github.com/MetaCubeX/mihomo/releases/download/v1.19.28/mihomo-darwin-arm64-v1.19.28.gz"
            )
        )
        XCTAssertFalse(
            TunHelperPaths.isTrustedMihomoReleaseURL(
                "https://evil.example.com/MetaCubeX/mihomo/releases/download/v1.19.28/mihomo-darwin-arm64-v1.19.28.gz"
            )
        )
        XCTAssertFalse(
            TunHelperPaths.isTrustedMihomoReleaseURL(
                "https://github.com/OtherOrg/mihomo/releases/download/v1.19.28/mihomo-darwin-arm64-v1.19.28.gz"
            )
        )
        XCTAssertFalse(
            TunHelperPaths.isTrustedMihomoReleaseURL(
                "https://github.com/MetaCubeX/mihomo/releases/download/../v1.19.28/mihomo-darwin-arm64-v1.19.28.gz"
            )
        )
        XCTAssertFalse(
            TunHelperPaths.isTrustedMihomoReleaseURL(
                "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.28/mihomo-linux-arm64-v1.19.28.gz"
            )
        )
        XCTAssertFalse(
            TunHelperPaths.isTrustedMihomoReleaseURL(
                "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.28/mihomo-darwin-arm64-v1.19.28.gz?redirect=1"
            )
        )
        XCTAssertThrowsError(
            try TunHelperCommand.parse(["--update-mihomo-url", "https://evil.com/mihomo.gz"])
        )
        XCTAssertThrowsError(
            try TunHelperCommand.parse([
                "--update-mihomo-url",
                "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.28/mihomo-darwin-arm64-v1.19.28.gz",
                "--sha256",
                "not-a-valid-sha256",
            ])
        )
        XCTAssertThrowsError(
            try TunHelperCommand.parse([
                "--update-mihomo-url",
                "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.28/mihomo-darwin-arm64-v1.19.28.gz",
                "--proxy-port",
                "70000",
            ])
        )

        XCTAssertEqual(TunHelperPaths.parseHelperVersion(from: "RouteWeaverTunHelper 7\n"), "7")
        XCTAssertNil(TunHelperPaths.parseHelperVersion(from: "unexpected output"))
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
        XCTAssertTrue(pfWithLAN.contains("pass in quick inet from"))
        XCTAssertTrue(pfWithLAN.contains("flags any keep state"))
        XCTAssertTrue(pfWithLAN.contains("block drop out quick all"))

        let pfNoLAN = TunHelperPFRules.renderKillSwitchPFConfig(allowLAN: false)
        XCTAssertFalse(pfNoLAN.contains("192.168.0.0/16"))

        let tokenOutput = "pf enabled\nToken : 123456789012345\n"
        XCTAssertEqual(TunHelperPFRules.parsePFEnableToken(from: tokenOutput), "123456789012345")
    }

    func testKillSwitchPFRuleGenerationOrderAndConstants() {
        XCTAssertEqual(TunHelperPFRules.anchorName, TunHelperPaths.killSwitchAnchor)
        XCTAssertEqual(
            TunHelperPFRules.emergencyResetCommand,
            "sudo pfctl -a \(TunHelperPaths.killSwitchAnchor) -F all"
        )
        XCTAssertEqual(TunHelperPFRules.dedicatedGID, TunHelperPaths.mihomoDedicatedGid)

        let withLAN = TunHelperPFRules.renderKillSwitchPFConfig(allowLAN: true)
        let withoutLAN = TunHelperPFRules.renderKillSwitchPFConfig(allowLAN: false)

        // Core allowlist rules and strict ordering: lo0 -> utun -> Mihomo dedicated GID -> block port 53 -> DHCP -> (optional LAN) -> drop all
        let lo0Idx = withLAN.range(of: "pass quick on lo0 all")?.lowerBound
        let utunIdx = withLAN.range(of: "utun0, utun1")?.lowerBound
        let mihomoIdx = withLAN.range(of: "user 0 group \(TunHelperPFRules.dedicatedGID)")?.lowerBound
        let dnsBlockIdx = withLAN.range(of: "block drop out quick proto { tcp, udp } from any to any port 53")?.lowerBound
        let dhcpIdx = withLAN.range(of: "from any port 68 to any port 67")?.lowerBound
        let lanIdx = withLAN.range(of: "192.168.0.0/16")?.lowerBound
        let dropAllIdx = withLAN.range(of: "block drop out quick all")?.lowerBound

        XCTAssertNotNil(lo0Idx)
        XCTAssertNotNil(utunIdx)
        XCTAssertNotNil(mihomoIdx)
        XCTAssertNotNil(dnsBlockIdx)
        XCTAssertNotNil(dhcpIdx)
        XCTAssertNotNil(lanIdx)
        XCTAssertNotNil(dropAllIdx)
        XCTAssertTrue(withLAN.contains("pass in quick inet from"))
        XCTAssertTrue(withLAN.contains("flags any keep state"))

        if let lo0Idx, let utunIdx, let mihomoIdx, let dnsBlockIdx, let dhcpIdx, let lanIdx, let dropAllIdx {
            XCTAssertLessThan(lo0Idx, utunIdx)
            XCTAssertLessThan(utunIdx, mihomoIdx)
            XCTAssertLessThan(mihomoIdx, dnsBlockIdx)
            XCTAssertLessThan(dnsBlockIdx, dhcpIdx)
            XCTAssertLessThan(dhcpIdx, lanIdx)
            XCTAssertLessThan(lanIdx, dropAllIdx)
        }

        // Without LAN: DHCP still allowed so NICs can acquire leases, but RFC1918 / link-local pass rules are omitted
        XCTAssertTrue(withoutLAN.contains("from any port 68 to any port 67"))
        XCTAssertTrue(withoutLAN.contains("from any port 546 to any port 547"))
        XCTAssertFalse(withoutLAN.contains("192.168.0.0/16"))
        XCTAssertFalse(withoutLAN.contains("fe80::/10"))
        XCTAssertTrue(withoutLAN.contains("block drop out quick all"))

        // Verify syntax against macOS /sbin/pfctl -vnf - when available
        #if os(macOS)
        let pfctlPath = "/sbin/pfctl"
        if FileManager.default.isExecutableFile(atPath: pfctlPath) {
            for rules in [withLAN, withoutLAN] {
                let proc = Process()
                let inPipe = Pipe()
                let outPipe = Pipe()
                proc.executableURL = URL(fileURLWithPath: pfctlPath)
                proc.arguments = ["-vnf", "-"]
                proc.standardInput = inPipe
                proc.standardOutput = outPipe
                proc.standardError = outPipe
                try? proc.run()
                inPipe.fileHandleForWriting.write(Data(rules.utf8))
                try? inPipe.fileHandleForWriting.close()
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                XCTAssertEqual(
                    proc.terminationStatus,
                    0,
                    "pfctl syntax validation failed: \(String(decoding: outData, as: UTF8.self))"
                )
            }
        }
        #endif
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
