import RoutingCore
import SwiftUI

struct SettingsCoreView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if state.hasPendingHotReload {
                    HStack(spacing: 10) {
                        InlineNote("部分配置已修改，点击「热重载生效」即可在不重启核心的情况下应用。")
                        Spacer()
                        Button("热重载生效") { state.hotReload() }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .disabled(state.isHotReloading || state.configValidationError != nil)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.10)))
                }
                startupCard
                tunModeCard
                killSwitchCard
                gatewayModeCard
                proxyListenerCard
                profileStorageCard
                coreBinaryCard
                EngineLogCardView(state: state, logStore: state.engine.logStore)
            }
            .padding(20)
        }
        .onAppear {
            state.refreshLaunchAtLoginStatus()
            state.refreshKillSwitchStatus()
        }
    }

    private var startupCard: some View {
        SectionCard("启动与自动化", icon: "power.circle") {
            HStack(spacing: 8) {
                if state.engine.isLaunchdManaged {
                    StatusPill(
                        state.engine.launchdRestartCount > 0
                            ? "launchd 守护中（已自愈 \(state.engine.launchdRestartCount) 次）"
                            : "launchd 守护中",
                        systemImage: "shield.checkered",
                        color: .green
                    )
                }
                StatusPill(
                    state.launchAtLoginStatus.title,
                    systemImage: state.launchAtLoginStatus.isEnabled ? "checkmark.circle.fill" : "circle",
                    color: state.launchAtLoginStatus == .requiresApproval
                        ? .orange
                        : (state.launchAtLoginStatus.isEnabled ? .green : .secondary)
                )
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                FormRow("开机自动启动", labelWidth: 168) {
                    HStack(spacing: 8) {
                        Toggle(
                            "登录 macOS 时自动运行 RouteWeaver",
                            isOn: Binding(
                                get: { state.launchAtLoginStatus.isEnabled },
                                set: { state.setLaunchAtLogin($0) }
                            )
                        )
                        Spacer()
                        if state.launchAtLoginStatus == .requiresApproval {
                            Button("打开登录项设置") {
                                state.openLoginItemsSettings()
                            }
                            .controlSize(.small)
                        }
                    }
                }

                FormRow("自动启动核心", labelWidth: 168) {
                    Toggle("打开应用时自动启动 Mihomo 核心（开机后会自动等待网卡就绪）", isOn: $state.autoStartCoreOnLaunch)
                }

                FormRow("系统级进程保活", labelWidth: 168) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("通过 macOS launchd 守护 Mihomo 核心（崩溃或被意外终止时自动拉起）", isOn: $state.systemKeepAliveEnabled)
                            .disabled(state.editingLocked)
                        InlineNote("普通模式注册用户级 LaunchAgent，TUN / 网关模式注册系统级 LaunchDaemon；即使退出 RouteWeaver 界面仍持续保活，手动停止核心时会自动卸载服务。")
                    }
                }

                FormRow("说明", labelWidth: 168) {
                    InlineNote(state.launchAtLoginStatus.detail + " 若已开启并授权 TUN 模式，开机自启核心无需重复输入管理员密码。")
                }
            }
        }
    }

    private var tunModeCard: some View {
        SectionCard("TUN 透明代理模式", icon: "shield.lefthalf.filled") {
            StatusPill(
                state.tunPermissionStatus.title,
                systemImage: state.tunPermissionStatus.isReady ? "checkmark.shield.fill" : "exclamationmark.shield",
                color: tunStatusColor
            )
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                FormRow("启用 TUN 模式", labelWidth: 168) {
                    Toggle(
                        "接管全系统 TCP / UDP 流量（utun 虚拟网卡）",
                        isOn: Binding(
                            get: { state.profile.tunEnabled },
                            set: { state.setTunEnabled($0) }
                        )
                    )
                    .disabled(state.editingLocked)
                }

                FormRow("管理员授权状态", labelWidth: 168) {
                    HStack(spacing: 8) {
                        InlineNote(state.tunPermissionStatus.detail)
                        Spacer()
                        if state.isAuthorizingTun {
                            ProgressView().controlSize(.small)
                        }
                        if state.tunPermissionStatus == .ready {
                            Button("重新同步") { state.authorizeTun() }
                                .controlSize(.small)
                                .disabled(state.engine.isBusy || state.isAuthorizingTun || state.binary == nil)
                                .help(state.engine.isRunning ? "将先停止核心，同步授权后自动重启" : "重新同步受信任的内核副本")
                            Button("撤销授权") { state.revokeTunAuthorization() }
                                .controlSize(.small)
                                .disabled(state.editingLocked || state.isAuthorizingTun)
                        } else if state.tunPermissionStatus != .helperMissing {
                            Button(state.tunPermissionStatus == .needsSync ? "重新授权" : "授权 TUN 权限") {
                                state.authorizeTun()
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .disabled(state.engine.isBusy || state.isAuthorizingTun || state.binary == nil)
                            .help(state.engine.isRunning ? "将先停止核心，完成管理员授权后自动重启" : "授予管理员权限以同步 TUN 组件")
                        }
                    }
                }

                if state.profile.tunEnabled {
                    Divider()

                    FormRow("协议栈 (stack)", labelWidth: 168) {
                        Picker("", selection: $state.profile.tunStack) {
                            ForEach(TunStack.allCases) { stack in
                                Text(stack.title).tag(stack)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                        .disabled(state.hotReloadEditingLocked)
                        InlineNote(state.profile.tunStack.subtitle)
                    }

                    FormRow("DNS 增强模式", labelWidth: 168) {
                        Picker("", selection: $state.profile.tunDNSMode) {
                            ForEach(TunDNSMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                        .disabled(state.hotReloadEditingLocked)
                        InlineNote(state.profile.tunDNSMode.subtitle)
                    }

                    FormRow("严格路由 (strict-route)", labelWidth: 168) {
                        Toggle("阻止绕过 TUN 的流量与 DNS 泄漏", isOn: $state.profile.tunStrictRoute)
                            .disabled(state.hotReloadEditingLocked)
                    }

                    FormRow("默认能力", labelWidth: 168) {
                        InlineNote("已自动开启 auto-route、auto-detect-interface、dns-hijack（any:53）与 TLS/HTTP/QUIC 域名嗅探。")
                    }
                }
            }
        }
    }

    private var tunStatusColor: Color {
        switch state.tunPermissionStatus {
        case .ready: return .green
        case .needsSync: return .orange
        case .notAuthorized: return .secondary
        case .helperMissing: return .red
        }
    }

    private var killSwitchCard: some View {
        SectionCard("断网保护（Kill Switch）", icon: "lock.shield") {
            HStack(spacing: 8) {
                if state.isUpdatingKillSwitch {
                    ProgressView().controlSize(.small)
                }
                StatusPill(
                    state.killSwitchActive ? "已开启防泄漏" : "未开启",
                    systemImage: state.killSwitchActive ? "lock.shield.fill" : "shield.slash",
                    color: state.killSwitchActive ? .red : .secondary
                )
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                FormRow("启用断网保护", labelWidth: 168) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(
                            "核心未启动或重启/重载瞬间，内核级阻断物理网卡外网流量",
                            isOn: Binding(
                                get: { state.killSwitchActive },
                                set: { state.setKillSwitchEnabled($0) }
                            )
                        )
                        .disabled(state.isUpdatingKillSwitch || state.isAuthorizingTun)
                        InlineNote("基于 macOS 原生 PF 防火墙独立 Anchor（\(KillSwitchRules.anchorName)），仅放行回环、utun 虚拟网卡与受信任的 TUN Mihomo 进程本身；重新授权、热重载重建 utun 或核心异常退出期间绝不回落国内默认网卡。")
                    }
                }

                if state.killSwitchActive && !state.engine.isRunning {
                    FormRow("", labelWidth: 168) {
                        InlineValidationMessage("当前核心未运行且断网保护已开启：本机外网（包括应用内订阅刷新与更新检查）均已被阻断。请启动 TUN 核心或关闭断网保护。", isError: true)
                    }
                }

                if !state.profile.effectiveTunEnabled {
                    FormRow("", labelWidth: 168) {
                        InlineNote("提示：断网保护仅放行 TUN 模式下以受信任辅助组件启动的核心进程；普通混合代理模式下开启断网保护会导致核心自身也无法联网。")
                    }
                }

                Divider()

                FormRow("放行局域网通信", labelWidth: 168) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(
                            "允许访问局域网私有网段（192.168.x.x / 10.x.x.x / 172.16.x.x）",
                            isOn: Binding(
                                get: { state.killSwitchAllowLAN },
                                set: { state.setKillSwitchAllowLAN($0) }
                            )
                        )
                        .disabled(state.isUpdatingKillSwitch)
                        InlineNote("开启后可正常访问路由器、NAS、内网 SSH 及使用局域网网关模式，同时仍会强制拦截非核心进程发往局域网 53 端口的 DNS 泄漏；关闭后仅保留 DHCP 租约通信。")
                    }
                }

                FormRow("开机自动生效", labelWidth: 168) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(
                            "系统启动登录前即加载断网保护规则（防开机瞬间泄漏）",
                            isOn: Binding(
                                get: { state.killSwitchPersistOnBoot },
                                set: { state.setKillSwitchPersistOnBoot($0) }
                            )
                        )
                        .disabled(state.isUpdatingKillSwitch)
                        InlineNote("建议配合上方「开机自动启动」与「自动启动核心」一起开启；关闭断网保护时会自动清理开机守护。")
                    }
                }

                FormRow("应急恢复命令", labelWidth: 168) {
                    HStack(spacing: 8) {
                        Text(KillSwitchRules.emergencyResetCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.10)))
                        Spacer()
                        Button("复制命令") {
                            state.copyText(KillSwitchRules.emergencyResetCommand, label: "PF 应急恢复命令")
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var gatewayModeCard: some View {
        SectionCard("局域网网关模式（旁路由）", icon: "wifi.router") {
            HStack(spacing: 8) {
                if state.profile.gatewayModeEnabled {
                    StatusPill(
                        state.isIPForwardingEnabled ? "IP 转发已开启" : "IP 转发待启动",
                        systemImage: state.isIPForwardingEnabled ? "arrow.triangle.branch" : "clock",
                        color: state.isIPForwardingEnabled ? .teal : .secondary
                    )
                }
                StatusPill(
                    state.engine.isGatewayActive ? "网关运行中" : (state.profile.gatewayModeEnabled ? "已启用" : "未启用"),
                    systemImage: state.engine.isGatewayActive ? "checkmark.circle.fill" : "circle",
                    color: state.engine.isGatewayActive ? .teal : (state.profile.gatewayModeEnabled ? .cyan : .secondary)
                )
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                FormRow("启用网关模式", labelWidth: 168) {
                    Toggle(
                        "作为局域网透明网关（自动启用 TUN、监听 DNS 0.0.0.0:53 与内核 IP 转发）",
                        isOn: Binding(
                            get: { state.profile.gatewayModeEnabled },
                            set: { state.setGatewayModeEnabled($0) }
                        )
                    )
                    .disabled(state.editingLocked)
                }

                FormRow("工作原理", labelWidth: 168) {
                    InlineNote("启动核心时将通过已授权的 root 辅助组件开启 net.inet.ip.forwarding、关闭 ICMP 重定向，并由 Mihomo 监听 0.0.0.0:53 处理局域网 DNS 及开启 Endpoint-Independent NAT；停止核心时自动恢复系统原值。")
                }

                if state.profile.gatewayModeEnabled {
                    Divider()

                    FormRow("局域网接入参数", labelWidth: 168) {
                        VStack(alignment: .leading, spacing: 8) {
                            if state.activeLANInterfaces.isEmpty {
                                InlineNote("当前未检测到活跃局域网 IPv4 地址，请检查 Wi-Fi 或有线网络连接。")
                            } else {
                                ForEach(state.activeLANInterfaces) { info in
                                    if let ip = info.ipv4Address {
                                        HStack(spacing: 10) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(info.shortLabel)
                                                    .font(.caption.weight(.medium))
                                                    .foregroundStyle(.secondary)
                                                HStack(spacing: 8) {
                                                    Text("网关 / 路由器：\(ip)")
                                                        .font(.system(.caption, design: .monospaced))
                                                        .textSelection(.enabled)
                                                    Text("DNS：\(ip)")
                                                        .font(.system(.caption, design: .monospaced))
                                                        .textSelection(.enabled)
                                                    if let mask = info.ipv4Netmask {
                                                        Text("子网掩码：\(mask)")
                                                            .font(.system(.caption, design: .monospaced))
                                                            .foregroundStyle(.secondary)
                                                            .textSelection(.enabled)
                                                    }
                                                }
                                            }
                                            Spacer()
                                            Button("复制配置") {
                                                state.copyGatewaySetup(for: info)
                                            }
                                            .controlSize(.mini)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.teal.opacity(0.07)))
                    }

                    FormRow("使用建议", labelWidth: 168) {
                        InlineNote("1. 建议在路由器 DHCP 或本机「系统设置 → 网络」中为 Mac 固定局域网 IP；2. 将手机、Apple TV、游戏机等设备的「路由器/网关」和「DNS」设为上述 IP；3. 若本机开启了 macOS 互联网共享等占用 53 端口的服务，请先关闭。")
                    }
                }
            }
        }
    }

    private var proxyListenerCard: some View {
        SectionCard("代理端口与局域网暴露", icon: "network") {
            VStack(alignment: .leading, spacing: 12) {
                FormRow("HTTP / SOCKS5 混合端口", labelWidth: 168) {
                    TextField("7890", value: $state.profile.mixedPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                        .disabled(state.hotReloadEditingLocked)
                    InlineNote("单个端口同时支持 HTTP 与 SOCKS5 协议")
                }

                FormRow("允许局域网连接", labelWidth: 168) {
                    Toggle("向局域网暴露代理端口 (allow-lan)", isOn: $state.profile.allowLAN)
                        .disabled(state.hotReloadEditingLocked)
                }

                FormRow("IPv6 支持", labelWidth: 168) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("启用 IPv6 解析与出站（关闭可屏蔽 AAAA 记录）", isOn: $state.profile.ipv6Enabled)
                            .disabled(state.hotReloadEditingLocked)
                        InlineNote("若代理节点不支持 IPv6 或 UDP 丢包，建议保持关闭以避免 WebRTC 与网页访问超时；局域网网关模式目前仅支持 IPv4。")
                    }
                }

                if state.profile.allowLAN {
                    VStack(alignment: .leading, spacing: 6) {
                        if state.lanIPAddresses.isEmpty {
                            InlineNote("当前未检测到局域网 IPv4 地址。")
                        } else {
                            ForEach(state.lanIPAddresses, id: \.self) { ip in
                                HStack(spacing: 10) {
                                    Text("HTTP: http://\(ip):\(state.profile.httpPort ?? state.profile.mixedPort)")
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                    Text("SOCKS5: socks5://\(ip):\(state.profile.socksPort ?? state.profile.mixedPort)")
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                    Spacer()
                                    Button("复制") {
                                        state.copyText("\(ip):\(state.profile.mixedPort)", label: "局域网地址")
                                    }
                                    .controlSize(.mini)
                                }
                            }
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.06)))
                }

                Divider()

                FormRow("独立 HTTP 端口（可选）", labelWidth: 168) {
                    TextField(
                        "留空则共用混合端口",
                        text: Binding(
                            get: { state.profile.httpPort.map(String.init) ?? "" },
                            set: { raw in
                                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                                state.profile.httpPort = trimmed.isEmpty ? nil : Int(trimmed)
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .disabled(state.hotReloadEditingLocked)
                }

                FormRow("独立 SOCKS5 端口（可选）", labelWidth: 168) {
                    TextField(
                        "留空则共用混合端口",
                        text: Binding(
                            get: { state.profile.socksPort.map(String.init) ?? "" },
                            set: { raw in
                                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                                state.profile.socksPort = trimmed.isEmpty ? nil : Int(trimmed)
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .disabled(state.hotReloadEditingLocked)
                }

                Divider()

                FormRow("在线规则自动更新周期", labelWidth: 168) {
                    Picker("", selection: $state.profile.ruleSetUpdateIntervalHours) {
                        Text("每 6 小时").tag(6)
                        Text("每 12 小时").tag(12)
                        Text("每 24 小时（推荐）").tag(24)
                        Text("每 72 小时").tag(72)
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .disabled(state.hotReloadEditingLocked)
                    InlineNote("适用于所有 ACL4SSR / 远程规则集 (rule-providers)")
                }

                FormRow("规则集下载网络策略", labelWidth: 168) {
                    Picker("", selection: $state.profile.ruleProviderProxyMode) {
                        Text("自动（GitHub 走代理，其余直连）").tag(RuleProviderProxyMode.auto)
                        Text("始终直连 (DIRECT)").tag(RuleProviderProxyMode.direct)
                        if !state.profile.targets.isEmpty {
                            Divider()
                            ForEach(state.profile.targets) { target in
                                Text("指定目标：\(target.name)").tag(RuleProviderProxyMode.target(target.id))
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                    .disabled(state.hotReloadEditingLocked)
                    InlineNote("订阅节点 (proxy-providers) 始终直连以防循环依赖")
                }
            }
        }
    }

    private var profileStorageCard: some View {
        SectionCard("配置存储与同步", icon: "folder") {
            HStack(spacing: 8) {
                Button("重新加载") { state.reloadProfileFromDisk() }
                    .controlSize(.small)
                    .disabled(state.editingLocked)
                Button("在访达中显示") { state.revealProfileDirectory() }
                    .controlSize(.small)
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                FormRow("配置保存目录", labelWidth: 128) {
                    HStack(spacing: 8) {
                        Text(state.activeProfileDirectory.path)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(state.activeProfileDirectory.path)
                        Spacer()
                        if state.isUsingCustomProfileDirectory {
                            Button("恢复默认") { state.resetProfileDirectory() }
                                .disabled(state.editingLocked)
                        }
                        Button("选择目录…") { state.chooseProfileDirectory() }
                            .disabled(state.editingLocked)
                    }
                }

                FormRow("同步说明", labelWidth: 128) {
                    InlineNote(
                        state.isUsingCustomProfileDirectory
                        ? "当前使用自定义目录保存 \(ProfileStore.fileName)，可配合 iCloud Drive 等云盘在多台 Mac 间同步配置。"
                        : "当前保存在本机默认目录。可选择 iCloud Drive 文件夹以跨设备同步 \(ProfileStore.fileName)。"
                    )
                }
            }
        }
    }

    private var coreBinaryCard: some View {
        CoreBinaryCardView(state: state, coreStore: state.coreBinaryStore)
    }
}

private struct CoreBinaryCardView: View {
    @ObservedObject var state: AppState
    @ObservedObject var coreStore: CoreBinaryStore

    var body: some View {
        SectionCard("Mihomo 内核与方案", icon: "cpu") {
            HStack(spacing: 8) {
                Button("导入方案…") { state.importProfile() }
                    .controlSize(.small)
                    .disabled(state.editingLocked)
                Button("保存方案…") { state.saveProfile() }
                    .controlSize(.small)
                Button("导出 YAML…") { state.exportConfig() }
                    .controlSize(.small)
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                FormRow("当前内核状态", labelWidth: 128) {
                    HStack(spacing: 8) {
                        StatusPill(
                            coreStore.source.title,
                            systemImage: coreStore.binary == nil ? "exclamationmark.triangle" : "cpu",
                            color: binarySourceColor
                        )
                        if let version = coreStore.version {
                            StatusPill(version, color: .secondary)
                        }
                        Text(CoreBinaryStore.currentArchitecture)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)

                        Spacer()

                        if coreStore.isCheckingUpdate || coreStore.isUpdating {
                            ProgressView()
                                .controlSize(.small)
                        }

                        if coreStore.hasNewerVersion, let tag = coreStore.latestRelease?.tagName {
                            Button(coreStore.binary == nil ? "下载 \(tag)" : "更新到 \(tag)") {
                                state.installCoreUpdate()
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .disabled(coreStore.isUpdating || coreStore.isCheckingUpdate)
                        } else {
                            Button(coreStore.binary == nil ? "检查并下载内核" : "检查更新") {
                                state.checkForCoreUpdate()
                            }
                            .controlSize(.small)
                            .disabled(coreStore.isCheckingUpdate || coreStore.isUpdating)
                        }

                        if coreStore.canResetToBundled {
                            Button("恢复内置") {
                                state.resetToBundledCore()
                            }
                            .controlSize(.small)
                            .disabled(state.editingLocked || coreStore.isUpdating)
                        }
                    }
                }

                if let msg = coreStore.updateMessage {
                    FormRow("", labelWidth: 128) {
                        HStack(spacing: 8) {
                            InlineValidationMessage(msg, isError: false)
                            if coreStore.pendingRestart && state.engine.isRunning {
                                Button("停止并应用") {
                                    state.stop()
                                }
                                .controlSize(.mini)
                            }
                        }
                    }
                }

                if let err = coreStore.updateError {
                    FormRow("", labelWidth: 128) {
                        InlineValidationMessage(err, isError: true)
                    }
                }

                FormRow("本机控制端口", labelWidth: 128) {
                    TextField("19090", value: $state.controllerPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                        .disabled(state.editingLocked)
                    InlineNote("仅绑定 127.0.0.1，不会暴露到局域网")
                }

                FormRow("Geo 路由数据库", labelWidth: 128) {
                    HStack(spacing: 8) {
                        InlineNote("已内置 Country.mmdb 与 geosite.dat，首次启动离线可用；更新校验失败自动保留旧版")
                        Spacer()
                        if state.updatingGeoResources {
                            ProgressView().controlSize(.small)
                        }
                        Button("更新 Geo 数据库") {
                            state.updateGeoResources()
                        }
                        .controlSize(.small)
                        .disabled(state.updatingGeoResources)
                    }
                }

                if let geoMsg = state.geoUpdateMessage {
                    FormRow("", labelWidth: 128) {
                        InlineValidationMessage(geoMsg, isError: geoMsg.contains("失败") && !geoMsg.contains("保留"))
                    }
                }

                if let err = state.configValidationError {
                    InlineValidationMessage(err, isError: true)
                }
            }
        }
    }

    private var binarySourceColor: Color {
        switch coreStore.source {
        case .bundled: return .green
        case .managed: return .blue
        case .system: return .teal
        case .none: return .orange
        }
    }
}

private struct EngineLogCardView: View {
    @ObservedObject var state: AppState
    @ObservedObject var logStore: EngineLogStore

    var body: some View {
        SectionCard("运行日志", icon: "terminal") {
            HStack(spacing: 8) {
                Picker("日志级别", selection: $state.profile.logLevel) {
                    ForEach(MihomoLogLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 165)
                .disabled(state.hotReloadEditingLocked)
                .help("选择 Debug 可输出完整 [DNS] 解析日志；运行中修改后点击顶部「热重载」即可生效")

                Button("校验配置") { state.validate() }
                    .controlSize(.small)
                    .disabled(state.editingLocked || state.binary == nil)
                Button("复制日志") {
                    state.copyText(logStore.text, label: "运行日志")
                }
                .controlSize(.small)
                .disabled(logStore.isEmpty)
                Button("清空") { state.engine.clearLog() }
                    .controlSize(.small)
                    .disabled(logStore.isEmpty)
            }
        } content: {
            ScrollView {
                Text(logStore.isEmpty ? "暂无日志输出。点击「校验配置」或「启动核心」查看 Mihomo 日志。" : logStore.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(logStore.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(minHeight: 180, maxHeight: 300)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
        }
    }
}
