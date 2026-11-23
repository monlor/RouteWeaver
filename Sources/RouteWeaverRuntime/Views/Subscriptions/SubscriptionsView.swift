import RoutingCore
import SwiftUI

struct SubscriptionsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var subscriptionStore: SubscriptionStore
    @State private var editingSubscription: ProxySubscription?
    @State private var isNewSubscription = false
    @State private var inspectingSubscription: ProxySubscription?

    @State private var editingHostModule: HostModule?
    @State private var isNewHostModule = false
    @State private var inspectingHostModuleID: UUID?

    @State private var editingNodeGroup: NodeGroup?
    @State private var isNewNodeGroup = false
    @State private var groupKindFilter: NodeGroupKind? = nil
    @State private var showRegionalGenerator = false
    @State private var expandedGroupIDs: Set<UUID> = []

    private var filteredGroups: [NodeGroup] {
        guard let filter = groupKindFilter else { return state.profile.nodeGroups }
        return state.profile.nodeGroups.filter { $0.kind == filter }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if state.hasPendingHotReload {
                    HStack(spacing: 10) {
                        InlineNote("订阅或节点组已修改，点击「热重载生效」即可在不重启核心的情况下应用。")
                        Spacer()
                        Button("热重载生效") { state.hotReload() }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .disabled(state.isHotReloading || state.configValidationError != nil)
                    }
                } else if state.engine.isRunning {
                    InlineNote("核心运行中，支持直接编辑订阅、Host 模块与节点组，修改后点击顶部「热重载生效」即可应用。")
                }

                subscriptionsCard
                hostModulesCard
                nodeGroupsCard
            }
            .padding(20)
        }
        .sheet(item: $editingSubscription) { sub in
            SubscriptionEditorSheet(initial: sub, isNew: isNewSubscription) { saved in
                if let idx = state.profile.subscriptions.firstIndex(where: { $0.id == saved.id }) {
                    state.profile.subscriptions[idx] = saved
                } else {
                    state.profile.subscriptions.append(saved)
                    // Convenience: if starter node groups have no subscription bound yet, offer automatic binding on first subscription
                    autoBindUnboundNodeGroupsIfNeeded(for: saved)
                }
                state.showFeedback("已保存订阅「\(saved.name)」，正在下载并缓存节点…")
                state.fetchSubscriptionNodes(saved)
            }
        }
        .sheet(item: $inspectingSubscription) { sub in
            SubscriptionNodesSheet(state: state, subscriptionStore: subscriptionStore, subscription: sub)
        }
        .sheet(item: $editingHostModule) { module in
            HostModuleEditorSheet(initial: module, isNew: isNewHostModule) { saved in
                var shouldRefresh = isNewHostModule
                if let idx = state.profile.hostModules.firstIndex(where: { $0.id == saved.id }) {
                    if state.profile.hostModules[idx].url != saved.url {
                        shouldRefresh = true
                    }
                    state.profile.hostModules[idx] = saved
                } else {
                    state.profile.hostModules.append(saved)
                }
                let displayName = saved.name.isEmpty ? "Host 模块" : saved.name
                state.showFeedback("已保存模块「\(displayName)」")
                if shouldRefresh {
                    state.refreshHostModule(id: saved.id)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { inspectingHostModuleID != nil },
            set: { if !$0 { inspectingHostModuleID = nil } }
        )) {
            if let id = inspectingHostModuleID,
               let module = state.profile.hostModules.first(where: { $0.id == id }) {
                HostModuleDetailSheet(state: state, subscriptionStore: subscriptionStore, module: module)
            }
        }
        .sheet(item: $editingNodeGroup) { group in
            NodeGroupEditorSheet(
                state: state,
                subscriptionStore: subscriptionStore,
                subscriptions: state.profile.subscriptions,
                initial: group,
                isNew: isNewNodeGroup
            ) { saved in
                if let idx = state.profile.nodeGroups.firstIndex(where: { $0.id == saved.id }) {
                    state.profile.nodeGroups[idx] = saved
                } else {
                    state.profile.nodeGroups.append(saved)
                }
                state.showFeedback("已保存节点组「\(saved.name)」")
            }
        }
        .sheet(isPresented: $showRegionalGenerator) {
            RegionalGroupsGeneratorSheet(state: state)
        }
    }

    private var subscriptionsCard: some View {
        SectionCard("订阅管理（链式代理 / 出口代理）", icon: "link.badge.plus") {
            HStack(spacing: 8) {
                if !state.profile.subscriptions.isEmpty {
                    Button {
                        state.fetchAllSubscriptionNodes()
                    } label: {
                        Label("拉取全部节点", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(!subscriptionStore.fetchingIDs.isEmpty)
                }

                Button {
                    isNewSubscription = true
                    editingSubscription = ProxySubscription(name: "", url: "", role: .exit)
                } label: {
                    Label("添加订阅", systemImage: "plus")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(state.hotReloadEditingLocked)
            }
        } content: {
            if state.profile.subscriptions.isEmpty {
                InlineNote("尚未添加代理订阅。点击「添加订阅」填入 HTTPS 订阅地址，即可供出口节点组和链式节点组使用。")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(state.profile.subscriptions.enumerated()), id: \.element.id) { idx, sub in
                        let cacheEntry = subscriptionStore.cache[sub.id]
                        let isFetching = subscriptionStore.fetchingIDs.contains(sub.id)
                        let fetchError = subscriptionStore.fetchErrors[sub.id]

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 8) {
                                        Text(sub.name).font(.subheadline.weight(.medium))
                                        StatusPill(sub.role.title, color: roleColor(sub.role))

                                        if let cacheEntry {
                                            StatusPill("\(cacheEntry.nodes.count) 个节点", color: .green)
                                        } else if !isFetching {
                                            StatusPill("未拉取节点", color: .secondary)
                                        }
                                    }
                                    HStack(spacing: 8) {
                                        Text(maskedURL(sub.url))
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        if let cacheEntry {
                                            Text("· 更新于 \(Self.timeFormatter.string(from: cacheEntry.updatedAt))")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }

                                Spacer()

                                if isFetching {
                                    ProgressView()
                                        .controlSize(.small)
                                }

                                Button {
                                    state.fetchSubscriptionNodes(sub)
                                } label: {
                                    Label(cacheEntry == nil ? "拉取节点" : "刷新", systemImage: "arrow.clockwise")
                                }
                                .controlSize(.small)
                                .disabled(isFetching)

                                Button {
                                    inspectingSubscription = sub
                                } label: {
                                    Label("节点列表", systemImage: "list.bullet")
                                }
                                .controlSize(.small)
                                .disabled(cacheEntry == nil && !isFetching)

                                Button("编辑") {
                                    isNewSubscription = false
                                    editingSubscription = sub
                                }
                                .controlSize(.small)
                                .disabled(state.hotReloadEditingLocked)

                                Button(role: .destructive) {
                                    state.deleteSubscription(id: sub.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .controlSize(.small)
                                .disabled(state.hotReloadEditingLocked)
                            }

                            if let usage = cacheEntry?.usage {
                                SubscriptionUsageBar(usage: usage)
                                    .padding(.top, 2)
                            }

                            if let fetchError {
                                InlineValidationMessage(fetchError, isError: true)
                            }
                        }
                        .padding(.vertical, 8)

                        if idx < state.profile.subscriptions.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var hostModulesCard: some View {
        SectionCard("Surge Host 模块（.sgmodule）", icon: "server.rack") {
            HStack(spacing: 8) {
                if !state.profile.hostModules.isEmpty {
                    Button {
                        state.refreshAllHostModules()
                    } label: {
                        Label("刷新全部", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(!subscriptionStore.updatingHostModuleIDs.isEmpty)
                }

                Button {
                    isNewHostModule = true
                    editingHostModule = HostModule(name: "", url: "", isEnabled: true)
                } label: {
                    Label("添加模块", systemImage: "plus")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(state.hotReloadEditingLocked)
            }
        } content: {
            if state.profile.hostModules.isEmpty {
                InlineNote("尚未添加 Surge Host 模块（.sgmodule）。可用于机场节点域名 CNAME / IP 映射，启用的模块会自动写入 Mihomo 的 hosts 并开启 dns.use-hosts。")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(state.profile.hostModules.enumerated()), id: \.element.id) { idx, module in
                        let isUpdating = subscriptionStore.updatingHostModuleIDs.contains(module.id)
                        let displayName = module.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? (URL(string: module.url)?.lastPathComponent ?? "未命名模块")
                            : module.name

                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { module.isEnabled },
                                set: { enabled in
                                    if let i = state.profile.hostModules.firstIndex(where: { $0.id == module.id }) {
                                        state.profile.hostModules[i].isEnabled = enabled
                                    }
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.mini)
                            .disabled(state.hotReloadEditingLocked)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(displayName)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(module.isEnabled ? .primary : .secondary)

                                    if module.cachedHosts.isEmpty {
                                        StatusPill(module.lastUpdated == nil ? "未拉取" : "0 条映射", color: .secondary)
                                    } else {
                                        StatusPill("\(module.cachedHosts.count) 条 Host 映射", color: module.isEnabled ? .teal : .secondary)
                                    }
                                }
                                HStack(spacing: 8) {
                                    Text(maskedURL(module.url))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    if let updatedAt = module.lastUpdated {
                                        Text("· 更新于 \(Self.timeFormatter.string(from: updatedAt))")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }

                            Spacer()

                            if isUpdating {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            Button {
                                state.refreshHostModule(id: module.id)
                            } label: {
                                Label(module.lastUpdated == nil ? "拉取" : "刷新", systemImage: "arrow.clockwise")
                            }
                            .controlSize(.small)
                            .disabled(isUpdating)

                            Button {
                                inspectingHostModuleID = module.id
                            } label: {
                                Label("查看映射", systemImage: "list.bullet")
                            }
                            .controlSize(.small)
                            .disabled(module.cachedHosts.isEmpty)

                            Button("编辑") {
                                isNewHostModule = false
                                editingHostModule = module
                            }
                            .controlSize(.small)
                            .disabled(state.hotReloadEditingLocked)

                            Button(role: .destructive) {
                                state.deleteHostModule(id: module.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .controlSize(.small)
                            .disabled(state.hotReloadEditingLocked)
                        }
                        .padding(.vertical, 8)

                        if idx < state.profile.hostModules.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var nodeGroupsCard: some View {
        SectionCard("节点组（自定义正则筛选）", icon: "point.3.filled.connected.trianglepath.dotted") {
            HStack(spacing: 8) {
                Picker("", selection: $groupKindFilter) {
                    Text("全部").tag(NodeGroupKind?.none)
                    Text("出口").tag(NodeGroupKind?.some(.exit))
                    Text("链式").tag(NodeGroupKind?.some(.relay))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)

                Button {
                    showRegionalGenerator = true
                } label: {
                    Label("按地区生成", systemImage: "globe.asia.australia")
                }
                .controlSize(.small)
                .disabled(state.hotReloadEditingLocked)
                .help("一键补全香港、日本、新加坡、台湾、美国、澳洲、新西兰、英国、德国节点组")

                Button {
                    isNewNodeGroup = true
                    editingNodeGroup = NodeGroup(
                        name: "",
                        kind: groupKindFilter ?? .exit,
                        subscriptionID: state.profile.subscriptions.first?.id,
                        filterPattern: "",
                        autoTest: (groupKindFilter ?? .exit) == .exit
                    )
                } label: {
                    Label("新建节点组", systemImage: "plus")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(state.hotReloadEditingLocked)
            }
        } content: {
            if filteredGroups.isEmpty {
                InlineNote("暂无节点组。可按地区或用途（如香港出口、美国链式）创建正则匹配节点组。")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(filteredGroups.enumerated()), id: \.element.id) { idx, group in
                        let matched = state.matchedNodes(for: group)
                        let isExpanded = expandedGroupIDs.contains(group.id)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                StatusPill(
                                    group.kind.shortLabel,
                                    color: group.kind == .exit ? .blue : .purple
                                )

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 8) {
                                        Text(group.name).font(.subheadline.weight(.medium))
                                        if let sub = state.profile.subscription(id: group.subscriptionID) {
                                            Text("订阅：\(sub.name)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Text("未绑定订阅")
                                                .font(.caption)
                                                .foregroundStyle(.orange)
                                        }
                                        Text(group.autoTest ? "自动测速" : "手动选节点")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)

                                        if let matched {
                                            StatusPill(
                                                "匹配 \(matched.count) 个节点",
                                                color: matched.isEmpty ? .orange : .teal
                                            )
                                        }
                                    }

                                    Text(group.filterPattern.isEmpty ? "正则：全部节点（不过滤）" : "正则：\(group.filterPattern)")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)

                                    if !group.excludeFilterPattern.isEmpty {
                                        Text("排除：\(group.excludeFilterPattern)")
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.orange)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                if let matched, !matched.isEmpty {
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            if isExpanded {
                                                expandedGroupIDs.remove(group.id)
                                            } else {
                                                expandedGroupIDs.insert(group.id)
                                            }
                                        }
                                    } label: {
                                        Label(isExpanded ? "收起" : "预览", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                                    }
                                    .controlSize(.small)
                                }

                                Button("编辑") {
                                    isNewNodeGroup = false
                                    editingNodeGroup = group
                                }
                                .controlSize(.small)
                                .disabled(state.hotReloadEditingLocked)

                                Button(role: .destructive) {
                                    state.deleteNodeGroup(id: group.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .controlSize(.small)
                                .disabled(state.hotReloadEditingLocked)
                            }

                            if isExpanded, let matched, !matched.isEmpty {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], alignment: .leading, spacing: 6) {
                                    ForEach(matched) { node in
                                        HStack(spacing: 6) {
                                            Text(node.type.uppercased())
                                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.14)))
                                            Text(node.name)
                                                .font(.caption)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                                .help(node.name)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .fill(Color(nsColor: .textBackgroundColor).opacity(0.7))
                                        )
                                    }
                                }
                                .padding(.leading, 44)
                                .padding(.top, 2)
                            }
                        }
                        .padding(.vertical, 8)

                        if idx < filteredGroups.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func autoBindUnboundNodeGroupsIfNeeded(for sub: ProxySubscription) {
        for idx in state.profile.nodeGroups.indices where state.profile.nodeGroups[idx].subscriptionID == nil {
            let groupKind = state.profile.nodeGroups[idx].kind
            if sub.role == .general || (sub.role == .exit && groupKind == .exit) || (sub.role == .relay && groupKind == .relay) {
                state.profile.nodeGroups[idx].subscriptionID = sub.id
            }
        }
    }

    private func roleColor(_ role: SubscriptionRole) -> Color {
        switch role {
        case .exit: return .blue
        case .relay: return .purple
        case .general: return .teal
        }
    }

    private func maskedURL(_ raw: String) -> String {
        guard let comps = URLComponents(string: raw), let host = comps.host else { return raw }
        return "\(comps.scheme ?? "https")://\(host)/…"
    }

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        return df
    }()
}

