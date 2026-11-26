import NetworkExtension
import RoutingCore
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: MobileAppModel

    private enum ScenarioPreset: String, CaseIterable, Identifiable {
        case auto = "自动策略"
        case bypassChain = "跳过链式代理"
        case disabled = "临时禁用 VPN"

        var id: String { rawValue }
    }

    private var currentScenario: ScenarioPreset {
        switch model.switchPolicy.manualOverride {
        case .none:
            return .auto
        case .disabled:
            return .disabled
        case .localCore(let opts) where opts.bypassChainedProxy:
            return .bypassChain
        case .localCore, .directPCSocks5:
            return .auto
        }
    }

    var body: some View {
        NavigationStack {
            List {
                vpnPowerSection

                if let error = model.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                } else if let msg = model.statusMessage {
                    Section {
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.footnote)
                    }
                }

                runtimeStatusSection
                quickScenarioSection
                syncedProfileSection
            }
            .navigationTitle("RouteWeaver")
            .refreshable {
                await model.refreshRuntimeStatusFromTunnel()
                await model.syncNow()
            }
        }
    }

    // MARK: - Sections

    private var vpnPowerSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: vpnIconName)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(vpnAccentColor)
                    .frame(width: 44, height: 44)
                    .background(vpnAccentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text(vpnStatusTitle)
                        .font(.headline)
                    Text(modeDescription(model.runtimeStatus?.activeMode ?? model.effectiveMode))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task { await model.toggleVPN() }
                } label: {
                    if model.isBusy {
                        ProgressView()
                    } else {
                        Text(isVPNActive ? "断开" : "连接")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(isVPNActive ? .red : .accentColor)
                .disabled(model.isBusy)
            }
            .padding(.vertical, 4)
        }
    }

    private var runtimeStatusSection: some View {
        Section("当前网络与隧道状态") {
            LabeledContent("网络类型") {
                Text(networkKindLabel(model.currentNetworkSnapshot.interfaceKind))
            }

            if model.currentNetworkSnapshot.interfaceKind == .wifi {
                LabeledContent("当前 Wi-Fi") {
                    if let ssid = model.currentNetworkSnapshot.wifiSSID, !ssid.isEmpty {
                        Text(ssid)
                    } else {
                        Button("授权读取 SSID") {
                            model.requestLocationForSSID()
                        }
                        .font(.caption)
                    }
                }
            }

            LabeledContent("生效模式") {
                Text(modeShortBadge(model.runtimeStatus?.activeMode ?? model.effectiveMode))
                    .foregroundStyle(.secondary)
            }

            let relayed = model.runtimeStatus?.relayedInterfaces
                ?? model.interfaceMappings.compactMap { rule -> String? in
                    if case .relayToPCInterface = rule.action { return rule.bsdName }
                    return nil
                }
            LabeledContent("经 Relay 转发网卡") {
                if relayed.isEmpty {
                    Text("无（全部本地直出）")
                        .foregroundStyle(.secondary)
                } else {
                    Text(relayed.joined(separator: ", "))
                        .font(.system(.body, design: .monospaced))
                }
            }

            if let status = model.runtimeStatus {
                LabeledContent("Relay 通道") {
                    Text(status.relayConnected ? "已连接" : "未连接")
                        .foregroundStyle(status.relayConnected ? .green : .secondary)
                }
            }
        }
    }

    private var quickScenarioSection: some View {
        Section {
            Picker("运行场景", selection: Binding(
                get: { currentScenario },
                set: { preset in
                    Task {
                        switch preset {
                        case .auto:
                            await model.setManualScenario(nil)
                        case .bypassChain:
                            await model.setManualScenario(.localCore(LocalCoreExecutionOptions(bypassChainedProxy: true)))
                        case .disabled:
                            await model.setManualScenario(.disabled)
                        }
                    }
                }
            )) {
                ForEach(ScenarioPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("快捷场景切换")
        } footer: {
            Text("「跳过链式代理」会跳过规则与中继的链式前置代理，直接连接出口节点与中继服务，同时保留已配置走中继的 PC 网卡映射。")
        }
    }

    private var syncedProfileSection: some View {
        Section("远程 PC 与配置同步") {
            if let host = model.activeHost {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(host.hostName)
                            .font(.headline)
                        if let status = model.remoteSnapshot?.status {
                            Text("\(status.phaseTitle) · \(status.activeConnectionCount) 活跃连接")
                                .font(.caption)
                                .foregroundStyle(status.isRunning ? .green : .secondary)
                        } else {
                            Text("点击刷新或同步以获取最新状态")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(model.isConnectedViaRelay ? "中继远程" : "局域网直连")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background((model.isConnectedViaRelay ? Color.purple : Color.green).opacity(0.14), in: Capsule())
                        .foregroundStyle(model.isConnectedViaRelay ? .purple : .green)
                }

                if let status = model.remoteSnapshot?.status {
                    HStack(spacing: 12) {
                        Label("\(TrafficFormatter.bytes(status.uploadSpeed))/s", systemImage: "arrow.up")
                            .foregroundStyle(.orange)
                        Spacer()
                        Label("\(TrafficFormatter.bytes(status.downloadSpeed))/s", systemImage: "arrow.down")
                            .foregroundStyle(.green)
                    }
                    .font(.caption.monospacedDigit().weight(.medium))
                }

                let remoteIsRunning = model.remoteSnapshot?.status.isRunning ?? false
                let remoteIsBusy = model.remoteSnapshot?.status.isBusy ?? false
                let hasRemoteStatus = model.remoteSnapshot != nil

                HStack(spacing: 8) {
                    compactActionButton(title: "启动", icon: "play.fill", tint: .green) {
                        Task { await model.startRemotePC() }
                    }
                    .disabled(remoteIsRunning || remoteIsBusy)
                    .opacity((remoteIsRunning || remoteIsBusy) ? 0.45 : 1)

                    compactActionButton(title: "停止", icon: "stop.fill", tint: .red) {
                        Task { await model.stopRemotePC() }
                    }
                    .disabled(hasRemoteStatus && !remoteIsRunning && !remoteIsBusy)
                    .opacity((hasRemoteStatus && !remoteIsRunning && !remoteIsBusy) ? 0.45 : 1)

                    compactActionButton(title: "热重载", icon: "arrow.clockwise", tint: .blue) {
                        Task { await model.hotReloadRemotePC() }
                    }
                    .disabled((hasRemoteStatus && !remoteIsRunning) || remoteIsBusy)
                    .opacity(((hasRemoteStatus && !remoteIsRunning) || remoteIsBusy) ? 0.45 : 1)

                    compactActionButton(title: model.isSyncing ? "同步中" : "同步", icon: "arrow.triangle.2.circlepath", tint: .teal) {
                        Task { await model.syncNow() }
                    }
                }
                .disabled(model.isBusy || model.isSyncing)

                NavigationLink {
                    RemotePCView(embedded: true)
                } label: {
                    Label("管理远程主机与配对", systemImage: "desktopcomputer")
                }
            } else {
                Text("尚未配对远程 PC，配对后可远程控制、同步规则与查看实时流量。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                NavigationLink {
                    RemotePCView(embedded: true)
                } label: {
                    Label("前往配对远程 PC", systemImage: "plus.circle.fill")
                }
            }
        }
    }

    private func compactActionButton(title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                Text(title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var isVPNActive: Bool {
        switch model.vpnStatus {
        case .connected, .connecting, .reasserting:
            return true
        default:
            return false
        }
    }

    private var vpnIconName: String {
        switch model.vpnStatus {
        case .connected: return "checkmark.shield.fill"
        case .connecting, .reasserting: return "arrow.triangle.2.circlepath.circle.fill"
        case .disconnecting: return "xmark.shield"
        default: return "shield.slash"
        }
    }

    private var vpnAccentColor: Color {
        switch model.vpnStatus {
        case .connected: return .green
        case .connecting, .reasserting: return .orange
        default: return .secondary
        }
    }

    private var vpnStatusTitle: String {
        switch model.vpnStatus {
        case .connected: return "VPN 已连接"
        case .connecting: return "正在连接…"
        case .reasserting: return "正在重新连接…"
        case .disconnecting: return "正在断开…"
        case .disconnected: return "VPN 未连接"
        case .invalid: return "VPN 未初始化"
        @unknown default: return "未知状态"
        }
    }

    private func networkKindLabel(_ kind: MobileNetworkSnapshot.InterfaceKind) -> String {
        switch kind {
        case .wifi: return "Wi-Fi"
        case .cellular: return "蜂窝网络"
        case .wired: return "有线网络"
        case .other: return "其他"
        }
    }

    private func modeShortBadge(_ mode: MobileVPNMode) -> String {
        switch mode {
        case .disabled:
            return "已禁用"
        case .localCore(let opts):
            return opts.bypassChainedProxy ? "本地内核 · 无链式" : "本地内核"
        case .directPCSocks5(let host, let port):
            return "直连 PC (\(host):\(port))"
        }
    }

    private func modeDescription(_ mode: MobileVPNMode) -> String {
        switch mode {
        case .disabled:
            return "当前策略为直连移动网络（不使用 VPN）"
        case .localCore(let opts):
            return opts.bypassChainedProxy
                ? "iOS 本地 Mihomo 内核 · 已跳过链式代理"
                : "iOS 本地 Mihomo 内核 · 完整分流与网卡映射"
        case .directPCSocks5(let host, let port):
            return "极简模式 · 全局转发至 PC SOCKS5 (\(host):\(port))"
        }
    }
}
