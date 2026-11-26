import RoutingCore
import SwiftUI

struct NetworkTargetsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var monitor: ConnectionMonitorService
    @State private var editingTarget: NetworkTarget?
    @State private var isCreatingNew = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerBar

                if state.activeHasPendingHotReload {
                    HStack(spacing: 10) {
                        InlineNote("网络目标已修改，点击「热重载生效」即可在不重启核心的情况下应用。")
                        Spacer()
                        Button("热重载生效") { state.hotReload() }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .disabled(state.isHotReloading || state.activeConfigValidationError != nil)
                    }
                } else if state.isCoreRunning {
                    InlineNote("核心运行中，支持直接编辑网络目标，修改后点击顶部「热重载生效」即可应用。")
                }

                if state.profile.targets.isEmpty {
                    SectionCard("尚无网络目标", icon: "point.topleft.down.to.point.bottomright.curvepath") {
                        InlineNote("点击右上角「新建网络目标」，自由组合 出口节点组 → (可选)链式代理节点组 → (可选)网卡，或创建纯网卡直连目标。")
                    }
                } else {
                    VStack(spacing: 12) {
                        ForEach(state.profile.targets) { target in
                            targetCard(target)
                        }
                    }
                }
            }
            .padding(20)
        }
        .onAppear {
            state.refreshInterfaces()
        }
        .sheet(item: $editingTarget) { draft in
            NetworkTargetEditorSheet(
                state: state,
                initial: draft,
                isNew: isCreatingNew
            ) { saved in
                if let idx = state.profile.targets.firstIndex(where: { $0.id == saved.id }) {
                    let previousName = state.profile.targets[idx].name
                    state.profile.targets[idx] = saved
                    if previousName != saved.name {
                        monitor.renameTrafficHistoryTarget(from: previousName, to: saved.name)
                    }
                } else {
                    state.profile.targets.append(saved)
                }
                state.showFeedback("已保存网络目标「\(saved.name)」")
            }
        }
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("自由组合出口节点组、链式代理与网卡，保存后供规则组直接选用。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                state.refreshInterfaces()
                state.showFeedback("已刷新网卡列表")
            } label: {
                Label("刷新网卡", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)

            Button {
                isCreatingNew = true
                editingTarget = NetworkTarget(
                    name: "",
                    mode: .proxy,
                    exitGroupID: state.profile.nodeGroups.first(where: { $0.kind == .exit })?.id,
                    relayGroupID: nil,
                    interfaceName: nil
                )
            } label: {
                Label("新建网络目标", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.hotReloadEditingLocked)
        }
    }

    private func targetCard(_ target: NetworkTarget) -> some View {
        let usedByGroups = state.profile.ruleGroups
            .filter { $0.target == .target(target.id) }
            .map(\.name)
        let referencedByAliases = state.profile.aliasReferrers(of: target.id).map(\.name)
        let isFallback = state.profile.fallbackTarget == .target(target.id)
        let preview = state.targetChainPreview(for: target)
        let resolvedLeaf = target.mode == .alias ? state.profile.resolvedLeafTarget(id: target.id) : nil
        let trafficTargetName = resolvedLeaf?.name ?? target.name
        let todayTraffic = monitor.trafficHistory.todayRecord(target: trafficTargetName)
        let weekTraffic = monitor.trafficHistory.totalBytes(lastNDays: 7, target: trafficTargetName)
        let weekTotal = weekTraffic.upload + weekTraffic.download
        let liveSpeed = monitor.tracker.liveSpeed(for: trafficTargetName)
        let selectableAliasTargets = target.mode == .alias
            ? state.profile.targets.filter { state.profile.canTarget(target.id, pointTo: $0.id) }
            : []

        let iconName: String = switch target.mode {
        case .direct: "cable.connector"
        case .proxy: "network"
        case .alias: "arrow.triangle.branch"
        }
        let pillColor: Color = switch target.mode {
        case .direct: .green
        case .proxy: .blue
        case .alias: .indigo
        }

        return SectionCard(
            target.name,
            icon: iconName
        ) {
            HStack(spacing: 8) {
                StatusPill(
                    target.mode.title,
                    color: pillColor
                )

                if target.mode == .alias {
                    Menu {
                        ForEach(selectableAliasTargets) { candidate in
                            Button {
                                state.setAliasTarget(id: target.id, targetID: candidate.id)
                            } label: {
                                if candidate.id == target.targetID {
                                    Label(candidate.name, systemImage: "checkmark")
                                } else {
                                    Text(candidate.name)
                                }
                            }
                        }
                    } label: {
                        Text("切换指向")
                    }
                    .menuStyle(.button)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(state.hotReloadEditingLocked || selectableAliasTargets.isEmpty)
                    .help("快速切换当前目标所指向的网络目标")
                }

                if target.mode == .proxy, target.relayGroupID != nil {
                    Button("移除链式") {
                        state.removeRelay(fromTargetID: target.id)
                    }
                    .controlSize(.small)
                    .disabled(state.hotReloadEditingLocked)
                    .help("一键移除链式代理，让出口节点组直接走所选网卡")
                }

                Button("编辑") {
                    isCreatingNew = false
                    editingTarget = target
                }
                .controlSize(.small)
                .disabled(state.hotReloadEditingLocked)

                Button(role: .destructive) {
                    state.deleteTarget(id: target.id)
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .disabled(state.hotReloadEditingLocked)
                .help("删除网络目标")
            }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                ChainFlowBadge(
                    steps: preview.steps,
                    isDirect: preview.isDirect,
                    aliasStepCount: preview.aliasStepCount
                )

                HStack(spacing: 8) {
                    if !usedByGroups.isEmpty {
                        Text("关联规则组：\(usedByGroups.joined(separator: "、"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !referencedByAliases.isEmpty {
                        Text("被目标指向：\(referencedByAliases.joined(separator: "、"))")
                            .font(.caption)
                            .foregroundStyle(.indigo)
                    }
                    if usedByGroups.isEmpty && referencedByAliases.isEmpty && !isFallback {
                        Text("暂未分配给规则组（已预配置）")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if isFallback {
                        StatusPill("默认兜底", color: .orange)
                    }
                }

                HStack(spacing: 12) {
                    Label {
                        HStack(spacing: 4) {
                            if let leaf = resolvedLeaf {
                                Text("[\(leaf.name)]")
                                    .foregroundStyle(.indigo)
                            }
                            Text("今日")
                                .foregroundStyle(.secondary)
                            Text(TrafficFormatter.bytes(todayTraffic.total))
                                .foregroundStyle(.primary)
                                .fontWeight(.medium)
                            if todayTraffic.total > 0 {
                                Text("(↑\(TrafficFormatter.shortBytes(todayTraffic.upload)) ↓\(TrafficFormatter.shortBytes(todayTraffic.download)))")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    } icon: {
                        Image(systemName: "chart.bar.fill")
                            .foregroundStyle(.teal)
                    }

                    Text("·")
                        .foregroundStyle(.quaternary)

                    HStack(spacing: 4) {
                        Text("近 7 天")
                            .foregroundStyle(.secondary)
                        Text(TrafficFormatter.bytes(weekTotal))
                            .foregroundStyle(.primary)
                            .fontWeight(.medium)
                    }

                    if state.isCoreRunning && liveSpeed.total > 0 {
                        Text("·")
                            .foregroundStyle(.quaternary)
                        HStack(spacing: 4) {
                            Text("↓ \(TrafficFormatter.shortSpeed(liveSpeed.download))")
                                .foregroundStyle(.green)
                            if liveSpeed.upload > 0 {
                                Text("↑ \(TrafficFormatter.shortSpeed(liveSpeed.upload))")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }

                    Spacer(minLength: 0)
                }
                .font(.system(.caption2, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
                )
            }
        }
    }
}

private struct NetworkTargetEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var state: AppState
    let isNew: Bool
    let onSave: (NetworkTarget) -> Void

    @State private var draft: NetworkTarget

    init(state: AppState, initial: NetworkTarget, isNew: Bool, onSave: @escaping (NetworkTarget) -> Void) {
        self.state = state
        self.isNew = isNew
        self.onSave = onSave
        _draft = State(initialValue: initial)
    }

    private var exitGroups: [NodeGroup] {
        let exits = state.profile.nodeGroups.filter { $0.kind == .exit }
        return exits.isEmpty ? state.profile.nodeGroups : exits
    }

    private var relayGroups: [NodeGroup] {
        let relays = state.profile.nodeGroups.filter { $0.kind == .relay }
        return relays.isEmpty ? state.profile.nodeGroups : relays
    }

    private var availableAliasTargets: [NetworkTarget] {
        state.profile.targets.filter { state.profile.canTarget(draft.id, pointTo: $0.id) }
    }

    private var canSave: Bool {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains(","), !name.contains("/") else { return false }
        switch draft.mode {
        case .proxy:
            return draft.exitGroupID != nil
        case .direct:
            return true
        case .alias:
            guard let targetID = draft.targetID else { return false }
            return state.profile.canTarget(draft.id, pointTo: targetID)
                && state.profile.target(id: targetID) != nil
        }
    }

    var body: some View {
        let preview = state.targetChainPreview(for: draft)
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "新建网络目标" : "编辑网络目标")
                .font(.headline)

            FormRow("目标名称", labelWidth: 108) {
                TextField("例如 新加坡节点、香港、USB 网卡", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            FormRow("目标类型", labelWidth: 108) {
                Picker("", selection: $draft.mode) {
                    ForEach(NetworkTargetMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if draft.mode == .alias {
                FormRow("指向网络目标", labelWidth: 108) {
                    Picker("", selection: $draft.targetID) {
                        Text("请选择要指向的网络目标").tag(UUID?.none)
                        ForEach(availableAliasTargets) { candidate in
                            Text("\(candidate.name)（\(candidate.mode.title)）").tag(UUID?.some(candidate.id))
                        }
                    }
                    .labelsHidden()
                }

                if availableAliasTargets.isEmpty {
                    InlineNote("当前没有可指向的其他网络目标，请先创建代理出口或网卡直连目标。")
                } else {
                    InlineNote("指向目标本身不重复配置节点或网卡，所有关联此目标的规则组会自动走所指向的目标，方便在多个节点间一键切换。")
                }
            } else {
                if draft.mode == .proxy {
                    FormRow("出口节点组", labelWidth: 108) {
                        Picker("", selection: $draft.exitGroupID) {
                            Text("请选择出口节点组").tag(UUID?.none)
                            ForEach(exitGroups) { group in
                                Text(group.name).tag(UUID?.some(group.id))
                            }
                        }
                        .labelsHidden()
                    }

                    FormRow("链式代理（可选）", labelWidth: 108) {
                        Picker("", selection: $draft.relayGroupID) {
                            Text("无（不使用链式代理）").tag(UUID?.none)
                            ForEach(relayGroups) { group in
                                Text(group.name).tag(UUID?.some(group.id))
                            }
                        }
                        .labelsHidden()
                    }
                }

                FormRow("出口网卡（可选）", labelWidth: 108) {
                    HStack(spacing: 6) {
                        Picker("", selection: Binding(
                            get: { draft.normalizedInterface ?? "" },
                            set: { draft.interfaceName = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("系统默认（不绑定网卡）").tag("")
                            ForEach(state.activeInterfaces) { info in
                                Text(info.pickerLabel).tag(info.bsdName)
                            }
                            if let current = draft.normalizedInterface,
                               !state.activeInterfaces.contains(where: { $0.bsdName == current }) {
                                Text("\(current)（当前未检测到）").tag(current)
                            }
                        }
                        .labelsHidden()

                        Button {
                            state.refreshInterfaces()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("刷新网卡列表")
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("链路预览").font(.caption).foregroundStyle(.secondary)
                ChainFlowBadge(
                    steps: preview.steps,
                    isDirect: preview.isDirect,
                    aliasStepCount: preview.aliasStepCount
                )
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    switch draft.mode {
                    case .direct:
                        draft.exitGroupID = nil
                        draft.relayGroupID = nil
                        draft.targetID = nil
                    case .proxy:
                        draft.targetID = nil
                    case .alias:
                        draft.exitGroupID = nil
                        draft.relayGroupID = nil
                        draft.interfaceName = nil
                    }
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            state.refreshInterfaces()
        }
    }
}
