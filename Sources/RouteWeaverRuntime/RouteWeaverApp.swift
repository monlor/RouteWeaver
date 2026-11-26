import AppKit
import Darwin
import SwiftUI

private enum SingleInstanceGuard {
    static let reopenNotification = Notification.Name("local.routeweaver.mac.reopenMainWindow")

    @MainActor
    static func activateExistingAndExitIfNeeded() {
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
            return
        }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != currentPID && !$0.isTerminated }
        guard let existing else { return }

        DistributedNotificationCenter.default().postNotificationName(
            reopenNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        if #available(macOS 14.0, *) {
            existing.activate()
        } else {
            existing.activate(options: [.activateIgnoringOtherApps])
        }
        Darwin.exit(0)
    }
}

@MainActor
final class RouteWeaverAppDelegate: NSObject, NSApplicationDelegate {
    static weak var sharedState: AppState?
    static var onReopenMainWindow: (@MainActor () -> Void)?
    private var isSystemPoweringOff = false
    private var powerOffObserver: NSObjectProtocol?
    private var reopenObserver: NSObjectProtocol?
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

        reopenObserver = DistributedNotificationCenter.default().addObserver(
            forName: SingleInstanceGuard.reopenNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                Self.onReopenMainWindow?()
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            Self.sharedState?.syncSelectedDeviceOnWindowOpen()
            Self.onReopenMainWindow?()
        }
        return true
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
        if let observer = reopenObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            reopenObserver = nil
        }
        guard let state = Self.sharedState else { return }
        if !handledQuitDecision {
            // Unexpected/external termination path (e.g. SIGTERM / restart): keep Mihomo core running.
            state.prepareForQuit(stopCore: false)
        }
    }
}

@MainActor
public struct RouteWeaverApp: App {
    @NSApplicationDelegateAdaptor(RouteWeaverAppDelegate.self) private var appDelegate
    @StateObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    public init() {
        SingleInstanceGuard.activateExistingAndExitIfNeeded()
        let appState = AppState()
        _state = StateObject(wrappedValue: appState)
        RouteWeaverAppDelegate.sharedState = appState
    }

    public var body: some Scene {
        Window("RouteWeaver", id: "main") {
            MainView(state: state)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    RouteWeaverAppDelegate.onReopenMainWindow = {
                        state.syncSelectedDeviceOnWindowOpen()
                        openWindow(id: "main")
                    }
                }
        }
        .defaultSize(width: 1080, height: 720)
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
                    .disabled(state.isCoreBusy)
            }

            CommandMenu("控制") {
                if state.isCoreRunning || state.isCoreBusy {
                    Button("停止核心") { state.stop() }
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button("启动核心") { state.start() }
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(!state.canStart)
                }

                Button("校验配置") { state.validate() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(state.editingLocked || (!state.isViewingRemote && state.binary == nil))

                Divider()

                Button("刷新节点") { state.refreshGroups() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!state.isCoreRunning || state.activeLiveProxyStore.readsGroups)

                Button("立即更新在线规则") { state.updateOnlineRuleProviders() }
                    .disabled(!state.isCoreRunning || state.activeLiveProxyStore.updatingRuleProviders)

                Button("断开全部活跃连接") { state.closeAllMonitoredConnections() }
                    .disabled(!state.isCoreRunning)

                Button("刷新网卡列表") {
                    state.refreshInterfaces()
                    state.showFeedback("已刷新网卡列表")
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Divider()

                Toggle("断网保护（Kill Switch）", isOn: Binding(
                    get: { state.activeKillSwitchActive },
                    set: { state.setKillSwitchEnabled($0) }
                ))
                .disabled(state.isUpdatingKillSwitch || state.isAuthorizingTun)

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
        if let link = state.remoteBridge.activeLink {
            Text("远程接入：\(link.remoteHostName)（\(link.mode.title)）")
            Button("断开远程接入并恢复本机网络") {
                state.disconnectRemoteBridge()
            }
        }
        Text("模式：\(state.localProfile.gatewayModeEnabled ? "局域网网关（TUN + DNS :53）" : (state.localProfile.tunEnabled ? "TUN 透明代理" : "混合代理端口"))")
        if state.killSwitchActive {
            Text("断网保护：已开启（防默认网卡泄漏）")
        }
        Text("本机：127.0.0.1:\(state.localProfile.mixedPort)")
        if state.localProfile.gatewayModeEnabled, let lan = state.localPrimaryLANAddress {
            Text("网关 / DNS：\(lan)")
        } else if state.localProfile.allowLAN, let lan = state.localPrimaryLANAddress {
            Text("局域网：\(lan):\(state.localProfile.mixedPort)")
        }

        Divider()

        if state.engine.isRunning || state.engine.isBusy {
            Button("停止本机核心") { state.stopLocal() }
        } else {
            Button("启动本机核心") { state.startLocal() }
                .disabled(!state.localCanStart)
            Toggle("启用 TUN 模式", isOn: Binding(
                get: { state.localProfile.tunEnabled },
                set: { state.setLocalTunEnabled($0) }
            ))
            Toggle("启用局域网网关模式", isOn: Binding(
                get: { state.localProfile.gatewayModeEnabled },
                set: { state.setLocalGatewayModeEnabled($0) }
            ))
        }

        Toggle("断网保护（Kill Switch）", isOn: Binding(
            get: { state.killSwitchActive },
            set: { state.setKillSwitchEnabled($0) }
        ))
        .disabled(state.isUpdatingKillSwitch || state.isAuthorizingTun)

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
            state.syncSelectedDeviceOnWindowOpen()
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }

        Button("退出 RouteWeaver") {
            NSApp.terminate(nil)
        }
    }
}
