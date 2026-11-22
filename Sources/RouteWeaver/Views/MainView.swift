import SwiftUI

struct MainView: View {
    @ObservedObject var state: AppState

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $state.selectedSection) { section in
                HStack(spacing: 8) {
                    Label(section.title, systemImage: section.icon)
                    Spacer()
                    if section == .monitor && state.engine.isRunning {
                        ActiveConnectionsBadge(monitor: state.connectionMonitor)
                    } else if hasIssue(in: section) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 7, height: 7)
                            .help("此页面有待完成的配置项")
                    }
                }
                .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 195, max: 230)
            .safeAreaInset(edge: .bottom) {
                sidebarFooter
            }
        } detail: {
            detailView
                .navigationTitle(state.selectedSection?.title ?? "RouteWeaver")
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if !state.feedback.isEmpty {
                            Text(state.feedback)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .transition(.opacity)
                        }

                        Button {
                            state.copyProxyAddress()
                        } label: {
                            Label("复制代理地址", systemImage: "doc.on.doc")
                        }
                        .help("复制本机代理地址 \(state.localProxyAddress) (⌘⇧C)")

                        Button {
                            state.validate()
                        } label: {
                            Label("校验配置", systemImage: "checkmark.shield")
                        }
                        .disabled(state.editingLocked || state.binary == nil)
                        .help("使用 Mihomo -t 校验当前配置 (⌘⇧V)")

                        if state.engine.isRunning {
                            if state.isHotReloading {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Button {
                                    state.hotReload()
                                } label: {
                                    Label(
                                        state.hasPendingHotReload ? "热重载生效" : "热重载",
                                        systemImage: "arrow.triangle.2.circlepath"
                                    )
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(state.hasPendingHotReload ? .orange : .secondary)
                                .disabled(state.configValidationError != nil)
                                .help("无需重启核心，直接将当前规则、目标、订阅、端口及 TUN 参数热重载到 Mihomo")
                            }
                        }

                        if state.engine.isRunning || state.engine.isBusy {
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
                            .help("校验并启动 Mihomo 核心进程 (⌘R)")
                        }
                    }
                }
        }
        .animation(.easeInOut(duration: 0.2), value: state.feedback)
        .alert("操作未完成", isPresented: Binding(
            get: { state.alertText != nil },
            set: { if !$0 { state.alertText = nil } }
        )) {
            Button("关闭", role: .cancel) { state.alertText = nil }
        } message: {
            Text(state.alertText ?? "")
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch state.selectedSection ?? .overview {
        case .overview:
            OverviewView(state: state)
        case .monitor:
            RequestMonitorView(state: state, monitor: state.connectionMonitor)
        case .ruleGroups:
            RuleGroupsView(state: state)
        case .customDNS:
            CustomDNSView(state: state)
        case .targets:
            NetworkTargetsView(state: state)
        case .subscriptions:
            SubscriptionsView(state: state, subscriptionStore: state.subscriptionStore)
        case .settings:
            SettingsCoreView(state: state)
        }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(state.engine.phase.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if state.profile.gatewayModeEnabled || state.profile.effectiveTunEnabled || state.profile.effectiveAllowLAN {
                HStack(spacing: 5) {
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        switch state.engine.phase {
        case .running: return .green
        case .idle: return state.engine.lastError == nil ? .secondary : .red
        default: return .orange
        }
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
