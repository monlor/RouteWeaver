import RoutingCore
import SwiftUI

struct ProxyAndRulesView: View {
    @EnvironmentObject private var model: MobileAppModel
    @State private var activeSegment: Segment = .rules

    private enum Segment: String, CaseIterable, Identifiable {
        case proxies = "代理节点"
        case rules = "规则与网卡"

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("视图切换", selection: $activeSegment) {
                        ForEach(Segment.allCases) { seg in
                            Text(seg.rawValue).tag(seg)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    .listRowBackground(Color.clear)
                }

                switch activeSegment {
                case .proxies:
                    proxyGroupsContent
                case .rules:
                    rulesAndInterfacesContent
                }
            }
            .navigationTitle("节点与规则")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            if activeSegment == .rules {
                                await model.syncNow()
                            } else {
                                await model.refreshRemoteDashboard()
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.activeHost == nil || model.isSyncing)
                }
            }
            .refreshable {
                await model.refreshRemoteDashboard()
                if activeSegment == .rules {
                    await model.syncNow()
                }
            }
        }
    }

    // MARK: - 代理节点

    @ViewBuilder
    private var proxyGroupsContent: some View {
        let groups = model.remoteSnapshot?.proxies ?? []
        if groups.isEmpty {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "globe")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text(model.activeHost == nil ? "尚未配对远程 PC" : "暂无活跃代理节点组")
                        .font(.headline)
                    Text(model.activeHost == nil
                         ? "请先在「总览」或「设置」中配对远程 PC。"
                         : "请确认 PC 端核心已启动，或下拉刷新。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        } else {
            ForEach(groups) { group in
                Section {
                    ForEach(group.all, id: \.self) { node in
                        Button {
                            Task { await model.selectRemoteProxy(group: group.name, node: node) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: group.now == node ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(group.now == node ? Color.accentColor : Color.secondary.opacity(0.45))

                                Text(node)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Spacer()

                                if let delay = group.delays[node], delay > 0 {
                                    Text("\(delay) ms")
                                        .font(.caption.monospacedDigit().weight(.medium))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(delayColor(delay).opacity(0.14), in: Capsule())
                                        .foregroundStyle(delayColor(delay))
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("\(group.name) · \(group.type)")
                        Spacer()
                        Button("测速") {
                            Task { await model.testRemoteDelay(group: group.name) }
                        }
                        .font(.caption.weight(.medium))
                        .textCase(nil)
                    }
                }
            }
        }
    }

    // MARK: - 规则与网卡

    @ViewBuilder
    private var rulesAndInterfacesContent: some View {
        if let profile = model.activeSyncedProfile {
            // 1. 仅展示规则实际引用到的 PC 网卡
            let referencedMappings = model.referencedInterfaceMappings
            if !referencedMappings.isEmpty {
                Section {
                    ForEach(referencedMappings) { rule in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(rule.bsdName, systemImage: "network")
                                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                                if !rule.displayName.isEmpty && rule.displayName != rule.bsdName {
                                    Text(rule.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }

                            Picker("路由方式", selection: Binding(
                                get: {
                                    switch model.interfaceAction(for: rule.bsdName) {
                                    case .useMobileDefault: return 0
                                    case .relayToPCInterface: return 1
                                    }
                                },
                                set: { selection in
                                    let action: PCInterfaceMappingAction = (selection == 0)
                                        ? .useMobileDefault
                                        : .relayToPCInterface(routeOverride: nil)
                                    Task { await model.setInterfaceAction(action, for: rule.bsdName) }
                                }
                            )) {
                                Text("直连本机默认网卡").tag(0)
                                Text("经中继访问 PC 网卡").tag(1)
                            }
                            .pickerStyle(.segmented)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("规则引用的 PC 网卡（\(referencedMappings.count)）")
                } footer: {
                    Text("仅显示当前规则组中实际绑定过的 PC 网卡；修改后立即同步至 VPN 隧道。")
                }
            }

            // 2. 远程规则组列表（支持在规则组上直接指定绑定网卡的路由方式）
            Section {
                if profile.ruleGroups.isEmpty {
                    Text("PC 端尚未配置规则组。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(profile.ruleGroups) { group in
                        ruleGroupRow(group: group)
                    }
                }
            } header: {
                Text("远程规则组（\(profile.ruleGroups.count)）")
            }

            // 3. 默认兜底规则
            Section("默认兜底 (MATCH)") {
                let fallback = model.resolvedTargetInfo(for: profile.fallbackTarget)
                targetBadgeRow(
                    title: "未命中以上规则时",
                    subtitle: nil,
                    targetName: fallback.name,
                    modeTitle: fallback.modeTitle,
                    boundInterface: fallback.boundInterface,
                    isEnabled: true
                )
            }
        } else {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("尚未同步 PC 规则组")
                        .font(.headline)
                    Text("配对并同步远程 PC 后，此处将展示所有规则组及规则引用的 PC 网卡。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if model.activeHost != nil {
                        Button("立即同步") {
                            Task { await model.syncNow() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        }
    }

    private func ruleGroupRow(group: RuleGroup) -> some View {
        let info = model.resolvedTargetInfo(for: group.target)
        let ruleCountText = "\(group.rules.count) 条规则"
        return targetBadgeRow(
            title: group.name,
            subtitle: group.isEnabled ? ruleCountText : "\(ruleCountText) · 已禁用",
            targetName: info.name,
            modeTitle: info.modeTitle,
            boundInterface: info.boundInterface,
            isEnabled: group.isEnabled
        )
    }

    @ViewBuilder
    private func targetBadgeRow(
        title: String,
        subtitle: String?,
        targetName: String,
        modeTitle: String,
        boundInterface: String?,
        isEnabled: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isEnabled ? .primary : .secondary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(targetName)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                    Text(modeTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let iface = boundInterface {
                let currentAction = model.interfaceAction(for: iface)
                let isRelay = {
                    if case .relayToPCInterface = currentAction { return true }
                    return false
                }()
                HStack(spacing: 8) {
                    Label("\(iface) (\(model.interfaceDisplayName(for: iface)))", systemImage: "cable.connector")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Menu {
                        Button {
                            Task { await model.setInterfaceAction(.useMobileDefault, for: iface) }
                        } label: {
                            Label("直连本机默认网卡", systemImage: isRelay ? "" : "checkmark")
                        }
                        Button {
                            Task { await model.setInterfaceAction(.relayToPCInterface(routeOverride: nil), for: iface) }
                        } label: {
                            Label("经中继访问 PC 网卡", systemImage: isRelay ? "checkmark" : "")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(isRelay ? "经中继访问" : "本机直连")
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                        }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background((isRelay ? Color.purple : Color.teal).opacity(0.14), in: Capsule())
                        .foregroundStyle(isRelay ? .purple : .teal)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func delayColor(_ ms: Int) -> Color {
        if ms < 150 { return .green }
        if ms < 350 { return .orange }
        return .red
    }
}
