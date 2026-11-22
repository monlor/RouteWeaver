import Foundation
import XCTest
@testable import RoutingCore

final class RoutingCoreTests: XCTestCase {
    private let exitSubURL = "https://exit.example.invalid/nodes?token=exit1"
    private let relaySubURL = "https://relay.example.invalid/nodes?token=relay1"

    private func decodeJSON(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testChainedTargetAndDirectUSBTargetAndChainRemoval() throws {
        // Build user's exact scenario:
        // 1. 香港出口 => 香港链式 => 有线网卡(en0) => 保存为「香港」
        // 2. USB网卡(en5) => 保存为「USB 网卡」
        // 3. 美国出口 => 美国链式 => 有线网卡(en0) => 保存为「美国」
        let exitSub = ProxySubscription(name: "出口订阅", url: exitSubURL, role: .exit)
        let relaySub = ProxySubscription(name: "链式订阅", url: relaySubURL, role: .relay)

        let hkExit = NodeGroup(name: "香港出口", kind: .exit, subscriptionID: exitSub.id, filterPattern: "(?i)HK|香港", autoTest: true)
        let hkRelay = NodeGroup(name: "香港链式", kind: .relay, subscriptionID: relaySub.id, filterPattern: "(?i)HK|香港", autoTest: false)
        let usExit = NodeGroup(name: "美国出口", kind: .exit, subscriptionID: exitSub.id, filterPattern: "(?i)US|美国", autoTest: true)
        let usRelay = NodeGroup(name: "美国链式", kind: .relay, subscriptionID: relaySub.id, filterPattern: "(?i)US|美国", autoTest: false)

        let hkTarget = NetworkTarget(name: "香港", mode: .proxy, exitGroupID: hkExit.id, relayGroupID: hkRelay.id, interfaceName: "en0")
        let usbTarget = NetworkTarget(name: "USB网卡", mode: .direct, interfaceName: "en5")
        var usTarget = NetworkTarget(name: "美国", mode: .proxy, exitGroupID: usExit.id, relayGroupID: usRelay.id, interfaceName: "en0")

        let aiGroup = RuleGroup(
            name: "AI服务",
            target: .target(usTarget.id),
            rules: [
                RuleItem(type: .domainSuffix, value: "openai.com"),
                RuleItem(type: .processName, value: "Claude"),
                RuleItem(type: .processName, value: "Google Chrome"),
            ]
        )
        let directGroup = RuleGroup(
            name: "USB直连应用",
            target: .target(usbTarget.id),
            rules: [RuleItem(type: .domainSuffix, value: "claude.ai")]
        )

        var profile = RoutingProfile(
            name: "测试",
            mixedPort: 7890,
            allowLAN: false,
            subscriptions: [exitSub, relaySub],
            nodeGroups: [hkExit, hkRelay, usExit, usRelay],
            targets: [hkTarget, usbTarget, usTarget],
            ruleGroups: [aiGroup, directGroup],
            fallbackTarget: .target(hkTarget.id)
        )

        let rendered = try MihomoConfig.renderDetailed(profile)
        let config = try decodeJSON(rendered.data)

        // Process rules automatically enable find-process-mode: strict
        XCTAssertEqual(config["find-process-mode"] as? String, "strict")
        XCTAssertEqual(config["tcp-concurrent"] as? Bool, true)
        XCTAssertEqual(config["unified-delay"] as? Bool, true)
        XCTAssertEqual(config["keep-alive-idle"] as? Int, 15)
        XCTAssertEqual(config["keep-alive-interval"] as? Int, 15)
        let dns = try XCTUnwrap(config["dns"] as? [String: Any])
        XCTAssertEqual(dns["cache-algorithm"] as? String, "arc")
        XCTAssertEqual(rendered.requiredInterfaces, ["en0", "en5"])
        XCTAssertEqual(Set(rendered.activeProxyGroupNames), Set(["香港", "香港·链式", "美国", "美国·链式"]))

        // Verify url-test tuning: lazy=true, chained exit tolerance=100ms
        let groups = try XCTUnwrap(config["proxy-groups"] as? [[String: Any]])
        let usGroupChained = try XCTUnwrap(groups.first { ($0["name"] as? String) == "美国" })
        XCTAssertEqual(usGroupChained["lazy"] as? Bool, true)
        XCTAssertEqual(usGroupChained["tolerance"] as? Int, 100)

        // Verify direct USB proxy
        let proxies = try XCTUnwrap(config["proxies"] as? [[String: Any]])
        XCTAssertEqual(proxies.count, 1)
        XCTAssertEqual(proxies[0]["name"] as? String, "USB网卡")
        XCTAssertEqual(proxies[0]["interface-name"] as? String, "en5")

        // Verify chained providers: shared relay provider has interface-name en0 & empty dialer,
        // each chained exit provider has dialer-proxy = "<Target>·链式" & additional-prefix.
        let providers = try XCTUnwrap(config["proxy-providers"] as? [String: [String: Any]])
        XCTAssertEqual(providers.count, 3) // 1 shared relay provider + 2 chained exit providers
        let relayProvider = try XCTUnwrap(providers.values.first { ($0["url"] as? String) == relaySubURL })
        let usExitProvider = try XCTUnwrap(providers.values.first { ($0["override"] as? [String: String])?["additional-prefix"] == "[美国] " })
        XCTAssertEqual((relayProvider["override"] as? [String: String])?["interface-name"], "en0")
        XCTAssertEqual((relayProvider["override"] as? [String: String])?["dialer-proxy"], "")
        XCTAssertEqual((usExitProvider["override"] as? [String: String])?["dialer-proxy"], "美国·链式")
        XCTAssertNil((usExitProvider["override"] as? [String: String])?["interface-name"])
        // Provider health-check is disabled to avoid duplicate checks with url-test proxy-groups
        XCTAssertEqual((usExitProvider["health-check"] as? [String: Any])?["enable"] as? Bool, false)

        // Verify rules order and space support in PROCESS-NAME
        let rules = try XCTUnwrap(config["rules"] as? [String])
        XCTAssertEqual(rules, [
            "DOMAIN-SUFFIX,openai.com,美国",
            "PROCESS-NAME,Claude,美国",
            "PROCESS-NAME,Google Chrome,美国",
            "DOMAIN-SUFFIX,claude.ai,USB网卡",
            "MATCH,香港",
        ])

        // Now remove chain proxy from 美国 so 美国出口 directly uses 有线网卡(en0)
        usTarget.relayGroupID = nil
        profile.targets[2] = usTarget
        let renderedNoChain = try MihomoConfig.renderDetailed(profile)
        let configNoChain = try decodeJSON(renderedNoChain.data)
        XCTAssertFalse(renderedNoChain.activeProxyGroupNames.contains("美国·链式"))
        XCTAssertTrue(renderedNoChain.activeProxyGroupNames.contains("美国"))
        let groupsNoChain = try XCTUnwrap(configNoChain["proxy-groups"] as? [[String: Any]])
        let usGroupNoChain = try XCTUnwrap(groupsNoChain.first { ($0["name"] as? String) == "美国" })
        let usProviderKey = try XCTUnwrap((usGroupNoChain["use"] as? [String])?.first)
        let providersNoChain = try XCTUnwrap(configNoChain["proxy-providers"] as? [String: [String: Any]])
        let usExitDirect = try XCTUnwrap(providersNoChain[usProviderKey])
        XCTAssertEqual((usExitDirect["override"] as? [String: String])?["dialer-proxy"], "")
        XCTAssertEqual((usExitDirect["override"] as? [String: String])?["interface-name"], "en0")
        XCTAssertEqual(usGroupNoChain["filter"] as? String, "(?i)US|美国")
        XCTAssertEqual(usGroupNoChain["lazy"] as? Bool, true)
        XCTAssertEqual(usGroupNoChain["tolerance"] as? Int, 50)
    }

    func testOptionalInterfaceSystemDefaultAndLANExposure() throws {
        let sub = ProxySubscription(name: "主订阅", url: exitSubURL, role: .general)
        let hkGroup = NodeGroup(name: "香港", kind: .exit, subscriptionID: sub.id, filterPattern: "(?i)HK", autoTest: true)
        let hkTarget = NetworkTarget(name: "香港", mode: .proxy, exitGroupID: hkGroup.id, relayGroupID: nil, interfaceName: nil)
        let directTarget = NetworkTarget(name: "直连", mode: .direct, interfaceName: nil)

        let profile = RoutingProfile(
            name: "LAN测试",
            mixedPort: 7890,
            httpPort: 7891,
            socksPort: 7892,
            allowLAN: true,
            subscriptions: [sub],
            nodeGroups: [hkGroup],
            targets: [hkTarget, directTarget],
            ruleGroups: [
                RuleGroup(name: "国内", target: .target(directTarget.id), rules: [RuleItem(type: .geosite, value: "cn")]),
            ],
            fallbackTarget: .target(hkTarget.id)
        )

        let rendered = try MihomoConfig.renderDetailed(profile, controllerPort: 19090, secret: "secret-key")
        let config = try decodeJSON(rendered.data)

        // No bound interfaces required
        XCTAssertTrue(rendered.requiredInterfaces.isEmpty)
        // LAN exposure enabled, controller still bound to loopback
        XCTAssertEqual(config["allow-lan"] as? Bool, true)
        XCTAssertEqual(config["bind-address"] as? String, "*")
        XCTAssertEqual(config["mixed-port"] as? Int, 7890)
        XCTAssertEqual(config["port"] as? Int, 7891)
        XCTAssertEqual(config["socks-port"] as? Int, 7892)
        XCTAssertEqual(config["external-controller"] as? String, "127.0.0.1:19090")
        XCTAssertEqual(config["find-process-mode"] as? String, "off")

        // Direct proxy has no interface-name
        let proxies = try XCTUnwrap(config["proxies"] as? [[String: Any]])
        XCTAssertNil(proxies[0]["interface-name"])

        // Proxy provider has no interface-name
        let providers = try XCTUnwrap(config["proxy-providers"] as? [String: [String: Any]])
        let onlyProvider = try XCTUnwrap(providers.values.first)
        XCTAssertNil((onlyProvider["override"] as? [String: String])?["interface-name"])
    }

    func testSharedSubscriptionAmbiguousRelayRejected() throws {
        let sub = ProxySubscription(name: "共享订阅", url: exitSubURL, role: .general)
        let exitG = NodeGroup(name: "出口", kind: .exit, subscriptionID: sub.id, filterPattern: "(?i)HK", autoTest: true)
        let relayG = NodeGroup(name: "链式", kind: .relay, subscriptionID: sub.id, filterPattern: "(?i)HK", autoTest: false)
        let target = NetworkTarget(name: "香港", mode: .proxy, exitGroupID: exitG.id, relayGroupID: relayG.id)

        let profile = RoutingProfile(
            subscriptions: [sub],
            nodeGroups: [exitG, relayG],
            targets: [target],
            ruleGroups: [],
            fallbackTarget: .target(target.id)
        )

        XCTAssertThrowsError(try MihomoConfig.render(profile)) { error in
            XCTAssertEqual(error as? RoutingConfigurationError, .ambiguousRelayPattern("香港"))
        }
    }

    func testUnreferencedDraftTargetDoesNotBreakRender() throws {
        let directTarget = NetworkTarget(name: "直连", mode: .direct)
        // Incomplete draft proxy target not referenced by any enabled rule or fallback
        let draftTarget = NetworkTarget(name: "草稿美国", mode: .proxy, exitGroupID: nil)

        let profile = RoutingProfile(
            targets: [directTarget, draftTarget],
            ruleGroups: [],
            fallbackTarget: .target(directTarget.id)
        )

        let rendered = try MihomoConfig.renderDetailed(profile)
        let config = try decodeJSON(rendered.data)
        XCTAssertEqual(config["rules"] as? [String], ["MATCH,直连"])
    }

    func testDuplicatePortRejected() {
        let directTarget = NetworkTarget(name: "直连", mode: .direct)
        let profile = RoutingProfile(
            mixedPort: 7890,
            httpPort: 7890,
            targets: [directTarget],
            fallbackTarget: .target(directTarget.id)
        )
        XCTAssertThrowsError(try MihomoConfig.render(profile)) { error in
            XCTAssertEqual(error as? RoutingConfigurationError, .invalidPort("独立 HTTP 端口"))
        }
    }

    func testRuleSetGeneratesMihomoRuleProviders() throws {
        let directTarget = NetworkTarget(name: "直连", mode: .direct)
        let listURL = SubconverterMirror.jsdelivr.acl4ssrURL(file: "Ruleset/OpenAi.list")
        let yamlURL = "https://example.invalid/custom-rules.yaml"

        let profile = RoutingProfile(
            ruleSetUpdateIntervalHours: 6,
            targets: [directTarget],
            ruleGroups: [
                RuleGroup(
                    name: "ACL4SSR测试",
                    target: .target(directTarget.id),
                    rules: [
                        RuleItem(type: .ruleSet, value: listURL, note: "OpenAI"),
                        RuleItem(type: .ruleSet, value: yamlURL, note: "Custom YAML"),
                    ]
                ),
            ],
            fallbackTarget: .target(directTarget.id)
        )

        let rendered = try MihomoConfig.renderDetailed(profile)
        let config = try decodeJSON(rendered.data)
        let providers = try XCTUnwrap(config["rule-providers"] as? [String: [String: Any]])
        XCTAssertEqual(providers.count, 2)

        let listProvider = try XCTUnwrap(providers.values.first { ($0["url"] as? String) == listURL })
        XCTAssertEqual(listProvider["type"] as? String, "http")
        XCTAssertEqual(listProvider["behavior"] as? String, "classical")
        XCTAssertEqual(listProvider["format"] as? String, "text")
        XCTAssertEqual(listProvider["interval"] as? Int, 21_600)

        let yamlProvider = try XCTUnwrap(providers.values.first { ($0["url"] as? String) == yamlURL })
        XCTAssertEqual(yamlProvider["format"] as? String, "yaml")

        let rules = try XCTUnwrap(config["rules"] as? [String])
        XCTAssertEqual(rules.count, 3)
        XCTAssertTrue(rules[0].hasPrefix("RULE-SET,rs-"))
        XCTAssertTrue(rules[0].hasSuffix(",直连"))
        XCTAssertEqual(rules[2], "MATCH,直连")

        // Verify starter includes all 9 regions (exit + relay), full ACL4SSR catalog, and monlor/subconverter-rules
        let starter = RoutingProfile.starter()
        XCTAssertEqual(RegexPreset.regions.count, 9)
        XCTAssertEqual(starter.nodeGroups.filter { $0.kind == .exit }.count, 9)
        XCTAssertEqual(starter.nodeGroups.filter { $0.kind == .relay }.count, 9)
        XCTAssertEqual(SubconverterCatalog.allRuleSets.count, 182)
        XCTAssertEqual(SubconverterCatalog.monlorRuleSets.count, 34)
        XCTAssertEqual(SubconverterCatalog.monlorFullPresets.count, 16)
        XCTAssertEqual(
            SubconverterMirror.monlorProxy.monlorRuleURL(file: "kiro.ini"),
            "https://gh.monlor.com/https://raw.githubusercontent.com/monlor/subconverter-rules/main/rules/kiro.ini"
        )
    }

    func testSurgeSGModuleHostParsingAndMihomoHostsInjection() throws {
        let sgmodule = """
        #!name=TAG Profile
        #!desc=TAG Custom Profiles

        [Host]
        www.qq.com = www.qq.com
        c7f0ef4e.sankuaei.com = 5bf96e74.definition-meaning.top
        2fc4443b.aixifan7498.com = 5aa5e367.sfr-bouygues.cloud
        ignored.example = server:223.5.5.5
        """
        let parsed = HostModuleParser.parse(sgmodule)
        XCTAssertEqual(parsed.name, "TAG Profile")
        XCTAssertEqual(parsed.hosts.count, 2)
        XCTAssertEqual(parsed.hosts["c7f0ef4e.sankuaei.com"], "5bf96e74.definition-meaning.top")
        XCTAssertNil(parsed.hosts["www.qq.com"])
        XCTAssertNil(parsed.hosts["ignored.example"])

        let directTarget = NetworkTarget(name: "直连", mode: .direct)
        let module = HostModule(name: "TAG Profile", url: "https://example.invalid/tag.sgmodule", cachedHosts: parsed.hosts)
        let profile = RoutingProfile(
            hostModules: [module],
            targets: [directTarget],
            fallbackTarget: .target(directTarget.id)
        )
        let rendered = try MihomoConfig.renderDetailed(profile)
        let config = try decodeJSON(rendered.data)
        let hosts = try XCTUnwrap(config["hosts"] as? [String: String])
        XCTAssertEqual(hosts["c7f0ef4e.sankuaei.com"], "5bf96e74.definition-meaning.top")
        let dns = try XCTUnwrap(config["dns"] as? [String: Any])
        XCTAssertEqual(dns["enable"] as? Bool, true)
        XCTAssertEqual(dns["use-hosts"] as? Bool, true)
    }

    func testVersionCheck() {
        XCTAssertTrue(MihomoConfig.supportsVersionOutput("Mihomo Meta v1.19.27 darwin arm64"))
        XCTAssertTrue(MihomoConfig.supportsVersionOutput("Mihomo Meta v1.20.1 darwin arm64"))
        XCTAssertFalse(MihomoConfig.supportsVersionOutput("Mihomo Meta v1.19.26 darwin arm64"))
        XCTAssertEqual(MihomoConfig.parseVersion(from: "Mihomo Meta v1.19.27 darwin arm64"), "v1.19.27")
        XCTAssertEqual(MihomoConfig.compareVersions("v1.19.27", "v1.19.28"), .orderedAscending)
        XCTAssertEqual(MihomoConfig.compareVersions("v1.20.0", "v1.19.99"), .orderedDescending)
        XCTAssertEqual(MihomoConfig.compareVersions("v1.19.27", "1.19.27"), .orderedSame)
    }

    func testMihomoReleaseAssetSelection() {
        let assets = [
            MihomoReleaseAsset(name: "mihomo-darwin-arm64-go120-v1.19.28.gz", downloadURL: URL(string: "https://github.com/a")!, size: 100),
            MihomoReleaseAsset(name: "mihomo-darwin-arm64-v1.19.28.gz", downloadURL: URL(string: "https://github.com/b")!, size: 100),
            MihomoReleaseAsset(name: "mihomo-darwin-amd64-compatible-v1.19.28.gz", downloadURL: URL(string: "https://github.com/c")!, size: 100),
            MihomoReleaseAsset(name: "mihomo-darwin-amd64-v1.19.28.gz", downloadURL: URL(string: "https://github.com/d")!, size: 100),
        ]
        XCTAssertEqual(MihomoReleaseSelector.selectMacOSAsset(from: assets, arch: "arm64")?.name, "mihomo-darwin-arm64-v1.19.28.gz")
        XCTAssertEqual(MihomoReleaseSelector.selectMacOSAsset(from: assets, arch: "x86_64")?.name, "mihomo-darwin-amd64-v1.19.28.gz")
        XCTAssertNil(MihomoReleaseSelector.selectMacOSAsset(from: assets, arch: "riscv64"))
    }

    func testSubscriptionParserClashYAMLAndBase64URIAndRegexMatch() {
        let yaml = """
        port: 7890
        proxies:
          - name: "🇭🇰 香港 IEPL 01"
            type: trojan
            server: hk1.example.com
            port: 443
          - { name: '🇺🇸 美国 洛杉矶 02', type: vless, server: us2.example.com, port: 8443 }
        proxy-groups:
          - name: Proxy
        """
        let yamlNodes = SubscriptionParser.parse(Data(yaml.utf8))
        XCTAssertEqual(yamlNodes.count, 2)
        XCTAssertEqual(yamlNodes[0].name, "🇭🇰 香港 IEPL 01")
        XCTAssertEqual(yamlNodes[0].type, "trojan")
        XCTAssertEqual(yamlNodes[0].server, "hk1.example.com")
        XCTAssertEqual(yamlNodes[0].port, 443)
        XCTAssertEqual(yamlNodes[1].name, "🇺🇸 美国 洛杉矶 02")
        XCTAssertEqual(yamlNodes[1].type, "vless")

        let hkMatched = SubscriptionParser.matchingNodes(yamlNodes, pattern: #"(?i)(香港|HK)"#)
        XCTAssertEqual(hkMatched.map(\.name), ["🇭🇰 香港 IEPL 01"])

        let vmessPayload = Data(#"{"ps":"🇯🇵 日本 东京","add":"jp.example.com","port":"443"}"#.utf8).base64EncodedString()
        let uriList = """
        vmess://\(vmessPayload)
        trojan://secret@sg.example.com:443#%F0%9F%87%B8%F0%9F%87%AC%20%E6%96%B0%E5%8A%A0%E5%9D%A1%2001
        """
        let base64Sub = Data(uriList.utf8).base64EncodedString()
        let uriNodes = SubscriptionParser.parse(Data(base64Sub.utf8))
        XCTAssertEqual(uriNodes.count, 2)
        XCTAssertEqual(uriNodes[0].name, "🇯🇵 日本 东京")
        XCTAssertEqual(uriNodes[0].type, "vmess")
        XCTAssertEqual(uriNodes[1].name, "🇸🇬 新加坡 01")
        XCTAssertEqual(uriNodes[1].type, "trojan")
    }

    func testProfileStoreCustomDirectoryAndRoundTrip() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("RouteWeaverTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let defaultDir = root.appendingPathComponent("default", isDirectory: true)
        let customDir = root.appendingPathComponent("iCloudDrive/RouteWeaver", isDirectory: true)

        var store = ProfileStore(defaultDirectory: defaultDir)
        XCTAssertFalse(store.isUsingCustomDirectory)
        XCTAssertEqual(store.activeDirectory, defaultDir.standardizedFileURL)
        XCTAssertEqual(store.activeProfileURL, defaultDir.standardizedFileURL.appendingPathComponent("profile.json"))

        // Setting custom directory equal to default is treated as default
        store.customDirectory = defaultDir
        XCTAssertFalse(store.isUsingCustomDirectory)

        // Setting a distinct custom directory switches activeDirectory & activeProfileURL
        store.customDirectory = customDir
        XCTAssertTrue(store.isUsingCustomDirectory)
        XCTAssertEqual(store.activeDirectory, customDir.standardizedFileURL)
        XCTAssertFalse(ProfileStore.profileExists(in: customDir))

        var profile = RoutingProfile.starter()
        profile.mixedPort = 8899
        try ProfileStore.writeProfile(profile, to: customDir, enforcePrivateDirectoryPermissions: false)

        XCTAssertTrue(ProfileStore.profileExists(in: customDir))
        let loaded = try ProfileStore.readProfile(from: customDir)
        XCTAssertEqual(loaded.mixedPort, 8899)
        XCTAssertEqual(loaded.subscriptions.count, profile.subscriptions.count)
    }

    func testProfileStoreRejectsOversizedFile() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("RouteWeaverOversize-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let oversized = Data(repeating: 0x20, count: ProfileStore.maxProfileBytes + 1)
        try oversized.write(to: ProfileStore.profileFileURL(in: dir))

        XCTAssertThrowsError(try ProfileStore.readProfile(from: dir)) { error in
            XCTAssertEqual(error as? ProfileStoreError, .fileTooLarge)
        }
    }

    func testNodeGroupExcludeFilterPatternPreviewConfigAndLegacyDecode() throws {
        // 1. Live preview matching with excludePattern
        let nodes = [
            SubscriptionNode(name: "🇭🇰 香港 01 | 1x HK", type: "trojan"),
            SubscriptionNode(name: "🇭🇰 香港 02 | 1x HK", type: "trojan"),
            SubscriptionNode(name: "🇭🇰 香港家宽 01 | 1x HK", type: "trojan"),
            SubscriptionNode(name: "🇭🇰 香港 03 | 2x HK", type: "trojan"),
            SubscriptionNode(name: "🇺🇸 美国 01 | 1x US", type: "vless"),
        ]
        let filtered = SubscriptionParser.matchingNodes(
            nodes,
            pattern: #"(?i)(香港|HK)"#,
            excludePattern: #"(?i)(家宽|2x)"#
        )
        XCTAssertEqual(filtered.map(\.name), ["🇭🇰 香港 01 | 1x HK", "🇭🇰 香港 02 | 1x HK"])

        // Exclude-only (empty include pattern)
        let excludeOnly = SubscriptionParser.matchingNodes(nodes, pattern: "", excludePattern: #"家宽|美国"#)
        XCTAssertEqual(excludeOnly.count, 3)

        // Invalid exclude regex returns empty
        XCTAssertTrue(SubscriptionParser.matchingNodes(nodes, pattern: "香港", excludePattern: "[unclosed").isEmpty)

        // 2. Mihomo config emits `exclude-filter` when non-empty and omits when empty
        let sub = ProxySubscription(name: "主订阅", url: exitSubURL, role: .general)
        let hkExit = NodeGroup(
            name: "香港出口",
            kind: .exit,
            subscriptionID: sub.id,
            filterPattern: #"(?i)(香港|HK)"#,
            excludeFilterPattern: #"(?i)(家宽|2x)"#,
            autoTest: true
        )
        let usExit = NodeGroup(
            name: "美国出口",
            kind: .exit,
            subscriptionID: sub.id,
            filterPattern: #"(?i)(美国|US)"#,
            excludeFilterPattern: "",
            autoTest: true
        )
        let hkTarget = NetworkTarget(name: "香港", mode: .proxy, exitGroupID: hkExit.id)
        let usTarget = NetworkTarget(name: "美国", mode: .proxy, exitGroupID: usExit.id)
        let profile = RoutingProfile(
            subscriptions: [sub],
            nodeGroups: [hkExit, usExit],
            targets: [hkTarget, usTarget],
            ruleGroups: [
                RuleGroup(name: "AI", target: .target(usTarget.id), rules: [RuleItem(type: .domainSuffix, value: "openai.com")]),
            ],
            fallbackTarget: .target(hkTarget.id)
        )

        let rendered = try MihomoConfig.renderDetailed(profile)
        let config = try decodeJSON(rendered.data)
        // Shared subscription across multiple unchained targets is deduplicated into 1 provider
        let providers = try XCTUnwrap(config["proxy-providers"] as? [String: [String: Any]])
        XCTAssertEqual(providers.count, 1)

        let groups = try XCTUnwrap(config["proxy-groups"] as? [[String: Any]])
        let hkGroup = try XCTUnwrap(groups.first { ($0["name"] as? String) == "香港" })
        let usGroup = try XCTUnwrap(groups.first { ($0["name"] as? String) == "美国" })

        XCTAssertEqual(hkGroup["filter"] as? String, #"(?i)(香港|HK)"#)
        XCTAssertEqual(hkGroup["exclude-filter"] as? String, #"(?i)(家宽|2x)"#)
        XCTAssertEqual(usGroup["filter"] as? String, #"(?i)(美国|US)"#)
        XCTAssertNil(usGroup["exclude-filter"])

        // Invalid exclude regex rejected by MihomoConfig.render
        var badProfile = profile
        badProfile.nodeGroups[0].excludeFilterPattern = "(unclosed"
        XCTAssertThrowsError(try MihomoConfig.render(badProfile)) { error in
            XCTAssertEqual(error as? RoutingConfigurationError, .invalidPattern("节点组「香港出口」排除正则"))
        }

        // 3. Legacy JSON without `excludeFilterPattern` decodes cleanly with empty string
        let legacyJSON = #"{"id":"00000000-0000-0000-0000-000000000001","name":"香港出口","kind":"exit","filterPattern":"HK","autoTest":true}"#
        let decoded = try JSONDecoder().decode(NodeGroup.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.name, "香港出口")
        XCTAssertEqual(decoded.filterPattern, "HK")
        XCTAssertEqual(decoded.excludeFilterPattern, "")
    }

    func testReviewFixesGeoIPRuleSetMRSReservedNamesAndMultiIPHosts() throws {
        // 1. GEOIP must NOT emit no-resolve, while IP-CIDR / IP-CIDR6 must keep no-resolve
        XCTAssertEqual(RuleItem(type: .geoip, value: "CN").formatted(target: "国内直连"), "GEOIP,CN,国内直连")
        XCTAssertEqual(RuleItem(type: .ipCIDR, value: "192.168.0.0/16").formatted(target: "国内直连"), "IP-CIDR,192.168.0.0/16,国内直连,no-resolve")
        XCTAssertEqual(RuleItem(type: .ipCIDR6, value: "fc00::/7").formatted(target: "国内直连"), "IP-CIDR6,fc00::/7,国内直连,no-resolve")

        // 2. RULE-SET enables find-process-mode: strict and supports .mrs (domain & ipcidr)
        let directTarget = NetworkTarget(name: "国内直连", mode: .direct)
        let domainMRS = "https://example.invalid/geosite-cn.mrs"
        let ipMRS = "https://example.invalid/geoip-cn.mrs"
        let hostModule = HostModule(
            name: "MultiHost",
            url: "https://example.invalid/host.sgmodule",
            cachedHosts: HostModuleParser.parse("""
            [Host]
            single.example = 1.1.1.1
            multi.example = 1.1.1.1, 1.0.0.1
            """).hosts
        )
        let profile = RoutingProfile(
            hostModules: [hostModule],
            targets: [directTarget],
            ruleGroups: [
                RuleGroup(
                    name: "MRS测试",
                    target: .target(directTarget.id),
                    rules: [
                        RuleItem(type: .ruleSet, value: domainMRS),
                        RuleItem(type: .ruleSet, value: ipMRS),
                    ]
                ),
            ],
            fallbackTarget: .target(directTarget.id)
        )

        let rendered = try MihomoConfig.renderDetailed(profile)
        let config = try decodeJSON(rendered.data)
        XCTAssertEqual(config["find-process-mode"] as? String, "strict")

        let ruleProviders = try XCTUnwrap(config["rule-providers"] as? [String: [String: Any]])
        let domainProvider = try XCTUnwrap(ruleProviders.values.first { ($0["url"] as? String) == domainMRS })
        let ipProvider = try XCTUnwrap(ruleProviders.values.first { ($0["url"] as? String) == ipMRS })
        XCTAssertEqual(domainProvider["format"] as? String, "mrs")
        XCTAssertEqual(domainProvider["behavior"] as? String, "domain")
        XCTAssertEqual(ipProvider["format"] as? String, "mrs")
        XCTAssertEqual(ipProvider["behavior"] as? String, "ipcidr")

        // 3. Multi-IP host emitted as JSON array and DNS nameserver uses DoH without plaintext UDP race
        let hosts = try XCTUnwrap(config["hosts"] as? [String: Any])
        XCTAssertEqual(hosts["single.example"] as? String, "1.1.1.1")
        XCTAssertEqual(hosts["multi.example"] as? [String], ["1.1.1.1", "1.0.0.1"])

        let dns = try XCTUnwrap(config["dns"] as? [String: Any])
        XCTAssertEqual(dns["nameserver"] as? [String], ["system", "223.5.5.5", "119.29.29.29"])
        XCTAssertEqual(dns["respect-rules"] as? Bool, false)
        XCTAssertEqual(dns["default-nameserver"] as? [String], ["system", "223.5.5.5", "119.29.29.29"])
        XCTAssertEqual(dns["proxy-server-nameserver"] as? [String], ["system", "223.5.5.5", "119.29.29.29"])
        XCTAssertEqual(dns["direct-nameserver"] as? [String], ["system", "223.5.5.5", "119.29.29.29"])
        // Pure-direct profile must NOT emit overseas fallback
        XCTAssertNil(dns["fallback"])
        XCTAssertNil(dns["fallback-filter"])

        // 4. Mihomo reserved names & relay suffix collision rejected
        for reserved in ["GLOBAL", "PASS", "REJECT-DROP", "COMPATIBLE"] {
            let badTarget = NetworkTarget(name: reserved, mode: .direct)
            let badProfile = RoutingProfile(targets: [badTarget], fallbackTarget: .target(badTarget.id))
            XCTAssertThrowsError(try MihomoConfig.render(badProfile))
        }

        let sub = ProxySubscription(name: "Sub", url: exitSubURL, role: .general)
        let exitG = NodeGroup(name: "出口", kind: .exit, subscriptionID: sub.id, filterPattern: "HK")
        let relayG = NodeGroup(name: "链式", kind: .relay, subscriptionID: sub.id, filterPattern: "JP")
        let hk = NetworkTarget(name: "香港", mode: .proxy, exitGroupID: exitG.id, relayGroupID: relayG.id)
        let colliding = NetworkTarget(name: "香港·链式", mode: .direct)
        let collisionProfile = RoutingProfile(
            subscriptions: [sub],
            nodeGroups: [exitG, relayG],
            targets: [hk, colliding],
            ruleGroups: [RuleGroup(name: "R", target: .target(colliding.id), rules: [RuleItem(type: .domain, value: "a.com")])],
            fallbackTarget: .target(hk.id)
        )
        XCTAssertThrowsError(try MihomoConfig.render(collisionProfile)) { error in
            XCTAssertEqual(error as? RoutingConfigurationError, .duplicateTargetName("香港·链式"))
        }
    }

    func testRuleSetFormatBehaviorInferenceAndExplicitOverrides() throws {
        // 1. .mrs filenames containing "ip" as a substring must NOT be misclassified as ipcidr
        for url in [
            "https://example.invalid/rules/wikipedia.mrs",
            "https://example.invalid/rules/stripe.mrs",
            "https://example.invalid/rules/vip.mrs",
            "https://example.invalid/geosite/shopify.mrs",
        ] {
            let resolved = try RuleSetResolver.resolve(url: url, format: nil, behavior: nil)
            XCTAssertEqual(resolved.format, "mrs")
            XCTAssertEqual(resolved.behavior, "domain", "Unexpected ipcidr for \(url)")
        }

        // 2. Genuine IP .mrs rulesets are recognized via path segment or delimited tokens
        for url in [
            "https://example.invalid/geoip/cn.mrs",
            "https://example.invalid/rules/geoip-cn.mrs",
            "https://example.invalid/rules/telegram-ip.mrs",
            "https://example.invalid/rules/cn_ipcidr.mrs",
        ] {
            let resolved = try RuleSetResolver.resolve(url: url, format: nil, behavior: nil)
            XCTAssertEqual(resolved.format, "mrs")
            XCTAssertEqual(resolved.behavior, "ipcidr", "Expected ipcidr for \(url)")
            XCTAssertFalse(resolved.isAmbiguous)
        }

        // 3. MRS + classical is explicitly rejected
        XCTAssertThrowsError(
            try RuleSetResolver.resolve(url: "https://example.invalid/a.mrs", format: .mrs, behavior: .classical)
        ) { error in
            if case RoutingConfigurationError.invalidRule = error {
                // expected
            } else {
                XCTFail("Expected invalidRule, got \(error)")
            }
        }

        // 4. YAML rulesets infer domain/ipcidr when path/tokens indicate, and flag ambiguity otherwise
        let yamlDomain = try RuleSetResolver.resolve(url: "https://example.invalid/geosite/google.yaml", format: nil, behavior: nil)
        XCTAssertEqual(yamlDomain.format, "yaml")
        XCTAssertEqual(yamlDomain.behavior, "domain")
        XCTAssertFalse(yamlDomain.isAmbiguous)

        let yamlIP = try RuleSetResolver.resolve(url: "https://example.invalid/rules/cncidr.yaml", format: nil, behavior: nil)
        XCTAssertEqual(yamlIP.format, "yaml")
        XCTAssertEqual(yamlIP.behavior, "ipcidr")

        let yamlUnknown = try RuleSetResolver.resolve(url: "https://example.invalid/custom.yaml", format: nil, behavior: nil)
        XCTAssertEqual(yamlUnknown.format, "yaml")
        XCTAssertEqual(yamlUnknown.behavior, "classical")
        XCTAssertTrue(yamlUnknown.isAmbiguous)

        // Explicit override resolves ambiguity
        let yamlOverride = try RuleSetResolver.resolve(url: "https://example.invalid/custom.yaml", format: .yaml, behavior: .domain)
        XCTAssertEqual(yamlOverride.behavior, "domain")
        XCTAssertFalse(yamlOverride.isAmbiguous)

        // 5. Render config emits explicit overrides and optional no-resolve on RULE-SET
        let direct = NetworkTarget(name: "直连", mode: .direct)
        let profile = RoutingProfile(
            targets: [direct],
            ruleGroups: [
                RuleGroup(
                    name: "自定义规则集",
                    target: .target(direct.id),
                    rules: [
                        RuleItem(
                            type: .ruleSet,
                            value: "https://example.invalid/rules/wikipedia.mrs",
                            ruleSetFormat: .mrs,
                            ruleSetBehavior: .domain
                        ),
                        RuleItem(
                            type: .ruleSet,
                            value: "https://example.invalid/rules/telegram-ip.mrs",
                            ruleSetFormat: .mrs,
                            ruleSetBehavior: .ipcidr,
                            ruleSetNoResolve: true
                        ),
                    ]
                ),
            ],
            fallbackTarget: .target(direct.id)
        )
        let rendered = try MihomoConfig.renderDetailed(profile)
        let config = try decodeJSON(rendered.data)
        let rules = try XCTUnwrap(config["rules"] as? [String])
        XCTAssertFalse(rules[0].hasSuffix(",no-resolve"))
        XCTAssertTrue(rules[1].hasSuffix(",直连,no-resolve"))

        // 6. Legacy RuleItem JSON without new optional fields decodes cleanly
        let legacyRuleJSON = #"{"id":"00000000-0000-0000-0000-000000000002","type":"RULE-SET","value":"https://example.invalid/a.list","note":"A","isEnabled":true}"#
        let decodedRule = try JSONDecoder().decode(RuleItem.self, from: Data(legacyRuleJSON.utf8))
        XCTAssertNil(decodedRule.ruleSetFormat)
        XCTAssertNil(decodedRule.ruleSetBehavior)
        XCTAssertNil(decodedRule.ruleSetNoResolve)
    }

    func testDNSFollowsProxyNodeDirectInterfaceAndPreventsDNSLeak() throws {
        let sub = ProxySubscription(name: "订阅", url: exitSubURL, role: .general)
        let hkGroup = NodeGroup(name: "香港", kind: .exit, subscriptionID: sub.id, filterPattern: "HK", autoTest: true)
        let usGroup = NodeGroup(name: "美国", kind: .exit, subscriptionID: sub.id, filterPattern: "US", autoTest: true)
        let hkTarget = NetworkTarget(name: "香港", mode: .proxy, exitGroupID: hkGroup.id, interfaceName: "en0")
        let usTarget = NetworkTarget(name: "美国", mode: .proxy, exitGroupID: usGroup.id, interfaceName: "en0")
        let defaultDirect = NetworkTarget(name: "默认", mode: .direct, interfaceName: nil)
        let usbDirect = NetworkTarget(name: "新加坡eSIM", mode: .direct, interfaceName: "en10")

        // 1. Proxy fallback + unbound default direct + USB eSIM direct + multi-proxy rule groups
        let profile = RoutingProfile(
            subscriptions: [sub],
            nodeGroups: [hkGroup, usGroup],
            targets: [defaultDirect, usbDirect, hkTarget, usTarget],
            ruleGroups: [
                RuleGroup(
                    name: "AI服务",
                    target: .target(usbDirect.id),
                    rules: [
                        RuleItem(type: .domainSuffix, value: "openai.com"),
                        RuleItem(type: .domain, value: "intranet.corp"),
                    ]
                ),
                RuleGroup(
                    name: "海外社交",
                    target: .target(usTarget.id),
                    rules: [
                        RuleItem(type: .domainSuffix, value: "x.com"),
                        RuleItem(type: .ruleSet, value: "https://example.invalid/geoip-us.mrs", ruleSetFormat: .mrs, ruleSetBehavior: .ipcidr),
                    ]
                ),
                RuleGroup(
                    name: "中国直连",
                    target: .target(defaultDirect.id),
                    rules: [
                        RuleItem(type: .domainSuffix, value: "cn"),
                        RuleItem(type: .geosite, value: "cn"),
                        RuleItem(type: .geoip, value: "CN"),
                    ]
                ),
            ],
            fallbackTarget: .target(hkTarget.id)
        )

        let config = try decodeJSON(try MihomoConfig.render(profile, interfaceDNS: ["en0": ["192.168.100.1"], "en10": ["192.168.0.1"]]))
        XCTAssertEqual(config["log-level"] as? String, "info")
        XCTAssertEqual(config["geo-auto-update"] as? Bool, false)
        XCTAssertNotNil(config["geox-url"])

        let dns = try XCTUnwrap(config["dns"] as? [String: Any])
        XCTAssertEqual(dns["enable"] as? Bool, true)
        XCTAssertEqual(dns["respect-rules"] as? Bool, false)
        XCTAssertEqual(dns["direct-nameserver-follow-policy"] as? Bool, true)
        // Anti-DNS-leak: MATCH goes to 香港 -> default nameserver resolves via #香港, no fallback leak
        XCTAssertEqual(dns["nameserver"] as? [String], ["https://1.1.1.1/dns-query#香港", "https://8.8.8.8/dns-query#香港"])
        XCTAssertNil(dns["fallback"])
        XCTAssertNil(dns["fallback-filter"])
        // Because an unbound direct target ("默认") exists alongside USB en10, direct-nameserver uses system + IP fallback
        XCTAssertEqual(dns["direct-nameserver"] as? [String], ["system", "223.5.5.5", "119.29.29.29"])
        // Proxy node domains share en0 -> proxy-server-nameserver uses discovered en0 DNS + IP fallback (never broken dhcp:// on macOS)
        XCTAssertEqual(dns["proxy-server-nameserver"] as? [String], ["192.168.100.1", "223.5.5.5", "119.29.29.29"])

        // nameserver-policy routes USB eSIM rules strictly via #新加坡eSIM (en10), default direct via system+fallback, US proxy via #美国, skips ipcidr rule-set,
        // and pins subscription hosts to direct DNS to prevent circular deadlock on startup.
        let policy = try XCTUnwrap(dns["nameserver-policy"] as? [String: [String]])
        XCTAssertEqual(policy["exit.example.invalid"], ["system", "223.5.5.5", "119.29.29.29"])
        XCTAssertEqual(policy["+.openai.com"], ["192.168.0.1#新加坡eSIM"])
        XCTAssertEqual(policy["intranet.corp"], ["192.168.0.1#新加坡eSIM"])
        XCTAssertEqual(policy["+.x.com"], ["https://1.1.1.1/dns-query#美国", "https://8.8.8.8/dns-query#美国"])
        XCTAssertEqual(policy["+.cn"], ["system", "223.5.5.5", "119.29.29.29"])
        XCTAssertEqual(policy["geosite:cn"], ["system", "223.5.5.5", "119.29.29.29"])
        XCTAssertFalse(policy.keys.contains { $0.hasPrefix("rule-set:") })

        // Verify preloadResources includes both proxy-provider and rule-provider, and custom logLevel works
        var debugProfile = profile
        debugProfile.logLevel = .debug
        let renderedDebug = try MihomoConfig.renderDetailed(debugProfile)
        let debugConfig = try decodeJSON(renderedDebug.data)
        XCTAssertEqual(debugConfig["log-level"] as? String, "debug")
        XCTAssertTrue(renderedDebug.preloadResources.contains { $0.kind == .proxyProvider && $0.url == exitSubURL })
        XCTAssertTrue(renderedDebug.preloadResources.contains { $0.kind == .ruleProvider && $0.url == "https://example.invalid/geoip-us.mrs" })

        // 2. Pure USB-only direct profile: default-nameserver uses discovered en10 DNS + fallback, direct/nameserver bind strictly to #新加坡eSIM
        let usbOnlyProfile = RoutingProfile(
            targets: [usbDirect],
            ruleGroups: [],
            fallbackTarget: .target(usbDirect.id)
        )
        let usbOnlyConfig = try decodeJSON(try MihomoConfig.render(usbOnlyProfile, interfaceDNS: ["en10": ["192.168.0.1"]]))
        let usbDNS = try XCTUnwrap(usbOnlyConfig["dns"] as? [String: Any])
        XCTAssertEqual(usbDNS["default-nameserver"] as? [String], ["192.168.0.1", "223.5.5.5", "119.29.29.29"])
        XCTAssertEqual(usbDNS["direct-nameserver"] as? [String], ["192.168.0.1#新加坡eSIM"])
        XCTAssertEqual(usbDNS["nameserver"] as? [String], ["192.168.0.1#新加坡eSIM"])
        XCTAssertNil(usbDNS["fallback"])
    }

    func testRuleProviderProxyModesAndProxyProviderStaysDirect() throws {
        let sub = ProxySubscription(name: "订阅", url: exitSubURL, role: .general)
        let hkGroup = NodeGroup(name: "香港", kind: .exit, subscriptionID: sub.id, filterPattern: "HK")
        let usGroup = NodeGroup(name: "美国", kind: .exit, subscriptionID: sub.id, filterPattern: "US")
        let hkTarget = NetworkTarget(name: "香港", mode: .proxy, exitGroupID: hkGroup.id)
        let usTarget = NetworkTarget(name: "美国", mode: .proxy, exitGroupID: usGroup.id)
        let directTarget = NetworkTarget(name: "国内直连", mode: .direct)

        let ghURL = "https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/Ruleset/OpenAi.list"
        let jsdURL = "https://fastly.jsdelivr.net/gh/ACL4SSR/ACL4SSR@master/Clash/ChinaDomain.list"

        var profile = RoutingProfile(
            ruleProviderProxyMode: .auto,
            subscriptions: [sub],
            nodeGroups: [hkGroup, usGroup],
            targets: [directTarget, hkTarget, usTarget],
            ruleGroups: [
                RuleGroup(
                    name: "规则集测试",
                    target: .target(hkTarget.id),
                    rules: [
                        RuleItem(type: .ruleSet, value: ghURL, ruleSetFormat: .text, ruleSetBehavior: .classical),
                        RuleItem(type: .ruleSet, value: jsdURL, ruleSetFormat: .text, ruleSetBehavior: .classical),
                    ]
                ),
            ],
            fallbackTarget: .target(hkTarget.id)
        )

        // Auto mode: raw.githubusercontent.com -> 香港, jsDelivr -> DIRECT; proxy-providers stays DIRECT
        let autoConfig = try decodeJSON(try MihomoConfig.render(profile))
        let autoRP = try XCTUnwrap(autoConfig["rule-providers"] as? [String: [String: Any]])
        XCTAssertEqual(autoRP.values.first { ($0["url"] as? String) == ghURL }?["proxy"] as? String, "香港")
        XCTAssertEqual(autoRP.values.first { ($0["url"] as? String) == jsdURL }?["proxy"] as? String, "DIRECT")
        let autoPP = try XCTUnwrap(autoConfig["proxy-providers"] as? [String: [String: Any]])
        XCTAssertEqual(autoPP.values.first?["proxy"] as? String, "DIRECT")

        // Direct mode: all rule-providers use DIRECT
        profile.ruleProviderProxyMode = .direct
        let directConfig = try decodeJSON(try MihomoConfig.render(profile))
        let directRP = try XCTUnwrap(directConfig["rule-providers"] as? [String: [String: Any]])
        XCTAssertEqual(directRP.values.first { ($0["url"] as? String) == ghURL }?["proxy"] as? String, "DIRECT")

        // Specific target mode (even one not referenced by any rule group): automatically activates `美国`
        profile.ruleProviderProxyMode = .target(usTarget.id)
        let targetConfig = try decodeJSON(try MihomoConfig.render(profile))
        let targetRP = try XCTUnwrap(targetConfig["rule-providers"] as? [String: [String: Any]])
        XCTAssertEqual(targetRP.values.first { ($0["url"] as? String) == ghURL }?["proxy"] as? String, "美国")
        XCTAssertEqual(targetRP.values.first { ($0["url"] as? String) == jsdURL }?["proxy"] as? String, "美国")
    }

    func testBundledResourceSeedingValidationAtomicUpdateAndFallback() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("RouteWeaverGeoTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let bundleDir = root.appendingPathComponent("bundled", isDirectory: true)
        let workDir = root.appendingPathComponent("work", isDirectory: true)
        try fm.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        // Synthetic valid MMDB (>= 1024 bytes with MaxMind marker) and valid protobuf .dat (>= 1024 bytes starting with 0x0A)
        let bundledMMDBData = Data(repeating: 0x01, count: 1500) + Data([0xAB, 0xCD, 0xEF]) + Data("MaxMind.com".utf8) + Data(repeating: 0x00, count: 32)
        let bundledDatData = Data([0x0A, 0x10]) + Data(repeating: 0x42, count: 1500)
        let bundledMMDB = bundleDir.appendingPathComponent("Country.mmdb")
        let bundledDat = bundleDir.appendingPathComponent("geosite.dat")
        try bundledMMDBData.write(to: bundledMMDB)
        try bundledDatData.write(to: bundledDat)

        let manifest = BundledResourceManifest(
            generatedAt: "2026-11-22T00:00:00Z",
            entries: [
                BundledResourceEntry(
                    id: "country-mmdb",
                    relativePath: "Country.mmdb",
                    kind: .mmdb,
                    version: "2026-11-22",
                    sha256: ResourceIntegrityValidator.sha256Hex(of: bundledMMDBData),
                    sizeBytes: Int64(bundledMMDBData.count),
                    sourceURL: "https://example.invalid/country.mmdb",
                    license: "GPL-3.0",
                    attribution: "MetaCubeX/meta-rules-dat"
                ),
                BundledResourceEntry(
                    id: "geosite-dat",
                    relativePath: "geosite.dat",
                    kind: .dat,
                    version: "2026-11-22",
                    sha256: ResourceIntegrityValidator.sha256Hex(of: bundledDatData),
                    sizeBytes: Int64(bundledDatData.count),
                    sourceURL: "https://example.invalid/geosite.dat",
                    license: "GPL-3.0",
                    attribution: "MetaCubeX/meta-rules-dat"
                ),
            ]
        )

        // 1. Cold start seeds missing resources
        let firstSeed = try BundledResourceManager.seedMissingResources(from: bundleDir, to: workDir, manifest: manifest)
        XCTAssertEqual(firstSeed.seeded, ["Country.mmdb", "geosite.dat"])
        XCTAssertTrue(firstSeed.keptExisting.isEmpty)

        // 2. Simulate user-updated newer valid MMDB: subsequent seed must NOT overwrite it
        let newerMMDBData = Data(repeating: 0x09, count: 1800) + Data([0xAB, 0xCD, 0xEF]) + Data("MaxMind.com".utf8) + Data(repeating: 0x00, count: 32)
        let destMMDB = workDir.appendingPathComponent("Country.mmdb")
        try newerMMDBData.write(to: destMMDB)
        let secondSeed = try BundledResourceManager.seedMissingResources(from: bundleDir, to: workDir, manifest: manifest)
        XCTAssertEqual(secondSeed.keptExisting, ["Country.mmdb", "geosite.dat"])
        XCTAssertEqual(try Data(contentsOf: destMMDB), newerMMDBData)

        // 3. Corrupted download (HTML error page / truncated) must NOT overwrite good cached MMDB
        let badTemp = root.appendingPathComponent("bad.tmp")
        try Data("<html>502 Bad Gateway</html>".utf8).write(to: badTemp)
        let badOutcome = BundledResourceManager.installValidatedUpdate(
            tempFile: badTemp,
            kind: .mmdb,
            destination: destMMDB,
            bundledFallback: bundledMMDB
        )
        if case .keptExistingAfterFailure = badOutcome {
            // expected
        } else {
            XCTFail("Expected keptExistingAfterFailure, got \(badOutcome)")
        }
        XCTAssertEqual(try Data(contentsOf: destMMDB), newerMMDBData)

        // 4. Valid update atomically replaces destination
        let goodTemp = root.appendingPathComponent("good.tmp")
        let v3MMDBData = Data(repeating: 0x07, count: 2048) + Data([0xAB, 0xCD, 0xEF]) + Data("MaxMind.com".utf8) + Data(repeating: 0x00, count: 16)
        try v3MMDBData.write(to: goodTemp)
        let goodOutcome = BundledResourceManager.installValidatedUpdate(
            tempFile: goodTemp,
            kind: .mmdb,
            destination: destMMDB,
            bundledFallback: bundledMMDB
        )
        XCTAssertEqual(goodOutcome, .updated)
        XCTAssertEqual(try Data(contentsOf: destMMDB), v3MMDBData)

        // 5. If destination is missing/corrupted and download fails, restores bundled fallback
        try Data("corrupted".utf8).write(to: destMMDB)
        let badTemp2 = root.appendingPathComponent("bad2.tmp")
        try Data().write(to: badTemp2)
        let fallbackOutcome = BundledResourceManager.installValidatedUpdate(
            tempFile: badTemp2,
            kind: .mmdb,
            destination: destMMDB,
            bundledFallback: bundledMMDB
        )
        if case .restoredBundledAfterFailure = fallbackOutcome {
            // expected
        } else {
            XCTFail("Expected restoredBundledAfterFailure, got \(fallbackOutcome)")
        }
        XCTAssertEqual(try Data(contentsOf: destMMDB), bundledMMDBData)
    }

    func testTunModeConfigRenderingAndLegacyProfileDecode() throws {
        let directTarget = NetworkTarget(name: "直连", mode: .direct)

        // 1. Default profile has TUN disabled, redir-host DNS, no sniffer, no fake-ip-range
        let defaultProfile = RoutingProfile(
            targets: [directTarget],
            ruleGroups: [],
            fallbackTarget: .target(directTarget.id)
        )
        let defaultRendered = try MihomoConfig.renderDetailed(defaultProfile)
        XCTAssertFalse(defaultRendered.tunEnabled)
        let defaultConfig = try decodeJSON(defaultRendered.data)
        let defaultTun = try XCTUnwrap(defaultConfig["tun"] as? [String: Any])
        XCTAssertEqual(defaultTun["enable"] as? Bool, false)
        XCTAssertNil(defaultConfig["sniffer"])
        let defaultDNS = try XCTUnwrap(defaultConfig["dns"] as? [String: Any])
        XCTAssertEqual(defaultDNS["enhanced-mode"] as? String, "redir-host")
        XCTAssertNil(defaultDNS["fake-ip-range"])

        // 2. TUN enabled with default fake-ip + mixed stack + strict-route
        var tunProfile = defaultProfile
        tunProfile.tunEnabled = true
        let tunRendered = try MihomoConfig.renderDetailed(tunProfile)
        XCTAssertTrue(tunRendered.tunEnabled)
        let tunConfig = try decodeJSON(tunRendered.data)
        XCTAssertEqual(tunConfig["find-process-mode"] as? String, "strict")

        let tun = try XCTUnwrap(tunConfig["tun"] as? [String: Any])
        XCTAssertEqual(tun["enable"] as? Bool, true)
        XCTAssertEqual(tun["stack"] as? String, "mixed")
        XCTAssertEqual(tun["auto-route"] as? Bool, true)
        XCTAssertEqual(tun["auto-detect-interface"] as? Bool, true)
        XCTAssertEqual(tun["strict-route"] as? Bool, true)
        XCTAssertEqual(tun["dns-hijack"] as? [String], ["any:53", "tcp://any:53"])

        let sniffer = try XCTUnwrap(tunConfig["sniffer"] as? [String: Any])
        XCTAssertEqual(sniffer["enable"] as? Bool, true)
        XCTAssertEqual(sniffer["parse-pure-ip"] as? Bool, true)

        let tunDNS = try XCTUnwrap(tunConfig["dns"] as? [String: Any])
        XCTAssertEqual(tunDNS["enhanced-mode"] as? String, "fake-ip")
        XCTAssertEqual(tunDNS["fake-ip-range"] as? String, MihomoConfig.defaultFakeIPRange)
        XCTAssertEqual(tunDNS["fake-ip-filter"] as? [String], MihomoConfig.defaultFakeIPFilter)
        // In TUN mode, system DNS is hijacked to 198.18.0.2; omit `system` to prevent self-lookup loops.
        XCTAssertEqual(tunDNS["default-nameserver"] as? [String], ["223.5.5.5", "119.29.29.29"])
        XCTAssertEqual(tunDNS["proxy-server-nameserver"] as? [String], ["223.5.5.5", "119.29.29.29"])
        XCTAssertEqual(tunDNS["direct-nameserver"] as? [String], ["223.5.5.5", "119.29.29.29"])
        XCTAssertEqual(tunDNS["nameserver"] as? [String], ["223.5.5.5", "119.29.29.29"])

        // 3. TUN enabled with redir-host + system stack + strict-route disabled
        tunProfile.tunStack = .system
        tunProfile.tunStrictRoute = false
        tunProfile.tunDNSMode = .redirHost
        let customTunConfig = try decodeJSON(try MihomoConfig.render(tunProfile))
        let customTun = try XCTUnwrap(customTunConfig["tun"] as? [String: Any])
        XCTAssertEqual(customTun["stack"] as? String, "system")
        XCTAssertEqual(customTun["strict-route"] as? Bool, false)
        let customDNS = try XCTUnwrap(customTunConfig["dns"] as? [String: Any])
        XCTAssertEqual(customDNS["enhanced-mode"] as? String, "redir-host")
        XCTAssertNil(customDNS["fake-ip-range"])
        XCTAssertNil(customDNS["fake-ip-filter"])

        // 4. Legacy v2 JSON without TUN fields decodes cleanly with safe defaults
        let legacyJSON = #"{"schemaVersion":2,"name":"旧方案","mixedPort":7890,"allowLAN":false,"subscriptions":[],"nodeGroups":[],"targets":[],"ruleGroups":[],"fallbackTarget":{"kind":"reject"}}"#
        let decoded = try RoutingProfile.decodeOrMigrate(from: Data(legacyJSON.utf8))
        XCTAssertFalse(decoded.tunEnabled)
        XCTAssertFalse(decoded.gatewayModeEnabled)
        XCTAssertEqual(decoded.tunStack, .mixed)
        XCTAssertTrue(decoded.tunStrictRoute)
        XCTAssertEqual(decoded.tunDNSMode, .fakeIP)
    }

    func testGatewayModeEnablesTunAllowLANAndDNSListen53() throws {
        let direct = NetworkTarget(name: "直连", mode: .direct)

        // Even when tunEnabled and allowLAN are false, gatewayModeEnabled forces TUN + allow-lan + DNS 0.0.0.0:53
        let gatewayProfile = RoutingProfile(
            name: "网关测试",
            mixedPort: 7890,
            allowLAN: false,
            tunEnabled: false,
            gatewayModeEnabled: true,
            tunStack: .mixed,
            tunStrictRoute: true,
            tunDNSMode: .fakeIP,
            targets: [direct],
            ruleGroups: [],
            fallbackTarget: .target(direct.id)
        )

        XCTAssertTrue(gatewayProfile.effectiveTunEnabled)
        XCTAssertTrue(gatewayProfile.effectiveAllowLAN)

        let rendered = try MihomoConfig.renderDetailed(gatewayProfile)
        XCTAssertTrue(rendered.tunEnabled)
        XCTAssertTrue(rendered.gatewayModeEnabled)

        let config = try decodeJSON(rendered.data)
        XCTAssertEqual(config["allow-lan"] as? Bool, true)
        XCTAssertEqual(config["bind-address"] as? String, "*")
        XCTAssertEqual(config["find-process-mode"] as? String, "strict")

        let tun = try XCTUnwrap(config["tun"] as? [String: Any])
        XCTAssertEqual(tun["enable"] as? Bool, true)
        XCTAssertEqual(tun["auto-route"] as? Bool, true)
        XCTAssertEqual(tun["auto-detect-interface"] as? Bool, true)
        XCTAssertEqual(tun["endpoint-independent-nat"] as? Bool, true)
        XCTAssertEqual(tun["dns-hijack"] as? [String], ["any:53", "tcp://any:53"])

        let sniffer = try XCTUnwrap(config["sniffer"] as? [String: Any])
        XCTAssertEqual(sniffer["enable"] as? Bool, true)

        let dns = try XCTUnwrap(config["dns"] as? [String: Any])
        XCTAssertEqual(dns["listen"] as? String, "0.0.0.0:53")
        XCTAssertEqual(dns["enhanced-mode"] as? String, "fake-ip")
        XCTAssertEqual(dns["fake-ip-range"] as? String, MihomoConfig.defaultFakeIPRange)

        // Non-gateway TUN mode should NOT bind 0.0.0.0:53 or enable endpoint-independent-nat
        var tunOnlyProfile = gatewayProfile
        tunOnlyProfile.tunEnabled = true
        tunOnlyProfile.gatewayModeEnabled = false
        let tunOnlyRendered = try MihomoConfig.renderDetailed(tunOnlyProfile)
        XCTAssertTrue(tunOnlyRendered.tunEnabled)
        XCTAssertFalse(tunOnlyRendered.gatewayModeEnabled)
        let tunOnlyConfig = try decodeJSON(tunOnlyRendered.data)
        let tunOnlyDNS = try XCTUnwrap(tunOnlyConfig["dns"] as? [String: Any])
        XCTAssertNil(tunOnlyDNS["listen"])
        let tunOnlyTun = try XCTUnwrap(tunOnlyConfig["tun"] as? [String: Any])
        XCTAssertNil(tunOnlyTun["endpoint-independent-nat"])
    }

    func testCustomDNSHostsWildcardsServersFakeIPFilterAndUpstreamOverrides() throws {
        let sub = ProxySubscription(name: "订阅", url: exitSubURL, role: .general)
        let hkGroup = NodeGroup(name: "香港", kind: .exit, subscriptionID: sub.id, filterPattern: "HK", autoTest: true)
        let hkTarget = NetworkTarget(name: "香港", mode: .proxy, exitGroupID: hkGroup.id)
        let directTarget = NetworkTarget(name: "国内直连", mode: .direct)
        let corpTarget = NetworkTarget(name: "内网网卡", mode: .direct, interfaceName: "en5")

        let module = HostModule(
            name: "Module",
            url: "https://example.invalid/hosts.sgmodule",
            cachedHosts: [
                "override.example": "9.9.9.9",
                "module.example": "8.8.8.8",
            ]
        )

        let customDNS = CustomDNSConfig(
            entries: [
                CustomDNSEntry(pattern: "override.example", kind: .host, value: "10.0.0.1"),
                CustomDNSEntry(pattern: "*.dev.local", kind: .host, value: "127.0.0.1"),
                CustomDNSEntry(pattern: "+.home.arpa", kind: .host, value: "192.168.1.10, 192.168.1.11"),
                CustomDNSEntry(pattern: ".internal.example", kind: .host, value: "gateway.internal.example"),
                CustomDNSEntry(pattern: "disabled.local", kind: .host, value: "127.0.0.2", isEnabled: false),
                CustomDNSEntry(
                    pattern: "*.corp.local",
                    kind: .server,
                    value: "10.0.0.53",
                    targetID: corpTarget.id,
                    bypassFakeIP: true
                ),
                CustomDNSEntry(
                    pattern: "+.company.com",
                    kind: .server,
                    value: "https://dns.alidns.com/dns-query, 223.5.5.5"
                ),
                // Explicitly override a subdomain under +.cn to use #香港 (same as defaultNameserver):
                // must NOT be omitted so it beats the broader +.cn direct policy.
                CustomDNSEntry(
                    pattern: "special.example.cn",
                    kind: .server,
                    value: "https://1.1.1.1/dns-query, https://8.8.8.8/dns-query",
                    targetID: hkTarget.id
                ),
            ],
            directServers: ["https://dns.alidns.com/dns-query", "223.5.5.5"],
            bootstrapServers: ["223.5.5.5", "119.29.29.29"]
        )

        let profile = RoutingProfile(
            tunEnabled: true,
            tunDNSMode: .fakeIP,
            subscriptions: [sub],
            hostModules: [module],
            customDNS: customDNS,
            nodeGroups: [hkGroup],
            targets: [directTarget, corpTarget, hkTarget],
            ruleGroups: [
                RuleGroup(
                    name: "国内",
                    target: .target(directTarget.id),
                    rules: [RuleItem(type: .domainSuffix, value: "cn")]
                ),
            ],
            fallbackTarget: .target(hkTarget.id)
        )

        // Active targets must include `corpTarget` because an enabled custom DNS server entry references it
        XCTAssertTrue(profile.activeTargetIDs.contains(corpTarget.id))

        let rendered = try MihomoConfig.renderDetailed(profile)
        XCTAssertTrue(rendered.requiredInterfaces.contains("en5"))
        let config = try decodeJSON(rendered.data)

        // 1. Verify merged hosts with wildcards, multi-IP, CNAME, module override, and disabled exclusion
        let hosts = try XCTUnwrap(config["hosts"] as? [String: Any])
        XCTAssertEqual(hosts["module.example"] as? String, "8.8.8.8")
        XCTAssertEqual(hosts["override.example"] as? String, "10.0.0.1")
        XCTAssertEqual(hosts["*.dev.local"] as? String, "127.0.0.1")
        XCTAssertEqual(hosts["+.home.arpa"] as? [String], ["192.168.1.10", "192.168.1.11"])
        XCTAssertEqual(hosts[".internal.example"] as? String, "gateway.internal.example")
        XCTAssertNil(hosts["disabled.local"])

        // 2. Verify custom DNS server policies, target binding, and non-omission when matching defaultNameserver
        let dns = try XCTUnwrap(config["dns"] as? [String: Any])
        XCTAssertEqual(dns["default-nameserver"] as? [String], ["223.5.5.5", "119.29.29.29"])
        XCTAssertEqual(dns["proxy-server-nameserver"] as? [String], ["223.5.5.5", "119.29.29.29"])
        XCTAssertEqual(dns["direct-nameserver"] as? [String], ["https://dns.alidns.com/dns-query", "223.5.5.5"])

        let policy = try XCTUnwrap(dns["nameserver-policy"] as? [String: [String]])
        XCTAssertEqual(policy["*.corp.local"], ["10.0.0.53#内网网卡"])
        XCTAssertEqual(policy["+.company.com"], ["https://dns.alidns.com/dns-query", "223.5.5.5"])
        XCTAssertEqual(
            policy["special.example.cn"],
            ["https://1.1.1.1/dns-query#香港", "https://8.8.8.8/dns-query#香港"]
        )
        XCTAssertEqual(policy["+.cn"], ["https://dns.alidns.com/dns-query", "223.5.5.5"])

        // 3. Verify bypassFakeIP appended to fake-ip-filter
        let fakeIPFilter = try XCTUnwrap(dns["fake-ip-filter"] as? [String])
        XCTAssertTrue(fakeIPFilter.contains("*.corp.local"))
        XCTAssertFalse(fakeIPFilter.contains("+.company.com"))

        // 4. Verify validation rejects bare wildcard, self-referencing host, and invalid server
        var badWildcard = profile
        badWildcard.customDNS.entries = [CustomDNSEntry(pattern: "*", kind: .host, value: "127.0.0.1")]
        XCTAssertThrowsError(try MihomoConfig.render(badWildcard)) { error in
            if case RoutingConfigurationError.invalidDNS = error {} else {
                XCTFail("Expected invalidDNS, got \(error)")
            }
        }

        var selfCNAME = profile
        selfCNAME.customDNS.entries = [CustomDNSEntry(pattern: "a.local", kind: .host, value: "a.local")]
        XCTAssertThrowsError(try MihomoConfig.render(selfCNAME)) { error in
            if case RoutingConfigurationError.invalidDNS = error {} else {
                XCTFail("Expected invalidDNS, got \(error)")
            }
        }

        var badServer = profile
        badServer.customDNS.entries = [CustomDNSEntry(pattern: "*.corp.local", kind: .server, value: "ftp://1.1.1.1")]
        XCTAssertThrowsError(try MihomoConfig.render(badServer)) { error in
            if case RoutingConfigurationError.invalidDNS = error {} else {
                XCTFail("Expected invalidDNS, got \(error)")
            }
        }
    }

    func testCustomDNSBulkParserAndLegacyProfileDecode() throws {
        let bulk = """
        # Comment line
        [Host]
        *.corp.local = server:10.0.0.53
        +.company.com = server:https://dns.alidns.com/dns-query, 223.5.5.5
        *.dev.local = 127.0.0.1
        multi.local = 10.0.0.1, 10.0.0.2
        loop.local = loop.local
        192.168.1.10 nas.local *.nas.local # NAS hosts
        media.home.arpa 192.168.100.2
        list.home.arpa 192.168.100.2
        *.lan.example server:10.0.0.53
        """
        let parsed = CustomDNSParser.parseBulk(bulk)
        XCTAssertEqual(parsed.count, 9)
        XCTAssertEqual(parsed[0].pattern, "*.corp.local")
        XCTAssertEqual(parsed[0].kind, .server)
        XCTAssertEqual(parsed[0].value, "10.0.0.53")
        XCTAssertTrue(parsed[0].isWildcard)

        XCTAssertEqual(parsed[1].pattern, "+.company.com")
        XCTAssertEqual(parsed[1].kind, .server)
        XCTAssertEqual(parsed[1].value, "https://dns.alidns.com/dns-query, 223.5.5.5")

        XCTAssertEqual(parsed[2].pattern, "*.dev.local")
        XCTAssertEqual(parsed[2].kind, .host)
        XCTAssertEqual(parsed[2].value, "127.0.0.1")

        XCTAssertEqual(parsed[3].pattern, "multi.local")
        XCTAssertEqual(parsed[3].kind, .host)
        XCTAssertEqual(parsed[3].value, "10.0.0.1, 10.0.0.2")

        XCTAssertEqual(parsed[4].pattern, "nas.local")
        XCTAssertEqual(parsed[4].kind, .host)
        XCTAssertEqual(parsed[4].value, "192.168.1.10")

        XCTAssertEqual(parsed[5].pattern, "*.nas.local")
        XCTAssertEqual(parsed[5].kind, .host)
        XCTAssertEqual(parsed[5].value, "192.168.1.10")

        // Host-first whitespace-separated entries (`<domain> <ip>` & `<domain> server:...`)
        XCTAssertEqual(parsed[6].pattern, "media.home.arpa")
        XCTAssertEqual(parsed[6].kind, .host)
        XCTAssertEqual(parsed[6].value, "192.168.100.2")

        XCTAssertEqual(parsed[7].pattern, "list.home.arpa")
        XCTAssertEqual(parsed[7].kind, .host)
        XCTAssertEqual(parsed[7].value, "192.168.100.2")

        XCTAssertEqual(parsed[8].pattern, "*.lan.example")
        XCTAssertEqual(parsed[8].kind, .server)
        XCTAssertEqual(parsed[8].value, "10.0.0.53")

        // Legacy profile JSON without `customDNS` decodes cleanly
        let legacyProfileJSON = #"{"schemaVersion":2,"name":"旧方案","mixedPort":7890,"targets":[],"ruleGroups":[]}"#
        let decoded = try JSONDecoder().decode(RoutingProfile.self, from: Data(legacyProfileJSON.utf8))
        XCTAssertTrue(decoded.customDNS.isEmpty)
    }
}
