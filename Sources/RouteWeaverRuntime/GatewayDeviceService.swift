import Darwin
import Foundation
import RoutingCore

enum GatewayDeviceInspector {
    /// Reads the macOS ARP neighbor table without blocking on DNS resolution (`arp -an`).
    static func readARPEntries() -> [ARPEntry] {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        p.arguments = ["-an"]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        return ARPTableParser.parse(output)
    }

    static func currentDevices(
        records: [MonitoredConnection],
        localIPs: Set<String>,
        includeARPOnly: Bool = true
    ) -> [GatewayClientDevice] {
        let arpEntries = readARPEntries()
        var candidateIPSet = Set<String>()
        for record in records {
            let ip = record.metadata.sourceIP.trimmingCharacters(in: .whitespacesAndNewlines)
            if isCandidateLANIP(ip, localIPs: localIPs) {
                candidateIPSet.insert(ip)
            }
        }
        if includeARPOnly {
            for entry in arpEntries where isCandidateLANIP(entry.ip, localIPs: localIPs) {
                candidateIPSet.insert(entry.ip)
            }
        }
        let hostnames = LANHostnameResolver.shared.resolveHostnames(for: Array(candidateIPSet))
        return GatewayDeviceAggregator.aggregate(
            records: records,
            arpEntries: arpEntries,
            localIPs: localIPs,
            includeARPOnly: includeARPOnly,
            hostnamesByIP: hostnames
        )
    }

    private static func isCandidateLANIP(_ ip: String, localIPs: Set<String>) -> Bool {
        guard !ip.isEmpty, !localIPs.contains(ip) else { return false }
        if ip == "127.0.0.1" || ip == "::1" || ip.hasPrefix("127.") || ip.hasPrefix("198.18.") || ip.hasPrefix("169.254.") {
            return false
        }
        return true
    }

    static func currentDevices(
        tracker: ConnectionTracker,
        localIPs: Set<String>,
        includeARPOnly: Bool = true
    ) -> [GatewayClientDevice] {
        currentDevices(records: tracker.allRecords, localIPs: localIPs, includeARPOnly: includeARPOnly)
    }
}

/// Fast, cached reverse-DNS (LAN router PTR + mDNS 224.0.0.251:5353 PTR) resolver for LAN client IPs.
/// Works even when TUN / Fake-IP hijacks macOS system DNS to 198.18.0.2.
final class LANHostnameResolver: @unchecked Sendable {
    static let shared = LANHostnameResolver()

    private struct CacheEntry {
        let hostname: String?
        let expiresAt: Date
    }

    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    private let hitTTL: TimeInterval = 300
    private let missTTL: TimeInterval = 45

    func resolveHostnames(for ips: [String]) -> [String: String] {
        let uniqueIPs = Array(Set(ips)).filter(Self.isPrivateIPv4)
        guard !uniqueIPs.isEmpty else { return [:] }

        let now = Date()
        var resolved: [String: String] = [:]
        var toQuery: [String] = []

        lock.lock()
        for ip in uniqueIPs {
            if let entry = cache[ip], entry.expiresAt > now {
                if let name = entry.hostname {
                    resolved[ip] = name
                }
            } else {
                toQuery.append(ip)
            }
        }
        lock.unlock()

        guard !toQuery.isEmpty else { return resolved }

        let routerDNSServers = discoverPrivateDNSServers()
        let group = DispatchGroup()
        let resultLock = NSLock()
        var freshlyResolved: [String: String?] = [:]

        for ip in toQuery {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let name = self.lookupSingle(ip: ip, routerDNSServers: routerDNSServers)
                resultLock.lock()
                freshlyResolved[ip] = name
                resultLock.unlock()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 1.2)

        let storeTime = Date()
        lock.lock()
        for (ip, name) in freshlyResolved {
            let ttl = name != nil ? hitTTL : missTTL
            cache[ip] = CacheEntry(hostname: name, expiresAt: storeTime.addingTimeInterval(ttl))
            if let name {
                resolved[ip] = name
            }
        }
        lock.unlock()

        return resolved
    }

    private func lookupSingle(ip: String, routerDNSServers: [String]) -> String? {
        // 1. Query LAN router / interface DNS server(s) first (e.g. 192.168.100.1:53)
        var candidates = routerDNSServers
        if let guessedGateway = Self.guessedSubnetGateway(for: ip), !candidates.contains(guessedGateway) {
            candidates.append(guessedGateway)
        }
        for dnsServer in candidates {
            if let name = Self.queryUDPReversePTR(ip: ip, server: dnsServer, port: 53, timeoutMs: 320, matchTxID: true) {
                return name
            }
        }

        // 2. Fall back to mDNS (224.0.0.251:5353) for Apple / Linux `.local` devices
        if let name = Self.queryUDPReversePTR(ip: ip, server: "224.0.0.251", port: 5353, timeoutMs: 350, matchTxID: false) {
            return name
        }

        return nil
    }

    private func discoverPrivateDNSServers() -> [String] {
        let perInterface = NetworkEnvironment.interfaceDNSServers(includeIPv6: false)
        var servers: [String] = []
        for (_, list) in perInterface {
            for raw in list {
                let ip = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard Self.isPrivateIPv4(ip), !servers.contains(ip) else { continue }
                servers.append(ip)
            }
        }
        return servers
    }

    private static func guessedSubnetGateway(for ip: String) -> String? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let gw = "\(parts[0]).\(parts[1]).\(parts[2]).1"
        return gw == ip ? nil : gw
    }

    private static func isPrivateIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        return false
    }

    private static func queryUDPReversePTR(
        ip: String,
        server: String,
        port: UInt16,
        timeoutMs: Int32,
        matchTxID: Bool
    ) -> String? {
        let txID: UInt16 = matchTxID ? UInt16.random(in: 1...65535) : 0
        guard let query = LANHostnameResolverCodec.buildPTRQuery(ipv4: ip, transactionID: txID) else {
            return nil
        }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, server, &addr.sin_addr) == 1 else { return nil }

        let sent: Int = query.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return -1 }
            return withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, base, query.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == query.count else { return nil }

        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, timeoutMs)
        guard ready > 0, (pfd.revents & Int16(POLLIN)) != 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: 1500)
        let received = recv(fd, &buffer, buffer.count, 0)
        guard received >= 12 else { return nil }

        let responseData = Data(buffer.prefix(received))
        return LANHostnameResolverCodec.parsePTRResponse(
            responseData,
            expectedTransactionID: matchTxID ? txID : nil
        )
    }
}
