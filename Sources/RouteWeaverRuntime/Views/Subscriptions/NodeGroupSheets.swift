import RoutingCore
import SwiftUI

struct NodeGroupEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var state: AppState
    @ObservedObject var subscriptionStore: SubscriptionStore
    let subscriptions: [ProxySubscription]
    let isNew: Bool
    let onSave: (NodeGroup) -> Void

    @State private var draft: NodeGroup

    init(
        state: AppState,
        subscriptionStore: SubscriptionStore,
        subscriptions: [ProxySubscription],
        initial: NodeGroup,
        isNew: Bool,
        onSave: @escaping (NodeGroup) -> Void
    ) {
        self.state = state
        self.subscriptionStore = subscriptionStore
        self.subscriptions = subscriptions
        self.isNew = isNew
        self.onSave = onSave
        _draft = State(initialValue: initial)
    }

    private var regexValid: Bool {
        let p = draft.filterPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty || (try? NSRegularExpression(pattern: p)) != nil
    }

    private var excludeRegexValid: Bool {
        let p = draft.excludeFilterPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty || (try? NSRegularExpression(pattern: p)) != nil
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && regexValid && excludeRegexValid
    }

    private var liveMatchedNodes: [SubscriptionNode]? {
        guard regexValid, excludeRegexValid, let subID = draft.subscriptionID, let entry = subscriptionStore.cache[subID] else {
            return nil
        }
        return SubscriptionParser.matchingNodes(
            entry.nodes,
            pattern: draft.filterPattern,
            excludePattern: draft.excludeFilterPattern
        )
    }

    private var liveExcludedCount: Int {
        guard regexValid, excludeRegexValid,
              !draft.excludeFilterPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let subID = draft.subscriptionID,
              let entry = subscriptionStore.cache[subID],
              let matched = liveMatchedNodes else {
            return 0
        }
        let beforeExclude = SubscriptionParser.matchingNodes(entry.nodes, pattern: draft.filterPattern)
        return max(0, beforeExclude.count - matched.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "新建节点组" : "编辑节点组").font(.headline)

            FormRow("节点组名称", labelWidth: 96) {
                TextField("例如 香港出口、美国链式", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            FormRow("节点组类型", labelWidth: 96) {
                Picker("", selection: $draft.kind) {
                    ForEach(NodeGroupKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            FormRow("来源订阅", labelWidth: 96) {
                Picker("", selection: $draft.subscriptionID) {
                    Text("暂不绑定").tag(UUID?.none)
                    ForEach(subscriptions) { sub in
                        Text(sub.name).tag(UUID?.some(sub.id))
                    }
                }
                .labelsHidden()
            }

            FormRow("匹配正则", labelWidth: 96) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("留空匹配全部节点，例如 (?i)(香港|HK)", text: $draft.filterPattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(RegexPreset.common) { preset in
                            Button(preset.title) {
                                draft.filterPattern = preset.pattern
                            }
                            .controlSize(.mini)
                            .buttonStyle(.bordered)
                        }
                    }

                    if !regexValid {
                        InlineValidationMessage("正则表达式语法无效", isError: true)
                    }
                }
            }

            FormRow("排除正则", labelWidth: 96) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("留空不排除，例如 (?i)(家宽|倍率|过期|剩余)", text: $draft.excludeFilterPattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                    if !excludeRegexValid {
                        InlineValidationMessage("排除正则表达式语法无效", isError: true)
                    } else if let matched = liveMatchedNodes {
                        VStack(alignment: .leading, spacing: 4) {
                            let excludedSuffix = liveExcludedCount > 0 ? "（已排除 \(liveExcludedCount) 个）" : ""
                            Text("实时匹配预览：共 \(matched.count) 个节点\(excludedSuffix)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(matched.isEmpty ? .orange : .teal)
                            if !matched.isEmpty {
                                Text(matched.prefix(6).map(\.name).joined(separator: " · ") + (matched.count > 6 ? " …" : ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }

            FormRow("选节点方式", labelWidth: 96) {
                Toggle("自动测速选择最低延迟节点 (url-test)", isOn: $draft.autoTest)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft.filterPattern = draft.filterPattern.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft.excludeFilterPattern = draft.excludeFilterPattern.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct RegionalGroupsGeneratorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var state: AppState

    @State private var kind: NodeGroupKind = .exit
    @State private var subscriptionID: UUID? = nil
    @State private var autoTest = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("按地区一键生成节点组").font(.headline)
            InlineNote("将自动补全缺失的地区节点组（香港、日本、新加坡、台湾、美国、澳洲、新西兰、英国、德国），已存在的同名节点组不会被覆盖。")

            FormRow("节点组类型", labelWidth: 96) {
                Picker("", selection: $kind) {
                    ForEach(NodeGroupKind.allCases) { k in
                        Text(k.title).tag(k)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: kind) { newKind in
                    autoTest = (newKind == .exit)
                }
            }

            FormRow("绑定订阅", labelWidth: 96) {
                Picker("", selection: $subscriptionID) {
                    Text("暂不绑定").tag(UUID?.none)
                    ForEach(state.profile.subscriptions) { sub in
                        Text(sub.name).tag(UUID?.some(sub.id))
                    }
                }
                .labelsHidden()
            }

            FormRow("选节点方式", labelWidth: 96) {
                Toggle("自动测速选择最低延迟节点 (url-test)", isOn: $autoTest)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("一键生成") {
                    let suffix = kind == .exit ? "出口节点组" : "链式节点组"
                    var addedCount = 0
                    for region in RegexPreset.regions {
                        let groupName = "\(region.title)\(suffix)"
                        let exists = state.profile.nodeGroups.contains { $0.name == groupName && $0.kind == kind }
                        if !exists {
                            state.profile.nodeGroups.append(
                                NodeGroup(
                                    name: groupName,
                                    kind: kind,
                                    subscriptionID: subscriptionID,
                                    filterPattern: region.pattern,
                                    autoTest: autoTest
                                )
                            )
                            addedCount += 1
                        }
                    }
                    state.showFeedback(addedCount > 0 ? "已生成 \(addedCount) 个地区\(suffix)" : "所有地区\(suffix)均已存在")
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            subscriptionID = state.profile.subscriptions.first?.id
        }
    }
}
