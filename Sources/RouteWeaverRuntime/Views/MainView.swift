import RoutingCore
import SwiftUI

struct MainView: View {
    @ObservedObject var state: AppState

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $state.selectedSection) { section in
                HStack(spacing: 8) {
                    Label(section.title, systemImage: section.icon)
                    Spacer()
                    if section == .monitor && state.isCoreRunning {
                        ActiveConnectionsBadge(monitor: state.activeConnectionMonitor)
                    } else if section == .topology && state.isCoreRunning {
                        TopologySidebarBadge(
                            state: state,
                            liveProxyStore: state.activeLiveProxyStore,
                            monitor: state.activeConnectionMonitor
                        )
                    } else if hasIssue(in: section) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 7, height: 7)
                            .help("此页面有待完成的配置项")
                    }
                }
                .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 240)
            .safeAreaInset(edge: .bottom) {
                sidebarFooter
            }
        } detail: {
            detailView
                .isolateHorizontalOverflow(minWidth: 480)
                .navigationTitle(navigationTitle)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if !state.feedback.isEmpty {
                            Text(state.feedback)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .transition(.opacity)
                        }

                        if state.isViewingRemote {
                            Button {
                                Task { await state.remoteClient.refreshAll() }
                            } label: {
                                Label("刷新远程状态", systemImage: "arrow.clockwise")
                            }
                            .help("立即同步远程设备最新状态")
                        }

                        Button {
                            state.copyProxyAddress()
                        } label: {
                            Label("复制代理地址", systemImage: "doc.on.doc")
                        }
                        .help("复制代理地址 \(state.localProxyAddress) (⌘⇧C)")

                        Button {
                            state.validate()
                        } label: {
                            Label("校验配置", systemImage: "checkmark.shield")
                        }
                        .disabled(state.editingLocked || (!state.isViewingRemote && state.binary == nil))
                        .help("使用 Mihomo -t 校验当前配置 (⌘⇧V)")

                        if state.isCoreRunning {
                            if state.isHotReloading {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Button {
                                    state.hotReload()
                                } label: {
                                    Label(
                                        state.activeHasPendingHotReload ? "热重载生效" : "热重载",
                                        systemImage: "arrow.triangle.2.circlepath"
                                    )
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(state.activeHasPendingHotReload ? .orange : .secondary)
                                .disabled(state.activeConfigValidationError != nil)
                                .help("无需重启核心，直接将当前规则、目标、订阅、端口及 TUN 参数热重载到 Mihomo")
                            }
                        }

                        if state.isCoreRunning || state.isCoreBusy {
                            Button {
                                state.stop()
                            } label: {
                                Label("停止核心", systemImage: "stop.fill")
                            }
                            .help("停止 Mihomo 核心进程 (⌘.)")
                        } else {
                            Button {
                                state.start()
                            } label: {
                                Label("启动核心", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!state.canStart)
                            .help(startButtonHelp)
                        }
                    }
                }
        }
        .animation(.easeInOut(duration: 0.2), value: state.feedback)
        .sheet(isPresented: $state.showingRemoteDeviceSheet) {
            RemoteDeviceManagerSheet(
                state: state,
                server: state.remoteServer,
                client: state.remoteClient,
                onDismiss: { state.showingRemoteDeviceSheet = false }
            )
        }
        .alert("操作未完成", isPresented: Binding(
            get: { state.alertText != nil },
            set: { if !$0 { state.alertText = nil } }
        )) {
            Button("关闭", role: .cancel) { state.alertText = nil }
        } message: {
            Text(state.alertText ?? "")
        }
        .onAppear {
            state.syncSelectedDeviceOnWindowOpen()
        }
    }

    private var navigationTitle: String {
        let base = state.selectedSection?.title ?? "RouteWeaver"
        if let host = state.activeRemoteHost {
            return "\(base) · \(host.hostName)"
        }
        return base
    }

    private var startButtonHelp: String {
        if !state.isViewingRemote, let link = state.remoteBridge.activeLink {
            return "本机正使用远程设备「\(link.remoteHostName)」的\(link.mode.title)，请先断开后再启动本机核心"
        }
        return "校验并启动 Mihomo 核心进程 (⌘R)"
    }

    @ViewBuilder
    private var detailView: some View {
        switch state.selectedSection ?? .overview {
        case .overview:
            OverviewView(
                state: state,
                liveProxyStore: state.activeLiveProxyStore,
                bridge: state.remoteBridge
            )
        case .topology:
            NetworkTopologyView(
                state: state,
                liveProxyStore: state.activeLiveProxyStore,
                monitor: state.activeConnectionMonitor
            )
        case .monitor:
            RequestMonitorView(state: state, monitor: state.activeConnectionMonitor)
        case .trafficStats:
            TrafficStatsView(state: state, monitor: state.activeConnectionMonitor)
        case .ruleGroups:
            RuleGroupsView(state: state)
        case .customDNS:
            CustomDNSView(state: state)
        case .targets:
            NetworkTargetsView(state: state, monitor: state.activeConnectionMonitor)
        case .subscriptions:
            SubscriptionsView(state: state, subscriptionStore: state.activeSubscriptionStore)
        case .settings:
            SettingsCoreView(state: state)
        }
    }

    // MARK: - Bottom-Left Device Switcher & Status Footer

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            HStack(spacing: 6) {
                Menu {
                    Button {
                        state.selectDevice(.local)
                    } label: {
                        HStack {
                            Label(
                                localDeviceMenuTitle,
                                systemImage: "laptopcomputer"
                            )
                            if !state.isViewingRemote {
                                Image(systemName: "checkmark")
                            }
                        }
                    }

                    if !state.remoteClient.savedHosts.isEmpty {
                        Divider()
                        ForEach(state.remoteClient.savedHosts) { host in
                            let isSelected = state.selectedDevice == .remote(host.id)
                            let isBridged = state.remoteBridge.activeLink?.remoteHostId == host.id
                            Button {
                                state.selectDevice(.remote(host.id))
                            } label: {
                                HStack {
                                    Label(
                                        isBridged ? "\(host.hostName)（本机使用中）" : host.hostName,
                                        systemImage: "desktopcomputer"
                                    )
                                    if isSelected {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }

                    Divider()

                    Button {
                        state.showingRemoteDeviceSheet = true
                    } label: {
                        Label("添加 / 管理远程设备…", systemImage: "plus.circle")
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: state.isViewingRemote ? "desktopcomputer" : "laptopcomputer")
                            .font(.caption)
                            .foregroundStyle(state.isViewingRemote ? Color.accentColor : .secondary)
                        Text(state.currentDeviceDisplayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(state.isViewingRemote ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.10))
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("切换当前控制的设备（本机或已添加的远程设备）")

                Button {
                    state.showingRemoteDeviceSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.secondary.opacity(0.10))
                        )
                }
                .buttonStyle(.plain)
                .help("添加远程设备或配置本机被控端服务")
            }

            if let link = state.remoteBridge.activeLink {
                HStack(spacing: 5) {
                    Image(systemName: link.mode == .gateway ? "wifi.router.fill" : "network")
                        .font(.system(size: 9))
                    Text("已接入 \(link.remoteHostName)")
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.teal)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.teal.opacity(0.12)))
                .help("本机正在使用 \(link.remoteHostName) 的\(link.mode.title)")
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(state.corePhaseTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if state.profile.gatewayModeEnabled || state.profile.effectiveTunEnabled || state.profile.effectiveAllowLAN {
                    FlowLayout(horizontalSpacing: 5, verticalSpacing: 4) {
                        if state.profile.gatewayModeEnabled {
                            sidebarBadge("GW", color: .teal)
                        }
                        if state.profile.effectiveTunEnabled {
                            sidebarBadge("TUN", color: .purple)
                        }
                        if state.profile.effectiveAllowLAN {
                            sidebarBadge("LAN", color: .blue)
                        }
                    }
                }
                Text(state.localProxyAddress)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var localDeviceMenuTitle: String {
        let name = state.remoteServer.hostDisplayName
        if state.isLocalCoreActive {
            return "本机 · \(name)（运行中）"
        }
        return "本机 · \(name)"
    }

    private func sidebarBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private var statusColor: Color {
        if state.isCoreRunning { return .green }
        if state.isCoreBusy { return .orange }
        return state.coreLastError == nil ? .secondary : .red
    }

    private func hasIssue(in section: SidebarSection) -> Bool {
        state.readinessItems.contains { !$0.isReady && $0.targetSection == section }
    }
}

private struct ActiveConnectionsBadge: View {
    @ObservedObject var monitor: ConnectionMonitorService

    var body: some View {
        let count = monitor.tracker.businessActiveCount
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
        }
    }
}

private struct TopologySidebarBadge: View {
    @ObservedObject var state: AppState
    @ObservedObject var liveProxyStore: LiveProxyStore
    @ObservedObject var monitor: ConnectionMonitorService

    var body: some View {
        let snap = state.buildTopologySnapshot()
        if snap.errorCount > 0 {
            Text("\(snap.errorCount)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.red))
                .help("\(snap.errorCount) 个网络目标存在断跳异常")
        } else if snap.warningCount > 0 {
            Circle()
                .fill(Color.orange)
                .frame(width: 7, height: 7)
                .help("\(snap.warningCount) 个网络目标存在延迟或静默丢包预警")
        }
    }
}
