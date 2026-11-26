import CoreImage.CIFilterBuiltins
import RoutingCore
import SwiftUI

private enum RemoteSheetTab: String, CaseIterable, Identifiable {
    case devices = "添加与管理设备"
    case hostServer = "本机被控端服务"

    var id: String { rawValue }
}

struct RemoteDeviceManagerSheet: View {
    @ObservedObject var state: AppState
    @ObservedObject var server: RemoteServerService
    @ObservedObject var client: RemoteClientService
    let onDismiss: () -> Void

    @State private var activeTab: RemoteSheetTab = .devices
    @State private var pairingTarget: DiscoveredRemoteDevice?
    @State private var showingManualPair = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("远程设备管理", systemImage: "desktopcomputer.and.macbook")
                    .font(.headline)
                Spacer()
                Picker("", selection: $activeTab) {
                    ForEach(RemoteSheetTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)

                Button("完成") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch activeTab {
                    case .devices:
                        devicesContent
                    case .hostServer:
                        localServerContent
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 600, height: 500)
        .onAppear {
            client.startDiscovery()
        }
        .sheet(item: $pairingTarget) { device in
            PairDiscoveredDeviceSheet(
                device: device,
                client: client,
                onPaired: { hostId in
                    pairingTarget = nil
                    state.selectDevice(.remote(hostId))
                    onDismiss()
                },
                onDismiss: { pairingTarget = nil }
            )
        }
        .sheet(isPresented: $showingManualPair) {
            ManualPairSheet(
                client: client,
                onPaired: { hostId in
                    showingManualPair = false
                    state.selectDevice(.remote(hostId))
                    onDismiss()
                },
                onDismiss: { showingManualPair = false }
            )
        }
    }

    // MARK: - Devices Discovery & Saved Hosts

    private var devicesContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionCard("局域网发现与添加设备", icon: "bonjour") {
                HStack(spacing: 8) {
                    StatusPill(
                        client.isBrowsing ? "正在扫描" : "未扫描",
                        systemImage: client.isBrowsing ? "dot.radiowaves.left.and.right" : "pause.circle",
                        color: client.isBrowsing ? .blue : .secondary
                    )
                    Button("手动添加 IP…") {
                        showingManualPair = true
                    }
                    .controlSize(.small)
                    Button {
                        client.stopDiscovery()
                        client.startDiscovery()
                    } label: {
                        Label("重新扫描", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }
            } content: {
                VStack(alignment: .leading, spacing: 10) {
                    if let err = client.lastError {
                        InlineValidationMessage(err, isError: true)
                    }
                    if let feedback = client.actionFeedback {
                        InlineValidationMessage(feedback, isError: false)
                    }

                    if client.discoveredDevices.isEmpty {
                        InlineNote("暂未在局域网发现其他已开启远程管理的 RouteWeaver 设备。请确认目标设备已开启「本机被控端服务」，或点击右上角「手动添加 IP…」。")
                    } else {
                        ForEach(client.discoveredDevices) { device in
                            HStack(spacing: 10) {
                                Image(systemName: "macbook")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                        .font(.subheadline.weight(.medium))
                                    Text(device.ips.isEmpty ? "端口 \(device.port)" : "\(device.ips.joined(separator: ", ")):\(device.port)")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if client.isPaired(device.id) {
                                    StatusPill("已配对", systemImage: "checkmark.seal.fill", color: .green)
                                    Button("切换控制") {
                                        state.selectDevice(.remote(device.id))
                                        onDismiss()
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.borderedProminent)
                                } else {
                                    Button("配对…") {
                                        pairingTarget = device
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
                        }
                    }
                }
            }

            SectionCard("已添加的远程设备 (\(client.savedHosts.count))", icon: "desktopcomputer") {
                if state.isViewingRemote {
                    Button("切回本机") {
                        state.selectDevice(.local)
                        onDismiss()
                    }
                    .controlSize(.small)
                }
            } content: {
                if client.savedHosts.isEmpty {
                    InlineNote("尚未添加任何远程设备。配对后可直接在左下角切换控制任意设备，所有界面完全复用。")
                } else {
                    VStack(spacing: 8) {
                        ForEach(client.savedHosts) { host in
                            let isSelected = state.selectedDevice == .remote(host.id)
                            let isBridged = state.remoteBridge.activeLink?.remoteHostId == host.id
                            HStack(spacing: 10) {
                                Image(systemName: isSelected ? "desktopcomputer.and.macbook" : "desktopcomputer")
                                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(host.hostName)
                                            .font(.subheadline.weight(.medium))
                                        if isSelected {
                                            StatusPill("当前查看", color: .blue)
                                        }
                                        if isBridged {
                                            StatusPill("本机使用中", color: .teal)
                                        }
                                    }
                                    Text("\(host.host):\(host.port)")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !isSelected {
                                    Button("切换控制") {
                                        state.selectDevice(.remote(host.id))
                                        onDismiss()
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.borderedProminent)
                                }
                                Button("移除", role: .destructive) {
                                    if isBridged {
                                        state.disconnectRemoteBridge()
                                    }
                                    if isSelected {
                                        state.selectDevice(.local)
                                    }
                                    client.removeSavedHost(host.id)
                                }
                                .controlSize(.small)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06))
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Local Host Server Config

    private var localServerContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionCard("本机远程管理服务（被控端）", icon: "antenna.radiowaves.left.and.right") {
            StatusPill(
                server.isListening ? "监听中 :\(server.listeningPort ?? server.port)" : (server.isEnabled ? "启动中…" : "未开启"),
                systemImage: server.isListening ? "checkmark.circle.fill" : "circle",
                color: server.isListening ? .green : (server.isEnabled ? .orange : .secondary)
            )
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                FormRow("开启远程管理", labelWidth: 120) {
                    Toggle("允许局域网内已配对的 RouteWeaver 设备远程控制本机", isOn: $server.isEnabled)
                }

                FormRow("服务端口", labelWidth: 120) {
                    TextField(
                        "19098",
                        value: Binding(
                            get: { Int(server.port) },
                            set: { newVal in
                                if (1024...65535).contains(newVal) {
                                    server.port = UInt16(newVal)
                                }
                            }
                        ),
                        format: .number.grouping(.never)
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)

                    Text("设备：\(server.hostDisplayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let primaryIP = state.localPrimaryLANAddress {
                        Text("· \(primaryIP)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                if let err = server.lastError {
                    InlineValidationMessage(err, isError: true)
                }

                if server.isEnabled {
                    Divider()

                    FormRow("一次性配对码", labelWidth: 120) {
                        HStack(spacing: 10) {
                            Text(server.activePairingCode)
                                .font(.system(.title2, design: .monospaced).weight(.bold))
                                .tracking(3)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.10)))
                                .textSelection(.enabled)

                            Button("复制") {
                                state.copyText(server.activePairingCode, label: "远程配对码")
                            }
                            .controlSize(.small)

                            Button("刷新") {
                                server.regeneratePairingCode()
                            }
                            .controlSize(.small)
                        }
                    }

                    FormRow("已配对控制端", labelWidth: 120) {
                        if server.pairedClients.isEmpty {
                            InlineNote("暂无已配对的控制端设备。在其他 Mac 的 RouteWeaver 左下角点击「+」即可发现本机并输入配对码。")
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(server.pairedClients) { record in
                                    HStack(spacing: 10) {
                                        Image(systemName: "laptopcomputer")
                                            .foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(record.deviceName)
                                                .font(.subheadline.weight(.medium))
                                            Text("配对时间：\(record.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                        Spacer()
                                        Button("撤销", role: .destructive) {
                                            server.revokeClient(record.id)
                                        }
                                        .controlSize(.mini)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
                                }
                            }
                        }
                    }
                }
            }
        }

            LumzelRelayHostSection(state: state, server: server, relayHost: server.relayHost)
        }
    }
}

private struct LumzelRelayHostSection: View {
    @ObservedObject var state: AppState
    @ObservedObject var server: RemoteServerService
    @ObservedObject var relayHost: LumzelRelayHostService

    var body: some View {
        SectionCard("中继服务（外网穿透与网卡转发）", icon: "network.badge.shield.half.filled") {
            StatusPill(
                relayHost.isConnected ? "已连接" : (relayHost.isEnabled ? "连接中…" : "未开启"),
                systemImage: relayHost.isConnected ? "checkmark.shield.fill" : (relayHost.isEnabled ? "dot.radiowaves.left.and.right" : "circle"),
                color: relayHost.isConnected ? .green : (relayHost.isEnabled ? .orange : .secondary)
            )
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                FormRow("启用中继", labelWidth: 120) {
                    Toggle("通过中继服务提供外网远程管理与指定网卡转发", isOn: $relayHost.isEnabled)
                }

                FormRow("中继地址", labelWidth: 120) {
                    TextField("wss://relay.example.com", text: $relayHost.serverURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }

                FormRow("中继密码", labelWidth: 120) {
                    SecureField("可选", text: $relayHost.password)
                        .textFieldStyle(.roundedBorder)
                }

                FormRow("主机 ID", labelWidth: 120) {
                    HStack(spacing: 8) {
                        Text(relayHost.hostID)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if relayHost.isConnected || relayHost.activeControlSessions > 0 || relayHost.activeDataStreams > 0 {
                            Text("· 控制 \(relayHost.activeControlSessions) · 数据流 \(relayHost.activeDataStreams)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                if let err = relayHost.lastError {
                    InlineValidationMessage(err, isError: true)
                }

                Divider()

                let shareString = (try? relayHost.makePairingBundle(
                    server: server,
                    lanIPs: state.localLANIPAddresses,
                    mixedPort: state.localProfile.mixedPort
                ).encodeShareString()) ?? ""

                FormRow("iOS 一键配对", labelWidth: 120) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Button {
                                if !shareString.isEmpty {
                                    state.copyText(shareString, label: "iOS 一键配对码")
                                }
                            } label: {
                                Label("复制 iOS 一键配对码", systemImage: "doc.on.doc")
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .disabled(shareString.isEmpty)

                            Text("包含局域网地址、SOCKS5 端口、配对码及 Relay 端到端加密公钥")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if !shareString.isEmpty, let qrImage = Self.generateQRCode(from: shareString) {
                            HStack(spacing: 12) {
                                Image(nsImage: qrImage)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 128, height: 128)
                                    .padding(6)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                    )

                                Text("在 iOS 端 RouteWeaver 中扫描此二维码，或粘贴「iOS 一键配对码」即可完成配置。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private static func generateQRCode(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        let rep = NSCIImageRep(ciImage: scaled)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
}

private struct PairDiscoveredDeviceSheet: View {
    let device: DiscoveredRemoteDevice
    @ObservedObject var client: RemoteClientService
    let onPaired: (String) -> Void
    let onDismiss: () -> Void

    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("配对远程设备：\(device.name)")
                .font(.headline)
            Text("请输入目标设备「本机被控端服务」中显示的 6 位配对码。")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("6 位配对码", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(.title3, design: .monospaced))

            if let err = client.lastError {
                InlineValidationMessage(err, isError: true)
            }

            HStack {
                Spacer()
                Button("取消") { onDismiss() }
                Button(client.isPairing ? "配对中…" : "确认配对") {
                    Task {
                        if await client.pair(discoveredDevice: device, pairingCode: code),
                           let hostId = client.activeHostId {
                            onPaired(hostId)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(client.isPairing || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

private struct ManualPairSheet: View {
    @ObservedObject var client: RemoteClientService
    let onPaired: (String) -> Void
    let onDismiss: () -> Void

    @State private var host = ""
    @State private var port = Int(RemoteControlProtocol.defaultPort)
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("手动添加并配对远程设备")
                .font(.headline)

            FormRow("主机 IP", labelWidth: 72) {
                TextField("例如 192.168.1.100", text: $host)
                    .textFieldStyle(.roundedBorder)
            }
            FormRow("端口", labelWidth: 72) {
                TextField("19098", value: $port, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }
            FormRow("配对码", labelWidth: 72) {
                TextField("6 位数字", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            if let err = client.lastError {
                InlineValidationMessage(err, isError: true)
            }

            HStack {
                Spacer()
                Button("取消") { onDismiss() }
                Button(client.isPairing ? "配对中…" : "配对并切换") {
                    Task {
                        let safePort = UInt16(clamping: max(1, min(65535, port)))
                        if await client.pairManual(host: host, port: safePort, pairingCode: code),
                           let hostId = client.activeHostId {
                            onPaired(hostId)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(client.isPairing || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
