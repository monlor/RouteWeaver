import RoutingCore
import SwiftUI

private enum CatalogTab: String, CaseIterable, Identifiable {
    case monlorFull
    case acl4ssrPresets
    case acl4ssrAll
    case monlorAll

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monlorFull: return "monlor 全套 (full.ini)"
        case .acl4ssrPresets: return "ACL4SSR 推荐组"
        case .acl4ssrAll: return "全部 ACL4SSR (\(SubconverterCatalog.allRuleSets.count))"
        case .monlorAll: return "monlor 规则 (\(SubconverterCatalog.monlorRuleSets.count))"
        }
    }
}

struct SubconverterCatalogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var state: AppState
    let onAdded: (RuleGroup) -> Void

    @State private var tab: CatalogTab = .monlorFull
    @State private var mirror: SubconverterMirror = .monlorProxy
    @State private var selectedTarget: TargetReference = .reject
    @State private var query = ""

    private var filteredMonlorFull: [SubconverterRuleGroupPreset] {
        filterPresets(SubconverterCatalog.monlorFullPresets)
    }

    private var filteredACL4SSRPresets: [SubconverterRuleGroupPreset] {
        filterPresets(SubconverterCatalog.presets)
    }

    private var filteredACL4SSRAll: [SubconverterRuleSet] {
        filterRuleSets(SubconverterCatalog.allRuleSets)
    }

    private var filteredMonlorAll: [SubconverterRuleSet] {
        filterRuleSets(SubconverterCatalog.monlorRuleSets)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("在线规则库（monlor / ACL4SSR）").font(.headline)
                    Text("Mihomo 每 \(state.profile.ruleSetUpdateIntervalHours) 小时自动更新，包含 monlor/subconverter-rules 与全部 \(SubconverterCatalog.allRuleSets.count) 个 ACL4SSR 规则。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if tab == .monlorFull {
                    Button("一键导入 full.ini 全套") {
                        importBatch(SubconverterCatalog.monlorFullPresets, label: "monlor full.ini")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                } else if tab == .acl4ssrPresets {
                    Button("一键导入 ACL4SSR 推荐") {
                        importBatch(SubconverterCatalog.presets, label: "ACL4SSR")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
                Button("完成") { dismiss() }
            }

            Picker("", selection: $tab) {
                ForEach(CatalogTab.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 10) {
                TextField("搜索规则组或规则文件名…", text: $query)
                    .textFieldStyle(.roundedBorder)

                Picker("", selection: $mirror) {
                    ForEach(SubconverterMirror.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .labelsHidden()
                .frame(width: 145)

                Picker("", selection: $selectedTarget) {
                    ForEach(state.profile.targets) { t in
                        Text(t.name).tag(TargetReference.target(t.id))
                    }
                    Divider()
                    Text("拦截 (REJECT)").tag(TargetReference.reject)
                }
                .labelsHidden()
                .frame(width: 130)
            }

            switch tab {
            case .monlorFull:
                presetList(filteredMonlorFull)
            case .acl4ssrPresets:
                presetList(filteredACL4SSRPresets)
            case .acl4ssrAll:
                singleRuleSetList(filteredACL4SSRAll)
            case .monlorAll:
                singleRuleSetList(filteredMonlorAll)
            }
        }
        .padding(18)
        .frame(width: 680, height: 550)
        .onAppear {
            selectedTarget = state.profile.targets.first(where: { $0.mode == .proxy }).map { .target($0.id) }
                ?? state.profile.targets.first.map { .target($0.id) }
                ?? .reject
        }
    }

    private func presetList(_ presets: [SubconverterRuleGroupPreset]) -> some View {
        List(presets) { preset in
            HStack(spacing: 10) {
                Image(systemName: preset.icon)
                    .foregroundStyle(.blue)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name).font(.subheadline.weight(.medium))
                    Text("\(preset.subtitle) · \(preset.ruleSets.count) 个规则集")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("导入") {
                    let group = importPreset(preset)
                    state.showFeedback("已导入规则组「\(preset.name)」")
                    onAdded(group)
                }
                .controlSize(.small)
            }
            .padding(.vertical, 3)
        }
        .listStyle(.inset)
        .frame(minHeight: 340)
    }

    private func singleRuleSetList(_ ruleSets: [SubconverterRuleSet]) -> some View {
        List(ruleSets) { rs in
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rs.name).font(.subheadline.weight(.medium))
                    Text(rs.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("导入为规则组") {
                    let group = RuleGroup(
                        name: rs.name,
                        icon: "globe",
                        target: selectedTarget,
                        isEnabled: true,
                        rules: [
                            RuleItem(type: .ruleSet, value: rs.url(mirror: mirror), note: "\(rs.sourceLabel) · \(rs.name)")
                        ]
                    )
                    state.profile.ruleGroups.append(group)
                    state.showFeedback("已导入「\(rs.name)」为规则组")
                    onAdded(group)
                }
                .controlSize(.small)
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
        .frame(minHeight: 340)
    }

    private func filterPresets(_ items: [SubconverterRuleGroupPreset]) -> [SubconverterRuleGroupPreset] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.subtitle.localizedCaseInsensitiveContains(q)
        }
    }

    private func filterRuleSets(_ items: [SubconverterRuleSet]) -> [SubconverterRuleSet] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.path.localizedCaseInsensitiveContains(q)
        }
    }

    private func importPreset(_ preset: SubconverterRuleGroupPreset) -> RuleGroup {
        let directTarget = state.profile.targets.first(where: { $0.mode == .direct }).map { TargetReference.target($0.id) }
        let targetRef: TargetReference
        if preset.suggestReject {
            targetRef = .reject
        } else if (preset.suggestDirect || preset.id == "chinaDirect"), let directTarget {
            targetRef = directTarget
        } else {
            targetRef = selectedTarget
        }
        let group = RuleGroup(
            name: preset.name,
            icon: preset.icon,
            target: targetRef,
            isEnabled: true,
            rules: preset.makeRules(mirror: mirror)
        )
        state.profile.ruleGroups.append(group)
        return group
    }

    private func importBatch(_ presets: [SubconverterRuleGroupPreset], label: String) {
        var added = 0
        var lastCreated: RuleGroup?
        for preset in presets {
            if !state.profile.ruleGroups.contains(where: { $0.name == preset.name }) {
                lastCreated = importPreset(preset)
                added += 1
            }
        }
        if let lastCreated { onAdded(lastCreated) }
        state.showFeedback(added > 0 ? "已导入 \(added) 个 \(label) 规则组" : "所有 \(label) 规则组均已存在")
    }
}

