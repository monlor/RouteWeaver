import Foundation
import RoutingCore
@testable import RouteWeaverRuntime
import XCTest

private final class FakeNetworkSetupTransport: NetworkSetupTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var recordedCommands: [[String]] = []
    private var handler: @Sendable ([String]) throws -> NetworkSetupCommandResult

    init(
        handler: @escaping @Sendable ([String]) throws -> NetworkSetupCommandResult = { args in
            FakeNetworkSetupTransport.defaultResponse(for: args)
        }
    ) {
        self.handler = handler
    }

    func setHandler(_ handler: @escaping @Sendable ([String]) throws -> NetworkSetupCommandResult) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    func run(_ arguments: [String]) async throws -> NetworkSetupCommandResult {
        let currentHandler: @Sendable ([String]) throws -> NetworkSetupCommandResult = lock.withLock {
            recordedCommands.append(arguments)
            return handler
        }
        return try currentHandler(arguments)
    }

    static func defaultResponse(for args: [String]) -> NetworkSetupCommandResult {
        guard let command = args.first else {
            return NetworkSetupCommandResult(terminationStatus: 0)
        }
        switch command {
        case "-listallhardwareports":
            return NetworkSetupCommandResult(
                terminationStatus: 0,
                standardOutput: """
                Hardware Port: Wi-Fi
                Device: en0
                Ethernet Address: aa:bb:cc:dd:ee:ff
                """
            )
        case "-getinfo":
            return NetworkSetupCommandResult(
                terminationStatus: 0,
                standardOutput: """
                DHCP Configuration
                IP address: 192.168.1.42
                Subnet mask: 255.255.255.0
                Router: 192.168.1.1
                """
            )
        case "-getdnsservers":
            return NetworkSetupCommandResult(
                terminationStatus: 0,
                standardOutput: "There aren't any DNS Servers set on Wi-Fi.\n"
            )
        case "-getwebproxy", "-getsecurewebproxy", "-getsocksfirewallproxy":
            return NetworkSetupCommandResult(
                terminationStatus: 0,
                standardOutput: """
                Enabled: No
                Server:
                Port: 0
                Authenticated Proxy Enabled: 0
                """
            )
        default:
            return NetworkSetupCommandResult(terminationStatus: 0)
        }
    }
}

private final class InMemoryRemoteNetworkLinkStore: RemoteNetworkLinkStore {
    var storedLink: ActiveRemoteNetworkLink?
    private(set) var saveHistory: [ActiveRemoteNetworkLink?] = []

    init(initialLink: ActiveRemoteNetworkLink? = nil) {
        self.storedLink = initialLink
    }

    func loadActiveLink() -> ActiveRemoteNetworkLink? {
        storedLink
    }

    func saveActiveLink(_ link: ActiveRemoteNetworkLink?) {
        storedLink = link
        saveHistory.append(link)
    }
}

@MainActor
final class RemoteNetworkBridgeTests: XCTestCase {
    private func makeHost(
        id: String = "host-1",
        name: String = "Mac Studio",
        ip: String = "10.0.0.2"
    ) -> RemoteSavedHost {
        RemoteSavedHost(
            hostDeviceId: id,
            hostName: name,
            host: ip,
            port: 9090,
            token: "secret"
        )
    }

    func testGatewayConnectAndRestoreHappyPath() async {
        let transport = FakeNetworkSetupTransport()
        let store = InMemoryRemoteNetworkLinkStore()
        let bridge = RemoteNetworkBridge(transport: transport, linkStore: store)
        let host = makeHost()

        let connected = await bridge.connectAsGateway(host: host, preferredBSDInterface: "en0")
        XCTAssertTrue(connected)
        XCTAssertFalse(bridge.isApplying)
        XCTAssertNil(bridge.lastError)
        XCTAssertNotNil(bridge.feedback)
        XCTAssertEqual(bridge.activeLink?.mode, .gateway)
        XCTAssertEqual(bridge.activeLink?.serviceName, "Wi-Fi")
        XCTAssertEqual(bridge.activeLink, store.storedLink)

        XCTAssertEqual(
            transport.recordedCommands,
            [
                ["-listallhardwareports"],
                ["-getinfo", "Wi-Fi"],
                ["-getdnsservers", "Wi-Fi"],
                ["-setmanual", "Wi-Fi", "192.168.1.42", "255.255.255.0", "10.0.0.2"],
                ["-setdnsservers", "Wi-Fi", "10.0.0.2"]
            ]
        )

        let restored = await bridge.disconnectAndRestore()
        XCTAssertTrue(restored)
        XCTAssertFalse(bridge.isApplying)
        XCTAssertNil(bridge.lastError)
        XCTAssertNotNil(bridge.feedback)
        XCTAssertNil(bridge.activeLink)
        XCTAssertNil(store.storedLink)

        XCTAssertEqual(
            Array(transport.recordedCommands.suffix(2)),
            [
                ["-setdhcp", "Wi-Fi"],
                ["-setdnsservers", "Wi-Fi", "Empty"]
            ]
        )
    }

    func testHTTPProxyConnectAndRestoreHappyPath() async {
        let transport = FakeNetworkSetupTransport { args in
            if args.first == "-getwebproxy" {
                return NetworkSetupCommandResult(
                    terminationStatus: 0,
                    standardOutput: "Enabled: Yes\nServer: 127.0.0.1\nPort: 8080\n"
                )
            }
            return FakeNetworkSetupTransport.defaultResponse(for: args)
        }
        let store = InMemoryRemoteNetworkLinkStore()
        let bridge = RemoteNetworkBridge(transport: transport, linkStore: store)

        let connected = await bridge.connectAsHTTPProxy(
            host: makeHost(),
            port: 7890,
            preferredBSDInterface: nil
        )
        XCTAssertTrue(connected)
        XCTAssertEqual(bridge.activeLink?.mode, .httpProxy)
        XCTAssertEqual(bridge.activeLink?.port, 7890)
        XCTAssertEqual(store.storedLink, bridge.activeLink)

        XCTAssertEqual(
            transport.recordedCommands,
            [
                ["-listallhardwareports"],
                ["-getwebproxy", "Wi-Fi"],
                ["-getsecurewebproxy", "Wi-Fi"],
                ["-setwebproxy", "Wi-Fi", "10.0.0.2", "7890"],
                ["-setwebproxystate", "Wi-Fi", "on"],
                ["-setsecurewebproxy", "Wi-Fi", "10.0.0.2", "7890"],
                ["-setsecurewebproxystate", "Wi-Fi", "on"]
            ]
        )

        let restored = await bridge.disconnectAndRestore()
        XCTAssertTrue(restored)
        XCTAssertNil(bridge.activeLink)
        XCTAssertNil(store.storedLink)
        XCTAssertEqual(
            Array(transport.recordedCommands.suffix(3)),
            [
                ["-setwebproxy", "Wi-Fi", "127.0.0.1", "8080"],
                ["-setwebproxystate", "Wi-Fi", "on"],
                ["-setsecurewebproxystate", "Wi-Fi", "off"]
            ]
        )
    }

    func testSOCKS5ConnectAndRestoreHappyPath() async {
        let transport = FakeNetworkSetupTransport { args in
            if args.first == "-getsocksfirewallproxy" {
                return NetworkSetupCommandResult(
                    terminationStatus: 0,
                    standardOutput: "Enabled: Yes\nServer: 127.0.0.1\nPort: 1080\n"
                )
            }
            return FakeNetworkSetupTransport.defaultResponse(for: args)
        }
        let store = InMemoryRemoteNetworkLinkStore()
        let bridge = RemoteNetworkBridge(transport: transport, linkStore: store)

        let connected = await bridge.connectAsSOCKS5(
            host: makeHost(),
            port: 1081,
            preferredBSDInterface: "en0"
        )
        XCTAssertTrue(connected)
        XCTAssertEqual(bridge.activeLink?.mode, .socks5)
        XCTAssertEqual(bridge.activeLink?.port, 1081)

        let restored = await bridge.disconnectAndRestore()
        XCTAssertTrue(restored)
        XCTAssertNil(bridge.activeLink)
        XCTAssertNil(store.storedLink)
        XCTAssertEqual(
            Array(transport.recordedCommands.suffix(2)),
            [
                ["-setsocksfirewallproxy", "Wi-Fi", "127.0.0.1", "1080"],
                ["-setsocksfirewallproxystate", "Wi-Fi", "on"]
            ]
        )
    }

    func testFailingRestoreWhenSwitchingLinksPreventsOverwritingSystemSettings() async {
        let existingLink = ActiveRemoteNetworkLink(
            mode: .gateway,
            remoteHostId: "host-old",
            remoteHostName: "Old Host",
            remoteIP: "10.0.0.99",
            port: nil,
            serviceName: "Wi-Fi",
            previousIPv4: NetworkServiceIPv4Info(
                isDHCP: true,
                ipAddress: "192.168.1.42",
                subnetMask: "255.255.255.0",
                router: "192.168.1.1"
            ),
            previousDNS: [],
            previousSOCKS: nil
        )
        let store = InMemoryRemoteNetworkLinkStore(initialLink: existingLink)
        let transport = FakeNetworkSetupTransport { args in
            if args.first == "-setdhcp" {
                return NetworkSetupCommandResult(terminationStatus: 1, standardError: "Permission denied")
            }
            return FakeNetworkSetupTransport.defaultResponse(for: args)
        }
        let bridge = RemoteNetworkBridge(transport: transport, linkStore: store)
        XCTAssertEqual(bridge.activeLink, existingLink)

        let newHost = makeHost(id: "host-new", name: "New Host", ip: "10.0.0.3")
        let switchedToHTTP = await bridge.connectAsHTTPProxy(host: newHost, port: 7890, preferredBSDInterface: "en0")
        XCTAssertFalse(switchedToHTTP)
        XCTAssertEqual(bridge.activeLink, existingLink)
        XCTAssertEqual(store.storedLink, existingLink)
        XCTAssertNotNil(bridge.lastError)
        XCTAssertNil(bridge.feedback)
        XCTAssertEqual(transport.recordedCommands, [["-setdhcp", "Wi-Fi"]])

        let switchedToGateway = await bridge.connectAsGateway(host: newHost, preferredBSDInterface: "en0")
        XCTAssertFalse(switchedToGateway)
        XCTAssertEqual(bridge.activeLink, existingLink)
        XCTAssertEqual(transport.recordedCommands, [["-setdhcp", "Wi-Fi"], ["-setdhcp", "Wi-Fi"]])

        let switchedToSOCKS = await bridge.connectAsSOCKS5(host: newHost, port: 1080, preferredBSDInterface: "en0")
        XCTAssertFalse(switchedToSOCKS)
        XCTAssertEqual(bridge.activeLink, existingLink)
        XCTAssertEqual(transport.recordedCommands, [["-setdhcp", "Wi-Fi"], ["-setdhcp", "Wi-Fi"], ["-setdhcp", "Wi-Fi"]])
    }

    func testGatewayPartialFailureOnSetDNSServersTriggersRollback() async {
        let transport = FakeNetworkSetupTransport { args in
            if args.first == "-setdnsservers", args.last == "10.0.0.2" {
                return NetworkSetupCommandResult(terminationStatus: 4, standardError: "Failed to set DNS")
            }
            return FakeNetworkSetupTransport.defaultResponse(for: args)
        }
        let store = InMemoryRemoteNetworkLinkStore()
        let bridge = RemoteNetworkBridge(transport: transport, linkStore: store)

        let ok = await bridge.connectAsGateway(host: makeHost(), preferredBSDInterface: "en0")
        XCTAssertFalse(ok)
        XCTAssertFalse(bridge.isApplying)
        XCTAssertNil(bridge.feedback)
        XCTAssertNotNil(bridge.lastError)
        XCTAssertNil(bridge.activeLink)
        XCTAssertNil(store.storedLink)

        XCTAssertEqual(
            transport.recordedCommands,
            [
                ["-listallhardwareports"],
                ["-getinfo", "Wi-Fi"],
                ["-getdnsservers", "Wi-Fi"],
                ["-setmanual", "Wi-Fi", "192.168.1.42", "255.255.255.0", "10.0.0.2"],
                ["-setdnsservers", "Wi-Fi", "10.0.0.2"],
                ["-setdhcp", "Wi-Fi"],
                ["-setdnsservers", "Wi-Fi", "Empty"]
            ]
        )
    }

    func testHTTPProxyPartialFailureMidwayTriggersRollback() async {
        let transport = FakeNetworkSetupTransport { args in
            if args.first == "-setsecurewebproxy", args.dropFirst(2).first == "10.0.0.2" {
                return NetworkSetupCommandResult(terminationStatus: 1, standardError: "Failed to set HTTPS proxy")
            }
            return FakeNetworkSetupTransport.defaultResponse(for: args)
        }
        let store = InMemoryRemoteNetworkLinkStore()
        let bridge = RemoteNetworkBridge(transport: transport, linkStore: store)

        let ok = await bridge.connectAsHTTPProxy(host: makeHost(), port: 7890, preferredBSDInterface: "en0")
        XCTAssertFalse(ok)
        XCTAssertNil(bridge.feedback)
        XCTAssertNotNil(bridge.lastError)
        XCTAssertNil(bridge.activeLink)
        XCTAssertNil(store.storedLink)

        XCTAssertEqual(
            transport.recordedCommands,
            [
                ["-listallhardwareports"],
                ["-getwebproxy", "Wi-Fi"],
                ["-getsecurewebproxy", "Wi-Fi"],
                ["-setwebproxy", "Wi-Fi", "10.0.0.2", "7890"],
                ["-setwebproxystate", "Wi-Fi", "on"],
                ["-setsecurewebproxy", "Wi-Fi", "10.0.0.2", "7890"],
                ["-setwebproxystate", "Wi-Fi", "off"],
                ["-setsecurewebproxystate", "Wi-Fi", "off"]
            ]
        )
    }

    func testRollbackFailurePreservesSavedActiveLinkForRetry() async {
        let transport = FakeNetworkSetupTransport { args in
            if args.first == "-setdnsservers", args.last == "10.0.0.2" {
                return NetworkSetupCommandResult(terminationStatus: 1, standardError: "DNS write failed")
            }
            if args.first == "-setdhcp" {
                return NetworkSetupCommandResult(terminationStatus: 1, standardError: "DHCP restore failed")
            }
            return FakeNetworkSetupTransport.defaultResponse(for: args)
        }
        let store = InMemoryRemoteNetworkLinkStore()
        let bridge = RemoteNetworkBridge(transport: transport, linkStore: store)

        let ok = await bridge.connectAsGateway(host: makeHost(), preferredBSDInterface: "en0")
        XCTAssertFalse(ok)
        XCTAssertNil(bridge.feedback)
        XCTAssertNotNil(bridge.lastError)

        // Active link must remain saved so the user can retry restore.
        XCTAssertEqual(bridge.activeLink?.mode, .gateway)
        XCTAssertEqual(bridge.activeLink?.serviceName, "Wi-Fi")
        XCTAssertEqual(store.storedLink, bridge.activeLink)

        // Now allow restore to succeed and retry disconnectAndRestore().
        transport.setHandler { args in
            FakeNetworkSetupTransport.defaultResponse(for: args)
        }
        let retried = await bridge.disconnectAndRestore()
        XCTAssertTrue(retried)
        XCTAssertNil(bridge.activeLink)
        XCTAssertNil(store.storedLink)
        XCTAssertNil(bridge.lastError)
        XCTAssertNotNil(bridge.feedback)
    }

    func testFirstMutationFailureSkipsRollbackAndClearsSavedLink() async {
        let transport = FakeNetworkSetupTransport { args in
            if args.first == "-setmanual" {
                return NetworkSetupCommandResult(terminationStatus: 1, standardError: "Cancelled by user")
            }
            return FakeNetworkSetupTransport.defaultResponse(for: args)
        }
        let store = InMemoryRemoteNetworkLinkStore()
        let bridge = RemoteNetworkBridge(transport: transport, linkStore: store)

        let ok = await bridge.connectAsGateway(host: makeHost(), preferredBSDInterface: "en0")
        XCTAssertFalse(ok)
        XCTAssertNil(bridge.activeLink)
        XCTAssertNil(store.storedLink)
        XCTAssertNotNil(bridge.lastError)

        // No rollback commands (-setdhcp / -setdnsservers Empty) should be issued.
        XCTAssertEqual(
            transport.recordedCommands,
            [
                ["-listallhardwareports"],
                ["-getinfo", "Wi-Fi"],
                ["-getdnsservers", "Wi-Fi"],
                ["-setmanual", "Wi-Fi", "192.168.1.42", "255.255.255.0", "10.0.0.2"]
            ]
        )
    }
}
