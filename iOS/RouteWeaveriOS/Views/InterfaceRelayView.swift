import RoutingCore
import SwiftUI

struct InterfaceRelayView: View {
    @EnvironmentObject private var model: MobileAppModel
    @State private var showManualOverride = false
    var embedded: Bool = false

    private var syncedRelayNodeGroups: [NodeGroup] {
        (model.activeSyncedProfile?.nodeGroups ?? []).filter { $0.kind == .relay }
    }

    private var isChainedRelayEnabled: Bool {
        if case .chainedNodeGroup = model.relayConfig.defaultRoute {
            return true
        }
        return false
    }

    private var selectedChainGroupID: UUID? {
        if case .chainedNodeGroup(let id) = model.relayConfig.defaultRoute,
           syncedRelayNodeGroups.contains(where: { $0.id == id }) {
            return id
        }
        return syncedRelayNodeGroups.first?.id
    }

    var body: some View {
        if embedded {
            formContent
        } else {
            NavigationStack {
                formContent
            }
        }
    }

    private var formContent: some View {
        Form {
            relayStatusSection
            chainedProxySection
            interfaceMappingSection

            Section {
                Button {
                    Task { await model.saveAndNotifyTunnel() }
                } label: {
                    HStack {
                        Spacer()
                        Text("保存并应用到隧道")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("中继与网卡")
    }

    // MARK: - Sections

    private var relayStatusSection: some View {
        Section {
            LabeledContent("中继状态") {
                Text(model.relayConfig.isEnabled ? "已从 PC 同步" : "未启用")
                    .foregroundStyle(model.relayConfig.isEnabled ? .green : .secondary)
            }

            if !model.relayConfig.serverURL.isEmpty {
                LabeledContent("中继地址") {
                    Text(model.relayConfig.serverURL)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if !model.relayConfig.hostID.isEmpty {
                LabeledContent("主机 ID") {
                    Text(model.relayConfig.hostID)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Picker("会话自动轮换阈值", selection: $model.relayConfig.sessionRotateThresholdBytes) {
                Text("关闭（不限流量）").tag(UInt64(0))
                Text("200 MB").tag(UInt64(200 * 1024 * 1024))
                Text("450 MB（公共中继推荐）").tag(LumzelRelayConstants.defaultSessionRotateBytes)
                Text("1 GB").tag(UInt64(1024 * 1024 * 1024))
            }

            DisclosureGroup("高级：手动覆盖中继连接", isExpanded: $showManualOverride) {
                Toggle("启用中继", isOn: $model.relayConfig.isEnabled)

                TextField("中继地址 (wss://...)", text: $model.relayConfig.serverURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("中继密码 (可选)", text: $model.relayConfig.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("主机 ID", text: $model.relayConfig.hostID)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } header: {
            Text("中继服务（由 PC 端自动同步）")
        } footer: {
            Text("中继地址与密码在 PC 端配置，手机端配对或同步配置时自动获取；用于远程管理 PC 与访问 PC 指定网卡。")
        }
    }

    private var chainedProxySection: some View {
        Section {
            Toggle("通过已同步链式节点组访问中继", isOn: Binding(
                get: { isChainedRelayEnabled },
                set: { enabled in
                    if enabled, let targetID = selectedChainGroupID {
                        model.relayConfig.defaultRoute = .chainedNodeGroup(targetID)
                    } else {
                        model.relayConfig.defaultRoute = .direct
                    }
                }
            ))
            .disabled(syncedRelayNodeGroups.isEmpty)

            if isChainedRelayEnabled {
                if syncedRelayNodeGroups.isEmpty {
                    Text("PC 端尚未配置链式代理节点组，请先在 PC 端创建并同步。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("链式入口节点组", selection: Binding(
                        get: { selectedChainGroupID ?? syncedRelayNodeGroups[0].id },
                        set: { newID in
                            model.relayConfig.defaultRoute = .chainedNodeGroup(newID)
                        }
                    )) {
                        ForEach(syncedRelayNodeGroups) { group in
                            Text(group.name).tag(group.id)
                        }
                    }
                }
            }
        } header: {
            Text("中继链式入口")
        } footer: {
            Text("开启后，连接中继服务的流量将复用 PC 同步过来的链式代理节点组，无需重复填写代理配置。")
        }
    }

    private var interfaceMappingSection: some View {
        let referenced = model.referencedInterfaceMappings
        return Section {
            if referenced.isEmpty {
                Text("当前同步的规则组未引用任何指定 PC 网卡。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(referenced) { rule in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(rule.bsdName)
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                            if !rule.displayName.isEmpty && rule.displayName != rule.bsdName {
                                Text(rule.displayName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Picker("映射策略", selection: Binding(
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
            }
        } header: {
            Text("规则引用的 PC 网卡（\(referenced.count)）")
        } footer: {
            Text("仅显示规则中实际配置过的 PC 网卡，也可在「节点与规则」页的对应规则组上直接切换。")
        }
    }
}
