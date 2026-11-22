import RoutingCore
import SwiftUI

struct HostModuleEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let isNew: Bool
    let onSave: (HostModule) -> Void

    @State private var draft: HostModule

    init(initial: HostModule, isNew: Bool, onSave: @escaping (HostModule) -> Void) {
        self.isNew = isNew
        self.onSave = onSave
        _draft = State(initialValue: initial)
    }

    private var canSave: Bool {
        draft.url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("https://")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "添加 Surge Host 模块" : "编辑 Surge Host 模块").font(.headline)

            FormRow("模块名称", labelWidth: 96) {
                TextField("留空自动读取模块内 #!name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            FormRow("模块地址", labelWidth: 96) {
                TextField("https://.../example.sgmodule", text: $draft.url)
                    .textFieldStyle(.roundedBorder)
            }

            FormRow("启用状态", labelWidth: 96) {
                Toggle("启用此模块的 [Host] 映射", isOn: $draft.isEnabled)
            }

            InlineNote("支持标准 Surge .sgmodule 中的 [Host] 段或纯 `host = target` 列表，自动忽略无效项与 server:/script: 指令。保存后将自动拉取。")

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft.url = draft.url.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

struct HostModuleDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var state: AppState
    @ObservedObject var subscriptionStore: SubscriptionStore
    let module: HostModule

    @State private var searchText = ""

    private var sortedEntries: [(host: String, target: String)] {
        let all = module.cachedHosts
            .map { (host: $0.key, target: $0.value) }
            .sorted { $0.host.localizedCaseInsensitiveCompare($1.host) == .orderedAscending }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.host.localizedCaseInsensitiveContains(q) || $0.target.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Host 映射明细 · \(module.name.isEmpty ? "Surge 模块" : module.name)").font(.headline)
                    Text("共 \(module.cachedHosts.count) 条映射\(searchText.isEmpty ? "" : "，筛选出 \(sortedEntries.count) 条")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    state.refreshHostModule(id: module.id)
                } label: {
                    Label("重新拉取", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(state.updatingHostModuleIDs.contains(module.id))

                Button("关闭") { dismiss() }
                    .controlSize(.small)
            }

            TextField("搜索域名或映射目标…", text: $searchText)
                .textFieldStyle(.roundedBorder)

            if sortedEntries.isEmpty {
                InlineNote("没有匹配的 Host 映射记录。")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List(sortedEntries, id: \.host) { entry in
                    HStack(spacing: 8) {
                        Text(entry.host)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(entry.target)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(20)
        .frame(width: 620, height: 460)
    }
}

