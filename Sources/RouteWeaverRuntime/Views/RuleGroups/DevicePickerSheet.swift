import RoutingCore
import SwiftUI

struct DevicePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var state: AppState
    let existingCIDRs: Set<String>
    let onSelect: (RuleGroupClientEntry) -> Void

    @State private var query = ""

    private var filteredLocalInterfaces: [NetworkInterfaceInfo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = state.activeLANInterfaces
        guard !q.isEmpty else { return list }
        return list.filter { iface in
            (iface.ipv4Address?.localizedCaseInsensitiveContains(q) ?? false)
                || iface.displayName.localizedCaseInsensitiveContains(q)
                || iface.bsdName.localizedCaseInsensitiveContains(q)
                || "本机".localizedCaseInsensitiveContains(q)
        }
    }

    private var filteredGatewayDevices: [GatewayClientDevice] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = state.activeGatewayDevices
        guard !q.isEmpty else { return list }
        return list.filter { dev in
            dev.ip.localizedCaseInsensitiveContains(q)
                || (dev.hostname?.localizedCaseInsensitiveContains(q) ?? false)
                || (dev.macAddress?.localizedCaseInsensitiveContains(q) ?? false)
                || (dev.interfaceName?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("选择局域网设备").font(.headline)
                Spacer()
                Button("刷新") {
                    state.refreshGatewayDevices()
                }
                .controlSize(.small)
                Button("完成") { dismiss() }
            }

            TextField("搜索设备名、IP 或 MAC 地址…", text: $query)
                .textFieldStyle(.roundedBorder)

            List {
                if !filteredLocalInterfaces.isEmpty {
                    Section("本机网卡地址") {
                        ForEach(filteredLocalInterfaces) { iface in
                            if let ip = iface.ipv4Address {
                                let normalized = ClientAddressValidator.normalizedCIDR(ip) ?? ip
                                let alreadyAdded = existingCIDRs.contains(normalized)
                                HStack(spacing: 10) {
                                    Image(systemName: "laptopcomputer")
                                        .foregroundStyle(.blue)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("本机 · \(iface.displayName)")
                                            .font(.subheadline.weight(.medium))
                                        Text("\(ip)  (\(iface.bsdName))")
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if alreadyAdded {
                                        Text("已添加")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Button("添加") {
                                            onSelect(RuleGroupClientEntry(
                                                address: ip,
                                                name: "本机 (\(iface.bsdName))"
                                            ))
                                        }
                                        .controlSize(.small)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }

                Section("局域网设备 (\(filteredGatewayDevices.count))") {
                    if filteredGatewayDevices.isEmpty {
                        InlineNote("暂未发现其他局域网设备。请确保设备与本机在同一局域网内，或点击右上角「刷新」；也可以在规则组页面手动输入 IP / 网段。")
                            .padding(.vertical, 6)
                    } else {
                        ForEach(filteredGatewayDevices) { dev in
                            let normalized = ClientAddressValidator.normalizedCIDR(dev.ip) ?? dev.ip
                            let alreadyAdded = existingCIDRs.contains(normalized)
                            HStack(spacing: 10) {
                                Image(systemName: dev.activeConnectionCount > 0 ? "desktopcomputer" : "network")
                                    .foregroundStyle(dev.activeConnectionCount > 0 ? .green : .secondary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(dev.hostname?.isEmpty == false ? dev.hostname! : dev.ip)
                                            .font(.subheadline.weight(.medium))
                                        if dev.activeConnectionCount > 0 {
                                            StatusPill("\(dev.activeConnectionCount) 活跃连接", color: .green)
                                        }
                                    }
                                    HStack(spacing: 8) {
                                        Text(dev.ip)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                        if let mac = dev.macAddress, !mac.isEmpty {
                                            Text(mac)
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(.tertiary)
                                        }
                                        if let iface = dev.interfaceName, !iface.isEmpty {
                                            Text(iface)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                                Spacer()
                                if alreadyAdded {
                                    Text("已添加")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Button("添加") {
                                        onSelect(RuleGroupClientEntry(
                                            address: dev.ip,
                                            name: dev.hostname ?? "",
                                            macAddress: dev.macAddress
                                        ))
                                    }
                                    .controlSize(.small)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 320)
        }
        .padding(18)
        .frame(width: 500, height: 480)
        .onAppear {
            state.refreshGatewayDevices()
        }
    }
}
