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
    @Published private(set) var verifiedHealthyAt: [String: Date] = [:]

    private(set) var controller: (any MihomoControlClient)?
    let clientFactory: MihomoControlClientFactory
    private var pollTask: Task<Void, Never>?
    private var lastAutoVerifyAtByTarget: [String: Date] = [:]
    let autoVerifyCooldownSeconds: TimeInterval = 30

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
        verifiedHealthyAt = [:]
        lastAutoVerifyAtByTarget = [:]
    }

    var healthSnapshots: [String: ProxyGroupHealthSnapshot] {
        var result: [String: ProxyGroupHealthSnapshot] = [:]
        for (name, status) in groupStatus {
            result[name] = ProxyGroupHealthSnapshot(
                name: name,
                type: status.type,
                now: status.now,
                all: status.all,
                delays: status.delays,
                timedOutNodes: status.timedOutNodes,
                isTesting: testingGroups.contains(name),
                lastVerifiedHealthyAt: verifiedHealthyAt[name]
            )
        }
        for name in activeProxyGroups where result[name] == nil {
            result[name] = ProxyGroupHealthSnapshot(
                name: name,
                type: "Selector",
                now: "",
                all: [],
                delays: [:],
                timedOutNodes: [],
                isTesting: testingGroups.contains(name),
                lastVerifiedHealthyAt: nil
            )
        }
        return result
    }

    func applyRemoteGroups(_ groups: [RemoteProxyGroupDTO]) {
        activeProxyGroups = groups.map(\.name)
        var statusMap: [String: LocalController.ProxyGroup] = [:]
        var selectionMap: [String: String] = [:]
        var testingSet = Set<String>()
        var verifiedMap: [String: Date] = [:]
        for g in groups {
            statusMap[g.name] = LocalController.ProxyGroup(
                type: g.type,
                now: g.now,
                all: g.all,
                delays: g.delays,
                timedOutNodes: Set(g.timedOutNodes)
            )
            selectionMap[g.name] = g.all.contains(g.now) ? g.now : ""
            if g.isTesting {
                testingSet.insert(g.name)
            }
            if let verifiedAt = g.lastVerifiedHealthyAt {
                verifiedMap[g.name] = verifiedAt
            }
        }
        groupStatus = statusMap
        groupSelection = selectionMap
        testingGroups = testingSet
        verifiedHealthyAt = verifiedMap
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
                if let updated = self.groupStatus[group], updated.currentDelay != nil, !updated.isCurrentNodeTimedOut {
                    self.verifiedHealthyAt[group] = Date()
                } else {
                    self.verifiedHealthyAt.removeValue(forKey: group)
                }
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
                let delays = try await active.testGroupDelay(group: group)
                try await self.reloadGroups(active, isEngineRunning: isEngineRunning)
                self.recordDelayVerificationOutcome(group: group, explicitDelays: delays)
                if let updated = self.groupStatus[group], !updated.now.isEmpty {
                    if updated.isCurrentNodeTimedOut {
                        onFeedback("「\(group)」当前节点 \(updated.now) 测速超时")
                    } else {
                        let delayText = updated.currentDelay.map { " (\($0) ms)" } ?? ""
                        onFeedback("「\(group)」测速完成，当前节点：\(updated.now)\(delayText)")
                    }
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

    /// Automatically runs a throttled dual-hop probe (`relayGroup` + `targetName`) when passive monitoring
    /// observes a dial error or zero-byte blackhole on `targetName`.
    func autoVerifyTargetIfNeeded(
        targetName: String,
        isEngineRunning: @escaping @MainActor () -> Bool,
        now: Date = Date()
    ) {
        guard isEngineRunning(), controller != nil else { return }
        if let last = lastAutoVerifyAtByTarget[targetName],
           now.timeIntervalSince(last) < autoVerifyCooldownSeconds {
            return
        }
        let relayName = MihomoConfig.relayGroupName(for: targetName)
        let hasTracked = activeProxyGroups.contains(targetName) || activeProxyGroups.contains(relayName)
        guard hasTracked else { return }
        lastAutoVerifyAtByTarget[targetName] = now
        diagnoseTargetHops(
            targetName: targetName,
            isEngineRunning: isEngineRunning,
            onFeedback: nil
        )
    }

    /// Probes both the relay hop (`<target>·链式`, if active) and exit hop (`<target>`) to isolate which hop failed.
    func diagnoseTargetHops(
        targetName: String,
        isEngineRunning: @escaping @MainActor () -> Bool,
        onFeedback: (@MainActor (String) -> Void)?
    ) {
        guard isEngineRunning(), let active = controller else { return }
        let relayGroup = MihomoConfig.relayGroupName(for: targetName)
        let groupsToProbe = [relayGroup, targetName].filter {
            activeProxyGroups.contains($0) && !testingGroups.contains($0)
        }
        guard !groupsToProbe.isEmpty else { return }
        for g in groupsToProbe {
            testingGroups.insert(g)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.controller?.sessionID == active.sessionID {
                    for g in groupsToProbe {
                        self.testingGroups.remove(g)
                    }
                }
            }

            var probeResults: [String: [String: Int]] = [:]
            await withTaskGroup(of: (String, [String: Int]?).self) { taskGroup in
                for g in groupsToProbe {
                    taskGroup.addTask {
                        let result = try? await active.testGroupDelay(group: g)
                        return (g, result)
                    }
                }
                for await (g, res) in taskGroup {
                    if let res {
                        probeResults[g] = res
                    }
                }
            }

            guard self.controller?.sessionID == active.sessionID, isEngineRunning() else { return }
            try? await self.reloadGroups(active, isEngineRunning: isEngineRunning)
            for g in groupsToProbe {
                self.recordDelayVerificationOutcome(group: g, explicitDelays: probeResults[g] ?? [:])
            }

            if let onFeedback {
                let summary = self.describeDualHopResult(targetName: targetName, relayGroup: relayGroup)
                onFeedback(summary)
            }
        }
    }

    func diagnoseAllActiveGroups(
        isEngineRunning: @escaping @MainActor () -> Bool,
        onFeedback: @escaping @MainActor (String) -> Void
    ) {
        guard isEngineRunning(), let active = controller else { return }
        let groupsToProbe = activeProxyGroups.filter { !testingGroups.contains($0) }
        guard !groupsToProbe.isEmpty else { return }
        for g in groupsToProbe {
            testingGroups.insert(g)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.controller?.sessionID == active.sessionID {
                    for g in groupsToProbe {
                        self.testingGroups.remove(g)
                    }
                }
            }

            var probeResults: [String: [String: Int]] = [:]
            await withTaskGroup(of: (String, [String: Int]?).self) { taskGroup in
                for g in groupsToProbe {
                    taskGroup.addTask {
                        let result = try? await active.testGroupDelay(group: g)
                        return (g, result)
                    }
                }
                for await (g, res) in taskGroup {
                    if let res {
                        probeResults[g] = res
                    }
                }
            }

            guard self.controller?.sessionID == active.sessionID, isEngineRunning() else { return }
            try? await self.reloadGroups(active, isEngineRunning: isEngineRunning)
            var timeoutCount = 0
            for g in groupsToProbe {
                self.recordDelayVerificationOutcome(group: g, explicitDelays: probeResults[g] ?? [:])
                if self.groupStatus[g]?.isCurrentNodeTimedOut == true {
                    timeoutCount += 1
                }
            }
            if timeoutCount > 0 {
                onFeedback("全链路巡检完成：发现 \(timeoutCount) 个节点组超时异常")
            } else {
                onFeedback("全链路巡检完成：全部 \(groupsToProbe.count) 个节点组连通正常")
            }
        }
    }

    private func recordDelayVerificationOutcome(group: String, explicitDelays: [String: Int]) {
        guard var status = groupStatus[group] else { return }
        let current = status.now
        guard !current.isEmpty, status.all != ["REJECT"] else { return }
        if let delay = explicitDelays[current], delay > 0 {
            var updatedDelays = status.delays
            updatedDelays[current] = delay
            var updatedTimedOut = status.timedOutNodes
            updatedTimedOut.remove(current)
            status = LocalController.ProxyGroup(
                type: status.type,
                now: status.now,
                all: status.all,
                delays: updatedDelays,
                timedOutNodes: updatedTimedOut
            )
            groupStatus[group] = status
            verifiedHealthyAt[group] = Date()
        } else if status.currentDelay != nil && !status.isCurrentNodeTimedOut && !explicitDelays.isEmpty {
            verifiedHealthyAt[group] = Date()
        } else if explicitDelays[current] == nil && status.currentDelay == nil {
            // Delay endpoint omitted `current` because its probe timed out
            var updatedTimedOut = status.timedOutNodes
            updatedTimedOut.insert(current)
            status = LocalController.ProxyGroup(
                type: status.type,
                now: status.now,
                all: status.all,
                delays: status.delays,
                timedOutNodes: updatedTimedOut
            )
            groupStatus[group] = status
            verifiedHealthyAt.removeValue(forKey: group)
        } else if status.isCurrentNodeTimedOut {
            verifiedHealthyAt.removeValue(forKey: group)
        }
    }

    private func describeDualHopResult(targetName: String, relayGroup: String) -> String {
        let hasRelay = activeProxyGroups.contains(relayGroup)
        let relayStatus = groupStatus[relayGroup]
        let exitStatus = groupStatus[targetName]
        if hasRelay {
            if relayStatus?.isCurrentNodeTimedOut == true {
                return "诊断定位：「\(targetName)」第一跳链式节点（\(relayStatus?.now ?? relayGroup)）连接超时"
            }
            let rText = relayStatus?.currentDelay.map { "\($0) ms" } ?? "正常"
            if exitStatus?.isCurrentNodeTimedOut == true {
                let exitNode = TopologySnapshotBuilder.stripTargetNodePrefix(exitStatus?.now ?? targetName, targetName: targetName)
                return "诊断定位：「\(targetName)」第一跳链式正常(\(rText))，第二跳出口（\(exitNode)）连接超时"
            }
            let eText = exitStatus?.currentDelay.map { "\($0) ms" } ?? "正常"
            return "「\(targetName)」双跳连通正常：链式 \(rText) → 出口 \(eText)"
        } else {
            if exitStatus?.isCurrentNodeTimedOut == true {
                return "诊断定位：「\(targetName)」出口节点（\(exitStatus?.now ?? targetName)）连接超时"
            }
            let eText = exitStatus?.currentDelay.map { "\($0) ms" } ?? "正常"
            return "「\(targetName)」出口连通正常（\(eText)）"
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
