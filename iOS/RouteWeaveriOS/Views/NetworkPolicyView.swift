import RoutingCore
import SwiftUI

struct NetworkPolicyView: View {
    @EnvironmentObject private var model: MobileAppModel

    @State private var showingAddSSIDSheet = false
    var embedded: Bool = false

    private enum ModeChoice: String, CaseIterable, Identifiable {
        case localCoreWithChain = "本地内核"
        case localCoreNoChain = "本地内核(跳过链式)"
        case directPCSocks5 = "直连内网 PC SOCKS5"
        case disabled = "禁用 VPN"

        var id: String { rawValue }
    }

    private var ssidRules: [NetworkSwitchRule] {
        model.switchPolicy.rules.filter {
            if case .wifiSSID = $0.condition { return true }
            return false
        }
    }

    private var cellularRule: NetworkSwitchRule? {
        model.switchPolicy.rules.first { $0.condition == .cellular }
    }

    private var anyWiFiRule: NetworkSwitchRule? {
        model.switchPolicy.rules.first { $0.condition == .anyWiFi }
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
                ssidRulesSection
                cellularSection
                otherWiFiSection

                Section {
                    Button {
                        Task { await model.saveAndNotifyTunnel() }
                    } label: {
                        HStack {
                            Spacer()
                            Text("保存并同步系统按需连接 (NEOnDemandRule)")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("网络策略")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddSSIDSheet = true
                    } label: {
                        Label("添加 Wi-Fi", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddSSIDSheet) {
                AddSSIDRuleSheet()
                    .environmentObject(model)
            }
    }

    // MARK: - Sections

    private var ssidRulesSection: some View {
        Section {
            if ssidRules.isEmpty {
                Text("暂无特定 Wi-Fi SSID 规则。可添加家庭或办公 Wi-Fi，命中时自动直连内网 PC SOCKS5。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ssidRules) { rule in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            if case .wifiSSID(let ssid) = rule.condition {
                                Label(ssid, systemImage: "wifi")
                                    .font(.headline)
                            }
                            Spacer()
                            Toggle("", isOn: bindingForRuleEnabled(id: rule.id))
                                .labelsHidden()
                        }

                        Picker("模式", selection: bindingForRuleMode(id: rule.id)) {
                            Text("直连内网 PC SOCKS5").tag(ModeChoice.directPCSocks5)
                            Text("本地内核").tag(ModeChoice.localCoreWithChain)
                            Text("禁用 VPN").tag(ModeChoice.disabled)
                        }
                        .pickerStyle(.menu)

                        if case .directPCSocks5(let host, let port) = rule.mode {
                            HStack {
                                Text("PC 地址")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(host):\(port)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { offsets in
                    let idsToDelete = offsets.map { ssidRules[$0].id }
                    model.switchPolicy.rules.removeAll { idsToDelete.contains($0.id) }
                }
            }

            Button {
                showingAddSSIDSheet = true
            } label: {
                Label("添加 Wi-Fi SSID 规则", systemImage: "plus.circle")
            }
        } header: {
            Text("指定 Wi-Fi SSID 规则")
        } footer: {
            Text("特定 SSID 规则优先级高于「其他 Wi-Fi」与「蜂窝网络」默认规则。")
        }
    }

    private var cellularSection: some View {
        Section {
            Picker("蜂窝网络默认模式", selection: Binding(
                get: { choice(for: cellularRule?.mode ?? .localCore(LocalCoreExecutionOptions())) },
                set: { newChoice in
                    upsertConditionRule(.cellular, name: "蜂窝网络", mode: mode(for: newChoice))
                }
            )) {
                Text("本地内核（启用链式）").tag(ModeChoice.localCoreWithChain)
                Text("本地内核（跳过链式代理）").tag(ModeChoice.localCoreNoChain)
                Text("禁用 VPN").tag(ModeChoice.disabled)
            }
        } header: {
            Text("蜂窝移动网络")
        }
    }

    private var otherWiFiSection: some View {
        Section {
            Picker("其他 Wi-Fi 默认模式", selection: Binding(
                get: { choice(for: anyWiFiRule?.mode ?? model.switchPolicy.defaultMode) },
                set: { newChoice in
                    upsertConditionRule(.anyWiFi, name: "其他 Wi-Fi", mode: mode(for: newChoice))
                }
            )) {
                Text("本地内核").tag(ModeChoice.localCoreWithChain)
                Text("本地内核（跳过链式）").tag(ModeChoice.localCoreNoChain)
                Text("直连内网 PC SOCKS5").tag(ModeChoice.directPCSocks5)
                Text("禁用 VPN").tag(ModeChoice.disabled)
            }
        } header: {
            Text("其他未知 Wi-Fi")
        }
    }

    // MARK: - Helpers

    private func bindingForRuleEnabled(id: UUID) -> Binding<Bool> {
        Binding(
            get: { model.switchPolicy.rules.first(where: { $0.id == id })?.isEnabled ?? true },
            set: { enabled in
                if let idx = model.switchPolicy.rules.firstIndex(where: { $0.id == id }) {
                    model.switchPolicy.rules[idx].isEnabled = enabled
                }
            }
        )
    }

    private func bindingForRuleMode(id: UUID) -> Binding<ModeChoice> {
        Binding(
            get: {
                let ruleMode = model.switchPolicy.rules.first(where: { $0.id == id })?.mode
                    ?? .localCore(LocalCoreExecutionOptions())
                return choice(for: ruleMode)
            },
            set: { newChoice in
                if let idx = model.switchPolicy.rules.firstIndex(where: { $0.id == id }) {
                    model.switchPolicy.rules[idx].mode = mode(for: newChoice)
                }
            }
        )
    }

    private func upsertConditionRule(_ condition: NetworkMatchCondition, name: String, mode: MobileVPNMode) {
        if let idx = model.switchPolicy.rules.firstIndex(where: { $0.condition == condition }) {
            model.switchPolicy.rules[idx].mode = mode
            model.switchPolicy.rules[idx].isEnabled = true
        } else {
            model.switchPolicy.rules.append(
                NetworkSwitchRule(name: name, isEnabled: true, condition: condition, mode: mode)
            )
        }
    }

    private func choice(for mode: MobileVPNMode) -> ModeChoice {
        switch mode {
        case .disabled:
            return .disabled
        case .directPCSocks5:
            return .directPCSocks5
        case .localCore(let opts):
            return opts.bypassChainedProxy ? .localCoreNoChain : .localCoreWithChain
        }
    }

    private func mode(for choice: ModeChoice) -> MobileVPNMode {
        switch choice {
        case .disabled:
            return .disabled
        case .localCoreWithChain:
            return .localCore(LocalCoreExecutionOptions(bypassChainedProxy: false))
        case .localCoreNoChain:
            return .localCore(LocalCoreExecutionOptions(bypassChainedProxy: true))
        case .directPCSocks5:
            let host = model.activeHost?.host ?? "192.168.1.2"
            let port = model.syncedHostState?.profile.mixedPort ?? 7890
            return .directPCSocks5(host: host, port: port)
        }
    }
}

// MARK: - Add SSID Rule Sheet

private struct AddSSIDRuleSheet: View {
    @EnvironmentObject private var model: MobileAppModel
    @Environment(\.dismiss) private var dismiss

    @State private var ssid = ""
    @State private var selectedMode = 0 // 0: directPCSocks5, 1: localCore, 2: disabled
    @State private var pcHost = ""
    @State private var pcPort = "7890"

    var body: some View {
        NavigationStack {
            Form {
                Section("Wi-Fi 名称 (SSID)") {
                    HStack {
                        TextField("输入 Wi-Fi SSID", text: $ssid)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if let currentSSID = model.currentNetworkSnapshot.wifiSSID, !currentSSID.isEmpty {
                            Button("填入当前") {
                                ssid = currentSSID
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        } else {
                            Button("获取当前") {
                                model.requestLocationForSSID()
                            }
                            .font(.caption)
                        }
                    }
                }

                Section("命中策略") {
                    Picker("运行模式", selection: $selectedMode) {
                        Text("直连内网 PC SOCKS5").tag(0)
                        Text("本地内核").tag(1)
                        Text("禁用 VPN").tag(2)
                    }

                    if selectedMode == 0 {
                        TextField("PC 内网 IP", text: $pcHost)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("PC SOCKS5/Mixed 端口", text: $pcPort)
                            .keyboardType(.numberPad)
                    }
                }
            }
            .navigationTitle("添加 Wi-Fi 规则")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if pcHost.isEmpty {
                    pcHost = model.activeHost?.host ?? ""
                }
                if let port = model.syncedHostState?.profile.mixedPort {
                    pcPort = String(port)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("添加") {
                        let trimmedSSID = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
                        let mode: MobileVPNMode
                        switch selectedMode {
                        case 0:
                            let port = Int(pcPort) ?? 7890
                            mode = .directPCSocks5(host: pcHost.trimmingCharacters(in: .whitespacesAndNewlines), port: port)
                        case 2:
                            mode = .disabled
                        default:
                            mode = .localCore(LocalCoreExecutionOptions())
                        }
                        model.switchPolicy.rules.insert(
                            NetworkSwitchRule(name: trimmedSSID, isEnabled: true, condition: .wifiSSID(trimmedSSID), mode: mode),
                            at: 0
                        )
                        dismiss()
                    }
                    .disabled(ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
