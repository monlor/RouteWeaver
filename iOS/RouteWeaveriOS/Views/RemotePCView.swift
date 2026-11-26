import RoutingCore
import SwiftUI

struct RemotePCView: View {
    @EnvironmentObject private var model: MobileAppModel
    @State private var showingPairSheet = false
    var embedded: Bool = false

    var body: some View {
        if embedded {
            contentList
        } else {
            NavigationStack {
                contentList
            }
        }
    }

    private var contentList: some View {
        List {
                if !model.savedHosts.isEmpty {
                    savedHostsSection
                }

                if let host = model.activeHost {
                    remoteDashboardSection(for: host)
                    proxyGroupsSection
                } else {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            Text("尚未配对远程 PC")
                                .font(.headline)
                            Text("点击右上角「配对」粘贴 PC 端导出的配对链接，或通过局域网 Bonjour 自动发现。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("立即配对") {
                                showingPairSheet = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                }
            }
            .navigationTitle("远程 PC")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingPairSheet = true
                    } label: {
                        Label("配对", systemImage: "plus")
                    }
                }
            }
            .refreshable {
                await model.refreshRemoteDashboard()
            }
            .sheet(isPresented: $showingPairSheet) {
                PairRemoteHostSheet()
                    .environmentObject(model)
            }
    }

    // MARK: - Sections

    private var savedHostsSection: some View {
        Section("已配对主机") {
            ForEach(model.savedHosts) { host in
                Button {
                    Task { await model.selectHost(host) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.hostName)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text(host.host.isEmpty ? "仅 Relay 通道" : "\(host.host):\(String(host.port))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.activeHost?.id == host.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    model.removeHost(model.savedHosts[index])
                }
            }
        }
    }

    private func remoteDashboardSection(for host: RemoteSavedHost) -> some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(host.hostName)
                        .font(.headline)
                    if let snap = model.remoteSnapshot {
                        Text(snap.status.phaseTitle)
                            .font(.caption)
                            .foregroundStyle(snap.status.isRunning ? .green : .secondary)
                    } else {
                        Text("正在等待数据或未连接")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(model.isConnectedViaRelay ? "中继远程" : "局域网直连")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        (model.isConnectedViaRelay ? Color.purple : Color.green).opacity(0.15),
                        in: Capsule()
                    )
                    .foregroundStyle(model.isConnectedViaRelay ? .purple : .green)
            }

            if let status = model.remoteSnapshot?.status {
                HStack {
                    Label("\(TrafficFormatter.bytes(status.uploadSpeed))/s", systemImage: "arrow.up")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Label("\(TrafficFormatter.bytes(status.downloadSpeed))/s", systemImage: "arrow.down")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline.monospacedDigit())
            }

            let remoteIsRunning = model.remoteSnapshot?.status.isRunning ?? false
            let remoteIsBusy = model.remoteSnapshot?.status.isBusy ?? false
            let hasRemoteStatus = model.remoteSnapshot != nil

            HStack(spacing: 10) {
                remoteControlTile(title: "启动", icon: "play.fill", tint: .green) {
                    Task { await model.startRemotePC() }
                }
                .disabled(remoteIsRunning || remoteIsBusy)
                .opacity((remoteIsRunning || remoteIsBusy) ? 0.45 : 1)

                remoteControlTile(title: "停止", icon: "stop.fill", tint: .red) {
                    Task { await model.stopRemotePC() }
                }
                .disabled(hasRemoteStatus && !remoteIsRunning && !remoteIsBusy)
                .opacity((hasRemoteStatus && !remoteIsRunning && !remoteIsBusy) ? 0.45 : 1)

                remoteControlTile(title: "热重载", icon: "arrow.clockwise", tint: .blue) {
                    Task { await model.hotReloadRemotePC() }
                }
                .disabled((hasRemoteStatus && !remoteIsRunning) || remoteIsBusy)
                .opacity(((hasRemoteStatus && !remoteIsRunning) || remoteIsBusy) ? 0.45 : 1)
            }
            .disabled(model.isBusy)

            Button {
                Task { await model.syncNow() }
            } label: {
                HStack {
                    Label("同步 PC 配置到本机", systemImage: "square.and.arrow.down")
                    Spacer()
                    if model.isSyncing {
                        ProgressView()
                    }
                }
            }
            .disabled(model.isSyncing)
        } header: {
            Text("主机控制台")
        }
    }

    @ViewBuilder
    private var proxyGroupsSection: some View {
        if let groups = model.remoteSnapshot?.proxies, !groups.isEmpty {
            Section("PC 代理节点组") {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(group.name)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Button("测速") {
                                Task { await model.testRemoteDelay(group: group.name) }
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        }

                        if !group.all.isEmpty {
                            Picker("当前节点", selection: Binding(
                                get: { group.now },
                                set: { newNode in
                                    Task {
                                        await model.selectRemoteProxy(group: group.name, node: newNode)
                                    }
                                }
                            )) {
                                ForEach(group.all, id: \.self) { node in
                                    HStack {
                                        Text(node)
                                        if let delay = group.delays[node], delay > 0 {
                                            Text("(\(delay) ms)")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .tag(node)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func remoteControlTile(title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pair Sheet

private struct PairRemoteHostSheet: View {
    @EnvironmentObject private var model: MobileAppModel
    @Environment(\.dismiss) private var dismiss

    @State private var bundleText = ""
    @State private var manualHost = ""
    @State private var manualPort = String(RemoteControlProtocol.defaultPort)
    @State private var pairingCode = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("粘贴 routeweaver://pair/... 链接", text: $bundleText, axis: .vertical)
                        .lineLimit(3...6)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("一键导入配对") {
                        Task {
                            await model.importPairingBundle(bundleText)
                            if model.lastError == nil {
                                dismiss()
                            }
                        }
                    }
                    .disabled(bundleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                } header: {
                    Text("一键导入配对包")
                } footer: {
                    Text("将自动同步局域网管理、PC SOCKS5 端口与中继连接信息。")
                }

                Section("局域网自动发现 (Bonjour)") {
                    if model.discoveredHosts.isEmpty {
                        HStack {
                            ProgressView()
                            Text("正在扫描 _routeweaver._tcp …")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(model.discoveredHosts) { device in
                            Button {
                                manualHost = device.ips.first ?? ""
                                manualPort = String(device.port)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.name)
                                            .foregroundStyle(.primary)
                                        Text("\(device.ips.joined(separator: ", ")) :\(String(device.port))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("填入")
                                        .font(.caption)
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }

                Section("手动配对") {
                    TextField("PC 局域网 IP", text: $manualHost)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("端口", text: $manualPort)
                        .keyboardType(.numberPad)
                    TextField("6 位配对码", text: $pairingCode)
                        .keyboardType(.numberPad)

                    Button("连接并配对") {
                        let port = UInt16(manualPort) ?? RemoteControlProtocol.defaultPort
                        Task {
                            await model.pairManualHost(host: manualHost, port: port, pairingCode: pairingCode)
                            if model.lastError == nil {
                                dismiss()
                            }
                        }
                    }
                    .disabled(
                        manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.isBusy
                    )
                }

                if let error = model.lastError {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("配对新 PC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
