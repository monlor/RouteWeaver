import RoutingCore
import SwiftUI

struct OverviewView: View {
    @ObservedObject var state: AppState
    @State private var expandedAutoGroups: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard

                if state.readinessItems.contains(where: { !$0.isReady }) {
                    readinessCard
                }

                TrafficOverviewCard(state: state, monitor: state.connectionMonitor)

                OverviewSubscriptionUsageCard(state: state, subscriptionStore: state.subscriptionStore)

                if state.engine.isRunning && !state.activeProxyGroups.isEmpty {
                    liveNodesCard
                }

                routingSummaryCard
            }
            .padding(20)
        }
    }

    private var statusCard: some View {
        SectionCard("运行状态与代理入口", icon: "bolt.shield") {
            HStack(spacing: 8) {
                if state.profile.gatewayModeEnabled {
                    StatusPill(
                        state.engine.isGatewayActive ? "网关运行中" : "网关模式",
                        systemImage: "wifi.router.fill",
                        color: state.engine.isGatewayActive ? .teal : .cyan
                    )
                }
                if state.profile.effectiveTunEnabled {
                    StatusPill(
                        state.engine.isTunActive ? "TUN 运行中" : "TUN 模式",
                        systemImage: "shield.lefthalf.filled",
                        color: state.engine.isTunActive ? .purple : .indigo
                    )
                }
                if state.profile.effectiveAllowLAN {
                    StatusPill("局域网已开放", systemImage: "wifi", color: .blue)
                }
                StatusPill(
                    state.engine.phase.title,
                    systemImage: state.engine.isRunning ? "checkmark.circle.fill" : "circle.fill",
                    color: state.engine.isRunning ? .green : (state.engine.isBusy ? .orange : .secondary)
                )
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            state.profile.gatewayModeEnabled
                            ? "局域网透明网关（TUN + DNS :53 + IP 转发）"
                            : (state.profile.tunEnabled ? "全系统 TUN 透明代理 + 本机端口" : "本机混合代理 (HTTP / SOCKS5)")
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(state.localProxyAddress)
                            .font(.system(.title3, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                    }

                    Spacer()

                    Button("复制地址") { state.copyProxyAddress() }
                    Button("复制终端命令") { state.copyShellExport() }

                    if state.engine.isRunning || state.engine.isBusy {
                        Button("停止核心") { state.stop() }
                    } else {
                        Button("启动核心") { state.start() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!state.canStart)
                    }
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

                    if state.profile.effectiveTunEnabled && !state.tunPermissionStatus.isReady {
                        if state.isAuthorizingTun {
                            ProgressView().controlSize(.small)
                        } else if state.tunPermissionStatus != .helperMissing {
                            Button(state.tunPermissionStatus == .needsSync ? "重新授权" : "授权权限") {
                                state.authorizeTun()
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .disabled(state.engine.isBusy || state.isAuthorizingTun || state.binary == nil)
                            .help(state.engine.isRunning ? "将先停止核心，完成管理员授权后自动重启" : "授予管理员权限以同步 TUN 组件")
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
                                 ? "DNS 0.0.0.0:53 · 内核 IP 转发（\(state.isIPForwardingEnabled ? "已开启" : "启动后自动开启")）"
                                 : "作为旁路由，让手机、电视、游戏机等设备将网关与 DNS 指向本机")
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
                                state.isIPForwardingEnabled ? "IP 转发已开启" : "IP 转发待启动",
                                systemImage: state.isIPForwardingEnabled ? "arrow.triangle.branch" : "clock",
                                color: state.isIPForwardingEnabled ? .teal : .secondary
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

                if let err = state.engine.lastError {
                    InlineValidationMessage(err, isError: true)
                }
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
            .disabled(state.readsGroups)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(state.activeProxyGroups, id: \.self) { groupName in
                    liveGroupRow(groupName)
                    if groupName != state.activeProxyGroups.last {
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func liveGroupRow(_ groupName: String) -> some View {
        let isTesting = state.testingGroups.contains(groupName)
        if let status = state.groupStatus[groupName], !status.all.isEmpty {
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
                        HStack(spacing: 8) {
                            Image(systemName: isRejectOnly ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(isRejectOnly ? Color.orange : Color.green)
                            Text(status.now.isEmpty ? "测速选路中…" : status.now)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(isRejectOnly ? .orange : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let delay = status.currentDelay {
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
                            get: { state.groupSelection[groupName] ?? status.now },
                            set: { state.selectNode(group: groupName, node: $0) }
                        )) {
                            ForEach(status.all, id: \.self) { node in
                                if let delay = status.delays[node] {
                                    Text("\(node)  (\(delay) ms)").tag(node)
                                } else {
                                    Text(node).tag(node)
                                }
                            }
                        }
                        .labelsHidden()
                        .disabled(state.readsGroups || isRejectOnly)

                        if let delay = status.currentDelay {
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
                                if let delay = status.delays[node] {
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
            HStack(spacing: 8) {
                if state.engine.isRunning {
                    Button {
                        state.updateOnlineRuleProviders()
                    } label: {
                        Label("更新在线规则", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .controlSize(.small)
                    .disabled(state.updatingRuleProviders)
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
                HStack(spacing: 8) {
                    Text(target.name)
                        .font(.subheadline.weight(.semibold))
                    ChainFlowBadge(
                        steps: state.targetSummaryChain(for: target),
                        isDirect: target.mode == .direct
                    )
                }
            } else {
                StatusPill("目标不存在", systemImage: "exclamationmark.triangle", color: .orange)
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
