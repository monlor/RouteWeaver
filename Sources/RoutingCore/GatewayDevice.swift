import Foundation

public struct ARPEntry: Equatable, Hashable, Sendable {
    public let ip: String
    public let macAddress: String
    public let interfaceName: String
    public let hostname: String?
    public let isPermanent: Bool

    public init(
        ip: String,
        macAddress: String,
        interfaceName: String,
        hostname: String? = nil,
        isPermanent: Bool = false
    ) {
        self.ip = ip
        self.macAddress = macAddress
        self.interfaceName = interfaceName
        self.hostname = hostname
        self.isPermanent = isPermanent
    }
}

public enum ARPTableParser {
    /// Parses macOS `arp -an` / `arp -a` output into structured LAN neighbor entries.
    public static func parse(_ output: String) -> [ARPEntry] {
        var entries: [ARPEntry] = []
        var seenIPs = Set<String>()

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            // Example: "? (192.168.1.55) at a:bb:cc:dd:ee:ff on en0 ifscope [ethernet]"
            guard let openParen = line.firstIndex(of: "("),
                  let closeParen = line[openParen...].firstIndex(of: ")"),
                  openParen < closeParen else {
                continue
            }

            let rawHost = line[..<openParen].trimmingCharacters(in: .whitespaces)
            let hostname = (rawHost.isEmpty || rawHost == "?") ? nil : rawHost
            let ip = String(line[line.index(after: openParen)..<closeParen]).trimmingCharacters(in: .whitespaces)
            guard !ip.isEmpty, isUnicastLANIPv4(ip) else { continue }

            let afterParen = String(line[line.index(after: closeParen)...])
            guard let atRange = afterParen.range(of: " at ") else { continue }
            let restAfterAt = afterParen[atRange.upperBound...]
            let tokens = restAfterAt.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let rawMAC = tokens.first else { continue }
            guard let normalizedMAC = normalizeMAC(rawMAC) else { continue }
            guard !isBroadcastOrMulticastMAC(normalizedMAC) else { continue }

            var interfaceName = ""
            if let onIndex = tokens.firstIndex(of: "on"), tokens.indices.contains(onIndex + 1) {
                interfaceName = tokens[onIndex + 1]
            }
            let isPermanent = tokens.contains("permanent")

            guard seenIPs.insert(ip).inserted else { continue }
            entries.append(ARPEntry(
                ip: ip,
                macAddress: normalizedMAC,
                interfaceName: interfaceName,
                hostname: hostname,
                isPermanent: isPermanent
            ))
        }

        return entries
    }

    public static func normalizeMAC(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed != "(incomplete)", !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":")
        guard parts.count == 6 else { return nil }
        var normalized: [String] = []
        normalized.reserveCapacity(6)
        for part in parts {
            guard !part.isEmpty, part.count <= 2, UInt8(part, radix: 16) != nil else {
                return nil
            }
            normalized.append(part.count == 1 ? "0\(part)" : String(part))
        }
        return normalized.joined(separator: ":")
    }

    private static func isBroadcastOrMulticastMAC(_ mac: String) -> Bool {
        if mac == "ff:ff:ff:ff:ff:ff" || mac == "00:00:00:00:00:00" { return true }
        // IPv4 multicast MACs start with 01:00:5e, IPv6 multicast MACs start with 33:33
        if mac.hasPrefix("01:00:5e:") || mac.hasPrefix("33:33:") { return true }
        return false
    }

    private static func isUnicastLANIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        let first = parts[0]
        let second = parts[1]
        if first == 127 || first == 0 || first >= 224 { return false }
        if first == 169 && second == 254 { return false }
        if first == 198 && second == 18 { return false }
        if parts[3] == 255 { return false }
        return true
    }
}

public struct GatewayClientDevice: Codable, Equatable, Identifiable, Sendable {
    public var id: String { ip }
    public let ip: String
    public let macAddress: String?
    public let interfaceName: String?
    public let hostname: String?
    public let activeConnectionCount: Int
    public let totalConnectionCount: Int
    public let uploadBytes: Int64
    public let downloadBytes: Int64
    public let uploadSpeed: Int64
    public let downloadSpeed: Int64
    public let lastSeen: Date?
    public let recentHosts: [String]

    public var hasGatewayTraffic: Bool {
        totalConnectionCount > 0 || uploadBytes > 0 || downloadBytes > 0
    }

    public init(
        ip: String,
        macAddress: String? = nil,
        interfaceName: String? = nil,
        hostname: String? = nil,
        activeConnectionCount: Int = 0,
        totalConnectionCount: Int = 0,
        uploadBytes: Int64 = 0,
        downloadBytes: Int64 = 0,
        uploadSpeed: Int64 = 0,
        downloadSpeed: Int64 = 0,
        lastSeen: Date? = nil,
        recentHosts: [String] = []
    ) {
        self.ip = ip
        self.macAddress = macAddress
        self.interfaceName = interfaceName
        self.hostname = hostname
        self.activeConnectionCount = activeConnectionCount
        self.totalConnectionCount = totalConnectionCount
        self.uploadBytes = uploadBytes
        self.downloadBytes = downloadBytes
        self.uploadSpeed = uploadSpeed
        self.downloadSpeed = downloadSpeed
        self.lastSeen = lastSeen
        self.recentHosts = recentHosts
    }
}

public enum GatewayDeviceAggregator {
    private struct TrafficBucket {
        var activeCount = 0
        var totalCount = 0
        var uploadBytes: Int64 = 0
        var downloadBytes: Int64 = 0
        var uploadSpeed: Int64 = 0
        var downloadSpeed: Int64 = 0
        var lastSeen: Date?
        var recentHosts: [String] = []
        var seenHosts = Set<String>()
    }

    public static func aggregate(
        records: [MonitoredConnection],
        arpEntries: [ARPEntry],
        localIPs: Set<String>,
        includeARPOnly: Bool = true,
        hostnamesByIP: [String: String] = [:]
    ) -> [GatewayClientDevice] {
        var buckets: [String: TrafficBucket] = [:]

        for record in records {
            let sourceIP = record.metadata.sourceIP.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isExternalLANClientIP(sourceIP, localIPs: localIPs) else { continue }

            var bucket = buckets[sourceIP] ?? TrafficBucket()
            if record.isActive {
                bucket.activeCount += 1
                bucket.uploadSpeed += max(0, record.uploadSpeed)
                bucket.downloadSpeed += max(0, record.downloadSpeed)
            }
            bucket.totalCount += 1
            bucket.uploadBytes += max(0, record.upload)
            bucket.downloadBytes += max(0, record.download)

            let seenAt = record.closedAt ?? record.lastSeenAt
            if let existing = bucket.lastSeen {
                if seenAt > existing { bucket.lastSeen = seenAt }
            } else {
                bucket.lastSeen = seenAt
            }

            let host = record.hostOnly
            if !host.isEmpty && bucket.recentHosts.count < 5 && bucket.seenHosts.insert(host).inserted {
                bucket.recentHosts.append(host)
            }
            buckets[sourceIP] = bucket
        }

        let arpByIP = Dictionary(uniqueKeysWithValues: arpEntries.map { ($0.ip, $0) })
        var allIPs = Set(buckets.keys)
        if includeARPOnly {
            for entry in arpEntries where isExternalLANClientIP(entry.ip, localIPs: localIPs) {
                allIPs.insert(entry.ip)
            }
        }

        return allIPs.map { ip in
            let bucket = buckets[ip]
            let arp = arpByIP[ip]
            let resolvedHostname: String? = {
                if let resolved = hostnamesByIP[ip]?.trimmingCharacters(in: .whitespacesAndNewlines), !resolved.isEmpty {
                    return resolved
                }
                return arp?.hostname
            }()
            return GatewayClientDevice(
                ip: ip,
                macAddress: arp?.macAddress,
                interfaceName: arp?.interfaceName.isEmpty == false ? arp?.interfaceName : nil,
                hostname: resolvedHostname,
                activeConnectionCount: bucket?.activeCount ?? 0,
                totalConnectionCount: bucket?.totalCount ?? 0,
                uploadBytes: bucket?.uploadBytes ?? 0,
                downloadBytes: bucket?.downloadBytes ?? 0,
                uploadSpeed: bucket?.uploadSpeed ?? 0,
                downloadSpeed: bucket?.downloadSpeed ?? 0,
                lastSeen: bucket?.lastSeen,
                recentHosts: bucket?.recentHosts ?? []
            )
        }
        .sorted { lhs, rhs in
            let lhsActive = lhs.activeConnectionCount > 0
            let rhsActive = rhs.activeConnectionCount > 0
            if lhsActive != rhsActive { return lhsActive }
            if lhs.hasGatewayTraffic != rhs.hasGatewayTraffic { return lhs.hasGatewayTraffic }
            let lhsSpeed = lhs.uploadSpeed + lhs.downloadSpeed
            let rhsSpeed = rhs.uploadSpeed + rhs.downloadSpeed
            if lhsSpeed != rhsSpeed { return lhsSpeed > rhsSpeed }
            let lhsBytes = lhs.uploadBytes + lhs.downloadBytes
            let rhsBytes = rhs.uploadBytes + rhs.downloadBytes
            if lhsBytes != rhsBytes { return lhsBytes > rhsBytes }
            return lhs.ip.localizedStandardCompare(rhs.ip) == .orderedAscending
        }
    }

    private static func isExternalLANClientIP(_ ip: String, localIPs: Set<String>) -> Bool {
        guard !ip.isEmpty, !localIPs.contains(ip) else { return false }
        if ip == "127.0.0.1" || ip == "::1" || ip.hasPrefix("127.") || ip.hasPrefix("198.18.") || ip.hasPrefix("169.254.") {
            return false
        }
        return true
    }
}

/// Pure-Swift RFC 1035 DNS PTR packet encoder/decoder for LAN reverse lookup (router DNS & mDNS).
public enum LANHostnameResolverCodec {
    public static func buildPTRQuery(ipv4: String, transactionID: UInt16 = 0) -> Data? {
        let octets = ipv4.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
            .compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }

        let labels = [
            String(octets[3]),
            String(octets[2]),
            String(octets[1]),
            String(octets[0]),
            "in-addr",
            "arpa",
        ]

        var packet = Data()
        packet.reserveCapacity(64)
        // Header: ID, Flags (RD=1), QDCOUNT=1, ANCOUNT=0, NSCOUNT=0, ARCOUNT=0
        packet.append(UInt8((transactionID >> 8) & 0xFF))
        packet.append(UInt8(transactionID & 0xFF))
        packet.append(contentsOf: [0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        for label in labels {
            let bytes = Array(label.utf8)
            guard !bytes.isEmpty, bytes.count <= 63 else { return nil }
            packet.append(UInt8(bytes.count))
            packet.append(contentsOf: bytes)
        }
        packet.append(0x00)
        // QTYPE = PTR (12), QCLASS = IN (1)
        packet.append(contentsOf: [0x00, 0x0C, 0x00, 0x01])
        return packet
    }

    public static func parsePTRResponse(_ data: Data, expectedTransactionID: UInt16? = nil) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { return nil }

        let txID = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        if let expectedTransactionID, txID != expectedTransactionID {
            return nil
        }

        let flags = (UInt16(bytes[2]) << 8) | UInt16(bytes[3])
        let isResponse = (flags & 0x8000) != 0
        let rcode = flags & 0x000F
        guard isResponse, rcode == 0 else { return nil }

        let qdCount = Int((UInt16(bytes[4]) << 8) | UInt16(bytes[5]))
        let anCount = Int((UInt16(bytes[6]) << 8) | UInt16(bytes[7]))
        guard anCount > 0 else { return nil }

        var offset = 12
        for _ in 0..<qdCount {
            guard let next = skipName(in: bytes, from: offset), next + 4 <= bytes.count else { return nil }
            offset = next + 4
        }

        for _ in 0..<anCount {
            guard let afterName = skipName(in: bytes, from: offset), afterName + 10 <= bytes.count else { return nil }
            let recordType = (UInt16(bytes[afterName]) << 8) | UInt16(bytes[afterName + 1])
            let rdLength = Int((UInt16(bytes[afterName + 8]) << 8) | UInt16(bytes[afterName + 9]))
            let rdataStart = afterName + 10
            guard rdataStart + rdLength <= bytes.count else { return nil }
            if recordType == 12,
               let (rawName, _) = readName(in: bytes, from: rdataStart),
               let cleaned = cleanHostname(rawName) {
                return cleaned
            }
            offset = rdataStart + rdLength
        }
        return nil
    }

    public static func cleanHostname(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasSuffix(".") {
            name.removeLast()
        }
        if name.lowercased().hasSuffix(".local") {
            name = String(name.dropLast(".local".count))
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "?", name.lowercased() != "localhost" else { return nil }
        return name
    }

    private static func skipName(in bytes: [UInt8], from start: Int) -> Int? {
        var idx = start
        var steps = 0
        while idx < bytes.count, steps < 128 {
            steps += 1
            let len = bytes[idx]
            if len == 0 {
                return idx + 1
            }
            if (len & 0xC0) == 0xC0 {
                return idx + 2 <= bytes.count ? idx + 2 : nil
            }
            guard (len & 0xC0) == 0 else { return nil }
            idx += 1 + Int(len)
        }
        return nil
    }

    private static func readName(in bytes: [UInt8], from start: Int) -> (String, Int)? {
        var labels: [String] = []
        var idx = start
        var jumped = false
        var endOffset = start
        var jumps = 0

        while idx < bytes.count, jumps < 32 {
            let len = bytes[idx]
            if len == 0 {
                if !jumped { endOffset = idx + 1 }
                return (labels.joined(separator: "."), endOffset)
            }
            if (len & 0xC0) == 0xC0 {
                guard idx + 1 < bytes.count else { return nil }
                let pointer = Int(((UInt16(len & 0x3F)) << 8) | UInt16(bytes[idx + 1]))
                guard pointer < bytes.count else { return nil }
                if !jumped {
                    endOffset = idx + 2
                    jumped = true
                }
                idx = pointer
                jumps += 1
                continue
            }
            guard (len & 0xC0) == 0 else { return nil }
            let labelStart = idx + 1
            let labelEnd = labelStart + Int(len)
            guard labelEnd <= bytes.count else { return nil }
            let label = String(decoding: bytes[labelStart..<labelEnd], as: UTF8.self)
            labels.append(label)
            idx = labelEnd
        }
        return nil
    }
}
