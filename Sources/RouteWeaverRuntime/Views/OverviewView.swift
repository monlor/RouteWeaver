import RoutingCore
import SwiftUI

struct OverviewView: View {
    @ObservedObject var state: AppState
    @ObservedObject var liveProxyStore: LiveProxyStore
    @ObservedObject var bridge: RemoteNetworkBridge
    @State private var expandedAutoGroups: Set<String> = []
    @State private var customHTTPPortText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let link = bridge.activeLink {
                    activeBridgeBanner(link)
                }

                statusCard

                if state.readinessItems.contains(where: { !$0.isReady }) {
                    readinessCard
                }

                if state.isCoreRunning {
                    OverviewNetworkHealthCard(
                        state: state,
                        liveProxyStore: liveProxyStore,
                        monitor: state.activeConnectionMonitor
                    )
                }

                TrafficOverviewCard(state: state, monitor: state.activeConnectionMonitor)

                if state.profile.gatewayModeEnabled {
                    GatewayDevicesCard(state: state, monitor: state.activeConnectionMonitor)
                }

                OverviewSubscriptionUsageCard(state: state, subscriptionStore: state.activeSubscriptionStore)

                if state.isCoreRunning && !liveProxyStore.activeProxyGroups.isEmpty {
                    liveNodesCard
                }

                routingSummaryCard
            }
            .padding(20)
        }
    }

    private func activeBridgeBanner(_ link: ActiveRemoteNetworkLink) -> some View {
        HStack(spacing: 12) {
            Image(systemName: link.mode == .gateway ? "wifi.router.fill" : "network")
                .font(.title3)
                .foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text("本机已接入「\(link.remoteHostName)」的\(link.mode.title)")
                    .font(.subheadline.weight(.semibold))
                Text(
                    link.mode == .gateway
                    ? "网络服务：\(link.serviceName) · 网关与 DNS：\(link.remoteIP)"
                    : "网络服务：\(link.serviceName) · 系统代理：\(link.remoteIP):\(link.port ?? 0)"
                )
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            }
            Spacer()
            if bridge.isApplying {
                ProgressView().controlSize(.small)
            }
            Button("断开并恢复本机网络") {
                state.disconnectRemoteBridge()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(bridge.isApplying)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.teal.opacity(0.12)))
    }

    private var statusCard: some View {
        SectionCard(
            state.isViewingRemote ? "运行状态与代理入口 · \(state.currentDeviceDisplayName)" : "运行状态与代理入口",
            icon: "bolt.shield"
        ) {
            FlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                if state.activeKillSwitchActive {
                    StatusPill(
                        state.isCoreRunning ? "断网保护中" : "已断网保护",
                        systemImage: "lock.shield.fill",
                        color: state.isCoreRunning ? .orange : .red
                    )
                }
                if state.profile.gatewayModeEnabled {
                    StatusPill(
                        state.isGatewayActive ? "网关运行中" : "网关模式",
                        systemImage: "wifi.router.fill",
                        color: state.isGatewayActive ? .teal : .cyan
                    )
                }
                if state.profile.effectiveTunEnabled {
                    StatusPill(
                        state.isTunActive ? "TUN 运行中" : "TUN 模式",
                        systemImage: "shield.lefthalf.filled",
                        color: state.isTunActive ? .purple : .indigo
                    )
                }
                if state.profile.effectiveAllowLAN {
                    StatusPill("局域网已开放", systemImage: "wifi", color: .blue)
                }
                StatusPill(
                    state.corePhaseTitle,
                    systemImage: state.isCoreRunning ? "checkmark.circle.fill" : "circle.fill",
                    color: state.isCoreRunning ? .green : (state.isCoreBusy ? .orange : .secondary)
                )
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                SplitHeaderBar(horizontalSpacing: 12, verticalSpacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            state.profile.gatewayModeEnabled
                            ? "局域网透明网关（TUN + DNS :53 + IP 转发）"
                            : (state.profile.tunEnabled ? "全系统 TUN 透明代理 + 混合端口" : "混合代理 (HTTP / SOCKS5)")
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(state.localProxyAddress)
                            .font(.system(.title3, design: .monospaced).weight(.semibold))
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                } trailing: {
                    HStack(spacing: 8) {
                        Button("复制地址") { state.copyProxyAddress() }
                        Button("复制终端命令") { state.copyShellExport() }

                        if state.isCoreRunning || state.isCoreBusy {
                            Button("停止核心") { state.stop() }
                        } else {
                            Button("启动核心") { state.start() }
                                .buttonStyle(.borderedProminent)
                                .disabled(!state.canStart)
                        }
                    }
                }

                if !state.isViewingRemote, let link = bridge.activeLink {
                    HStack(spacing: 10) {
                        Label(
                            "本机当前正在使用远程设备「\(link.remoteHostName)」的\(link.mode.title)，不能同时启动本机核心。",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        Spacer()
                        Button("断开远程接入") {
                            state.disconnectRemoteBridge()
                        }
                        .controlSize(.small)
                        .disabled(bridge.isApplying)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
                }

                if state.isViewingRemote, let host = state.activeRemoteHost {
                    Divider()
                    remoteBridgeControls(for: host)
                }

                Divider()

                HStack(spacing: 12) {
                    Toggle(isOn: Binding(
                        get: { state.profile.tunEnabled },
                        set: { state.setTunEnabled($0) }
                    )) {
                        HStack(spacing: 6) {
                            Text("TUN 透明代理模式")
                                .font(.subheadline.weight(.medium))
                            Text(state.profile.effectiveTunEnabled
                                 ? "\(state.profile.tunStack.rawValue) · \(state.profile.tunDNSMode.rawValue)"
                                 : "接管终端、应用与 UDP 流量，无需手动配置代理")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(state.editingLocked)

                    Spacer()

                    if !state.isViewingRemote && state.profile.effectiveTunEnabled && !state.tunPermissionStatus.isReady {
                        if state.isAuthorizingTun {
                            ProgressView().controlSize(.small)
                        } else if state.tunPermissionStatus == .needsSync {
                            Button("同步组件") {
                                state.authorizeTun()
                            }
                            .controlSize(.small)
                            .disabled(state.engine.isBusy || state.isAuthorizingTun || state.binary == nil)
                            .help("当前已授权旧组件仍可正常启停网关不断网；点击可同步新版辅助组件")
                        } else if state.tunPermissionStatus != .helperMissing {
                            Button("授权权限") {
                                state.authorizeTun()
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .disabled(state.engine.isBusy || state.isAuthorizingTun || state.binary == nil)
                            .help(state.engine.isRunning ? "将先停止核心，完成管理员授权后自动重启" : "授予管理员权限以安装 TUN 辅助组件")
                        }
                    }

                    Button("TUN 设置") { state.selectedSection = .settings }
                        .buttonStyle(.link)
                        .font(.caption)
                }

                HStack(spacing: 12) {
                    Toggle(isOn: Binding(
                        get: { state.profile.gatewayModeEnabled },
                        set: { state.setGatewayModeEnabled($0) }
                    )) {
                        HStack(spacing: 6) {
                            Text("局域网网关模式")
                                .font(.subheadline.weight(.medium))
                            Text(state.profile.gatewayModeEnabled
                                 ? "DNS 0.0.0.0:53 · 内核 IP 转发（\(state.activeIsIPForwardingEnabled ? "已开启" : "启动后自动开启")）"
                                 : "作为旁路由，让手机、电视、游戏机等设备将网关与 DNS 指向此设备")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(state.editingLocked)

                    Spacer()

                    Button("网关设置") { state.selectedSection = .settings }
                        .buttonStyle(.link)
                        .font(.caption)
                }

                if state.profile.gatewayModeEnabled {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("局域网设备网关配置（路由器 / DNS 均填以下 IP）", systemImage: "wifi.router")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            StatusPill(
                                state.activeIsIPForwardingEnabled ? "IP 转发已开启" : "IP 转发待启动",
                                systemImage: state.activeIsIPForwardingEnabled ? "arrow.triangle.branch" : "clock",
                                color: state.activeIsIPForwardingEnabled ? .teal : .secondary
                            )
                        }
                        if state.activeLANInterfaces.isEmpty {
                            InlineNote("未检测到活跃局域网 IPv4 地址，请检查网络连接。")
                        } else {
                            ForEach(state.activeLANInterfaces) { info in
                                if let ip = info.ipv4Address {
                                    HStack(spacing: 10) {
                                        Text(info.shortLabel)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)
                                        Text("网关 & DNS: \(ip)")
                                            .font(.system(.caption, design: .monospaced).weight(.medium))
                                            .textSelection(.enabled)
                                        if let mask = info.ipv4Netmask {
                                            Text("· 掩码 \(mask)")
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .textSelection(.enabled)
                                        }
                                        Spacer()
                                        Button("复制 IP") {
                                            state.copyText(ip, label: "网关 IP \(ip)")
                                        }
                                        .controlSize(.small)
                                        Button("复制配置") {
                                            state.copyGatewaySetup(for: info)
                                        }
                                        .controlSize(.small)
                                    }
                                }
                            }
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.teal.opacity(0.07)))
                }

                if state.profile.effectiveAllowLAN {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("局域网接入地址 (HTTP & SOCKS5)", systemImage: "network")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("端口设置") { state.selectedSection = .settings }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                        if state.lanIPAddresses.isEmpty {
                            InlineNote("未检测到活跃局域网 IPv4 地址，请检查网络连接。")
                        } else {
                            ForEach(state.lanIPAddresses, id: \.self) { ip in
                                HStack(spacing: 10) {
                                    Text("http://\(ip):\(state.profile.mixedPort)")
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                    Text("·")
                                        .foregroundStyle(.tertiary)
                                    Text("socks5://\(ip):\(state.profile.mixedPort)")
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                    Spacer()
                                    Button("复制 IP:端口") {
                                        state.copyText("\(ip):\(state.profile.mixedPort)", label: "局域网地址 \(ip):\(state.profile.mixedPort)")
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }

                if let err = state.coreLastError {
                    InlineValidationMessage(err, isError: true)
                }

                if state.activeKillSwitchActive && !state.isCoreRunning {
                    HStack(spacing: 10) {
                        Label("断网保护已生效：核心未启动前外网流量已阻断（防止走默认网卡泄漏）。", systemImage: "lock.shield.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Spacer()
                        Button("关闭断网保护") {
                            state.setKillSwitchEnabled(false)
                        }
                        .controlSize(.small)
                        .disabled(state.isUpdatingKillSwitch)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
                }
            }
        }
    }

    @ViewBuilder
    private func remoteBridgeControls(for host: RemoteSavedHost) -> some View {
        let defaultPort = state.profile.httpPort ?? state.activeMixedPort
        let effectivePort = Int(customHTTPPortText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? defaultPort
        let allowHTTPProxy = state.canConfigureRemoteBridge && state.isCoreRunning && state.profile.effectiveAllowLAN
        let allowGateway = state.canConfigureRemoteBridge && state.isGatewayActive

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label("将本机接入此远程设备", systemImage: "link.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()

                HStack(spacing: 4) {
                    Text("HTTP 端口:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("\(defaultPort)", text: $customHTTPPortText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 66)
                        .font(.system(.caption, design: .monospaced))
                        .disabled(!state.canConfigureRemoteBridge)
                }

                Button {
                    state.connectRemoteAsHTTPProxy(port: effectivePort)
                } label: {
                    Label("设为本机 HTTP 代理", systemImage: "network")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(bridge.isApplying || !allowHTTPProxy)
                .help(
                    !state.canConfigureRemoteBridge
                    ? "本机核心运行中，禁止配置远程 HTTP 代理"
                    : (!state.isCoreRunning
                       ? "请先启动此远程设备的核心"
                       : (!state.profile.effectiveAllowLAN
                          ? "请先在远程设备开启「允许局域网 (allow-lan)」"
                          : "将本机系统 HTTP/HTTPS 代理指向 \(host.host):\(effectivePort)"))
                )

                Button {
                    state.connectRemoteAsGateway()
                } label: {
                    Label("设为本机网关", systemImage: "wifi.router")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .disabled(bridge.isApplying || !allowGateway)
                .help(
                    !state.canConfigureRemoteBridge
                    ? "本机核心运行中，禁止配置远程网关"
                    : (!state.isGatewayActive
                       ? "请先在远程设备开启并启动局域网网关模式"
                       : "将本机默认网关与 DNS 指向 \(host.host)")
                )
            }

            if !state.canConfigureRemoteBridge {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("本机核心正在运行：可以正常启停和管理此远程设备，但不允许将本机配置为远程 HTTP 代理或网关。如需切换使用此设备，请先停止本机核心。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.09)))
            }
        }
    }

    private var readinessCard: some View {
        SectionCard("启动前检查", icon: "checklist") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(state.readinessItems) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(item.isReady ? Color.green : Color.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.subheadline.weight(.medium))
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !item.isReady {
                            Button("前往配置") { state.selectedSection = item.targetSection }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private var liveNodesCard: some View {
        SectionCard("实时节点状态与切换", icon: "point.3.connected.trianglepath.dotted") {
            Button {
                state.refreshGroups()
            } label: {
                Label("刷新节点", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(liveProxyStore.readsGroups)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(liveProxyStore.activeProxyGroups, id: \.self) { groupName in
                    liveGroupRow(groupName)
                    if groupName != liveProxyStore.activeProxyGroups.last {
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func liveGroupRow(_ groupName: String) -> some View {
        let isTesting = liveProxyStore.testingGroups.contains(groupName)
        if let status = liveProxyStore.groupStatus[groupName], !status.all.isEmpty {
            let isRejectOnly = status.all == ["REJECT"]
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(groupName)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            StatusPill(
                                status.isAutoTest ? "自动测速" : "手动选择",
                                color: status.isAutoTest ? .teal : .blue
                            )
                        }
                        if isRejectOnly {
                            Text("未匹配到可用节点（当前回退 REJECT），请检查订阅下载或正则过滤")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(width: 210, alignment: .leading)

                    if status.isAutoTest {
                        let isCurrentTimedOut = status.isCurrentNodeTimedOut
                        HStack(spacing: 8) {
                            Image(systemName: (isRejectOnly || isCurrentTimedOut) ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(isCurrentTimedOut ? Color.red : (isRejectOnly ? Color.orange : Color.green))
                            Text(status.now.isEmpty ? "测速选路中…" : status.now)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(isCurrentTimedOut ? .red : (isRejectOnly ? .orange : .primary))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if isCurrentTimedOut {
                                StatusPill("超时", color: .red)
                            } else if let delay = status.currentDelay {
                                StatusPill("\(delay) ms", color: latencyColor(delay))
                            }
                            Spacer(minLength: 4)
                            Button {
                                if expandedAutoGroups.contains(groupName) {
                                    expandedAutoGroups.remove(groupName)
                                } else {
                                    expandedAutoGroups.insert(groupName)
                                }
                            } label: {
                                Label(
                                    expandedAutoGroups.contains(groupName) ? "收起(\(status.all.count))" : "候选(\(status.all.count))",
                                    systemImage: expandedAutoGroups.contains(groupName) ? "chevron.up" : "chevron.down"
                                )
                                .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    } else {
                        Picker("", selection: Binding(
                            get: { liveProxyStore.groupSelection[groupName] ?? status.now },
                            set: { state.selectNode(group: groupName, node: $0) }
                        )) {
                            ForEach(status.all, id: \.self) { node in
                                if status.timedOutNodes.contains(node) {
                                    Text("\(node)  (超时)").tag(node)
                                } else if let delay = status.delays[node] {
                                    Text("\(node)  (\(delay) ms)").tag(node)
                                } else {
                                    Text(node).tag(node)
                                }
                            }
                        }
                        .labelsHidden()
                        .disabled(liveProxyStore.readsGroups || isRejectOnly)

                        if status.isCurrentNodeTimedOut {
                            StatusPill("超时", color: .red)
                        } else if let delay = status.currentDelay {
                            StatusPill("\(delay) ms", color: latencyColor(delay))
                        }
                    }

                    Button {
                        state.testGroupDelay(group: groupName)
                    } label: {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("测速", systemImage: "speedometer")
                                .font(.caption)
                        }
                    }
                    .controlSize(.small)
                    .disabled(isTesting || isRejectOnly)
                    .help("立即对「\(groupName)」执行延迟测速")
                }

                if status.isAutoTest && expandedAutoGroups.contains(groupName) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(status.all, id: \.self) { node in
                            let isCurrent = node == status.now
                            HStack(spacing: 8) {
                                Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                                    .font(.caption2)
                                    .foregroundStyle(isCurrent ? Color.green : Color.secondary.opacity(0.4))
                                Text(node)
                                    .font(.caption)
                                    .fontWeight(isCurrent ? .semibold : .regular)
                                    .foregroundStyle(isCurrent ? .primary : .secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if status.timedOutNodes.contains(node) {
                                    Text("超时")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.red)
                                } else if let delay = status.delays[node] {
                                    Text("\(delay) ms")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(latencyColor(delay))
                                } else {
                                    Text("—")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isCurrent ? Color.green.opacity(0.08) : Color.clear)
                            )
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.leading, 8)
                }
            }
        } else {
            HStack(spacing: 12) {
                Text(groupName)
                    .font(.subheadline.weight(.medium))
                    .frame(width: 210, alignment: .leading)
                Text("加载节点中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func latencyColor(_ ms: Int) -> Color {
        if ms < 150 { return .green }
        if ms < 400 { return .orange }
        return .red
    }

    private var routingSummaryCard: some View {
        SectionCard("当前分流拓扑", icon: "arrow.triangle.branch") {
            FlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                Button {
                    state.openTopology()
                } label: {
                    Label("实时流量拓扑", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .controlSize(.small)

                if state.isCoreRunning {
                    Button {
                        state.updateOnlineRuleProviders()
                    } label: {
                        Label("更新在线规则", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .controlSize(.small)
                    .disabled(liveProxyStore.updatingRuleProviders)
                }
                Button("管理规则组") { state.selectedSection = .ruleGroups }
                    .controlSize(.small)
                Button("管理网络目标") { state.selectedSection = .targets }
                    .controlSize(.small)
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                let enabledGroups = state.profile.ruleGroups.filter(\.isEnabled)
                if enabledGroups.isEmpty {
                    InlineNote("暂无启用的规则组，所有流量将走默认兜底目标。")
                } else {
                    ForEach(enabledGroups) { group in
                        HStack(spacing: 10) {
                            Label(group.name, systemImage: group.icon)
                                .font(.subheadline.weight(.medium))
                                .frame(width: 150, alignment: .leading)
                                .lineLimit(1)

                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)

                            targetOverviewBadge(for: group.target)

                            Spacer()

                            Text("\(group.rules.filter(\.isEnabled).count) 条规则")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        if group.id != enabledGroups.last?.id {
                            Divider()
                        }
                    }
                }

                Divider()

                HStack(spacing: 10) {
                    Label("默认兜底 (MATCH)", systemImage: "tray.full")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 150, alignment: .leading)

                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    targetOverviewBadge(for: state.profile.fallbackTarget)
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func targetOverviewBadge(for ref: TargetReference) -> some View {
        switch ref {
        case .reject:
            StatusPill("拦截 (REJECT)", systemImage: "hand.raised", color: .red)
        case .target(let id):
            if let target = state.profile.target(id: id) {
                let preview = state.targetChainPreview(for: target)
                HStack(spacing: 8) {
                    Text(target.name)
                        .font(.subheadline.weight(.semibold))
                    ChainFlowBadge(
                        steps: preview.steps,
                        isDirect: preview.isDirect,
                        aliasStepCount: preview.aliasStepCount
                    )
                }
            } else {
                StatusPill("目标不存在", systemImage: "exclamationmark.triangle", color: .orange)
            }
        }
    }
}

private struct OverviewNetworkHealthCard: View {
    @ObservedObject var state: AppState
    @ObservedObject var liveProxyStore: LiveProxyStore
    @ObservedObject var monitor: ConnectionMonitorService

    var body: some View {
        let snap = state.buildTopologySnapshot()
        let issues = snap.issueLanes
        let isProbingAny = !liveProxyStore.testingGroups.isEmpty

        if issues.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Text("全链路连通正常")
                    .font(.subheadline.weight(.medium))
                Text("· 共 \(snap.lanes.filter { !$0.isRejectBuiltin }.count) 个活跃网络目标，未检测到拨号中断或超时节点")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    state.diagnoseAllActiveHops()
                } label: {
                    if isProbingAny {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("测速中…")
                        }
                    } else {
                        Label("全链路体检", systemImage: "stethoscope")
                    }
                }
                .controlSize(.small)
                .disabled(isProbingAny || liveProxyStore.activeProxyGroups.isEmpty)

                Button {
                    state.openTopology()
                } label: {
                    Label("查看实时拓扑", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.green.opacity(0.24))
                    .allowsHitTesting(false)
            }
        } else {
            let hasHardError = snap.errorCount > 0
            let headerAccent: Color = hasHardError ? .red : .orange

            SectionCard(
                hasHardError ? "网络链路异常诊断" : "网络链路健康预警",
                icon: hasHardError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
            ) {
                HStack(spacing: 8) {
                    StatusPill(
                        hasHardError ? "\(snap.errorCount) 个目标中断" : "\(snap.warningCount) 个目标预警",
                        color: headerAccent
                    )
                    if !monitor.outboundErrors.isEmpty {
                        Button("忽略历史记录") {
                            state.clearOutboundErrors()
                        }
                        .controlSize(.small)
                    }
                    Button {
                        state.openTopology(focusingTarget: issues.first?.id)
                    } label: {
                        Label("打开拓扑图定位", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .controlSize(.small)
                }
            } content: {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(issues) { lane in
                        if let diag = lane.diagnosis {
                            let isErr = diag.severity == .error
                            let rowAccent: Color = isErr ? .red : .orange
                            let testingThis = liveProxyStore.testingGroups.contains(lane.name)
                                || (lane.relayGroupName.map { liveProxyStore.testingGroups.contains($0) } ?? false)

                            HStack(alignment: .center, spacing: 12) {
                                Image(systemName: isErr ? "bolt.slash.fill" : "exclamationmark.circle.fill")
                                    .foregroundStyle(rowAccent)
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(lane.name)
                                            .font(.subheadline.weight(.semibold))
                                        StatusPill(diag.headline, color: rowAccent)
                                        if !lane.affectedBranchNames.isEmpty {
                                            Text("波及：\(lane.affectedBranchNames.prefix(4).joined(separator: "、"))\(lane.affectedBranchNames.count > 4 ? "…" : "")")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Text(diag.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                Spacer()

                                if lane.mode == .proxy {
                                    Button {
                                        state.diagnoseTargetHops(targetName: lane.name)
                                    } label: {
                                        if testingThis {
                                            ProgressView().controlSize(.mini)
                                        } else {
                                            Text(lane.hasRelayHop ? "双跳测速" : "重测节点")
                                        }
                                    }
                                    .controlSize(.small)
                                    .disabled(testingThis)
                                }

                                Button("定位断点") {
                                    state.openTopology(focusingTarget: lane.id)
                                }
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                                .tint(rowAccent)
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(rowAccent.opacity(0.08))
                            )
                        }
                    }
                }
            }
        }
    }
}

private struct GatewayDevicesCard: View {
    @ObservedObject var state: AppState
    @ObservedObject var monitor: ConnectionMonitorService

    var body: some View {
        SectionCard("网关连接设备", icon: "laptopcomputer.and.iphone") {
            HStack(spacing: 8) {
                Toggle("含 ARP 邻居", isOn: $state.includeARPOnlyGatewayDevices)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("同时显示局域网 ARP 缓存中尚未产生网关流量的邻近设备")

                StatusPill(
                    "\(state.activeGatewayDevices.count) 台设备",
                    systemImage: "wifi.router",
                    color: state.activeGatewayDevices.isEmpty ? .secondary : .teal
                )

                Button {
                    state.refreshGatewayDevices()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
        } content: {
            if state.activeGatewayDevices.isEmpty {
                InlineNote(
                    state.isCoreRunning
                    ? "暂无其他设备通过网关发送流量。请将局域网设备的网关与 DNS 设为上方 IP。"
                    : "核心启动后，将在此显示通过网关接入的局域网设备与实时流量。"
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(state.activeGatewayDevices) { device in
                        HStack(spacing: 12) {
                            Image(systemName: device.activeConnectionCount > 0 ? "desktopcomputer" : "network")
                                .foregroundStyle(device.activeConnectionCount > 0 ? .teal : .secondary)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(device.hostname ?? device.ip)
                                        .font(.subheadline.weight(.medium))
                                    if device.hostname != nil {
                                        Text(device.ip)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    if let mac = device.macAddress {
                                        Text(mac)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                    }
                                    if let iface = device.interfaceName {
                                        Text(iface)
                                            .font(.caption2)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                HStack(spacing: 8) {
                                    if device.hasGatewayTraffic {
                                        Text("活跃连接 \(device.activeConnectionCount) · 累计 \(device.totalConnectionCount)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if !device.recentHosts.isEmpty {
                                            Text("最近: \(device.recentHosts.prefix(3).joined(separator: ", "))")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                                .lineLimit(1)
                                        }
                                    } else {
                                        Text("ARP 局域网邻居（暂无网关流量）")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }

                            Spacer()

                            if device.hasGatewayTraffic {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("↑ \(TrafficFormatter.speed(device.uploadSpeed))  ↓ \(TrafficFormatter.speed(device.downloadSpeed))")
                                        .font(.system(.caption, design: .monospaced).weight(.medium))
                                        .foregroundStyle(device.activeConnectionCount > 0 ? .primary : .secondary)
                                    Text("总计 ↑ \(TrafficFormatter.bytes(device.uploadBytes)) · ↓ \(TrafficFormatter.bytes(device.downloadBytes))")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            Button("复制 IP") {
                                state.copyText(device.ip, label: "设备 IP \(device.ip)")
                            }
                            .controlSize(.mini)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
                    }
                }
            }
        }
        .onAppear {
            state.refreshGatewayDevices()
        }
        .onChange(of: monitor.tracker.activeCount) { _ in
            state.refreshGatewayDevices()
        }
        .task(id: state.isCoreRunning) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { break }
                if !state.isViewingRemote {
                    state.refreshGatewayDevices()
                }
            }
        }
    }
}

private struct OverviewSubscriptionUsageCard: View {
    @ObservedObject var state: AppState
    @ObservedObject var subscriptionStore: SubscriptionStore

    private var subscriptionsWithUsage: [(subscription: ProxySubscription, usage: SubscriptionUsage, updatedAt: Date)] {
        state.profile.subscriptions.compactMap { sub in
            guard let entry = subscriptionStore.cache[sub.id], let usage = entry.usage else { return nil }
            return (sub, usage, entry.updatedAt)
        }
    }

    var body: some View {
        if !subscriptionsWithUsage.isEmpty {
            SectionCard("订阅用量", icon: "chart.pie.fill") {
                HStack(spacing: 8) {
                    Button {
                        state.fetchAllSubscriptionNodes()
                    } label: {
                        Label("刷新用量", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(!subscriptionStore.fetchingIDs.isEmpty)

                    Button("管理订阅") {
                        state.selectedSection = .subscriptions
                    }
                    .controlSize(.small)
                }
            } content: {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(subscriptionsWithUsage, id: \.subscription.id) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(item.subscription.name)
                                    .font(.subheadline.weight(.medium))
                                StatusPill(item.subscription.role.title, color: subscriptionRoleColor(item.subscription.role))
                                Spacer()
                                if subscriptionStore.fetchingIDs.contains(item.subscription.id) {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text("更新于 \(Self.usageTimeFormatter.string(from: item.updatedAt))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            SubscriptionUsageBar(usage: item.usage, compact: true)
                        }
                    }
                }
            }
        }
    }

    private func subscriptionRoleColor(_ role: SubscriptionRole) -> Color {
        switch role {
        case .exit: return .blue
        case .relay: return .purple
        case .general: return .teal
        }
    }

    private static let usageTimeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        return df
    }()
}
