import XCTest
import CryptoKit
@testable import RoutingCore

final class MobileRelayAndAdapterTests: XCTestCase {

    // MARK: - LumzelRelayProtocol Tests

    func testHKDFMatchesRFC5869TestCase1() {
        let ikm = Data(repeating: 0x0b, count: 22)
        let salt = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c])
        let info = Data([0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9])
        let expected = Data([
            0x3c, 0xb2, 0x5f, 0x25, 0xfa, 0xac, 0xd5, 0x7a, 0x90, 0x43, 0x4f, 0x64, 0xd0, 0x36,
            0x2f, 0x2a, 0x2d, 0x2d, 0x0a, 0x90, 0xcf, 0x1a, 0x5a, 0x4c, 0x5d, 0xb0, 0x2d, 0x56,
            0xec, 0xc4, 0xc5, 0xbf,
        ])
        let derived = LumzelRelayCrypto.hkdfSHA256(ikm: ikm, salt: salt, info: info, outputByteCount: 32)
        XCTAssertEqual(derived, expected)
    }

    func testHostIDFormatAndChallengeProofRoundtrip() throws {
        let host = try LumzelRelayIdentity.generate()
        XCTAssertEqual(host.hostID.count, 32)
        XCTAssertTrue(host.hostID.allSatisfy { ("a"..."z").contains($0) || ("2"..."7").contains($0) })

        // Restoring from raw private key reproduces identical public key and hostID.
        let restored = try LumzelRelayIdentity(privateKeyRaw: host.privateKeyRaw)
        XCTAssertEqual(restored.publicKeyRaw, host.publicKeyRaw)
        XCTAssertEqual(restored.hostID, host.hostID)

        // Simulate Relay issuing a /host challenge and verifying the Host's proof.
        let relayEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let nonce = Data((0..<32).map { UInt8($0) })
        let challenge = LumzelHostChallenge(
            key: relayEphemeral.publicKey.rawRepresentation.base64EncodedString(),
            nonce: nonce.base64EncodedString()
        )
        let registerMsg = try host.makeRegisterMessage(for: challenge)
        XCTAssertEqual(registerMsg.t, "register")
        XCTAssertEqual(registerMsg.host, host.hostID)

        // Relay verifies by computing the same DH + HKDF with its ephemeral private key and host's public key.
        let expectedProof = try LumzelRelayCrypto.computeHostProof(
            hostPrivateKeyRaw: relayEphemeral.rawRepresentation,
            challengePublicKeyRaw: host.publicKeyRaw,
            nonce: nonce
        )
        XCTAssertEqual(registerMsg.proof, expectedProof.base64EncodedString())
    }

    func testLowOrderKeyRejected() throws {
        let host = try LumzelRelayIdentity.generate()
        let allZero = Data(repeating: 0, count: 32)
        let nonce = Data(repeating: 1, count: 32)
        XCTAssertThrowsError(
            try LumzelRelayCrypto.computeHostProof(
                hostPrivateKeyRaw: host.privateKeyRaw,
                challengePublicKeyRaw: allZero,
                nonce: nonce
            )
        )
    }

    func testLumzelRelaySessionRoundtripReplayAndRotation() throws {
        let clientPriv = Curve25519.KeyAgreement.PrivateKey()
        let hostPriv = Curve25519.KeyAgreement.PrivateKey()
        let sid = "sid-test-01"
        let token = "pairing-secret-token"

        let clientKeys = try LumzelRelayCrypto.deriveDirectionalSessionKeys(
            localPrivateKeyRaw: clientPriv.rawRepresentation,
            remotePublicKeyRaw: hostPriv.publicKey.rawRepresentation,
            pairingToken: token,
            sid: sid
        )
        let hostKeys = try LumzelRelayCrypto.deriveDirectionalSessionKeys(
            localPrivateKeyRaw: hostPriv.rawRepresentation,
            remotePublicKeyRaw: clientPriv.publicKey.rawRepresentation,
            pairingToken: token,
            sid: sid
        )
        XCTAssertEqual(clientKeys.initiatorToResponder, hostKeys.initiatorToResponder)
        XCTAssertEqual(clientKeys.responderToInitiator, hostKeys.responderToInitiator)

        var clientSession = try LumzelRelaySession(
            sendKey: clientKeys.initiatorToResponder,
            recvKey: clientKeys.responderToInitiator,
            sid: sid
        )
        var hostSession = try LumzelRelaySession(
            sendKey: hostKeys.responderToInitiator,
            recvKey: hostKeys.initiatorToResponder,
            sid: sid
        )

        let payload = Data("hello-via-lumzel-relay".utf8)
        let frame1 = try clientSession.seal(host: "host-abc", plaintext: payload)
        XCTAssertEqual(frame1.prefix(6), LumzelRelayConstants.frameMagic)
        XCTAssertEqual(frame1[6], 2)

        let opened1 = try hostSession.open(frame1)
        XCTAssertEqual(opened1.header.host, "host-abc")
        XCTAssertEqual(opened1.header.sid, sid)
        XCTAssertEqual(opened1.header.sequence, 1)
        XCTAssertEqual(opened1.plaintext, payload)

        // Replay of frame1 must fail.
        XCTAssertThrowsError(try hostSession.open(frame1)) { err in
            XCTAssertEqual(err as? LumzelRelayError, .replayOrOutOfOrder(received: 1, expectedGreaterThan: 1))
        }

        // Tampered ciphertext must fail AEAD.
        var frame2 = try clientSession.seal(host: "host-abc", plaintext: Data("second".utf8))
        frame2[frame2.count - 1] ^= 0xff
        XCTAssertThrowsError(try hostSession.open(frame2)) { err in
            XCTAssertEqual(err as? LumzelRelayError, .aeadFailure)
        }

        // Rotation check triggers once threshold is reached.
        XCTAssertTrue(clientSession.shouldRotate(thresholdBytes: 10))
        XCTAssertFalse(clientSession.shouldRotate(thresholdBytes: 0))
    }

    func testRelayMuxFrameEncodeDecodeWithTargetInterface() throws {
        let openReq = RelayMuxOpenRequest(targetInterface: "en5", destinationHost: "10.0.0.5", destinationPort: 443)
        let reqData = try JSONEncoder().encode(openReq)
        let mux = RelayMuxFrame(command: .openTCP, streamID: 42, payload: reqData)
        let encoded = mux.encode()
        let decoded = try RelayMuxFrame.decode(encoded)

        XCTAssertEqual(decoded.command, .openTCP)
        XCTAssertEqual(decoded.streamID, 42)
        let decodedReq = try JSONDecoder().decode(RelayMuxOpenRequest.self, from: decoded.payload)
        XCTAssertEqual(decodedReq, openReq)
    }

    // MARK: - NetworkSwitchPolicy Tests

    func testNetworkSwitchPolicyResolvesHomeWiFiCellularAndManualOverride() {
        let homeMode = MobileVPNMode.directPCSocks5(host: "192.168.1.10", port: 7890)
        let domesticCellMode = MobileVPNMode.localCore(LocalCoreExecutionOptions(bypassChainedProxy: false))
        let sgSimMode = MobileVPNMode.localCore(LocalCoreExecutionOptions(bypassChainedProxy: true))

        var policy = NetworkSwitchPolicy(
            rules: [
                NetworkSwitchRule(name: "家里 Wi-Fi", condition: .wifiSSID("Home-5G"), mode: homeMode),
                NetworkSwitchRule(name: "其他 Wi-Fi", condition: .anyWiFi, mode: domesticCellMode),
                NetworkSwitchRule(name: "蜂窝网络", condition: .cellular, mode: domesticCellMode),
            ],
            defaultMode: domesticCellMode
        )

        // Exact SSID match (case-insensitive) wins over `.anyWiFi`.
        XCTAssertEqual(
            policy.resolve(for: MobileNetworkSnapshot(interfaceKind: .wifi, wifiSSID: "home-5g")),
            homeMode
        )
        // Other Wi-Fi falls back to `.anyWiFi`.
        XCTAssertEqual(
            policy.resolve(for: MobileNetworkSnapshot(interfaceKind: .wifi, wifiSSID: "Cafe-Free")),
            domesticCellMode
        )
        // Cellular matches `.cellular`.
        XCTAssertEqual(
            policy.resolve(for: MobileNetworkSnapshot(interfaceKind: .cellular)),
            domesticCellMode
        )

        // Manual override for Singapore eSIM (no chained proxy) or temporary disable takes precedence.
        policy.manualOverride = sgSimMode
        XCTAssertEqual(
            policy.resolve(for: MobileNetworkSnapshot(interfaceKind: .cellular)),
            sgSimMode
        )
        policy.manualOverride = .disabled
        XCTAssertEqual(
            policy.resolve(for: MobileNetworkSnapshot(interfaceKind: .cellular)),
            .disabled
        )
    }

    // MARK: - MobileProfileAdapter Tests

    private func makeSamplePCProfile() -> (
        profile: RoutingProfile,
        chainGroupID: UUID,
        exitGroupID: UUID
    ) {
        let exitSub = ProxySubscription(name: "落地订阅", url: "https://sub.example.com/exit", role: .exit)
        let chainSub = ProxySubscription(name: "中转订阅", url: "https://sub.example.com/relay", role: .relay)

        let exitGroup = NodeGroup(name: "美国落地", kind: .exit, subscriptionID: exitSub.id, filterPattern: "US")
        let chainGroup = NodeGroup(name: "香港链式", kind: .relay, subscriptionID: chainSub.id, filterPattern: "HK")

        // Target 1: PC Wi-Fi direct (`en0`)
        let tWifiDirect = NetworkTarget(name: "家里直连", mode: .direct, interfaceName: "en0")
        // Target 2: PC Singapore eSIM direct (`en5`)
        let tSgDirect = NetworkTarget(name: "新加坡流量卡", mode: .direct, interfaceName: "en5")
        // Target 3: Proxy with chained group bound to `en5`
        let tProxyViaSg = NetworkTarget(
            name: "美国代理",
            mode: .proxy,
            exitGroupID: exitGroup.id,
            relayGroupID: chainGroup.id,
            interfaceName: "en5"
        )

        let ruleGroup = RuleGroup(
            name: "测试分流",
            target: .target(tSgDirect.id),
            rules: [
                RuleItem(type: .domainSuffix, value: "sg-bank.com"),
            ]
        )
        let proxyRuleGroup = RuleGroup(
            name: "海外代理",
            target: .target(tProxyViaSg.id),
            rules: [
                RuleItem(type: .domainSuffix, value: "openai.com"),
            ]
        )

        let profile = RoutingProfile(
            name: "PC 主配置",
            mixedPort: 7890,
            allowLAN: true,
            tunEnabled: true,
            gatewayModeEnabled: true,
            subscriptions: [exitSub, chainSub],
            nodeGroups: [exitGroup, chainGroup],
            targets: [tWifiDirect, tSgDirect, tProxyViaSg],
            ruleGroups: [ruleGroup, proxyRuleGroup],
            fallbackTarget: .target(tWifiDirect.id)
        )
        return (profile, chainGroup.id, exitGroup.id)
    }

    func testModeBDirectPCSocks5RendersMinimalConfig() throws {
        let (profile, _, _) = makeSamplePCProfile()
        let adapted = try MobileProfileAdapter.render(
            pcProfile: profile,
            mode: .directPCSocks5(host: "192.168.1.10", port: 7890),
            relayConfig: RelayEndpointConfig(),
            interfaceMappings: []
        )

        XCTAssertNil(adapted.relayChainEntryPort)
        XCTAssertTrue(adapted.relayedPCInterfaces.isEmpty)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: adapted.configData) as? [String: Any])
        let proxies = try XCTUnwrap(json["proxies"] as? [[String: Any]])
        XCTAssertEqual(proxies.count, 1)
        XCTAssertEqual(proxies.first?["type"] as? String, "socks5")
        XCTAssertEqual(proxies.first?["server"] as? String, "192.168.1.10")
        XCTAssertEqual(proxies.first?["port"] as? Int, 7890)
        let rules = try XCTUnwrap(json["rules"] as? [String])
        XCTAssertEqual(rules.last, "MATCH,PC-LAN-SOCKS5")
    }

    func testModeAPerInterfaceMappingAndChainedRelayReuse() throws {
        let (profile, chainGroupID, _) = makeSamplePCProfile()
        let relayConfig = RelayEndpointConfig(
            isEnabled: true,
            serverURL: "https://relay.example.com",
            hostID: "abcd1234",
            defaultRoute: .chainedNodeGroup(chainGroupID)
        )
        let mappings: [PCInterfaceMappingRule] = [
            PCInterfaceMappingRule(bsdName: "en0", displayName: "Wi-Fi", action: .useMobileDefault),
            PCInterfaceMappingRule(bsdName: "en5", displayName: "Singapore eSIM", action: .relayToPCInterface()),
        ]

        let adapted = try MobileProfileAdapter.render(
            pcProfile: profile,
            mode: .localCore(LocalCoreExecutionOptions(bypassChainedProxy: false)),
            relayConfig: relayConfig,
            interfaceMappings: mappings
        )

        XCTAssertEqual(adapted.relayedPCInterfaces, ["en5"])
        XCTAssertEqual(adapted.relayChainEntryPort, MobileProfileAdapter.defaultRelayChainEntryPort)
        XCTAssertEqual(adapted.relayChainGroupName, MobileProfileAdapter.relayChainGroupOutboundName)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: adapted.configData) as? [String: Any])
        let proxies = try XCTUnwrap(json["proxies"] as? [[String: Any]])

        // `en0` target ("家里直连") stays direct without macOS `interface-name`.
        let homeDirect = try XCTUnwrap(proxies.first(where: { ($0["name"] as? String) == "家里直连" }))
        XCTAssertEqual(homeDirect["type"] as? String, "direct")
        XCTAssertNil(homeDirect["interface-name"])

        // `en5` direct target ("新加坡流量卡") is rewritten to local SOCKS5 RelayBridge with username=en5.
        let sgDirect = try XCTUnwrap(proxies.first(where: { ($0["name"] as? String) == "新加坡流量卡" }))
        XCTAssertEqual(sgDirect["type"] as? String, "socks5")
        XCTAssertEqual(sgDirect["port"] as? Int, MobileProfileAdapter.defaultRelayBridgePort)
        XCTAssertEqual(sgDirect["username"] as? String, "en5")

        // `IN-PORT` rule and listener exist for reusing the Mac chained proxy group.
        let rules = try XCTUnwrap(json["rules"] as? [String])
        XCTAssertTrue(rules.contains("IN-PORT,\(MobileProfileAdapter.defaultRelayChainEntryPort),\(MobileProfileAdapter.relayChainGroupOutboundName)"))
        let listeners = try XCTUnwrap(json["listeners"] as? [[String: Any]])
        XCTAssertEqual(listeners.first?["listen"] as? String, "127.0.0.1:\(MobileProfileAdapter.defaultRelayChainEntryPort)")

        // Proxy target bound to `en5` has its first-hop relay provider dialed via `Relay-PC-en5`.
        let providers = try XCTUnwrap(json["proxy-providers"] as? [String: [String: Any]])
        let hasDialerViaEn5 = providers.values.contains { provider in
            (provider["override"] as? [String: Any])?["dialer-proxy"] as? String == "Relay-PC-en5"
        }
        XCTAssertTrue(hasDialerViaEn5)
    }

    func testModeASingaporeSIMBypassChainedProxyKeepsRelayForPCInterface() throws {
        let (profile, chainGroupID, _) = makeSamplePCProfile()
        let relayConfig = RelayEndpointConfig(
            isEnabled: true,
            serverURL: "https://relay.example.com",
            hostID: "abcd1234",
            defaultRoute: .chainedNodeGroup(chainGroupID)
        )
        let mappings: [PCInterfaceMappingRule] = [
            PCInterfaceMappingRule(bsdName: "en0", displayName: "Wi-Fi", action: .useMobileDefault),
            PCInterfaceMappingRule(bsdName: "en5", displayName: "PC 内网网卡", action: .relayToPCInterface()),
        ]

        let adapted = try MobileProfileAdapter.render(
            pcProfile: profile,
            mode: .localCore(LocalCoreExecutionOptions(bypassChainedProxy: true)),
            relayConfig: relayConfig,
            interfaceMappings: mappings
        )

        // Relay itself connects directly (no chained proxy IN-PORT listener).
        XCTAssertNil(adapted.relayChainEntryPort)
        XCTAssertNil(adapted.relayChainGroupName)
        // PC interface `en5` STILL routes via Relay!
        XCTAssertEqual(adapted.relayedPCInterfaces, ["en5"])

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: adapted.configData) as? [String: Any])
        let proxyGroups = try XCTUnwrap(json["proxy-groups"] as? [[String: Any]])
        // The domestic chained group ("美国代理·链式") must be stripped!
        XCTAssertFalse(proxyGroups.contains(where: { ($0["name"] as? String) == MihomoConfig.relayGroupName(for: "美国代理") }))
        // The exit group ("美国代理") still exists and dials directly via Relay-PC-en5.
        XCTAssertTrue(proxyGroups.contains(where: { ($0["name"] as? String) == "美国代理" }))
        XCTAssertNil(json["listeners"])
    }
}
