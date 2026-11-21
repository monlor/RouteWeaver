import Foundation
import XCTest
@testable import RoutingCore

final class RoutingCoreTests: XCTestCase {
    private let subscription = "https://example.invalid/nodes?token=fixture"

    private func configured(_ template: RoutingTemplate = .dualUplink) -> RoutingProfile {
        var profile = RoutingProfile.template(template)
        profile.claudeInterface = "en5"
        profile.domesticInterface = "en0"
        profile.exitProviderURL = subscription
        profile.entryPattern = "(?i)relay|入口"
        return profile
    }

    private func config(_ profile: RoutingProfile) throws -> [String: Any] {
        let data = try MihomoConfig.render(profile)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testDualUplinkRulePrecedenceAndSecuredListener() throws {
        let config = try config(configured())
        let rules = try XCTUnwrap(config["rules"] as? [String])
        let claude = try XCTUnwrap(rules.firstIndex(of: "DOMAIN-SUFFIX,claude.ai,Claude-Interface"))
        let google = try XCTUnwrap(rules.firstIndex(of: "GEOSITE,google,Group-A"))
        let social = try XCTUnwrap(rules.firstIndex(of: "DOMAIN-SUFFIX,x.com,Group-A"))
        let cn = try XCTUnwrap(rules.firstIndex(of: "GEOSITE,cn,Domestic-Interface"))
        let cnIP = try XCTUnwrap(rules.firstIndex(of: "GEOIP,CN,Domestic-Interface"))
        XCTAssertLessThan(claude, google)
        XCTAssertLessThan(google, social)
        XCTAssertLessThan(social, cn)
        XCTAssertLessThan(cn, cnIP)
        XCTAssertEqual(rules.last, "MATCH,Group-B")
        XCTAssertEqual(config["bind-address"] as? String, "127.0.0.1")
        XCTAssertEqual(config["allow-lan"] as? Bool, false)
        XCTAssertEqual((config["tun"] as? [String: Bool])?["enable"], false)
        XCTAssertNil(config["external-controller"])
        XCTAssertNil(config["secret"])
        let proxies = try XCTUnwrap(config["proxies"] as? [[String: Any]])
        XCTAssertEqual(proxies[0]["interface-name"] as? String, "en5")
        XCTAssertEqual(proxies[1]["interface-name"] as? String, "en0")
    }

    func testSharedSubscriptionUsesSeparateCachesAndNoRecursiveDialer() throws {
        let profile = configured()
        let config = try config(profile)
        let providers = try XCTUnwrap(config["proxy-providers"] as? [String: [String: Any]])
        let l = try XCTUnwrap(providers["entry-l"])
        let a = try XCTUnwrap(providers["exit-a"])
        let b = try XCTUnwrap(providers["exit-b"])
        XCTAssertEqual([l, a, b].compactMap { $0["url"] as? String }, Array(repeating: subscription, count: 3))
        XCTAssertEqual(Set([l, a, b].compactMap { $0["path"] as? String }).count, 3)
        XCTAssertEqual((l["override"] as? [String: String])?["dialer-proxy"], "")
        XCTAssertEqual((l["override"] as? [String: String])?["interface-name"], "en0")
        XCTAssertEqual((a["override"] as? [String: String])?["dialer-proxy"], "Entry-L")
        XCTAssertEqual((b["override"] as? [String: String])?["dialer-proxy"], "Entry-L")
        XCTAssertEqual(a["filter"] as? String, profile.groupAPattern)
        XCTAssertEqual(b["filter"] as? String, profile.groupBPattern)
        XCTAssertEqual(l["filter"] as? String, profile.entryPattern)
        XCTAssertEqual((l["health-check"] as? [String: Any])?["enable"] as? Bool, false)
        XCTAssertEqual((a["health-check"] as? [String: Any])?["enable"] as? Bool, true)
        let groups = try XCTUnwrap(config["proxy-groups"] as? [[String: Any]])
        XCTAssertEqual(groups.compactMap { $0["type"] as? String }, ["select", "url-test", "url-test"])
        XCTAssertEqual(groups.compactMap { $0["use"] as? [String] }, [["entry-l"], ["exit-a"], ["exit-b"]])
        XCTAssertEqual(groups.compactMap { $0["empty-fallback"] as? String }, ["REJECT", "REJECT", "REJECT"])
        XCTAssertTrue(groups.allSatisfy { $0["proxies"] == nil })
    }

    func testSharedSubscriptionRequiresDistinctEntryFilter() throws {
        var profile = configured()
        profile.entryPattern = "   "
        XCTAssertThrowsError(try config(profile)) {
            XCTAssertEqual($0 as? RoutingConfigurationError, .ambiguousEntryPattern)
        }
        profile.entryProviderURL = subscription
        profile.entryPattern = profile.groupAPattern
        XCTAssertThrowsError(try config(profile)) {
            XCTAssertEqual($0 as? RoutingConfigurationError, .ambiguousEntryPattern)
        }
        profile.entryProviderURL = "https://relay.example.invalid/pool"
        profile.entryPattern = ""
        let config = try config(profile)
        let providers = try XCTUnwrap(config["proxy-providers"] as? [String: [String: Any]])
        XCTAssertNil(providers["entry-l"]?["filter"])
    }

    func testSubscriptionAndPatternChangesInvalidateOnlyAffectedCaches() throws {
        func paths(_ p: RoutingProfile) throws -> [String: String] {
            let config = try config(p)
            return try XCTUnwrap(config["proxy-providers"] as? [String: [String: Any]])
                .compactMapValues { $0["path"] as? String }
        }
        var changed = configured()
        let original = try paths(changed)
        XCTAssertEqual(original, try paths(changed))
        changed.groupAPattern = "(?i)Seattle"
        let newFilter = try paths(changed)
        XCTAssertNotEqual(original["exit-a"], newFilter["exit-a"])
        XCTAssertEqual(original["entry-l"], newFilter["entry-l"])
        XCTAssertEqual(original["exit-b"], newFilter["exit-b"])
        changed.exitProviderURL = "https://example.invalid/other"
        let newSource = try paths(changed)
        XCTAssertNotEqual(newFilter["exit-b"], newSource["exit-b"])
    }

    func testUnifiedAndGoogleOnlyTemplatesHaveMaterialRoutingDifferences() throws {
        var unified = configured(.unifiedUplink)
        unified.claudeInterface = ""
        XCTAssertEqual(unified.requiredInterfaces, ["en0"])
        let proxies = try XCTUnwrap(config(unified)["proxies"] as? [[String: Any]])
        XCTAssertEqual(proxies.compactMap { $0["interface-name"] as? String }, ["en0", "en0"])
        let rules = try XCTUnwrap(config(configured(.googleOnlyA))["rules"] as? [String])
        XCTAssertTrue(rules.contains("GEOSITE,youtube,Group-A"))
        XCTAssertTrue(rules.contains("DOMAIN-SUFFIX,x.com,Group-B"))
        XCTAssertEqual(rules.last, "MATCH,Group-B")
        XCTAssertEqual(RoutingTemplate.allCases.count, 3)
    }

    func testValidationFailuresAndLoopbackController() throws {
        var profile = configured()
        profile.claudeInterface = "utun1"
        XCTAssertThrowsError(try config(profile)) {
            XCTAssertEqual($0 as? RoutingConfigurationError, .invalidInterface("Claude 出口"))
        }
        profile.claudeInterface = " en0 "
        XCTAssertThrowsError(try config(profile)) {
            XCTAssertEqual($0 as? RoutingConfigurationError, .duplicateUplink)
        }
        profile.claudeInterface = "en5"
        profile.groupAPattern = "(invalid"
        XCTAssertThrowsError(try config(profile)) {
            XCTAssertEqual($0 as? RoutingConfigurationError, .invalidPattern("节点组 A"))
        }
        profile = configured()
        profile.exitProviderURL = "http://example.invalid/nodes"
        XCTAssertThrowsError(try config(profile)) {
            XCTAssertEqual($0 as? RoutingConfigurationError, .invalidSubscription("出口 A/B 订阅"))
        }
        profile = configured()
        profile.mixedPort = 80
        XCTAssertThrowsError(try config(profile)) {
            XCTAssertEqual($0 as? RoutingConfigurationError, .invalidPort("本地代理端口"))
        }
        profile = configured()
        XCTAssertThrowsError(try MihomoConfig.render(profile, controllerPort: profile.mixedPort, secret: "key"))
        XCTAssertThrowsError(try MihomoConfig.render(profile, controllerPort: 9090))
        let data = try MihomoConfig.render(profile, controllerPort: 9090, secret: "test-secret")
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(values["external-controller"] as? String, "127.0.0.1:9090")
        XCTAssertEqual(values["secret"] as? String, "test-secret")
    }

    func testEngineVersionRequiresFailClosedStableSupport() {
        XCTAssertTrue(MihomoConfig.supportsVersionOutput("Mihomo Meta v1.19.27 darwin arm64 with go1.26.2"))
        XCTAssertTrue(MihomoConfig.supportsVersionOutput("Mihomo Meta v1.20.0 darwin amd64"))
        XCTAssertFalse(MihomoConfig.supportsVersionOutput("Mihomo Meta v1.19.26 darwin arm64"))
        XCTAssertFalse(MihomoConfig.supportsVersionOutput("Mihomo Meta v1.20.0-rc1 darwin arm64"))
        XCTAssertFalse(MihomoConfig.supportsVersionOutput("Clash v1.19.27 darwin arm64"))
    }
}
