import RoutingCore
import SwiftUI

struct NetworkTargetsView: View {
    @ObservedObject var state: AppState
    @State private var editingTarget: NetworkTarget?
    @State private var isCreatingNew = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerBar

                if state.hasPendingHotReload {
                    HStack(spacing: 10) {
                        InlineNote("网络目标已修改，点击「热重载生效」即可在不重启核心的情况下应用。")
                        Spacer()
                        Button("热重载生效") { state.hotReload() }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .disabled(state.isHotReloading || state.configValidationError != nil)
                    }
                } else if state.engine.isRunning {
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
                    state.profile.targets[idx] = saved
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
        let isFallback = state.profile.fallbackTarget == .target(target.id)

        return SectionCard(
            target.name,
            icon: target.mode == .direct ? "cable.connector" : "network"
        ) {
            HStack(spacing: 8) {
                StatusPill(
                    target.mode.title,
                    color: target.mode == .direct ? .green : .blue
                )

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
                    steps: state.targetSummaryChain(for: target),
                    isDirect: target.mode == .direct
                )

                HStack(spacing: 8) {
                    if !usedByGroups.isEmpty {
                        Text("关联规则组：\(usedByGroups.joined(separator: "、"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !isFallback {
                        Text("暂未分配给规则组（已预配置）")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if isFallback {
                        StatusPill("默认兜底", color: .orange)
                    }
                }
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

    private var canSave: Bool {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains(","), !name.contains("/") else { return false }
        if draft.mode == .proxy {
            return draft.exitGroupID != nil
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "新建网络目标" : "编辑网络目标")
                .font(.headline)

            FormRow("目标名称", labelWidth: 108) {
                TextField("例如 香港、美国、USB 网卡", text: $draft.name)
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
                        ForEach(state.interfaces) { info in
                            Text(info.pickerLabel).tag(info.bsdName)
                        }
                        if let current = draft.normalizedInterface,
                           !state.interfaces.contains(where: { $0.bsdName == current }) {
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

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("链路预览").font(.caption).foregroundStyle(.secondary)
                ChainFlowBadge(
                    steps: state.targetSummaryChain(for: draft),
                    isDirect: draft.mode == .direct
                )
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if draft.mode == .direct {
                        draft.exitGroupID = nil
                        draft.relayGroupID = nil
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
