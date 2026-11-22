import AppKit
import Darwin
import SwiftUI

@MainActor
final class RouteWeaverAppDelegate: NSObject, NSApplicationDelegate {
    static weak var sharedState: AppState?
    private var isSystemPoweringOff = false
    private var powerOffObserver: NSObjectProtocol?
    private var sigtermSource: DispatchSourceSignal?
    private var handledQuitDecision = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isSystemPoweringOff = true
            }
        }

        // Handle external SIGTERM (e.g. Lumzel preview restart) cleanly without showing a modal alert
        // and without stopping the Mihomo core process.
        Darwin.signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self else {
                    Darwin.exit(0)
                }
                if !self.handledQuitDecision, let state = Self.sharedState {
                    state.prepareForQuit(stopCore: false)
                    self.handledQuitDecision = true
                }
                Darwin.exit(0)
            }
        }
        source.resume()
        sigtermSource = source
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = Self.sharedState else {
            return .terminateNow
        }

        // System shutdown/logout should never be blocked by a modal alert.
        if isSystemPoweringOff {
            state.prepareForQuit(stopCore: false)
            handledQuitDecision = true
            return .terminateNow
        }

        guard state.shouldConfirmCoreOnQuit else {
            state.connectionMonitor.flushHistory()
            handledQuitDecision = true
            return .terminateNow
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "退出 RouteWeaver"
        alert.informativeText = "Mihomo 核心当前正在运行。退出时默认保持核心在后台运行，可保证网络代理不中断；下次打开 RouteWeaver 时会自动重新接管。"
        alert.addButton(withTitle: "保持核心运行并退出")
        alert.addButton(withTitle: "同时关闭核心并退出")
        alert.addButton(withTitle: "取消")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            state.prepareForQuit(stopCore: false)
            handledQuitDecision = true
            return .terminateNow
        case .alertSecondButtonReturn:
            state.prepareForQuit(stopCore: true)
            handledQuitDecision = true
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let observer = powerOffObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            powerOffObserver = nil
        }
        guard let state = Self.sharedState else { return }
        if !handledQuitDecision {
            // Unexpected/external termination path (e.g. SIGTERM / restart): keep Mihomo core running.
            state.prepareForQuit(stopCore: false)
        }
    }
}

@main
@MainActor
struct RouteWeaverApp: App {
    @NSApplicationDelegateAdaptor(RouteWeaverAppDelegate.self) private var appDelegate
    @StateObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    init() {
        let appState = AppState()
        _state = StateObject(wrappedValue: appState)
        RouteWeaverAppDelegate.sharedState = appState
    }

    var body: some Scene {
        Window("RouteWeaver", id: "main") {
            MainView(state: state)
                .frame(minWidth: 860, minHeight: 600)
        }
        .defaultSize(width: 980, height: 680)
        .commands {
            SidebarCommands()

            CommandGroup(after: .newItem) {
                Button("打开方案…") { state.importProfile() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(state.editingLocked)

                Button("保存方案…") { state.saveProfile() }
                    .keyboardShortcut("s", modifiers: .command)

                Button("导出 Mihomo 配置…") { state.exportConfig() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(state.engine.isBusy)
            }

            CommandMenu("控制") {
                if state.engine.isRunning || state.engine.isBusy {
                    Button("停止核心") { state.stop() }
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button("启动核心") { state.start() }
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(!state.canStart)
                }

                Button("校验配置") { state.validate() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(state.editingLocked || state.binary == nil)

                Divider()

                Button("刷新节点") { state.refreshGroups() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!state.engine.isRunning || state.readsGroups)

                Button("立即更新在线规则") { state.updateOnlineRuleProviders() }
                    .disabled(!state.engine.isRunning || state.updatingRuleProviders)

                Button("断开全部活跃连接") { state.closeAllMonitoredConnections() }
                    .disabled(!state.engine.isRunning)

                Button("刷新网卡列表") {
                    state.refreshInterfaces()
                    state.showFeedback("已刷新网卡列表")
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Divider()

                Button("复制本机代理地址") { state.copyProxyAddress() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("复制终端代理命令") { state.copyShellExport() }
            }
        }

        MenuBarExtra {
            menuBarContent
        } label: {
            Image(systemName: state.engine.isRunning
                  ? "point.3.filled.connected.trianglepath.dotted"
                  : "point.3.connected.trianglepath.dotted")
        }
    }

    @ViewBuilder
    private var menuBarContent: some View {
        Text("状态：\(state.engine.phase.title)")
        Text("模式：\(state.profile.gatewayModeEnabled ? "局域网网关（TUN + DNS :53）" : (state.profile.tunEnabled ? "TUN 透明代理" : "混合代理端口"))")
        Text("本机：\(state.localProxyAddress)")
        if state.profile.gatewayModeEnabled, let lan = state.primaryLANAddress {
            Text("网关 / DNS：\(lan)")
        } else if state.profile.allowLAN, let lan = state.primaryLANAddress {
            Text("局域网：\(lan):\(state.profile.mixedPort)")
        }

        Divider()

        if state.engine.isRunning || state.engine.isBusy {
            Button("停止核心") { state.stop() }
        } else {
            Button("启动核心") { state.start() }
                .disabled(!state.canStart)
            Toggle("启用 TUN 模式", isOn: Binding(
                get: { state.profile.tunEnabled },
                set: { state.setTunEnabled($0) }
            ))
            Toggle("启用局域网网关模式", isOn: Binding(
                get: { state.profile.gatewayModeEnabled },
                set: { state.setGatewayModeEnabled($0) }
            ))
        }

        Button("复制本机代理地址") { state.copyProxyAddress() }
        if state.profile.gatewayModeEnabled, let lan = state.primaryLANAddress {
            Button("复制网关 IP (\(lan))") {
                state.copyText(lan, label: "局域网网关 IP")
            }
        }
        if state.profile.effectiveAllowLAN, let lan = state.primaryLANAddress {
            Button("复制局域网代理地址") {
                state.copyText("\(lan):\(state.profile.mixedPort)", label: "局域网代理地址")
            }
        }
        Button("复制终端代理命令") { state.copyShellExport() }

        Divider()

        Button("打开 RouteWeaver 主窗口") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }

        Button("退出 RouteWeaver") {
            NSApp.terminate(nil)
        }
    }
}
