import RoutingCore
import SwiftUI

struct SubscriptionNodesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var state: AppState
    @ObservedObject var subscriptionStore: SubscriptionStore
    let subscription: ProxySubscription

    @State private var searchText = ""

    private var allNodes: [SubscriptionNode] {
        state.nodes(forSubscriptionID: subscription.id)
    }

    private var filteredNodes: [SubscriptionNode] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return allNodes }
        return allNodes.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.type.localizedCaseInsensitiveContains(q)
                || ($0.server?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("订阅节点列表 · \(subscription.name)").font(.headline)
                    Text("共 \(allNodes.count) 个节点\(searchText.isEmpty ? "" : "，筛选出 \(filteredNodes.count) 个")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    state.fetchSubscriptionNodes(subscription)
                } label: {
                    Label("重新拉取", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(state.fetchingSubscriptionIDs.contains(subscription.id))

                Button("关闭") { dismiss() }
                    .controlSize(.small)
            }

            if let usage = state.subscriptionCache[subscription.id]?.usage {
                SubscriptionUsageBar(usage: usage, compact: true)
            }

            TextField("搜索节点名称、协议（如 ss / trojan / vless）或地址…", text: $searchText)
                .textFieldStyle(.roundedBorder)

            if let err = state.subscriptionFetchErrors[subscription.id] {
                InlineValidationMessage(err, isError: true)
            }

            if state.fetchingSubscriptionIDs.contains(subscription.id) && allNodes.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在拉取并解析订阅节点…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredNodes.isEmpty {
                InlineNote(allNodes.isEmpty ? "暂无节点，请点击「重新拉取」。" : "没有匹配当前搜索条件的节点。")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List(filteredNodes) { node in
                    HStack(spacing: 10) {
                        Text(node.type.uppercased())
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.blue)
                            .frame(width: 72, alignment: .center)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.blue.opacity(0.12)))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.name)
                                .font(.subheadline)
                                .lineLimit(1)
                            if let server = node.server, !server.isEmpty {
                                Text(node.port.map { "\(server):\($0)" } ?? server)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        Button {
                            state.copyText(node.name, label: "节点名「\(node.name)」")
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("复制节点名称")
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(20)
        .frame(width: 620, height: 480)
    }
}


struct SubscriptionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let isNew: Bool
    let onSave: (ProxySubscription) -> Void

    @State private var draft: ProxySubscription

    init(initial: ProxySubscription, isNew: Bool, onSave: @escaping (ProxySubscription) -> Void) {
        self.isNew = isNew
        self.onSave = onSave
        _draft = State(initialValue: initial)
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("https://")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "添加代理订阅" : "编辑代理订阅").font(.headline)

            FormRow("订阅名称", labelWidth: 96) {
                TextField("例如 主力出口订阅、专线链式订阅", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            FormRow("用途标签", labelWidth: 96) {
                Picker("", selection: $draft.role) {
                    ForEach(SubscriptionRole.allCases) { role in
                        Text(role.title).tag(role)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            FormRow("订阅地址", labelWidth: 96) {
                TextField("https://...", text: $draft.url)
                    .textFieldStyle(.roundedBorder)
            }

            InlineNote("仅支持 HTTPS 订阅链接。保存后会自动拉取节点列表供预览与正则匹配测试。")

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
        .frame(width: 480)
    }
}

