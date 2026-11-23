import Combine
import Foundation
import RoutingCore

typealias MihomoControlClientFactory = @Sendable (Int, String, [String]) -> any MihomoControlClient

@MainActor
final class LiveProxyStore: ObservableObject {
    @Published private(set) var activeProxyGroups: [String] = []
    @Published private(set) var groupStatus: [String: LocalController.ProxyGroup] = [:]
    @Published var groupSelection: [String: String] = [:]
    @Published private(set) var readsGroups = false
    @Published private(set) var testingGroups: Set<String> = []
    @Published private(set) var updatingRuleProviders = false

    private(set) var controller: (any MihomoControlClient)?
    let clientFactory: MihomoControlClientFactory
    private var pollTask: Task<Void, Never>?

    init(clientFactory: @escaping MihomoControlClientFactory = { port, secret, groups in
        LocalController(port: port, secret: secret, trackedGroups: groups)
    }) {
        self.clientFactory = clientFactory
    }

    func makeClient(port: Int, secret: String, trackedGroups: [String]) -> any MihomoControlClient {
        clientFactory(port, secret, trackedGroups)
    }

    func activate(controller: any MihomoControlClient, trackedGroups: [String]) {
        reset()
        self.controller = controller
        self.activeProxyGroups = trackedGroups
    }

    func replaceController(_ controller: any MihomoControlClient, trackedGroups: [String]) {
        self.controller = controller
        self.activeProxyGroups = trackedGroups
    }

    func reset() {
        pollTask?.cancel()
        pollTask = nil
        controller = nil
        activeProxyGroups = []
        groupStatus = [:]
        groupSelection = [:]
        readsGroups = false
        testingGroups = []
        updatingRuleProviders = false
    }

    func startPolling(isEngineRunning: @escaping @MainActor () -> Bool) {
        pollTask?.cancel()
        guard let active = controller, !active.trackedGroups.isEmpty else { return }
        pollTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self, isEngineRunning(), self.controller?.sessionID == active.sessionID else { return }
                let delayNs: UInt64
                switch attempt {
                case 0: delayNs = 500_000_000
                case 1...4: delayNs = 1_500_000_000
                default: delayNs = 5_000_000_000
                }
                attempt += 1
                try? await Task.sleep(nanoseconds: delayNs)
                guard !Task.isCancelled, isEngineRunning(), self.controller?.sessionID == active.sessionID else { return }
                do {
                    try await self.reloadGroups(active, isEngineRunning: isEngineRunning)
                } catch {
                    // Retry silently during startup warm-up or transient controller errors.
                }
            }
        }
    }

    func reloadGroups(
        _ active: any MihomoControlClient,
        isEngineRunning: @escaping @MainActor () -> Bool
    ) async throws {
        let values = try await active.groups()
        guard controller?.sessionID == active.sessionID, isEngineRunning() else { return }
        groupStatus = values
        for (key, group) in values {
            groupSelection[key] = group.all.contains(group.now) ? group.now : ""
        }
    }

    func refreshGroups(
        isEngineRunning: @escaping @MainActor () -> Bool,
        onFeedback: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) {
        guard isEngineRunning(), let active = controller, !readsGroups else { return }
        readsGroups = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.controller?.sessionID == active.sessionID { self.readsGroups = false } }
            do {
                try await self.reloadGroups(active, isEngineRunning: isEngineRunning)
                onFeedback("节点列表已刷新")
            } catch {
                if self.controller?.sessionID == active.sessionID {
                    onError(error.localizedDescription)
                }
            }
        }
    }

    func selectNode(
        group: String,
        node: String,
        isEngineRunning: @escaping @MainActor () -> Bool,
        onFeedback: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) {
        guard isEngineRunning(), let active = controller, !readsGroups,
              let status = groupStatus[group],
              !status.isAutoTest,
              status.all.contains(node) else { return }
        groupSelection[group] = node
        readsGroups = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.controller?.sessionID == active.sessionID { self.readsGroups = false } }
            do {
                try await active.select(group: group, node: node)
                try await self.reloadGroups(active, isEngineRunning: isEngineRunning)
                onFeedback("已切换 \(group) → \(node)")
            } catch {
                if self.controller?.sessionID == active.sessionID {
                    onError(error.localizedDescription)
                }
            }
        }
    }

    func testGroupDelay(
        group: String,
        isEngineRunning: @escaping @MainActor () -> Bool,
        onFeedback: @escaping @MainActor (String) -> Void
    ) {
        guard isEngineRunning(), let active = controller, !testingGroups.contains(group) else { return }
        testingGroups.insert(group)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.controller?.sessionID == active.sessionID {
                    self.testingGroups.remove(group)
                }
            }
            do {
                _ = try await active.testGroupDelay(group: group)
                try await self.reloadGroups(active, isEngineRunning: isEngineRunning)
                if let updated = self.groupStatus[group], !updated.now.isEmpty {
                    let delayText = updated.currentDelay.map { " (\($0) ms)" } ?? ""
                    onFeedback("「\(group)」测速完成，当前节点：\(updated.now)\(delayText)")
                } else {
                    onFeedback("「\(group)」测速完成")
                }
            } catch {
                if self.controller?.sessionID == active.sessionID {
                    onFeedback("「\(group)」测速失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func updateOnlineRuleProviders(
        isEngineRunning: @escaping @MainActor () -> Bool,
        onFeedback: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) {
        guard isEngineRunning(), let active = controller, !updatingRuleProviders else { return }
        updatingRuleProviders = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.controller?.sessionID == active.sessionID { self.updatingRuleProviders = false } }
            do {
                let count = try await active.updateAllRuleProviders()
                onFeedback(count > 0 ? "已更新 \(count) 个在线规则集" : "当前配置未启用远程规则集")
            } catch {
                if self.controller?.sessionID == active.sessionID {
                    onError(error.localizedDescription)
                }
            }
        }
    }
}
