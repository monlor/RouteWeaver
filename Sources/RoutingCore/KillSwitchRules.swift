import Foundation

/// Pure PF (Packet Filter) rule generator and shared constants for RouteWeaver's macOS Kill Switch.
public enum KillSwitchRules {
    /// macOS `/etc/pf.conf` automatically evaluates `anchor "com.apple/*"`, so using a sub-anchor
    /// under `com.apple/` activates rules without modifying `/etc/pf.conf`.
    public static let anchorName = "com.apple/routeweaver.killswitch"

    /// Dedicated unused GID assigned to the authorized Mihomo process so PF can allow outbound
    /// traffic exclusively from Mihomo itself (blocking even unrelated root daemons).
    public static let mihomoDedicatedGID: UInt32 = 47_921

    /// Terminal fallback command users can run to immediately remove Kill Switch rules.
    public static let emergencyResetCommand = "sudo pfctl -a \(anchorName) -F all"

    /// Maximum utun index included in the PF interface allowlist (`utun0` ... `utun31`).
    public static let maxUtunIndex = 31

    /// Renders the PF anchor ruleset for the given options.
    ///
    /// Rule evaluation order (all rules use `quick` so the first match wins):
    /// 1. Allow loopback (`lo0`) for local API (`127.0.0.1`) and IPC.
    /// 2. Allow TUN virtual interfaces (`utun0`..`utun31`) so all traffic routed into Mihomo TUN passes.
    /// 3. Allow outbound TCP/UDP/ICMP/ICMPv6 from Mihomo itself (`user 0 group <dedicatedGID>`).
    /// 4. Block all other outbound DNS (TCP/UDP port 53) to prevent leaks to domestic/router DNS even when LAN is allowed.
    /// 5. Allow DHCPv4 (68->67) and DHCPv6 (546->547) so physical NICs (Wi-Fi / Ethernet / USB) can acquire/renew IPs.
    /// 6. Optionally allow private/link-local LAN subnets (RFC1918, IPv4 link-local/multicast, IPv6 link-local/ULA/multicast).
    /// 7. Drop all remaining outbound traffic across all physical interfaces (`block drop out quick all`).
    public static func renderPFConfig(
        allowLAN: Bool,
        dedicatedGID: UInt32 = mihomoDedicatedGID
    ) -> String {
        let utunList = (0...maxUtunIndex).map { "utun\($0)" }.joined(separator: ", ")

        var lines: [String] = [
            "# RouteWeaver Kill Switch PF Anchor (\(anchorName))",
            "# Generated automatically — do not edit manually.",
            "",
            "# 1. Loopback (local controller API, mixed proxy port, IPC)",
            "pass quick on lo0 all",
            "",
            "# 2. Mihomo TUN virtual interfaces",
            "pass quick on { \(utunList) } all",
            "",
            "# 3. Authorized Mihomo core process only (uid 0, dedicated gid \(dedicatedGID))",
            "pass out quick proto { tcp, udp, icmp, icmp6 } from any to any user 0 group \(dedicatedGID) keep state",
            "",
            "# 4. Prevent non-core DNS leaks (including to LAN router port 53)",
            "block drop out quick proto { tcp, udp } from any to any port 53",
            "",
            "# 5. DHCPv4 / DHCPv6 so physical NICs can obtain and renew leases",
            "pass out quick inet proto udp from any port 68 to any port 67",
            "pass out quick inet6 proto udp from any port 546 to any port 547",
        ]

        if allowLAN {
            lines.append("")
            lines.append("# 6. Optional LAN / private network access (excluding port 53 blocked above)")
            lines.append("pass out quick inet to { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255/32 } keep state")
            lines.append("pass out quick inet6 to { fe80::/10, fc00::/7, ff00::/8 } keep state")
        }

        lines.append("")
        lines.append("# 7. Fail-closed: drop all other outbound traffic")
        lines.append("block drop out quick all")
        lines.append("")

        return lines.joined(separator: "\n")
    }
}
