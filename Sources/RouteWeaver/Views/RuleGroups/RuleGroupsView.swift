import AppKit
import RoutingCore
import SwiftUI
import UniformTypeIdentifiers

struct RuleGroupsView: View {
    @ObservedObject var state: AppState
    @State private var selectedGroupIDs = Set<UUID>()
    @State private var batchTarget: TargetReference = .reject
    @State private var newGroupName = ""
    @State private var showNewGroupSheet = false

    @State private var newRuleType: RuleType = .domainSuffix
    @State private var newRuleValue = ""
    @State private var newRuleSetFormat: RuleSetFormat = .auto
    @State private var newRuleSetBehavior: RuleSetBehavior = .auto
    @State private var newRuleSetNoResolve = false
    @State private var showRuleSetAdvanced = false
    @State private var editingRuleSetID: UUID?
    @State private var showAppPicker = false
    @State private var showProcessPicker = false
    @State private var showSubconverterCatalog = false
    @State private var showRuleSetPicker = false

    private var selectedGroupIndex: Int? {
        guard selectedGroupIDs.count == 1, let id = selectedGroupIDs.first else {
            return selectedGroupIDs.isEmpty ? state.profile.ruleGroups.indices.first : nil
        }
        return state.profile.ruleGroups.firstIndex { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 0) {
            leftGroupList
                .frame(width: 280)
            Divider()
            rightRuleDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selectedGroupIDs.isEmpty, let first = state.profile.ruleGroups.first?.id {
                selectedGroupIDs = [first]
            }
        }
        .sheet(isPresented: $showNewGroupSheet) {
            newRuleGroupSheet
        }
        .sheet(isPresented: $showAppPicker) {
            if let idx = selectedGroupIndex {
                AppPickerSheet { app in
                    addRule(to: idx, type: .processName, value: app.executableName, note: app.name)
                }
            }
        }
        .sheet(isPresented: $showProcessPicker) {
            if let idx = selectedGroupIndex {
                ProcessPickerSheet { proc in
                    addRule(to: idx, type: .processName, value: proc.name)
                }
            }
        }
        .sheet(isPresented: $showSubconverterCatalog) {
            SubconverterCatalogSheet(state: state) { created in
                selectedGroupIDs = [created.id]
            }
        }
        .sheet(isPresented: $showRuleSetPicker) {
            if let idx = selectedGroupIndex {
                RuleSetPickerSheet { ruleSet, mirror in
                    addRule(
                        to: idx,
                        type: .ruleSet,
                        value: ruleSet.url(mirror: mirror),
                        note: "\(ruleSet.sourceLabel) · \(ruleSet.name)",
                        ruleSetFormat: ruleSet.format,
                        ruleSetBehavior: ruleSet.behavior,
                        ruleSetNoResolve: ruleSet.noResolve ? true : nil
                    )
                }
            }
        }
    }

    private var leftGroupList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("规则组（拖拽排序）")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .help("拖动规则组调整匹配优先级；按住 ⌘ 或 ⇧ 可多选")
                Spacer()
                if selectedGroupIDs.count > 1 {
                    Button(role: .destructive) {
                        deleteGroups(ids: selectedGroupIDs)
                    } label: {
                        Label("删除(\(selectedGroupIDs.count))", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .disabled(state.hotReloadEditingLocked)
                    .help("批量删除已选中的 \(selectedGroupIDs.count) 个规则组")
                }

                Button {
                    showSubconverterCatalog = true
                } label: {
                    Label("规则库", systemImage: "books.vertical")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(state.hotReloadEditingLocked)
                .help("从 Subconverter / ACL4SSR / monlor 规则库导入规则组")

                Button {
                    newGroupName = ""
                    showNewGroupSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(state.hotReloadEditingLocked)
                .help("新建空白规则组")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            List(selection: $selectedGroupIDs) {
                ForEach($state.profile.ruleGroups) { $group in
                    let index = state.profile.ruleGroups.firstIndex(where: { $0.id == group.id })
                    let lastIndex = max(0, state.profile.ruleGroups.count - 1)

                    HStack(spacing: 8) {
                        if !state.hotReloadEditingLocked {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.quaternary)
                                .help("拖动调整优先级")
                        }

                        Toggle("", isOn: $group.isEnabled)
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .disabled(state.hotReloadEditingLocked)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(group.isEnabled ? .primary : .secondary)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text("→ \(state.profile.targetTitle(for: group.target))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(group.rules.count)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(group.id)
                    .contextMenu {
                        if selectedGroupIDs.count > 1 && selectedGroupIDs.contains(group.id) {
                            Button("移到最顶 (\(selectedGroupIDs.count))") {
                                moveSelectedGroupsToEdge(top: true)
                            }
                            .disabled(state.hotReloadEditingLocked)
                            Button("移到最底 (\(selectedGroupIDs.count))") {
                                moveSelectedGroupsToEdge(top: false)
                            }
                            .disabled(state.hotReloadEditingLocked)
                            Divider()
                            Button("批量启用 (\(selectedGroupIDs.count))") {
                                setEnabled(true, for: selectedGroupIDs)
                            }
                            .disabled(state.hotReloadEditingLocked)
                            Button("批量停用 (\(selectedGroupIDs.count))") {
                                setEnabled(false, for: selectedGroupIDs)
                            }
                            .disabled(state.hotReloadEditingLocked)
                            Divider()
                            Button("批量删除已选 (\(selectedGroupIDs.count))", role: .destructive) {
                                deleteGroups(ids: selectedGroupIDs)
                            }
                            .disabled(state.hotReloadEditingLocked)
                        } else if let index {
                            Button("移到最顶") { moveGroupToEdge(index, top: true) }
                                .disabled(state.hotReloadEditingLocked || index == 0)
                            Button("上移") { moveGroup(index, offset: -1) }
                                .disabled(state.hotReloadEditingLocked || index == 0)
                            Button("下移") { moveGroup(index, offset: 1) }
                                .disabled(state.hotReloadEditingLocked || index == lastIndex)
                            Button("移到最底") { moveGroupToEdge(index, top: false) }
                                .disabled(state.hotReloadEditingLocked || index == lastIndex)
                            Divider()
                            Button("全选所有规则组") {
                                selectedGroupIDs = Set(state.profile.ruleGroups.map(\.id))
                            }
                            Divider()
                            Button("删除规则组", role: .destructive) { deleteGroups(ids: [group.id]) }
                                .disabled(state.hotReloadEditingLocked)
                        }
                    }
                }
                .onMove(perform: state.hotReloadEditingLocked ? nil : moveGroups)
            }
            .listStyle(.inset)
            .onDeleteCommand {
                guard !state.hotReloadEditingLocked, !selectedGroupIDs.isEmpty else { return }
                deleteGroups(ids: selectedGroupIDs)
            }

            Divider()

            // Fallback (MATCH) target selector
            VStack(alignment: .leading, spacing: 6) {
                Text("未命中时的默认兜底目标 (MATCH)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                targetPicker(selection: $state.profile.fallbackTarget)
                    .disabled(state.hotReloadEditingLocked)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    @ViewBuilder
    private var rightRuleDetail: some View {
        if selectedGroupIDs.count > 1 {
            multiSelectDetailView
        } else if let idx = selectedGroupIndex {
            let group = state.profile.ruleGroups[idx]
            let groupID = group.id
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if state.hotReloadEditingLocked {
                        InlineNote("核心运行中，停止核心后可修改规则组和规则。")
                    }

                    // Group Settings Card
                    SectionCard("规则组设置", icon: group.icon) {
                        HStack(spacing: 6) {
                            Button {
                                moveGroupToEdge(idx, top: true)
                            } label: {
                                Image(systemName: "arrow.up.to.line")
                            }
                            .controlSize(.small)
                            .disabled(state.hotReloadEditingLocked || idx == 0)
                            .help("移到最顶（最高匹配优先级）")

                            Button {
                                moveGroup(idx, offset: -1)
                            } label: {
                                Image(systemName: "arrow.up")
                            }
                            .controlSize(.small)
                            .disabled(state.hotReloadEditingLocked || idx == 0)
                            .help("上移一位")

                            Button {
                                moveGroup(idx, offset: 1)
                            } label: {
                                Image(systemName: "arrow.down")
                            }
                            .controlSize(.small)
                            .disabled(state.hotReloadEditingLocked || idx == state.profile.ruleGroups.count - 1)
                            .help("下移一位")

                            Button {
                                moveGroupToEdge(idx, top: false)
                            } label: {
                                Image(systemName: "arrow.down.to.line")
                            }
                            .controlSize(.small)
                            .disabled(state.hotReloadEditingLocked || idx == state.profile.ruleGroups.count - 1)
                            .help("移到最底（最低匹配优先级）")

                            Button(role: .destructive) {
                                deleteGroups(ids: [group.id])
                            } label: {
                                Image(systemName: "trash")
                            }
                            .controlSize(.small)
                            .disabled(state.hotReloadEditingLocked)
                            .help("删除此规则组")
                        }
                    } content: {
                        VStack(alignment: .leading, spacing: 10) {
                            FormRow("规则组名称", labelWidth: 96) {
                                TextField(
                                    "例如 AI 服务",
                                    text: Binding(
                                        get: { state.profile.ruleGroups.first { $0.id == groupID }?.name ?? "" },
                                        set: { newValue in
                                            guard let gIdx = state.profile.ruleGroups.firstIndex(where: { $0.id == groupID }) else { return }
                                            state.profile.ruleGroups[gIdx].name = newValue
                                        }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                                .disabled(state.hotReloadEditingLocked)
                            }

                            FormRow("指向网络目标", labelWidth: 96) {
                                HStack(spacing: 10) {
                                    targetPicker(
                                        selection: Binding(
                                            get: { state.profile.ruleGroups.first { $0.id == groupID }?.target ?? .reject },
                                            set: { newValue in
                                                guard let gIdx = state.profile.ruleGroups.firstIndex(where: { $0.id == groupID }) else { return }
                                                state.profile.ruleGroups[gIdx].target = newValue
                                            }
                                        )
                                    )
                                    .frame(maxWidth: 220)
                                    .disabled(state.hotReloadEditingLocked)

                                    if case .target(let tid) = group.target,
                                       let target = state.profile.target(id: tid) {
                                        ChainFlowBadge(
                                            steps: state.targetSummaryChain(for: target),
                                            isDirect: target.mode == .direct
                                        )
                                    } else if group.target == .reject {
                                        StatusPill("直接拦截", systemImage: "hand.raised", color: .red)
                                    }
                                }
                            }
                        }
                    }

                    // Add Rules Card (App / Process / Custom)
                    SectionCard("添加规则", icon: "plus.circle") {
                        HStack(spacing: 8) {
                            Button {
                                showRuleSetPicker = true
                            } label: {
                                Label("ACL4SSR 规则集", systemImage: "books.vertical")
                            }
                            .controlSize(.small)
                            .disabled(state.hotReloadEditingLocked)

                            Button {
                                showAppPicker = true
                            } label: {
                                Label("选择 App", systemImage: "app.badge")
                            }
                            .controlSize(.small)
                            .disabled(state.hotReloadEditingLocked)

                            Button {
                                showProcessPicker = true
                            } label: {
                                Label("选择进程", systemImage: "cpu")
                            }
                            .controlSize(.small)
                            .disabled(state.hotReloadEditingLocked)

                            Button {
                                pickAppBundleFromDisk(into: idx)
                            } label: {
                                Label("浏览 .app…", systemImage: "folder")
                            }
                            .controlSize(.small)
                            .disabled(state.hotReloadEditingLocked)
                        }
                    } content: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Picker("", selection: $newRuleType) {
                                    ForEach(RuleType.allCases) { type in
                                        Text(type.title).tag(type)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 210)
                                .disabled(state.hotReloadEditingLocked)

                                TextField(newRuleType.placeholder, text: $newRuleValue)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(state.hotReloadEditingLocked)
                                    .onSubmit { addCustomRule(to: idx) }

                                Button("添加") { addCustomRule(to: idx) }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(
                                        state.hotReloadEditingLocked
                                            || newRuleValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                            || (newRuleType == .ruleSet && newRuleSetValidationError != nil)
                                    )
                            }

                            if newRuleType == .ruleSet {
                                DisclosureGroup("高级设置（格式 / 行为 / no-resolve）", isExpanded: $showRuleSetAdvanced) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack(spacing: 12) {
                                            Text("格式")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Picker("", selection: $newRuleSetFormat) {
                                                ForEach(RuleSetFormat.allCases) { fmt in
                                                    Text(fmt.title).tag(fmt)
                                                }
                                            }
                                            .labelsHidden()
                                            .frame(width: 185)
                                            .disabled(state.hotReloadEditingLocked)

                                            Text("行为")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Picker("", selection: $newRuleSetBehavior) {
                                                ForEach(RuleSetBehavior.allCases) { beh in
                                                    Text(beh.title).tag(beh)
                                                }
                                            }
                                            .labelsHidden()
                                            .frame(width: 185)
                                            .disabled(state.hotReloadEditingLocked)
                                        }

                                        Toggle("跳过 DNS 解析 (no-resolve，适用于前置 IP 规则集)", isOn: $newRuleSetNoResolve)
                                            .font(.caption)
                                            .disabled(state.hotReloadEditingLocked)
                                    }
                                    .padding(.top, 6)
                                }
                                .font(.caption.weight(.medium))

                                if let err = newRuleSetValidationError {
                                    InlineValidationMessage(err, isError: true)
                                } else if let hint = newRuleSetAmbiguityHint {
                                    InlineValidationMessage(hint, isError: false)
                                }
                            }
                        }
                    }

                    // Rules List Card
                    SectionCard("组内规则 (\(group.rules.count))", icon: "list.bullet") {
                        if group.rules.isEmpty {
                            InlineNote("此规则组暂无规则。点击上方「选择 App」「选择进程」或添加自定义规则。")
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(group.rules.enumerated()), id: \.element.id) { rIdx, rule in
                                    let ruleID = rule.id
                                    HStack(spacing: 10) {
                                        Toggle("", isOn: Binding(
                                            get: {
                                                state.profile.ruleGroups
                                                    .first { $0.id == groupID }?
                                                    .rules.first { $0.id == ruleID }?
                                                    .isEnabled ?? false
                                            },
                                            set: { newValue in
                                                guard let gIdx = state.profile.ruleGroups.firstIndex(where: { $0.id == groupID }),
                                                      let itemIdx = state.profile.ruleGroups[gIdx].rules.firstIndex(where: { $0.id == ruleID }) else {
                                                    return
                                                }
                                                state.profile.ruleGroups[gIdx].rules[itemIdx].isEnabled = newValue
                                            }
                                        ))
                                        .labelsHidden()
                                        .toggleStyle(.checkbox)
                                        .disabled(state.hotReloadEditingLocked)

                                        StatusPill(
                                            rule.type.shortLabel,
                                            color: rule.type == .ruleSet ? .teal : (rule.type.isProcessRule ? .purple : .blue)
                                        )
                                        .frame(width: 82, alignment: .leading)

                                        Text(rule.value)
                                            .font(.system(.callout, design: .monospaced))
                                            .foregroundStyle(rule.isEnabled ? .primary : .secondary)
                                            .lineLimit(1)
                                            .textSelection(.enabled)

                                        if !rule.note.isEmpty && rule.note != rule.value {
                                            Text(rule.note)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        if rule.type == .ruleSet {
                                            let resolved = try? RuleSetResolver.resolve(
                                                url: rule.value,
                                                format: rule.ruleSetFormat,
                                                behavior: rule.ruleSetBehavior
                                            )
                                            let badgeText: String = {
                                                if let r = resolved {
                                                    let nr = (rule.ruleSetNoResolve == true) ? " · no-resolve" : ""
                                                    return "\(r.format) · \(r.behavior)\(nr)"
                                                }
                                                return "格式冲突"
                                            }()
                                            Button {
                                                editingRuleSetID = rule.id
                                            } label: {
                                                StatusPill(
                                                    badgeText,
                                                    color: resolved == nil ? .red : (resolved?.isAmbiguous == true ? .orange : .secondary)
                                                )
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(state.hotReloadEditingLocked)
                                            .help(resolved?.hint ?? "点击修改规则集格式 / 行为 / no-resolve")
                                            .popover(
                                                isPresented: Binding(
                                                    get: { editingRuleSetID == ruleID },
                                                    set: { if !$0 { editingRuleSetID = nil } }
                                                )
                                            ) {
                                                ruleSetMetadataPopover(groupID: groupID, ruleID: ruleID)
                                            }
                                        }

                                        Spacer()

                                        Button(role: .destructive) {
                                            guard let gIdx = state.profile.ruleGroups.firstIndex(where: { $0.id == groupID }) else { return }
                                            state.profile.ruleGroups[gIdx].rules.removeAll { $0.id == ruleID }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.tertiary)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(state.hotReloadEditingLocked)
                                    }
                                    .padding(.vertical, 6)
                                    if rIdx < group.rules.count - 1 {
                                        Divider()
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        } else {
            VStack(spacing: 12) {
                Text("暂无规则组")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Button("新建规则组") {
                    newGroupName = ""
                    showNewGroupSheet = true
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var multiSelectDetailView: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionCard("已选中 \(selectedGroupIDs.count) 个规则组", icon: "checklist") {
                Button("取消多选") {
                    if let first = selectedGroupIDs.first {
                        selectedGroupIDs = [first]
                    }
                }
                .controlSize(.small)
            } content: {
                VStack(alignment: .leading, spacing: 14) {
                    FormRow("批量指向网络目标", labelWidth: 120) {
                        HStack(spacing: 8) {
                            targetPicker(selection: $batchTarget)
                                .frame(maxWidth: 220)
                                .disabled(state.hotReloadEditingLocked)
                            Button("应用到已选") {
                                for idx in state.profile.ruleGroups.indices where selectedGroupIDs.contains(state.profile.ruleGroups[idx].id) {
                                    state.profile.ruleGroups[idx].target = batchTarget
                                }
                                state.showFeedback("已更新 \(selectedGroupIDs.count) 个规则组的网络目标")
                            }
                            .disabled(state.hotReloadEditingLocked)
                        }
                    }

                    HStack(spacing: 10) {
                        Button("批量启用") { setEnabled(true, for: selectedGroupIDs) }
                            .disabled(state.hotReloadEditingLocked)
                        Button("批量停用") { setEnabled(false, for: selectedGroupIDs) }
                            .disabled(state.hotReloadEditingLocked)
                        Spacer()
                        Button(role: .destructive) {
                            deleteGroups(ids: selectedGroupIDs)
                        } label: {
                            Label("批量删除 (\(selectedGroupIDs.count))", systemImage: "trash")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(state.hotReloadEditingLocked)
                    }
                }
            }
            Spacer()
        }
        .padding(20)
        .onAppear {
            batchTarget = state.profile.targets.first.map { .target($0.id) } ?? .reject
        }
    }

    private func targetPicker(selection: Binding<TargetReference>) -> some View {
        Picker("", selection: selection) {
            ForEach(state.profile.targets) { target in
                Text(target.name).tag(TargetReference.target(target.id))
            }
            Divider()
            Text("拦截 (REJECT)").tag(TargetReference.reject)
        }
        .labelsHidden()
    }

    private var newRuleGroupSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建规则组").font(.headline)
            TextField("规则组名称（例如：AI 服务、工作应用）", text: $newGroupName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { showNewGroupSheet = false }
                Button("创建") {
                    let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    let defaultTarget: TargetReference = state.profile.targets.first.map { .target($0.id) } ?? .reject
                    let created = RuleGroup(name: name, target: defaultTarget, isEnabled: true, rules: [])
                    state.profile.ruleGroups.insert(created, at: 0)
                    selectedGroupIDs = [created.id]
                    showNewGroupSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private var newRuleSetValidationError: String? {
        let trimmed = newRuleValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            _ = try RuleSetResolver.resolve(url: trimmed, format: newRuleSetFormat, behavior: newRuleSetBehavior)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var newRuleSetAmbiguityHint: String? {
        let trimmed = newRuleValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (try? RuleSetResolver.resolve(url: trimmed, format: newRuleSetFormat, behavior: newRuleSetBehavior))?.hint
    }

    @ViewBuilder
    private func ruleSetMetadataPopover(groupID: UUID, ruleID: UUID) -> some View {
        if let gIdx = state.profile.ruleGroups.firstIndex(where: { $0.id == groupID }),
           let rIdx = state.profile.ruleGroups[gIdx].rules.firstIndex(where: { $0.id == ruleID }) {
            let rule = state.profile.ruleGroups[gIdx].rules[rIdx]
            let formatBinding = Binding<RuleSetFormat>(
                get: {
                    state.profile.ruleGroups.first { $0.id == groupID }?
                        .rules.first { $0.id == ruleID }?
                        .ruleSetFormat ?? .auto
                },
                set: { newValue in
                    guard let gi = state.profile.ruleGroups.firstIndex(where: { $0.id == groupID }),
                          let ri = state.profile.ruleGroups[gi].rules.firstIndex(where: { $0.id == ruleID }) else { return }
                    state.profile.ruleGroups[gi].rules[ri].ruleSetFormat = (newValue == .auto ? nil : newValue)
                }
            )
            let behaviorBinding = Binding<RuleSetBehavior>(
                get: {
                    state.profile.ruleGroups.first { $0.id == groupID }?
                        .rules.first { $0.id == ruleID }?
                        .ruleSetBehavior ?? .auto
                },
                set: { newValue in
                    guard let gi = state.profile.ruleGroups.firstIndex(where: { $0.id == groupID }),
                          let ri = state.profile.ruleGroups[gi].rules.firstIndex(where: { $0.id == ruleID }) else { return }
                    state.profile.ruleGroups[gi].rules[ri].ruleSetBehavior = (newValue == .auto ? nil : newValue)
                }
            )
            let noResolveBinding = Binding<Bool>(
                get: {
                    state.profile.ruleGroups.first { $0.id == groupID }?
                        .rules.first { $0.id == ruleID }?
                        .ruleSetNoResolve ?? false
                },
                set: { newValue in
                    guard let gi = state.profile.ruleGroups.firstIndex(where: { $0.id == groupID }),
                          let ri = state.profile.ruleGroups[gi].rules.firstIndex(where: { $0.id == ruleID }) else { return }
                    state.profile.ruleGroups[gi].rules[ri].ruleSetNoResolve = (newValue ? true : nil)
                }
            )
            let resolutionResult: Result<ResolvedRuleSetMetadata, Error> = Result {
                try RuleSetResolver.resolve(url: rule.value, format: rule.ruleSetFormat, behavior: rule.ruleSetBehavior)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("规则集高级设置").font(.headline)
                FormRow("格式 (format)", labelWidth: 96) {
                    Picker("", selection: formatBinding) {
                        ForEach(RuleSetFormat.allCases) { fmt in
                            Text(fmt.title).tag(fmt)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
                FormRow("行为 (behavior)", labelWidth: 96) {
                    Picker("", selection: behaviorBinding) {
                        ForEach(RuleSetBehavior.allCases) { beh in
                            Text(beh.title).tag(beh)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
                Toggle("跳过 DNS 解析 (no-resolve)", isOn: noResolveBinding)
                    .font(.caption)

                switch resolutionResult {
                case .failure(let error):
                    InlineValidationMessage(error.localizedDescription, isError: true)
                case .success(let meta):
                    if let hint = meta.hint {
                        InlineValidationMessage(hint, isError: false)
                    }
                }
            }
            .padding(14)
            .frame(width: 330)
        }
    }

    private func addCustomRule(to groupIndex: Int) {
        let value = newRuleValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if newRuleType == .ruleSet {
            addRule(
                to: groupIndex,
                type: .ruleSet,
                value: value,
                ruleSetFormat: newRuleSetFormat == .auto ? nil : newRuleSetFormat,
                ruleSetBehavior: newRuleSetBehavior == .auto ? nil : newRuleSetBehavior,
                ruleSetNoResolve: newRuleSetNoResolve ? true : nil
            )
            newRuleSetFormat = .auto
            newRuleSetBehavior = .auto
            newRuleSetNoResolve = false
        } else {
            addRule(to: groupIndex, type: newRuleType, value: value)
        }
        newRuleValue = ""
    }

    private func addRule(
        to groupIndex: Int,
        type: RuleType,
        value: String,
        note: String = "",
        ruleSetFormat: RuleSetFormat? = nil,
        ruleSetBehavior: RuleSetBehavior? = nil,
        ruleSetNoResolve: Bool? = nil
    ) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let exists = state.profile.ruleGroups[groupIndex].rules.contains {
            $0.type == type && $0.value.caseInsensitiveCompare(clean) == .orderedSame
        }
        if !exists {
            state.profile.ruleGroups[groupIndex].rules.insert(
                RuleItem(
                    type: type,
                    value: clean,
                    note: note,
                    ruleSetFormat: ruleSetFormat,
                    ruleSetBehavior: ruleSetBehavior,
                    ruleSetNoResolve: ruleSetNoResolve
                ),
                at: 0
            )
            state.showFeedback("已添加规则 \(type.shortLabel): \(clean)")
        } else {
            state.showFeedback("规则已存在：\(clean)")
        }
    }

    private func pickAppBundleFromDisk(into groupIndex: Int) {
        let panel = NSOpenPanel()
        panel.title = "选择应用程序 (.app)"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                if let exec = SystemInspector.executableName(forAppBundle: url) {
                    let appName = url.deletingPathExtension().lastPathComponent
                    addRule(to: groupIndex, type: .processName, value: exec, note: appName)
                }
            }
        }
    }

    private func moveGroups(from source: IndexSet, to destination: Int) {
        guard !state.hotReloadEditingLocked else { return }
        state.profile.ruleGroups.move(fromOffsets: source, toOffset: destination)
        state.showFeedback("已调整规则组顺序")
    }

    private func moveGroup(_ index: Int, offset: Int) {
        let dest = index + offset
        guard state.profile.ruleGroups.indices.contains(index),
              state.profile.ruleGroups.indices.contains(dest) else { return }
        state.profile.ruleGroups.swapAt(index, dest)
    }

    private func moveGroupToEdge(_ index: Int, top: Bool) {
        guard state.profile.ruleGroups.indices.contains(index) else { return }
        let item = state.profile.ruleGroups.remove(at: index)
        if top {
            state.profile.ruleGroups.insert(item, at: 0)
        } else {
            state.profile.ruleGroups.append(item)
        }
        state.showFeedback(top ? "已移到最顶" : "已移到最底")
    }

    private func moveSelectedGroupsToEdge(top: Bool) {
        let selected = state.profile.ruleGroups.filter { selectedGroupIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        let remaining = state.profile.ruleGroups.filter { !selectedGroupIDs.contains($0.id) }
        state.profile.ruleGroups = top ? (selected + remaining) : (remaining + selected)
        state.showFeedback("已将 \(selected.count) 个规则组移到\(top ? "最顶" : "最底")")
    }

    private func setEnabled(_ enabled: Bool, for ids: Set<UUID>) {
        for idx in state.profile.ruleGroups.indices where ids.contains(state.profile.ruleGroups[idx].id) {
            state.profile.ruleGroups[idx].isEnabled = enabled
        }
        state.showFeedback("已\(enabled ? "启用" : "停用") \(ids.count) 个规则组")
    }

    private func deleteGroups(ids: Set<UUID>) {
        let count = state.profile.ruleGroups.filter { ids.contains($0.id) }.count
        guard count > 0 else { return }
        state.profile.ruleGroups.removeAll { ids.contains($0.id) }
        selectedGroupIDs.subtract(ids)
        if selectedGroupIDs.isEmpty, let first = state.profile.ruleGroups.first?.id {
            selectedGroupIDs = [first]
        }
        state.showFeedback("已删除 \(count) 个规则组")
    }
}

