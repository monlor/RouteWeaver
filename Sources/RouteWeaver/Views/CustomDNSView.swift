import RoutingCore
import SwiftUI

struct CustomDNSView: View {
    @ObservedObject var state: AppState

    @State private var kindFilter: CustomDNSEntryKind? = nil
    @State private var searchText = ""
    @State private var editingEntry: CustomDNSEntry?
    @State private var isNewEntry = false
    @State private var showBulkImport = false

    private var filteredEntries: [CustomDNSEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.profile.customDNS.entries.filter { entry in
            if let filter = kindFilter, entry.kind != filter {
                return false
            }
            if query.isEmpty {
                return true
            }
            return entry.pattern.localizedCaseInsensitiveContains(query)
                || entry.value.localizedCaseInsensitiveContains(query)
                || entry.note.localizedCaseInsensitiveContains(query)
        }
    }

    private var hostCount: Int {
        state.profile.customDNS.entries.filter { $0.kind == .host && $0.isEnabled }.count
    }

    private var serverCount: Int {
        state.profile.customDNS.entries.filter { $0.kind == .server && $0.isEnabled }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if state.hasPendingHotReload {
                    HStack(spacing: 10) {
                        InlineNote("自定义 DNS 已修改，点击「热重载生效」即可在不重启核心的情况下应用。")
                        Spacer()
                        Button("热重载生效") { state.hotReload() }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .disabled(state.isHotReloading || state.configValidationError != nil)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.10)))
                } else if state.engine.isRunning {
                    InlineNote("核心运行中，支持直接编辑自定义 Host 与 DNS 服务器策略，修改后点击顶部「热重载生效」即可应用。")
                }

                if let err = state.configValidationError, err.contains("DNS") {
                    InlineValidationMessage(err, isError: true)
                }

                entriesCard
                upstreamServersCard
            }
            .padding(20)
        }
        .sheet(item: $editingEntry) { entry in
            CustomDNSEntryEditorSheet(
                initial: entry,
                isNew: isNewEntry,
                targets: state.profile.targets,
                tunFakeIPEnabled: state.profile.effectiveTunEnabled && state.profile.tunDNSMode == .fakeIP
            ) { saved in
                state.upsertCustomDNSEntry(saved)
                state.showFeedback("已保存自定义 DNS「\(saved.trimmedPattern)」")
            }
        }
        .sheet(isPresented: $showBulkImport) {
            CustomDNSBulkImportSheet { entries in
                state.importCustomDNSEntries(entries)
            }
        }
    }

    private var entriesCard: some View {
        SectionCard("自定义 Host 与域名 DNS 策略", icon: "globe") {
            HStack(spacing: 8) {
                Picker("", selection: $kindFilter) {
                    Text("全部").tag(CustomDNSEntryKind?.none)
                    Text("Host (\(hostCount))").tag(CustomDNSEntryKind?.some(.host))
                    Text("Server (\(serverCount))").tag(CustomDNSEntryKind?.some(.server))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)

                Button {
                    showBulkImport = true
                } label: {
                    Label("批量导入", systemImage: "square.and.arrow.down")
                }
                .controlSize(.small)
                .disabled(state.hotReloadEditingLocked)

                Button {
                    isNewEntry = true
                    editingEntry = CustomDNSEntry(
                        pattern: "",
                        kind: kindFilter ?? .host,
                        value: "",
                        isEnabled: true
                    )
                } label: {
                    Label("添加规则", systemImage: "plus")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(state.hotReloadEditingLocked)
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if !state.profile.customDNS.entries.isEmpty {
                    TextField("搜索域名、通配符、IP、DNS 服务器或备注…", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                }

                if filteredEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        InlineNote(
                            state.profile.customDNS.entries.isEmpty
                            ? "尚未添加自定义 DNS 规则。支持精确域名与通配符域名，分别写入 Mihomo 的 hosts 与 dns.nameserver-policy。"
                            : "没有匹配当前筛选条件的自定义 DNS 规则。"
                        )
                        if state.profile.customDNS.entries.isEmpty {
                            InlineNote("通配符示例：*.example.com（单级子域）、+.example.com（根域及所有子域）、.example.com（所有子域）。")
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { idx, entry in
                            entryRow(entry)
                            if idx < filteredEntries.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private func entryRow(_ entry: CustomDNSEntry) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { entry.isEnabled },
                set: { enabled in
                    if let i = state.profile.customDNS.entries.firstIndex(where: { $0.id == entry.id }) {
                        state.profile.customDNS.entries[i].isEnabled = enabled
                    }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.mini)
            .disabled(state.hotReloadEditingLocked)

            StatusPill(
                entry.kind.shortLabel,
                color: entry.kind == .host ? .blue : .purple
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.trimmedPattern)
                        .font(.system(.subheadline, design: .monospaced).weight(.medium))
                        .foregroundStyle(entry.isEnabled ? .primary : .secondary)
                        .textSelection(.enabled)

                    if entry.isWildcard {
                        StatusPill("通配符", color: .teal)
                    }

                    if entry.kind == .server, let targetID = entry.targetID {
                        let targetName = state.profile.target(id: targetID)?.name ?? "目标已删除"
                        StatusPill(
                            "出口：\(targetName)",
                            color: state.profile.target(id: targetID) == nil ? .orange : .indigo
                        )
                    }

                    if entry.kind == .server && entry.bypassFakeIP {
                        StatusPill("跳过 Fake-IP", color: .orange)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(entry.value)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)

                    if !entry.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("· \(entry.note)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            Button("编辑") {
                isNewEntry = false
                editingEntry = entry
            }
            .controlSize(.small)
            .disabled(state.hotReloadEditingLocked)

            Button(role: .destructive) {
                state.deleteCustomDNSEntry(id: entry.id)
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .disabled(state.hotReloadEditingLocked)
        }
        .padding(.vertical, 8)
    }

    private var upstreamServersCard: some View {
        SectionCard("全局上游 DNS 服务器（可选覆盖）", icon: "server.rack") {
            if !state.profile.customDNS.directServers.isEmpty || !state.profile.customDNS.bootstrapServers.isEmpty {
                Button("恢复自动") {
                    state.profile.customDNS.directServers = []
                    state.profile.customDNS.bootstrapServers = []
                    state.showFeedback("已恢复自动 DNS 配置")
                }
                .controlSize(.small)
                .disabled(state.hotReloadEditingLocked)
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                FormRow("直连上游 DNS", labelWidth: 168) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(
                            "留空自动使用系统 DNS + 223.5.5.5, 119.29.29.29",
                            text: Binding(
                                get: { state.profile.customDNS.directServers.joined(separator: ", ") },
                                set: { raw in
                                    state.profile.customDNS.directServers = CustomDNSParser.parseServerList(raw)
                                }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .disabled(state.hotReloadEditingLocked)
                        InlineNote("用于直连规则与 direct-nameserver，多个服务器用逗号分隔，支持 IP / DoH / DoT / DoQ（如 https://dns.alidns.com/dns-query）。")
                    }
                }

                FormRow("引导 DNS (bootstrap)", labelWidth: 168) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(
                            "留空自动使用网卡/系统 DNS + 223.5.5.5, 119.29.29.29",
                            text: Binding(
                                get: { state.profile.customDNS.bootstrapServers.joined(separator: ", ") },
                                set: { raw in
                                    state.profile.customDNS.bootstrapServers = CustomDNSParser.parseServerList(raw)
                                }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .disabled(state.hotReloadEditingLocked)
                        InlineNote("用于 default-nameserver 与 proxy-server-nameserver（解析 DoH/DoT 与代理节点域名），建议填写纯 IP 或 system。")
                    }
                }
            }
        }
    }
}

private struct CustomDNSEntryEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let isNew: Bool
    let targets: [NetworkTarget]
    let tunFakeIPEnabled: Bool
    let onSave: (CustomDNSEntry) -> Void

    @State private var draft: CustomDNSEntry

    init(
        initial: CustomDNSEntry,
        isNew: Bool,
        targets: [NetworkTarget],
        tunFakeIPEnabled: Bool,
        onSave: @escaping (CustomDNSEntry) -> Void
    ) {
        self.isNew = isNew
        self.targets = targets
        self.tunFakeIPEnabled = tunFakeIPEnabled
        self.onSave = onSave
        _draft = State(initialValue: initial)
    }

    private var validationError: String? {
        let pattern = draft.trimmedPattern
        if pattern.isEmpty { return nil }
        if !CustomDNSValidator.isValidPattern(pattern, allowPolicyPrefix: draft.kind == .server) {
            return "域名或通配符格式无效（不能包含空格、逗号，或仅填写单独的 * / +.）"
        }
        let values = draft.splitValues
        if values.isEmpty { return nil }
        switch draft.kind {
        case .host:
            if !values.allSatisfy({ CustomDNSValidator.isValidHostTarget($0, forPattern: pattern) }) {
                return "Host 映射值无效，或与域名自身相同（禁止循环 CNAME）"
            }
        case .server:
            if !values.allSatisfy(CustomDNSValidator.isValidServer) {
                return "DNS 服务器地址格式无效（支持 IP、IP:端口、system、udp/tcp/tls/https/quic/h3://）"
            }
        }
        return nil
    }

    private var canSave: Bool {
        !draft.trimmedPattern.isEmpty && !draft.splitValues.isEmpty && validationError == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "添加自定义 DNS 规则" : "编辑自定义 DNS 规则")
                .font(.headline)

            FormRow("规则类型", labelWidth: 108) {
                Picker("", selection: $draft.kind) {
                    ForEach(CustomDNSEntryKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }

            FormRow("域名 / 通配符", labelWidth: 108) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField(
                        draft.kind == .host ? "例如 nas.local、*.dev.local、+.home.arpa" : "例如 *.corp.local、+.company.com、internal.lan",
                        text: $draft.pattern
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    InlineNote("支持精确域名及通配符：*.a.com（单级子域）、+.a.com（根域+所有子域）、.a.com（所有子域）。")
                }
            }

            FormRow(draft.kind == .host ? "映射目标" : "DNS 服务器", labelWidth: 108) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(
                        draft.kind == .host ? "IP、多 IP（逗号分隔）或 CNAME，如 192.168.1.10" : "如 10.0.0.53 或 https://dns.alidns.com/dns-query",
                        text: $draft.value
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                    if draft.kind == .server {
                        HStack(spacing: 6) {
                            Text("快捷填入:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(Self.dnsPresets, id: \.label) { preset in
                                Button(preset.label) {
                                    draft.value = preset.value
                                }
                                .controlSize(.mini)
                            }
                        }
                    } else {
                        InlineNote("支持 IPv4 / IPv6、多 IP 逗号分隔（如 1.1.1.1, 1.0.0.1）或目标域名 CNAME。")
                    }
                }
            }

            if draft.kind == .server {
                FormRow("解析出口目标", labelWidth: 108) {
                    Picker("", selection: $draft.targetID) {
                        Text("自动 / 不指定（直接连接该 DNS）").tag(UUID?.none)
                        if !targets.isEmpty {
                            Divider()
                            ForEach(targets) { target in
                                Text(target.name).tag(UUID?.some(target.id))
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 260)
                }

                FormRow("Fake-IP 选项", labelWidth: 108) {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("跳过 Fake-IP，直接返回真实解析 IP（加入 fake-ip-filter）", isOn: $draft.bypassFakeIP)
                        if !tunFakeIPEnabled {
                            InlineNote("仅在启用 TUN 且 DNS 模式为 Fake-IP 时生效，适合内网域名或开发工具。")
                        }
                    }
                }
            }

            FormRow("备注（可选）", labelWidth: 108) {
                TextField("例如 公司内网 DNS、NAS 泛域名", text: $draft.note)
                    .textFieldStyle(.roundedBorder)
            }

            FormRow("启用状态", labelWidth: 108) {
                Toggle("启用此规则", isOn: $draft.isEnabled)
            }

            if let err = validationError {
                InlineValidationMessage(err, isError: true)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    draft.pattern = draft.trimmedPattern
                    draft.value = draft.splitValues.joined(separator: ", ")
                    draft.note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
                    if draft.kind == .host {
                        draft.targetID = nil
                        draft.bypassFakeIP = false
                    }
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private static let dnsPresets: [(label: String, value: String)] = [
        ("阿里 DoH", "https://dns.alidns.com/dns-query"),
        ("腾讯 DoH", "https://doh.pub/dns-query"),
        ("Cloudflare", "https://1.1.1.1/dns-query"),
        ("系统 DNS", "system"),
    ]
}

private struct CustomDNSBulkImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onImport: ([CustomDNSEntry]) -> Void

    @State private var rawText = ""

    private var parsedEntries: [CustomDNSEntry] {
        CustomDNSParser.parseBulk(rawText)
    }

    private var parsedHostCount: Int {
        parsedEntries.filter { $0.kind == .host }.count
    }

    private var parsedServerCount: Int {
        parsedEntries.filter { $0.kind == .server }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("批量导入自定义 DNS").font(.headline)

            InlineNote("每行一条，支持 Surge [Host] 格式与标准 /etc/hosts 格式，支持精确域名与通配符（*. / +. / .）。同名同类型规则将自动更新。")

            TextEditor(text: $rawText)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 200)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.25))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("格式示例（支持 = 或空格分隔，域名在前或 IP 在前均可自动识别）：")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("""
                *.corp.local = server:10.0.0.53
                +.company.com = server:https://dns.alidns.com/dns-query
                *.dev.local 127.0.0.1
                192.168.1.10 nas.local *.nas.local
                """)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
            }

            HStack {
                if !parsedEntries.isEmpty {
                    StatusPill("解析出 \(parsedHostCount) 条 Host，\(parsedServerCount) 条 Server", color: .teal)
                } else if !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    InlineValidationMessage("未识别出有效规则，请检查格式。", isError: true)
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("导入 \(parsedEntries.count) 条") {
                    onImport(parsedEntries)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(parsedEntries.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
