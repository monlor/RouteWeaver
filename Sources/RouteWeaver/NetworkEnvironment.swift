import Darwin
import Foundation
import SystemConfiguration

struct NetworkInterfaceInfo: Identifiable, Equatable, Sendable {
    var id: String { bsdName }
    let bsdName: String
    let displayName: String
    let isUpWithAddress: Bool
    let ipv4Address: String?
    let ipv4Netmask: String?

    private var cleanDisplayName: String {
        let suffix = " (\(bsdName))"
        if displayName.hasSuffix(suffix) {
            return String(displayName.dropLast(suffix.count))
        }
        return displayName
    }

    var pickerLabel: String {
        if let ipv4Address {
            return "\(cleanDisplayName) (\(bsdName) · \(ipv4Address))"
        }
        return "\(cleanDisplayName) (\(bsdName))"
    }

    var shortLabel: String {
        "\(cleanDisplayName) (\(bsdName))"
    }
}

enum NetworkEnvironment {
    static func interfaceDNSServers() -> [String: [String]] {
        guard let store = SCDynamicStoreCreate(nil, "RouteWeaver.DNSInspector" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String] else {
            return [:]
        }
        var result: [String: [String]] = [:]
        for ipv4Key in keys {
            guard let ipv4Dict = SCDynamicStoreCopyValue(store, ipv4Key as CFString) as? [String: Any],
                  let iface = ipv4Dict["InterfaceName"] as? String,
                  !iface.isEmpty else { continue }
            let dnsKey = ipv4Key.replacingOccurrences(of: "/IPv4", with: "/DNS")
            guard let dnsDict = SCDynamicStoreCopyValue(store, dnsKey as CFString) as? [String: Any],
                  let servers = dnsDict["ServerAddresses"] as? [String] else { continue }
            let filtered = servers.filter { ip in
                !ip.isEmpty
                    && !ip.hasPrefix("198.18.")
                    && !ip.hasPrefix("127.")
                    && ip != "::1"
            }
            if !filtered.isEmpty {
                var list = result[iface] ?? []
                for ip in filtered where !list.contains(ip) {
                    list.append(ip)
                }
                result[iface] = list
            }
        }
        return result
    }

    static func isIPForwardingEnabled() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("net.inet.ip.forwarding", &value, &size, nil, 0) == 0 && value != 0
    }

    static func detailedInterfaces() -> [NetworkInterfaceInfo] {
        let allNames = interfaceNames(requireAddress: false)
        let activeIPv4 = activeIPv4Details()
        let activeSet = Set(interfaceNames(requireAddress: true))

        let scInterfaces = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []
        var labels: [String: String] = [:]
        for networkInterface in scInterfaces {
            if let name = SCNetworkInterfaceGetBSDName(networkInterface),
               let label = SCNetworkInterfaceGetLocalizedDisplayName(networkInterface) {
                labels[name as String] = label as String
            }
        }

        return allNames.map { name in
            NetworkInterfaceInfo(
                bsdName: name,
                displayName: labels[name] ?? "网络接口",
                isUpWithAddress: activeSet.contains(name),
                ipv4Address: activeIPv4[name]?.address,
                ipv4Netmask: activeIPv4[name]?.netmask
            )
        }
        .sorted { lhs, rhs in
            if lhs.isUpWithAddress != rhs.isUpWithAddress {
                return lhs.isUpWithAddress
            }
            return lhs.bsdName.localizedStandardCompare(rhs.bsdName) == .orderedAscending
        }
    }

    static func interfaceNames(requireAddress: Bool) -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result = Set<String>()
        var cursor = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let info = entry.pointee
            let name = String(cString: info.ifa_name)
            guard name.range(of: #"^en[0-9]+$"#, options: .regularExpression) != nil else { continue }
            if requireAddress {
                guard (info.ifa_flags & UInt32(IFF_UP | IFF_RUNNING)) == UInt32(IFF_UP | IFF_RUNNING),
                      let addr = info.ifa_addr else { continue }
                switch Int32(addr.pointee.sa_family) {
                case AF_INET:
                    let address = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                    let host = UInt32(bigEndian: address.s_addr)
                    guard host != 0 && (host & 0xffff0000) != 0xa9fe0000 else { continue }
                case AF_INET6:
                    let address = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                    let bytes = withUnsafeBytes(of: address) { Array($0) }
                    guard bytes.contains(where: { $0 != 0 }),
                          !(bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) else { continue }
                default: continue
                }
            }
            result.insert(name)
        }
        return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Validates that all listening ports in the rendered Mihomo config are free.
    /// Returns a localized error message if a port is unavailable, or `nil` if all ports are free.
    static func validateAvailablePorts(in config: Data, useTun: Bool) -> String? {
        guard let parsed = (try? JSONSerialization.jsonObject(with: config)) as? [String: Any],
              let mixed = parsed["mixed-port"] as? Int, (1...65535).contains(mixed) else {
            return "无法读取本地监听配置。"
        }

        let allowLAN = (parsed["allow-lan"] as? Bool) ?? false
        var checks: [(port: Int, bindAll: Bool)] = [(mixed, allowLAN)]

        if let httpPort = parsed["port"] as? Int {
            checks.append((httpPort, allowLAN))
        }
        if let socksPort = parsed["socks-port"] as? Int {
            checks.append((socksPort, allowLAN))
        }
        if let endpoint = parsed["external-controller"] as? String {
            let host = "127.0.0.1:"
            guard endpoint.hasPrefix(host), let port = Int(endpoint.dropFirst(host.count)),
                  (1...65535).contains(port) else {
                return "控制接口必须使用独立的本机端口。"
            }
            checks.append((port, false))
        }

        for item in checks {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                return "无法检查本机端口。"
            }
            defer { Darwin.close(fd) }
            // Match Mihomo's listener behavior so TIME_WAIT sockets from a recently stopped core
            // (e.g. during TUN re-authorization or quick restarts) do not cause false EADDRINUSE errors.
            var reuseAddr: Int32 = 1
            _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(item.port).bigEndian
            address.sin_addr.s_addr = item.bindAll ? INADDR_ANY.bigEndian : inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result != 0 {
                let bindErrno = errno
                // On macOS/XNU, a non-root bind() with SO_REUSEADDR still fails with EADDRINUSE when
                // a root-owned TIME_WAIT/FIN_WAIT socket exists from a recently stopped TUN core.
                // Confirm via loopback connect probe whether anything is actually listening on the port.
                if bindErrno == EADDRINUSE && useTun && !isLoopbackPortListening(item.port) {
                    continue
                }
                return "端口 \(item.port) 不可用，请关闭占用该端口的应用或更换端口。"
            }
        }
        return nil
    }

    private static func activeIPv4Details() -> [String: (address: String, netmask: String?)] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [:] }
        defer { freeifaddrs(first) }
        var result: [String: (address: String, netmask: String?)] = [:]
        var cursor = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let info = entry.pointee
            let name = String(cString: info.ifa_name)
            guard name.range(of: #"^en[0-9]+$"#, options: .regularExpression) != nil,
                  (info.ifa_flags & UInt32(IFF_UP | IFF_RUNNING)) == UInt32(IFF_UP | IFF_RUNNING),
                  let addr = info.ifa_addr,
                  Int32(addr.pointee.sa_family) == AF_INET else { continue }
            var sin = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            let host = UInt32(bigEndian: sin.s_addr)
            guard host != 0 && (host & 0xffff0000) != 0xa9fe0000 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &sin, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                var maskString: String?
                if let maskAddr = info.ifa_netmask, Int32(maskAddr.pointee.sa_family) == AF_INET {
                    var maskSin = UnsafeRawPointer(maskAddr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                    var maskBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &maskSin, &maskBuffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                        maskString = String(cString: maskBuffer)
                    }
                }
                result[name] = (String(cString: buffer), maskString)
            }
        }
        return result
    }

    private static func isLoopbackPortListening(_ port: Int) -> Bool {
        if isIPv4LoopbackListening(port) { return true }
        if isIPv6LoopbackListening(port) { return true }
        return false
    }

    private static func isIPv4LoopbackListening(_ port: Int) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        let flags = Darwin.fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pollRc = Darwin.poll(&pfd, 1, 120)
        guard pollRc > 0 else { return false }
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard Darwin.getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len) == 0 else { return false }
        return soError == 0
    }

    private static func isIPv6LoopbackListening(_ port: Int) -> Bool {
        let fd = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        let flags = Darwin.fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) }

        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = UInt16(port).bigEndian
        addr.sin6_addr = in6addr_loopback

        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pollRc = Darwin.poll(&pfd, 1, 120)
        guard pollRc > 0 else { return false }
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard Darwin.getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len) == 0 else { return false }
        return soError == 0
    }
}
