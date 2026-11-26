import Foundation
@testable import RoutingCore
import XCTest

final class GatewayAndRemoteTests: XCTestCase {
    func testARPTableParserNormalizesMACAndFiltersInvalidEntries() {
        let output = """
        ? (192.168.1.1) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]
        iphone.local (192.168.1.42) at 4:a:1c:0:9f:2 on en0 ifscope [ethernet]
        ? (192.168.1.99) at (incomplete) on en0 ifscope [ethernet]
        ? (224.0.0.251) at 1:0:5e:0:0:fb on en0 ifscope permanent [ethernet]
        ? (192.168.1.255) at ff:ff:ff:ff:ff:ff on en0 ifscope [ethernet]
        """

        let entries = ARPTableParser.parse(output)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].ip, "192.168.1.1")
        XCTAssertEqual(entries[0].macAddress, "aa:bb:cc:dd:ee:ff")
        XCTAssertEqual(entries[0].interfaceName, "en0")
        XCTAssertNil(entries[0].hostname)

        XCTAssertEqual(entries[1].ip, "192.168.1.42")
        XCTAssertEqual(entries[1].macAddress, "04:0a:1c:00:9f:02")
        XCTAssertEqual(entries[1].hostname, "iphone.local")
    }

    func testGatewayDeviceAggregatorCombinesTrafficAndARP() {
        let now = Date()
        let activeConn = MonitoredConnection(
            id: "c1",
            metadata: MihomoConnectionMetadata(sourceIP: "192.168.1.42", host: "apple.com"),
            upload: 1024,
            download: 4096,
            uploadSpeed: 500,
            downloadSpeed: 1500,
            startRaw: "",
            startDate: now,
            firstSeenAt: now,
            lastSeenAt: now,
            closedAt: nil,
            chains: ["Proxy"],
            rule: "MATCH",
            rulePayload: "",
            isActive: true
        )
        let localConn = MonitoredConnection(
            id: "c2",
            metadata: MihomoConnectionMetadata(sourceIP: "192.168.1.10", host: "example.com"),
            upload: 200,
            download: 300,
            uploadSpeed: 10,
            downloadSpeed: 20,
            startRaw: "",
            startDate: now,
            firstSeenAt: now,
            lastSeenAt: now,
            closedAt: nil,
            chains: ["DIRECT"],
            rule: "MATCH",
            rulePayload: "",
            isActive: true
        )
        let arp = [
            ARPEntry(ip: "192.168.1.42", macAddress: "04:0a:1c:00:9f:02", interfaceName: "en0", hostname: "iPhone"),
            ARPEntry(ip: "192.168.1.88", macAddress: "11:22:33:44:55:66", interfaceName: "en0", hostname: "AppleTV"),
        ]

        let trafficOnly = GatewayDeviceAggregator.aggregate(
            records: [activeConn, localConn],
            arpEntries: arp,
            localIPs: ["192.168.1.10"],
            includeARPOnly: false
        )
        XCTAssertEqual(trafficOnly.count, 1)
        XCTAssertEqual(trafficOnly[0].ip, "192.168.1.42")
        XCTAssertEqual(trafficOnly[0].macAddress, "04:0a:1c:00:9f:02")
        XCTAssertEqual(trafficOnly[0].hostname, "iPhone")
        XCTAssertEqual(trafficOnly[0].activeConnectionCount, 1)
        XCTAssertEqual(trafficOnly[0].downloadBytes, 4096)

        let withARP = GatewayDeviceAggregator.aggregate(
            records: [activeConn, localConn],
            arpEntries: arp,
            localIPs: ["192.168.1.10"],
            includeARPOnly: true
        )
        XCTAssertEqual(withARP.count, 2)
        XCTAssertEqual(withARP[1].ip, "192.168.1.88")
        XCTAssertFalse(withARP[1].hasGatewayTraffic)
    }

    func testRemoteHTTPParserAndAuthHelper() {
        let body = #"{"group":"Proxy","node":"HK-01"}"#
        let raw = "POST /api/v1/proxies/select?foo=1 HTTP/1.1\r\nHost: 127.0.0.1:19098\r\nAuthorization: Bearer secret-token\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let parsed = RemoteHTTPParser.parse(Data(raw.utf8))
        guard case let .parsed(req) = parsed else {
            return XCTFail("Expected parsed request")
        }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/api/v1/proxies/select")
        XCTAssertEqual(req.bearerToken, "secret-token")
        XCTAssertEqual(String(data: req.body, encoding: .utf8), body)

        let partial = RemoteHTTPParser.parse(Data(raw.prefix(raw.count - 4).utf8))
        XCTAssertEqual(partial, .incomplete)

        let code = RemoteAuthHelper.generatePairingCode()
        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.allSatisfy(\.isNumber))

        let token = RemoteAuthHelper.generateToken()
        XCTAssertFalse(token.isEmpty)
        XCTAssertEqual(RemoteAuthHelper.sha256Hex(token).count, 64)
    }

    func testNetworkSetupParserParsesPortsInfoDNSAndSOCKS() {
        let hw = """
        Hardware Port: Wi-Fi
        Device: en0
        Ethernet Address: f4:d4:88:64:ac:32

        Hardware Port: USB 10/100/1000 LAN
        Device: en5
        Ethernet Address: 00:11:22:33:44:55
        """
        let map = NetworkSetupParser.parseHardwarePorts(hw)
        XCTAssertEqual(map["en0"], "Wi-Fi")
        XCTAssertEqual(map["en5"], "USB 10/100/1000 LAN")

        let info = NetworkSetupParser.parseServiceInfo("""
        DHCP Configuration
        IP address: 192.168.100.73
        Subnet mask: 255.255.255.0
        Router: 192.168.100.1
        """)
        XCTAssertTrue(info.isDHCP)
        XCTAssertEqual(info.ipAddress, "192.168.100.73")
        XCTAssertEqual(info.subnetMask, "255.255.255.0")
        XCTAssertEqual(info.router, "192.168.100.1")

        XCTAssertEqual(NetworkSetupParser.parseDNSServers("There aren't any DNS Servers set on Wi-Fi."), [])
        XCTAssertEqual(NetworkSetupParser.parseDNSServers("192.168.100.74\n1.1.1.1\n"), ["192.168.100.74", "1.1.1.1"])

        let socks = NetworkSetupParser.parseSOCKSProxy("""
        Enabled: Yes
        Server: 192.168.100.74
        Port: 7890
        """)
        XCTAssertTrue(socks.enabled)
        XCTAssertEqual(socks.server, "192.168.100.74")
        XCTAssertEqual(socks.port, 7890)

        let http = NetworkSetupParser.parseHTTPProxy("""
        Enabled: Yes
        Server: 192.168.100.5
        Port: 7890
        Authenticated Proxy Enabled: 0
        """)
        XCTAssertTrue(http.enabled)
        XCTAssertEqual(http.server, "192.168.100.5")
        XCTAssertEqual(http.port, 7890)
    }

    func testConnectionTrackerApplyRemoteSnapshotAndDNSReplace() {
        var tracker = ConnectionTracker()
        let now = Date()
        let conn = MonitoredConnection(
            id: "r1",
            metadata: MihomoConnectionMetadata(network: "tcp", sourceIP: "192.168.100.73", destinationIP: "1.1.1.1", host: "example.com"),
            upload: 500,
            download: 2500,
            uploadSpeed: 100,
            downloadSpeed: 500,
            startRaw: "",
            startDate: nil,
            firstSeenAt: now,
            lastSeenAt: now,
            closedAt: nil,
            chains: ["HK-01", "Proxy"],
            rule: "DOMAIN-SUFFIX",
            rulePayload: "example.com",
            isActive: true
        )
        tracker.applyRemoteSnapshot(
            records: [conn],
            uploadSpeed: 100,
            downloadSpeed: 500,
            uploadTotal: 500,
            downloadTotal: 2500,
            at: now
        )
        XCTAssertEqual(tracker.activeCount, 1)
        XCTAssertEqual(tracker.uploadSpeed, 100)
        XCTAssertEqual(tracker.downloadSpeed, 500)
        XCTAssertEqual(tracker.speedHistory.count, 1)
        XCTAssertEqual(tracker.sessionTraffic(for: "Proxy").download, 2500)

        var dnsTracker = DNSLogTracker(maxRecords: 10)
        dnsTracker.replaceAll([
            DNSLogRecord(domain: "example.com", recordType: "A", answers: ["93.184.216.34"], upstream: "remote", status: .resolved, rawPayload: "raw")
        ])
        XCTAssertEqual(dnsTracker.records.count, 1)
        XCTAssertEqual(dnsTracker.records[0].domain, "example.com")
    }

    func testLANHostnameResolverCodecBuildsAndParsesPTR() throws {
        let query = try XCTUnwrap(LANHostnameResolverCodec.buildPTRQuery(ipv4: "192.168.100.3", transactionID: 0x1234))
        XCTAssertEqual(query[0], 0x12)
        XCTAssertEqual(query[1], 0x34)
        XCTAssertNil(LANHostnameResolverCodec.buildPTRQuery(ipv4: "not-an-ip"))

        // Construct a DNS response:
        // Header: tx=0x1234, flags=0x8180 (response, no error), qd=1, an=1, ns=0, ar=0
        var response = Data([0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
        // Question: 3.100.168.192.in-addr.arpa PTR IN
        response.append(query.dropFirst(12))
        // Answer: name pointer 0xC00C, TYPE=PTR(12), CLASS=IN(1), TTL=60, RDLENGTH=15, RDATA="pc.monlor.cn."
        let rdata: [UInt8] = [
            2, 0x70, 0x63, // "pc"
            6, 0x6D, 0x6F, 0x6E, 0x6C, 0x6F, 0x72, // "monlor"
            2, 0x63, 0x6E, // "cn"
            0,
        ]
        response.append(contentsOf: [0xC0, 0x0C, 0x00, 0x0C, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C])
        response.append(UInt8((rdata.count >> 8) & 0xFF))
        response.append(UInt8(rdata.count & 0xFF))
        response.append(contentsOf: rdata)

        XCTAssertEqual(
            LANHostnameResolverCodec.parsePTRResponse(response, expectedTransactionID: 0x1234),
            "pc.monlor.cn"
        )
        XCTAssertNil(LANHostnameResolverCodec.parsePTRResponse(response, expectedTransactionID: 0x9999))
        XCTAssertEqual(LANHostnameResolverCodec.cleanHostname("monlor-nuc.local."), "monlor-nuc")
        XCTAssertEqual(LANHostnameResolverCodec.cleanHostname("pc.monlor.cn."), "pc.monlor.cn")
        XCTAssertNil(LANHostnameResolverCodec.cleanHostname("?"))

        // Verify GatewayDeviceAggregator applies hostnamesByIP over missing ARP hostname
        let arp = [ARPEntry(ip: "192.168.100.3", macAddress: "aa:bb:cc:dd:ee:ff", interfaceName: "en0", hostname: nil)]
        let devices = GatewayDeviceAggregator.aggregate(
            records: [],
            arpEntries: arp,
            localIPs: ["192.168.100.5"],
            includeARPOnly: true,
            hostnamesByIP: ["192.168.100.3": "pc.monlor.cn"]
        )
        XCTAssertEqual(devices.first?.hostname, "pc.monlor.cn")
    }
}
