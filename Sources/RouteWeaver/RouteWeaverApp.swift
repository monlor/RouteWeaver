import AppKit
import RoutingCore
import SwiftUI
import SystemConfiguration
import UniformTypeIdentifiers

@main
@MainActor
struct RouteWeaverApp: App {
    var body: some Scene {
        Window("RouteWeaver · 分流网络管理", id: "main") {
            RouteWeaverView()
                .frame(minWidth: 780, minHeight: 700)
        }
        .defaultSize(width: 900, height: 840)
    }
}

@MainActor
private struct RouteWeaverView: View {
    @StateObject private var engine = EngineController()
    @State private var profile = RoutingProfile.template(.dualUplink)
    @State private var interfaceNames: [String] = []
    @State private var interfaceLabels: [String: String] = [:]
    @State private var binary: URL?
    @State private var showSubscriptionURLs = false
    @State private var controllerPort = 19090
    @State private var controller: LocalController?
    @State private var groupStatus: [String: LocalController.ProxyGroup] = [:]
    @State private var groupSelection: [String: String] = [:]
    @State private var readsGroups = false
    @State private var alertText: String?
    @State private var feedback = ""

    private var unified: Bool { profile.useDomesticInterfaceForClaude }
    private var templateSelection: Binding<RoutingTemplate> {
        Binding(
            get: { profile.socialUsesGroupB ? .googleOnlyA : (unified ? .unifiedUplink : .dualUplink) },
            set: updateTemplate
        )
    }
    private var resolvedProfile: RoutingProfile {
        var config = profile
        if config.entryProviderURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            config.entryProviderURL = config.exitProviderURL
        }
        return config
    }
    private var editingLocked: Bool { engine.isRunning || engine.isBusy }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    configuration
                        .disabled(editingLocked)
                    groupControls
                    diagnostics
                }
                .padding(20)
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
            }
            Divider()
            actions
        }
        .onAppear(perform: refreshInterfaces)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            engine.terminateForAppExit()
        }
        .onDisappear { engine.stop() }
        .onChange(of: engine.isRunning) { running in
            if !running { resetActiveGroups() }
        }
        .onChange(of: engine.isBusy) { busy in
            if !busy && !engine.isRunning { resetActiveGroups() }
        }
        .alert("操作未完成", isPresented: Binding(
            get: { alertText != nil },
            set: { if !$0 { alertText = nil } }
        )) {
            Button("关闭", role: .cancel) { alertText = nil }
        } message: {
            Text(alertText ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 31))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("RouteWeaver").font(.title2.bold())
                Text("基于 Mihomo 的 macOS 分流管理")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(
                engine.isRunning ? "核心进程运行中" : (engine.isBusy ? "核心处理中" : "核心未运行"),
                systemImage: engine.isRunning ? "checkmark.circle.fill" : (engine.isBusy ? "hourglass" : "stop.circle")
            )
            .foregroundStyle(engine.isRunning ? Color.green : Color.secondary)
        }
        .padding(20)
    }

    private var configuration: some View {
        VStack(spacing: 14) {
            card("1. 规则模板与直连网卡", icon: "point.topleft.down.to.point.bottomright.curvepath") {
                row("内置模板") {
                    Picker("内置模板", selection: templateSelection) {
                        Text("双出口：Claude 单独使用 USB 网卡").tag(RoutingTemplate.dualUplink)
                        Text("单出口：Claude 与国内流量共用网卡").tag(RoutingTemplate.unifiedUplink)
                        Text("双出口：仅 Google / YouTube 使用 A").tag(RoutingTemplate.googleOnlyA)
                    }
                    .labelsHidden()
                }
                if !unified {
                    row("Claude 的 USB 网卡") {
                        interfacePicker("Claude 的 USB 网卡", selection: $profile.claudeInterface)
                    }
                }
                row(unified ? "直连网卡" : "国内的网线 / Wi-Fi") {
                    HStack {
                        interfacePicker("国内或共用的直连网卡", selection: domesticSelection)
                        Button("刷新网卡列表", action: refreshInterfaces)
                    }
                }
                HStack {
                    Button("打开方案…", action: importProfile)
                    Button("保存方案…", action: saveProfile)
                        .help("仅按需保存，并包含完整订阅地址。")
                }
                note(unified
                     ? "Claude 与国内规则仍分别匹配，但直连时绑定到同一张网卡。"
                     : "请选择 USB 网卡对应的接口，如 en7；国内流量绑定至另一张网线或 Wi-Fi 网卡。")
            }

            card("2. 订阅和节点组", icon: "point.3.filled.connected.trianglepath.dotted") {
                row("出口节点订阅") {
                    subscriptionField("A / B 节点订阅 URL", value: $profile.exitProviderURL)
                }
                row("前置 L 订阅（可选）") {
                    subscriptionField("留空与 A / B 使用同一订阅", value: $profile.entryProviderURL)
                }
                Toggle("显示订阅地址", isOn: $showSubscriptionURLs)
                note("需要 Mihomo proxy-provider 格式的 HTTPS 订阅。共用订阅时，L 必须配置能将其与 A/B 区分开的正则。留空仅表示共用来源，不表示省略 L。")
                Divider()
                groupRow("前置 L", pattern: $profile.entryPattern, auto: $profile.entryAutoTest)
                groupRow(profile.socialUsesGroupB ? "出口 A · Google" : "出口 A · Google / 社交", pattern: $profile.groupAPattern, auto: $profile.groupAAutoTest)
                groupRow(profile.socialUsesGroupB ? "出口 B · 社交 / 默认" : "出口 B · 默认", pattern: $profile.groupBPattern, auto: $profile.groupBAutoTest)
                note("客户端 → L → A 或 B → 目标。A/B 的测速同样按已配置的链路进行。关闭自动测速时，可以在核心启动后手选节点。")
            }

            card("3. Mihomo 核心与本地入口", icon: "terminal") {
                row("核心可执行文件") {
                    HStack {
                        Text(binary?.path ?? "未选择 Mihomo")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("选择文件…", action: chooseBinary)
                    }
                }
                row("HTTP / SOCKS 混合端口") {
                    Text("127.0.0.1")
                        .font(.system(.body, design: .monospaced))
                    TextField("混合端口", value: $profile.mixedPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 85)
                }
                row("本机控制端口") {
                    Text("127.0.0.1")
                        .font(.system(.body, design: .monospaced))
                    TextField("本机控制端口", value: $controllerPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 85)
                }
                Button("复制本地代理地址") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString("127.0.0.1:\(profile.mixedPort)", forType: .string)
                    feedback = "已复制代理地址"
                }
                note("应用只启动本机 HTTP/SOCKS5 代理，不自动修改 macOS 系统代理或开启 TUN。请在客户端填写上面的地址；未使用该代理的应用和 UDP 流量不保证经由这些规则。")
            }
        }
    }

    private var domesticSelection: Binding<String> {
        Binding(
            get: { profile.domesticInterface },
            set: { name in
                profile.domesticInterface = name
            }
        )
    }

    private var groupControls: some View {
        card("实时节点选择", icon: "arrow.triangle.branch") {
            HStack {
                note("刷新后查看每组当前节点。自动测速组只显示结果，手选组可修改节点。")
                Spacer()
                Button("刷新节点", action: refreshGroups)
                    .disabled(!engine.isRunning || controller == nil || readsGroups)
            }
            if !engine.isRunning {
                note("启动核心后可查看节点。")
            } else if groupStatus.isEmpty {
                note("没有节点数据，请等待核心加载订阅后刷新。")
            } else {
                liveGroup("前置 L", name: LocalController.entryGroup, auto: profile.entryAutoTest)
                liveGroup("出口 A", name: LocalController.aGroup, auto: profile.groupAAutoTest)
                liveGroup("出口 B", name: LocalController.bGroup, auto: profile.groupBAutoTest)
            }
        }
    }

    private func liveGroup(_ title: String, name: String, auto: Bool) -> some View {
        row(title) {
            if let group = groupStatus[name], !group.all.isEmpty {
                if auto {
                    Text(group.now.isEmpty ? "测速中" : group.now).foregroundStyle(.secondary)
                } else {
                    Picker("\(title) 节点", selection: Binding(
                        get: { groupSelection[name] ?? "" },
                        set: { groupSelection[name] = $0 }
                    )) {
                        Text("请选择").tag("")
                        ForEach(group.all, id: \.self) { node in
                            Text(node).tag(node)
                        }
                    }
                    .labelsHidden()
                    .disabled(readsGroups)
                    Button("应用") {
                        setGroup(name)
                    }
                    .disabled(readsGroups || !(group.all.contains(groupSelection[name] ?? "")))
                    Text(group.now.isEmpty ? "尚未选择" : "当前：\(group.now)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text("未匹配到节点").foregroundStyle(.secondary)
            }
        }
    }

    private func resetActiveGroups() {
        controller = nil
        groupStatus = [:]
        groupSelection = [:]
        readsGroups = false
    }

    private func reloadGroups(_ active: LocalController) async throws {
        let values = try await active.groups()
        guard controller == active, engine.isRunning else { return }
        groupStatus = values
        for (key, group) in values {
            groupSelection[key] = group.all.contains(group.now) ? group.now : ""
        }
    }

    private func refreshGroups() {
        guard engine.isRunning, let active = controller, !readsGroups else { return }
        readsGroups = true
        Task { @MainActor in
            defer { if controller == active { readsGroups = false } }
            do {
                try await reloadGroups(active)
            } catch {
                if controller == active { alertText = error.localizedDescription }
            }
        }
    }

    private func setGroup(_ group: String) {
        guard engine.isRunning, let active = controller, !readsGroups,
              let node = groupSelection[group], groupStatus[group]?.all.contains(node) == true else { return }
        readsGroups = true
        Task { @MainActor in
            defer { if controller == active { readsGroups = false } }
            do {
                try await active.select(group: group, node: node)
                try await reloadGroups(active)
            } catch {
                if controller == active { alertText = error.localizedDescription }
            }
        }
    }

    private var diagnostics: some View {
        card("运行日志", icon: "text.alignleft") {
            HStack {
                Text("日志可能包含节点、域名等信息，分享前请检查。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ScrollView {
                Text(engine.log.isEmpty ? "尚无日志。" : engine.log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
            }
            .frame(minHeight: 100, idealHeight: 130, maxHeight: 175)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Text(feedback)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("导出配置…", action: export)
                .disabled(engine.isBusy)
                .help("导出的文件包括订阅地址，请妥善保存。")
            Button("校验配置", action: validate)
                .disabled(editingLocked || binary == nil)
            if engine.isRunning || engine.isBusy {
                Button("停止核心", role: .destructive, action: engine.stop)
                    .buttonStyle(.bordered)
            } else {
                Button("启动核心", action: start)
                    .buttonStyle(.borderedProminent)
                    .disabled(engine.isBusy || binary == nil)
            }
        }
        .padding(16)
    }

    private func card<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.18))
                .allowsHitTesting(false)
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).frame(width: 148, alignment: .leading)
            content()
        }
    }

    private func note(_ value: String) -> some View {
        Text(value)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func groupRow(_ title: String, pattern: Binding<String>, auto: Binding<Bool>) -> some View {
        row(title) {
            TextField("\(title) 的节点正则", text: pattern)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            Toggle("自动测速", isOn: auto)
                .accessibilityLabel("\(title) 自动测速")
        }
    }

    private func subscriptionField(_ title: String, value: Binding<String>) -> some View {
        Group {
            if showSubscriptionURLs {
                TextField(title, text: value)
            } else {
                SecureField(title, text: value)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func interfacePicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("请选择网卡").tag("")
            if !selection.wrappedValue.isEmpty && !interfaceNames.contains(selection.wrappedValue) {
                Text("\(selection.wrappedValue)（不可用）").tag(selection.wrappedValue)
            }
            ForEach(interfaceNames, id: \.self) { name in
                Text(interfaceLabels[name].map { "\($0) · \(name)" } ?? name).tag(name)
            }
        }
        .labelsHidden()
    }

    private func refreshInterfaces() {
        interfaceNames = EngineController.interfaces()
        let interfaces = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []
        var labels: [String: String] = [:]
        for networkInterface in interfaces {
            if let name = SCNetworkInterfaceGetBSDName(networkInterface),
               let label = SCNetworkInterfaceGetLocalizedDisplayName(networkInterface) {
                labels[name as String] = label as String
            }
        }
        interfaceLabels = labels
    }

    private func updateTemplate(_ newTemplate: RoutingTemplate) {
        let old = profile
        var next = RoutingProfile.template(newTemplate)
        next.exitProviderURL = old.exitProviderURL
        next.entryProviderURL = old.entryProviderURL
        next.domesticInterface = old.domesticInterface
        next.claudeInterface = old.claudeInterface
        next.entryPattern = old.entryPattern
        next.groupAPattern = old.groupAPattern
        next.groupBPattern = old.groupBPattern
        next.entryAutoTest = old.entryAutoTest
        next.groupAAutoTest = old.groupAAutoTest
        next.groupBAutoTest = old.groupBAutoTest
        next.mixedPort = old.mixedPort
        profile = next
        feedback = ""
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.title = "选择可信的 Mihomo 可执行文件"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                alertText = "所选文件不可执行，请选择已安装的 Mihomo 核心。"
                return
            }
            binary = url
            feedback = ""
        }
    }

    private func validate() {
        guard let binary else { return }
        feedback = ""
        do {
            engine.validate(config: try MihomoConfig.render(resolvedProfile), binary: binary)
        } catch {
            alertText = error.localizedDescription
        }
    }

    private func start() {
        guard let binary else { return }
        feedback = ""
        do {
            guard (1024...65535).contains(controllerPort), controllerPort != profile.mixedPort else {
                alertText = "本机控制端口须为 1024 到 65535，且不能与混合端口相同。"
                return
            }
            let active = LocalController(port: controllerPort, secret: UUID().uuidString + UUID().uuidString)
            let config = try MihomoConfig.render(resolvedProfile, controllerPort: active.port, secret: active.secret)
            resetActiveGroups()
            controller = active
            engine.start(
                config: config,
                binary: binary,
                interfaces: resolvedProfile.requiredInterfaces.sorted()
            )
            if !engine.isBusy && !engine.isRunning { resetActiveGroups() }
        } catch {
            alertText = error.localizedDescription
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.title = "打开 RouteWeaver 方案"
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let limit = 1 << 20
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            guard data.count <= limit else {
                alertText = "方案文件超过 1 MB，无法打开。"
                return
            }
            profile = try JSONDecoder().decode(RoutingProfile.self, from: data)
            feedback = "方案已打开"
        } catch {
            alertText = "无法读取 RouteWeaver 方案；请检查文件格式。"
        }
    }

    private func saveProfile() {
        let panel = NSSavePanel()
        panel.title = "保存 RouteWeaver 方案"
        panel.message = "保留完整订阅地址，可能包含访问令牌。请存到自己有权访问的目录。"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "routeweaver-profile.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try writePrivateFile(encoder.encode(profile), to: url)
            feedback = "方案已保存"
        } catch {
            alertText = error.localizedDescription
        }
    }

    private func export() {
        let config: Data
        do {
            config = try MihomoConfig.render(resolvedProfile)
        } catch {
            alertText = error.localizedDescription
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出 Mihomo 配置"
        panel.message = "文件包含订阅地址，可能带有访问令牌，请妥善保管。"
        panel.nameFieldStringValue = "routeweaver.yaml"
        if let yaml = UTType(filenameExtension: "yaml") { panel.allowedContentTypes = [yaml] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try writePrivateFile(config, to: url)
            feedback = "已导出配置"
        } catch {
            alertText = error.localizedDescription
        }
    }

    private func writePrivateFile(_ data: Data, to url: URL) throws {
        // Build a private file on the same volume, then atomically move/replace it.
        let manager = FileManager.default
        let temp = try manager.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: url, create: true
        )
        defer { try? manager.removeItem(at: temp) }
        let privateFile = temp.appendingPathComponent("routeweaver.yaml")
        guard manager.createFile(atPath: privateFile.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: privateFile)
        if manager.fileExists(atPath: url.path) {
            _ = try manager.replaceItemAt(url, withItemAt: privateFile, backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            try manager.moveItem(at: privateFile, to: url)
        }
    }
}

private struct LocalController: Equatable {
    static let entryGroup = MihomoConfig.entryGroup
    static let aGroup = MihomoConfig.groupA
    static let bGroup = MihomoConfig.groupB

    let port: Int
    let secret: String

    struct ProxyGroup: Decodable {
        let now: String
        let all: [String]
    }

    private struct GroupResponse: Decodable {
        let now: String?
        let all: [String]?
    }

    private struct ProxyResponse: Decodable {
        let proxies: [String: GroupResponse]
    }

    private struct Selection: Encodable {
        let name: String
    }

    func groups() async throws -> [String: ProxyGroup] {
        let data = try await request(path: "/proxies")
        let response = try JSONDecoder().decode(ProxyResponse.self, from: data)
        var groups: [String: ProxyGroup] = [:]
        for name in [Self.entryGroup, Self.aGroup, Self.bGroup] {
            if let group = response.proxies[name], let nodes = group.all {
                var seen = Set<String>()
                groups[name] = ProxyGroup(now: group.now ?? "", all: nodes.filter { seen.insert($0).inserted })
            }
        }
        return groups
    }

    func select(group: String, node: String) async throws {
        guard [Self.entryGroup, Self.aGroup, Self.bGroup].contains(group) else {
            throw ControllerError.invalidGroup
        }
        _ = try await request(path: "/proxies/\(group)", body: JSONEncoder().encode(Selection(name: node)))
    }

    private func request(path: String, body: Data? = nil) async throws -> Data {
        var locator = URLComponents()
        locator.scheme = "http"
        locator.host = "127.0.0.1"
        locator.port = port
        locator.path = path
        guard let url = locator.url else { throw ControllerError.invalidAddress }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let settings = URLSessionConfiguration.ephemeral
        settings.connectionProxyDictionary = [
            "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0, "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0
        ]
        let session = URLSession(configuration: settings, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ControllerError.invalidAddress }
        guard (200...299).contains(response.statusCode) else { throw ControllerError.http(response.statusCode) }
        return data
    }

    private enum ControllerError: LocalizedError {
        case invalidAddress, invalidGroup, http(Int)

        var errorDescription: String? {
            switch self {
            case .invalidAddress: return "无法读取本机 Mihomo 控制接口。"
            case .invalidGroup: return "选择的节点组无效。"
            case .http(let code): return "本机 Mihomo 控制接口返回 HTTP \(code)。"
            }
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
