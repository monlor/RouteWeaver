import RoutingCore
import SwiftUI

enum TopologyDisplayMode: String, CaseIterable, Identifiable {
    case fused
    case targetsOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fused: return "融合汇聚（规则组 → 目标）"
        case .targetsOnly: return "精简链路（仅网络目标）"
        }
    }

    var compactTitle: String {
        switch self {
        case .fused: return "融合汇聚"
        case .targetsOnly: return "精简链路"
        }
    }
}

private struct TopologyPortFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct TopologyLinkSpec: Identifiable {
    let id: String
    let fromPortID: String
    let toPortID: String
    let speedBytesPerSec: Int64
    let isActive: Bool
    let health: TopologyHealthState
    let isHighlighted: Bool
}

struct NetworkTopologyView: View {
    @ObservedObject var state: AppState
    @ObservedObject var liveProxyStore: LiveProxyStore
    @ObservedObject var monitor: ConnectionMonitorService

    @State private var displayMode: TopologyDisplayMode = .fused
    @State private var collapseIdleBranches: Bool = true
    @State private var expandedIdleLaneIDs: Set<String> = []
    @State private var highlightedBranchID: String? = nil
    @State private var portFrames: [String: CGRect] = [:]
    @State private var didEvaluateInitialSelection: Bool = false

    private static let canvasSpaceName = "TopologyFlowCanvasSpace"
    static let horizontalClusterBreakpoint: CGFloat = 580

    private var snapshot: TopologySnapshot {
        let upInterfaces = Set(state.activeInterfaces.filter(\.isUpWithAddress).map(\.bsdName))
        var labels: [String: String] = [:]
        for info in state.activeInterfaces {
            labels[info.bsdName] = info.shortLabel
        }
        return TopologySnapshotBuilder.build(
            profile: state.profile,
            isCoreRunning: state.isCoreRunning,
            activeInterfaceNames: upInterfaces,
            interfaceLabels: labels,
            groupStatuses: liveProxyStore.healthSnapshots,
            tracker: monitor.tracker,
            dnsRecords: monitor.dnsLogs,
            outboundErrorTracker: monitor.outboundErrorTracker,
            ruleIndex: state.ruleMatchDisplayIndex
        )
    }

    private var selectedLane: TopologyTargetLane? {
        guard let key = state.selectedTopologyTargetKey else { return nil }
        return snapshot.lanes.first { $0.id == key }
    }

    private var isProbingAnyGroup: Bool {
        !liveProxyStore.testingGroups.isEmpty
    }

    private func evaluateInitialIssueSelectionIfNeeded(stageWidth: CGFloat) {
        guard !didEvaluateInitialSelection, stageWidth > 0 else { return }
        didEvaluateInitialSelection = true
        if state.selectedTopologyTargetKey == nil,
           let firstIssue = snapshot.issueLanes.first,
           AdaptiveInspectorScaffold<EmptyView, EmptyView>.docksInline(
               stageWidth: stageWidth,
               isInspectorPresented: true,
               inspectorWidth: 344,
               minContentWidth: 540
           ) {
            state.selectedTopologyTargetKey = firstIssue.id
        }
    }

    var body: some View {
        let snap = snapshot
        let hasLiveFlow = snap.isCoreRunning && (snap.totalUploadSpeed + snap.totalDownloadSpeed) > 0

        VStack(spacing: 0) {
            headerToolbar(snap)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            AdaptiveInspectorScaffold(
                isInspectorPresented: selectedLane != nil,
                inspectorWidth: 344,
                minContentWidth: 540,
                onDismiss: { state.selectedTopologyTargetKey = nil }
            ) { availableContentWidth in
                let innerCanvasWidth = max(280, availableContentWidth - 40)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !snap.isCoreRunning {
                            offlineHintBanner
                        } else if !snap.issueLanes.isEmpty {
                            activeAnomalySummaryStrip(snap)
                        }

                        if snap.lanes.isEmpty {
                            emptyTopologyState
                        } else {
                            topologyGraphBody(
                                snap: snap,
                                hasLiveFlow: hasLiveFlow,
                                canvasWidth: innerCanvasWidth
                            )
                        }

                        legendFooter
                    }
                    .padding(20)
                    .lockScrollDocumentWidth()
                }
                .onAppear {
                    evaluateInitialIssueSelectionIfNeeded(stageWidth: availableContentWidth)
                }
                .onChange(of: availableContentWidth) { updatedWidth in
                    evaluateInitialIssueSelectionIfNeeded(stageWidth: updatedWidth)
                }
            } inspector: {
                if let lane = selectedLane {
                    TopologyInspectorDrawer(
                        state: state,
                        liveProxyStore: liveProxyStore,
                        lane: lane,
                        onClose: { state.selectedTopologyTargetKey = nil }
                    )
                }
            }
        }
    }

    // MARK: - Top Header & Controls

    private func headerToolbar(_ snap: TopologySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SplitHeaderBar(horizontalSpacing: 12, verticalSpacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Picker("", selection: $displayMode) {
                            ForEach(TopologyDisplayMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 296)

                        if displayMode == .fused {
                            Toggle("折叠空闲规则组", isOn: $collapseIdleBranches)
                                .toggleStyle(.checkbox)
                                .controlSize(.small)
                                .fixedSize(horizontal: true, vertical: false)
                                .help("自动收纳当前无活跃流量且目标健康的规则组，突出正在传输或异常的链路")
                        }
                    }

                    HStack(spacing: 8) {
                        Picker("", selection: $displayMode) {
                            ForEach(TopologyDisplayMode.allCases) { mode in
                                Text(mode.compactTitle).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 168)

                        if displayMode == .fused {
                            Toggle("折叠空闲", isOn: $collapseIdleBranches)
                                .toggleStyle(.checkbox)
                                .controlSize(.small)
                                .fixedSize(horizontal: true, vertical: false)
                                .help("自动收纳当前无活跃流量且目标健康的规则组，突出正在传输或异常的链路")
                        }
                    }
                }
            } trailing: {
                FlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    statusSummaryPill(snap)

                    if state.isCoreRunning {
                        Button {
                            state.diagnoseAllActiveHops()
                        } label: {
                            if isProbingAnyGroup {
                                HStack(spacing: 5) {
                                    ProgressView().controlSize(.small)
                                    Text("巡检中…")
                                }
                            } else {
                                Label("全链路测速体检", systemImage: "stethoscope")
                            }
                        }
                        .controlSize(.small)
                        .fixedSize(horizontal: true, vertical: false)
                        .disabled(isProbingAnyGroup || liveProxyStore.activeProxyGroups.isEmpty)
                        .help("对所有活跃的链式节点组与出口节点组执行延迟测速，定位潜在断跳")

                        if !monitor.outboundErrors.isEmpty {
                            Button {
                                state.clearOutboundErrors()
                            } label: {
                                Label("清空异常记录", systemImage: "trash")
                            }
                            .controlSize(.small)
                            .fixedSize(horizontal: true, vertical: false)
                            .help("清空已捕获的历史拨号报错计数")
                        }
                    }
                }
            }

            SplitHeaderBar(horizontalSpacing: 14, verticalSpacing: 4) {
                FlowLayout(horizontalSpacing: 10, verticalSpacing: 4) {
                    Label("活跃连接 \(snap.totalActiveConnections)", systemImage: "link")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    HStack(spacing: 6) {
                        Text("实时总吞吐")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        MonospacedMetricText(
                            "↓ \(TrafficFormatter.speed(snap.totalDownloadSpeed))",
                            color: .green
                        )
                        MonospacedMetricText(
                            "↑ \(TrafficFormatter.speed(snap.totalUploadSpeed))",
                            color: .blue
                        )
                    }
                }
            } trailing: {
                Text("点击任意目标或跳点卡片可展开右侧排障面板、执行双跳测速或切换节点")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func statusSummaryPill(_ snap: TopologySnapshot) -> some View {
        if !snap.isCoreRunning {
            StatusPill("核心未运行（静态拓扑预览）", systemImage: "pause.circle", color: .secondary)
        } else if snap.errorCount > 0 {
            StatusPill(
                "\(snap.errorCount) 条链路中断",
                systemImage: "xmark.octagon.fill",
                color: .red
            )
        } else if snap.warningCount > 0 {
            StatusPill(
                "\(snap.warningCount) 条链路预警",
                systemImage: "exclamationmark.triangle.fill",
                color: .orange
            )
        } else {
            StatusPill("全链路连通正常", systemImage: "checkmark.circle.fill", color: .green)
        }
    }

    private var offlineHintBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
            Text("当前展示静态分流与链式结构预览；启动核心后将实时绘制各规则组流量传输与每一跳的健康/断点状态。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("启动核心") {
                state.start()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(!state.canStart)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.08)))
    }

    private func activeAnomalySummaryStrip(_ snap: TopologySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(snap.issueLanes) { lane in
                if let diag = lane.diagnosis {
                    let isError = diag.severity == .error
                    let accent: Color = isError ? .red : .orange
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 2) {
                            FlowLayout(horizontalSpacing: 6, verticalSpacing: 2) {
                                Text("目标「\(lane.name)」· \(diag.headline)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(accent)
                                    .lineLimit(1)
                                if !lane.affectedBranchNames.isEmpty {
                                    Text("波及：\(lane.affectedBranchNames.prefix(4).joined(separator: "、"))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Text(diag.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 6) {
                            if lane.mode == .proxy {
                                Button("双跳测速") {
                                    state.selectedTopologyTargetKey = lane.id
                                    state.diagnoseTargetHops(targetName: lane.name)
                                }
                                .controlSize(.mini)
                                .fixedSize(horizontal: true, vertical: false)
                            }
                            Button(state.selectedTopologyTargetKey == lane.id ? "已展开详情" : "排障详情") {
                                state.selectedTopologyTargetKey = lane.id
                            }
                            .controlSize(.mini)
                            .buttonStyle(.borderedProminent)
                            .tint(accent)
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(accent.opacity(0.09))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(accent.opacity(0.28))
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private var emptyTopologyState: some View {
        SectionCard("暂无活跃分流链路", icon: "point.3.connected.trianglepath.dotted") {
            InlineNote("请先在「网络目标」与「规则组」页面配置分流目标。")
        }
    }

    // MARK: - Main Fused / Targets-Only Graph Body

    @ViewBuilder
    private func topologyGraphBody(snap: TopologySnapshot, hasLiveFlow: Bool, canvasWidth: CGFloat) -> some View {
        if displayMode == .targetsOnly {
            VStack(spacing: 14) {
                ForEach(snap.lanes) { lane in
                    targetPipelineCard(lane: lane, showAffectedBranchesInline: true)
                }
            }
        } else if canvasWidth < Self.horizontalClusterBreakpoint {
            // L4 Responsive Breakpoint: when the canvas is narrower than 580pt, stack rule group
            // branches cleanly above each target trunk so target cards always retain 100% width.
            VStack(spacing: 16) {
                ForEach(snap.lanes) { lane in
                    compactStackedLaneCluster(lane: lane)
                }
            }
        } else {
            let linkSpecs = buildLinkSpecs(for: snap)
            VStack(spacing: 16) {
                ForEach(snap.lanes) { lane in
                    fusedLaneCluster(lane: lane)
                }
            }
            .padding(.vertical, 4)
            .background {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !hasLiveFlow)) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate
                    TopologyBezierCanvas(
                        links: linkSpecs,
                        portFrames: portFrames,
                        animationTime: phase
                    )
                }
            }
            .coordinateSpace(name: Self.canvasSpaceName)
            .onPreferenceChange(TopologyPortFramesKey.self) { updated in
                portFrames = updated
            }
        }
    }

    private func visibleAndCollapsedBranches(for lane: TopologyTargetLane) -> (visible: [TopologyRuleBranch], collapsed: [TopologyRuleBranch]) {
        guard collapseIdleBranches,
              !expandedIdleLaneIDs.contains(lane.id),
              lane.health != .error,
              lane.health != .warning else {
            return (lane.branches, [])
        }
        var activeOrRecent: [TopologyRuleBranch] = []
        var idle: [TopologyRuleBranch] = []
        for branch in lane.branches {
            if branch.activeConnectionCount > 0 || branch.totalSpeed > 0 || branch.recentErrorCount > 0 || branch.isFallbackMatch {
                activeOrRecent.append(branch)
            } else {
                idle.append(branch)
            }
        }
        if activeOrRecent.isEmpty, let first = idle.first {
            activeOrRecent.append(first)
            idle.removeFirst()
        }
        guard idle.count >= 2 else {
            return (lane.branches, [])
        }
        return (activeOrRecent, idle)
    }

    private func buildLinkSpecs(for snap: TopologySnapshot) -> [TopologyLinkSpec] {
        var specs: [TopologyLinkSpec] = []
        for lane in snap.lanes {
            let split = visibleAndCollapsedBranches(for: lane)
            let targetPort = "target-in:\(lane.id)"
            for branch in split.visible {
                let isHighlighted = highlightedBranchID == branch.id || state.selectedTopologyTargetKey == lane.id
                let branchHealth: TopologyHealthState = {
                    if lane.health == .error { return .error }
                    if lane.health == .warning || branch.recentErrorCount > 0 { return .warning }
                    return branch.totalSpeed > 0 || branch.activeConnectionCount > 0 ? .healthy : .idle
                }()
                specs.append(
                    TopologyLinkSpec(
                        id: "link:\(branch.id)->\(lane.id)",
                        fromPortID: "branch-out:\(branch.id)",
                        toPortID: targetPort,
                        speedBytesPerSec: branch.totalSpeed,
                        isActive: branch.activeConnectionCount > 0 || branch.totalSpeed > 0,
                        health: branchHealth,
                        isHighlighted: isHighlighted
                    )
                )
            }
            if !split.collapsed.isEmpty {
                specs.append(
                    TopologyLinkSpec(
                        id: "link:collapsed-\(lane.id)->\(lane.id)",
                        fromPortID: "branch-out:collapsed-\(lane.id)",
                        toPortID: targetPort,
                        speedBytesPerSec: 0,
                        isActive: false,
                        health: .idle,
                        isHighlighted: state.selectedTopologyTargetKey == lane.id
                    )
                )
            }
        }
        return specs
    }

    private func fusedLaneCluster(lane: TopologyTargetLane) -> some View {
        let split = visibleAndCollapsedBranches(for: lane)

        return HStack(alignment: .center, spacing: 36) {
            // Left Column: Rule Group Branches feeding into this Target Lane
            VStack(alignment: .trailing, spacing: 8) {
                if split.visible.isEmpty && split.collapsed.isEmpty {
                    Text("仅用于 DNS / 规则集代理")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(width: 214, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                        )
                } else {
                    ForEach(split.visible) { branch in
                        ruleBranchCard(branch: branch, parentLane: lane, cardWidth: 214)
                    }
                    if !split.collapsed.isEmpty {
                        collapsedBranchesPill(collapsed: split.collapsed, laneID: lane.id, cardWidth: 214)
                    }
                }
                if expandedIdleLaneIDs.contains(lane.id) && collapseIdleBranches && lane.branches.count > 2 {
                    Button {
                        expandedIdleLaneIDs.remove(lane.id)
                    } label: {
                        Label("收起空闲规则组", systemImage: "chevron.up")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(width: 220)

            // Right Side: Target Trunk + Hop-by-Hop Pipeline
            targetPipelineCard(lane: lane, showAffectedBranchesInline: false)
                .frame(minWidth: 320, maxWidth: .infinity)
                .background(alignment: .leading) {
                    portAnchor("target-in:\(lane.id)")
                        .offset(x: -4)
                }
        }
    }

    private func compactStackedLaneCluster(lane: TopologyTargetLane) -> some View {
        let split = visibleAndCollapsedBranches(for: lane)

        return VStack(alignment: .leading, spacing: 6) {
            if !split.visible.isEmpty || !split.collapsed.isEmpty {
                FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(split.visible) { branch in
                        compactRuleBranchChip(branch: branch, parentLane: lane)
                    }
                    if !split.collapsed.isEmpty {
                        Button {
                            expandedIdleLaneIDs.insert(lane.id)
                        } label: {
                            Label("+\(split.collapsed.count) 个空闲规则组", systemImage: "plus.circle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(Color.secondary.opacity(0.09))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    if expandedIdleLaneIDs.contains(lane.id) && collapseIdleBranches && lane.branches.count > 2 {
                        Button {
                            expandedIdleLaneIDs.remove(lane.id)
                        } label: {
                            Label("收起空闲", systemImage: "chevron.up")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(lane.health == .error ? Color.red.opacity(0.75) : Color.secondary.opacity(0.5))
                    Text("汇入目标链路")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 6)
            }

            targetPipelineCard(lane: lane, showAffectedBranchesInline: false)
        }
    }

    private func compactRuleBranchChip(branch: TopologyRuleBranch, parentLane: TopologyTargetLane) -> some View {
        let isSelected = highlightedBranchID == branch.id
        let isParentBroken = parentLane.health == .error
        let hasLive = branch.totalSpeed > 0 || branch.activeConnectionCount > 0

        return Button {
            if highlightedBranchID == branch.id {
                highlightedBranchID = nil
            } else {
                highlightedBranchID = branch.id
                state.selectedTopologyTargetKey = parentLane.id
            }
        } label: {
            HStack(spacing: 5) {
                Text("#\(branch.rank)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Image(systemName: branch.icon)
                    .font(.caption2)
                    .foregroundStyle(isParentBroken ? .red : (hasLive ? .green : .secondary))
                Text(branch.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if branch.activeConnectionCount > 0 {
                    Text("\(branch.activeConnectionCount)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isParentBroken ? .red : .teal)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 0.5)
                        .background(Capsule().fill((isParentBroken ? Color.red : Color.teal).opacity(0.14)))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : (hasLive ? Color.green.opacity(0.45) : Color.secondary.opacity(0.2)),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
    }

    private func ruleBranchCard(branch: TopologyRuleBranch, parentLane: TopologyTargetLane, cardWidth: CGFloat) -> some View {
        let isSelected = highlightedBranchID == branch.id
        let isParentBroken = parentLane.health == .error
        let hasLive = branch.totalSpeed > 0 || branch.activeConnectionCount > 0
        let borderColor: Color = {
            if isParentBroken { return .red.opacity(0.45) }
            if isSelected { return .accentColor }
            if hasLive { return .green.opacity(0.45) }
            return Color.secondary.opacity(0.18)
        }()

        return Button {
            if highlightedBranchID == branch.id {
                highlightedBranchID = nil
            } else {
                highlightedBranchID = branch.id
                state.selectedTopologyTargetKey = parentLane.id
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("#\(branch.rank)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Image(systemName: branch.icon)
                        .font(.caption)
                        .foregroundStyle(isParentBroken ? .red : (hasLive ? .green : .secondary))
                    Text(branch.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if branch.activeConnectionCount > 0 {
                        Text("\(branch.activeConnectionCount)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(isParentBroken ? .red : .teal)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill((isParentBroken ? Color.red : Color.teal).opacity(0.14)))
                    }
                }

                if !branch.aliasChain.isEmpty {
                    Text("经由指向：\(branch.aliasChain.joined(separator: " → "))")
                        .font(.system(size: 10))
                        .foregroundStyle(.indigo)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    if branch.totalSpeed > 0 {
                        Text("↓\(TrafficFormatter.shortSpeed(branch.downloadSpeed))")
                            .foregroundStyle(.green)
                        if branch.uploadSpeed > 0 {
                            Text("↑\(TrafficFormatter.shortSpeed(branch.uploadSpeed))")
                                .foregroundStyle(.blue)
                        }
                    } else if branch.sessionBytes > 0 {
                        Text("累计 \(TrafficFormatter.shortBytes(branch.sessionBytes))")
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(branch.isFallbackMatch ? "未命中前序规则时兜底" : "\(branch.enabledRuleCount) 条规则")
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    if branch.recentErrorCount > 0 {
                        Text("\(branch.recentErrorCount) 报错")
                            .foregroundStyle(.red)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: cardWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: isSelected || hasLive ? 1.3 : 1)
            }
            .background(alignment: .trailing) {
                portAnchor("branch-out:\(branch.id)")
                    .offset(x: 4)
            }
        }
        .buttonStyle(.plain)
    }

    private func collapsedBranchesPill(collapsed: [TopologyRuleBranch], laneID: String, cardWidth: CGFloat) -> some View {
        Button {
            expandedIdleLaneIDs.insert(laneID)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("其余 \(collapsed.count) 个空闲规则组（\(collapsed.prefix(2).map(\.name).joined(separator: "、"))\(collapsed.count > 2 ? "…" : "")）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: cardWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.07))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .background(alignment: .trailing) {
                portAnchor("branch-out:collapsed-\(laneID)")
                    .offset(x: 4)
            }
        }
        .buttonStyle(.plain)
    }

    private func portAnchor(_ id: String) -> some View {
        Color.clear
            .frame(width: 8, height: 8)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: TopologyPortFramesKey.self,
                        value: [id: geo.frame(in: .named(Self.canvasSpaceName))]
                    )
                }
            )
    }

    // MARK: - Target Trunk & Per-Hop Pipeline Card

    private func targetPipelineCard(lane: TopologyTargetLane, showAffectedBranchesInline: Bool) -> some View {
        let isSelected = state.selectedTopologyTargetKey == lane.id
        let accent = healthColor(for: lane.health, isReject: lane.isRejectBuiltin)
        let isFlowing = lane.totalSpeed > 0

        return Button {
            if state.selectedTopologyTargetKey == lane.id {
                state.selectedTopologyTargetKey = nil
            } else {
                state.selectedTopologyTargetKey = lane.id
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                // Top Header Bar of Target Lane: atomic single-line pills + automatic wrap when narrow
                SplitHeaderBar(horizontalSpacing: 10, verticalSpacing: 6) {
                    FlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: targetIcon(for: lane))
                                .foregroundStyle(accent)
                                .font(.subheadline.weight(.semibold))

                            Text(lane.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        .fixedSize(horizontal: true, vertical: false)

                        if let mode = lane.mode {
                            StatusPill(
                                lane.hasRelayHop ? "链式代理" : mode.title,
                                color: lane.hasRelayHop ? .purple : (mode == .direct ? .green : .blue)
                            )
                        }

                        if !lane.aliasReferrers.isEmpty {
                            StatusPill(
                                "被指向：\(lane.aliasReferrers.joined(separator: "、"))",
                                systemImage: "arrow.turn.down.right",
                                color: .indigo,
                                maxWidth: 190
                            )
                        }

                        laneHealthBadge(lane)
                    }
                } trailing: {
                    FlowLayout(horizontalSpacing: 8, verticalSpacing: 4) {
                        if lane.activeConnectionCount > 0 {
                            MonospacedMetricText("\(lane.activeConnectionCount) 活跃", color: .secondary)
                        }
                        if isFlowing {
                            MonospacedMetricText(
                                "↓ \(TrafficFormatter.shortSpeed(lane.downloadSpeed))",
                                color: .green
                            )
                            if lane.uploadSpeed > 0 {
                                MonospacedMetricText(
                                    "↑ \(TrafficFormatter.shortSpeed(lane.uploadSpeed))",
                                    color: .blue
                                )
                            }
                        } else if lane.sessionTotal > 0 {
                            MonospacedMetricText(
                                "本次 \(TrafficFormatter.shortBytes(lane.sessionTotal))",
                                color: .secondary.opacity(0.75)
                            )
                        }

                        if state.isCoreRunning && lane.mode == .proxy {
                            let testingThis = liveProxyStore.testingGroups.contains(lane.name)
                                || (lane.relayGroupName.map { liveProxyStore.testingGroups.contains($0) } ?? false)
                            Button {
                                state.selectedTopologyTargetKey = lane.id
                                state.diagnoseTargetHops(targetName: lane.name)
                            } label: {
                                if testingThis {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "speedometer")
                                        .font(.caption)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .fixedSize(horizontal: true, vertical: false)
                            .disabled(testingThis)
                            .help(lane.hasRelayHop ? "双跳测速：同时探测「链式跳」与「出口跳」定位断点" : "测试出口节点延迟")
                        }
                    }
                }

                // Hop-by-Hop Visual Pipeline
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(lane.hops.enumerated()), id: \.element.id) { index, hop in
                            if index > 0 {
                                hopStepConnector(
                                    previous: lane.hops[index - 1],
                                    current: hop,
                                    isFlowing: isFlowing
                                )
                            }
                            hopNodeBox(hop: hop)
                        }
                    }
                    .padding(.vertical, 2)
                }

                // Inline Fault Headline if Unhealthy
                if let diag = lane.diagnosis {
                    HStack(spacing: 6) {
                        Image(systemName: diag.severity == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption)
                        Text("\(diag.headline)：\(diag.detail)")
                            .font(.caption)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(diag.severity == .error ? Color.red : Color.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill((diag.severity == .error ? Color.red : Color.orange).opacity(0.08))
                    )
                } else if showAffectedBranchesInline && !lane.branches.isEmpty {
                    Text("关联规则组：\(lane.branches.map(\.name).joined(separator: "、"))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? Color.accentColor
                            : (lane.health == .error
                                ? Color.red.opacity(0.55)
                                : (lane.health == .warning ? Color.orange.opacity(0.45) : Color.secondary.opacity(0.18))),
                        lineWidth: isSelected || lane.health >= .warning ? 1.6 : 1.0
                    )
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func laneHealthBadge(_ lane: TopologyTargetLane) -> some View {
        if lane.isRejectBuiltin {
            StatusPill("策略阻断", color: .red)
        } else {
            switch lane.health {
            case .idle:
                EmptyView()
            case .healthy:
                if lane.totalSpeed > 0 {
                    StatusPill("传输中", systemImage: "bolt.horizontal.fill", color: .green)
                } else {
                    StatusPill("连通正常", systemImage: "checkmark.circle.fill", color: .green)
                }
            case .warning:
                StatusPill(
                    lane.diagnosis?.headline ?? "链路预警",
                    systemImage: "exclamationmark.triangle.fill",
                    color: .orange
                )
            case .error:
                let shortLabel: String = {
                    switch lane.diagnosis?.brokenHop {
                    case .interface: return "网卡离线"
                    case .relay: return "第一跳中断"
                    case .exit: return lane.hasRelayHop ? "第二跳中断" : "出口中断"
                    case .none: return "链路中断"
                    }
                }()
                StatusPill(shortLabel, systemImage: "xmark.octagon.fill", color: .red)
            }
        }
    }

    private func hopNodeBox(hop: TopologyHopNode) -> some View {
        let color = hopAccentColor(hop)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: hopSymbol(hop))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)
                Text(hop.roleLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if hop.isTesting {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(hop.statusText)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(color.opacity(0.13)))
                }
            }

            Text(hop.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(hop.health == .error ? .red : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 178, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    hop.health == .error
                        ? Color.red.opacity(0.08)
                        : Color(nsColor: .textBackgroundColor).opacity(0.65)
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    hop.health == .error
                        ? Color.red.opacity(0.55)
                        : (hop.health == .warning ? Color.orange.opacity(0.45) : Color.secondary.opacity(0.16)),
                    lineWidth: hop.health == .error ? 1.4 : 1.0
                )
        }
    }

    private func hopStepConnector(previous: TopologyHopNode, current: TopologyHopNode, isFlowing: Bool) -> some View {
        let isBrokenHere = current.health == .error && previous.health != .error
        let isBlockedUpstream = previous.health == .error
        let lineColor: Color = {
            if isBrokenHere { return .red }
            if isBlockedUpstream { return .secondary.opacity(0.35) }
            if isFlowing { return .green }
            return .secondary.opacity(0.45)
        }()

        return HStack(spacing: 2) {
            Rectangle()
                .fill(lineColor)
                .frame(width: 14, height: isBrokenHere || isFlowing ? 2 : 1.2)
            Image(systemName: isBrokenHere ? "xmark.circle.fill" : "arrow.right")
                .font(.system(size: isBrokenHere ? 11 : 10, weight: .bold))
                .foregroundStyle(lineColor)
            if isBrokenHere {
                Rectangle()
                    .fill(lineColor.opacity(0.45))
                    .frame(width: 10, height: 1.5)
            }
        }
        .padding(.horizontal, 4)
    }

    private var legendFooter: some View {
        FlowLayout(horizontalSpacing: 16, verticalSpacing: 6) {
            legendItem(color: .green, title: "实时传输 / 节点连通正常")
            legendItem(color: .orange, title: "高延迟 / 疑似静默丢包预警")
            legendItem(color: .red, title: "精确断跳（网卡离线 / 第一跳链式断 / 第二跳出口断）")
            legendItem(color: .secondary, title: "当前空闲待命")
        }
        .padding(.top, 4)
    }

    private func legendItem(color: Color, title: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func targetIcon(for lane: TopologyTargetLane) -> String {
        if lane.isRejectBuiltin { return "hand.raised.fill" }
        switch lane.mode {
        case .direct: return "cable.connector"
        case .proxy: return lane.hasRelayHop ? "point.3.connected.trianglepath.dotted" : "network"
        case .alias, .none: return "arrow.triangle.branch"
        }
    }

    private func healthColor(for health: TopologyHealthState, isReject: Bool) -> Color {
        if isReject { return .red }
        switch health {
        case .idle: return .secondary
        case .healthy: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func hopAccentColor(_ hop: TopologyHopNode) -> Color {
        switch hop.health {
        case .error: return .red
        case .warning: return .orange
        case .healthy:
            if let ms = hop.latencyMs, ms >= 350 { return .orange }
            return .green
        case .idle: return .secondary
        }
    }

    private func hopSymbol(_ hop: TopologyHopNode) -> String {
        switch hop.kind {
        case .relay: return "arrow.triangle.swap"
        case .exit: return "globe.americas.fill"
        case .interface: return "ethernet"
        }
    }
}

// MARK: - Smooth Bézier Flow Canvas (Rule Group -> Target Trunk)

private struct TopologyBezierCanvas: View {
    let links: [TopologyLinkSpec]
    let portFrames: [String: CGRect]
    let animationTime: TimeInterval

    var body: some View {
        Canvas { context, _ in
            for link in links {
                guard let fromRect = portFrames[link.fromPortID],
                      let toRect = portFrames[link.toPortID] else {
                    continue
                }
                let start = CGPoint(x: fromRect.midX, y: fromRect.midY)
                let end = CGPoint(x: toRect.midX, y: toRect.midY)
                let dx = max(22, (end.x - start.x) * 0.52)

                var path = Path()
                path.move(to: start)
                path.addCurve(
                    to: end,
                    control1: CGPoint(x: start.x + dx, y: start.y),
                    control2: CGPoint(x: end.x - dx, y: end.y)
                )

                let baseWidth: CGFloat = {
                    if link.speedBytesPerSec > 5_000_000 { return 3.8 }
                    if link.speedBytesPerSec > 500_000 { return 3.0 }
                    if link.speedBytesPerSec > 0 { return 2.2 }
                    return link.isHighlighted ? 1.8 : 1.2
                }()

                let strokeColor: Color = {
                    switch link.health {
                    case .error:
                        return Color.red.opacity(link.isHighlighted ? 0.85 : 0.55)
                    case .warning:
                        return Color.orange.opacity(link.isHighlighted ? 0.85 : 0.55)
                    case .healthy:
                        return link.speedBytesPerSec > 0
                            ? Color.green.opacity(0.75)
                            : Color.teal.opacity(link.isHighlighted ? 0.65 : 0.38)
                    case .idle:
                        return link.isHighlighted
                            ? Color.accentColor.opacity(0.65)
                            : Color.secondary.opacity(0.24)
                    }
                }()

                if link.health == .error {
                    context.stroke(
                        path,
                        with: .color(strokeColor),
                        style: StrokeStyle(lineWidth: baseWidth, lineCap: .round, dash: [5, 4])
                    )
                } else {
                    context.stroke(
                        path,
                        with: .color(strokeColor),
                        style: StrokeStyle(lineWidth: baseWidth, lineCap: .round)
                    )
                }

                // Draw animated flowing packets when bytes are actively moving on a non-broken link
                if link.speedBytesPerSec > 0 && link.health != .error {
                    let particleCount = link.speedBytesPerSec > 1_000_000 ? 3 : 2
                    let cycleSpeed = link.speedBytesPerSec > 1_000_000 ? 0.95 : 0.55
                    for i in 0..<particleCount {
                        let offset = Double(i) / Double(particleCount)
                        let rawT = (animationTime * cycleSpeed + offset).truncatingRemainder(dividingBy: 1.0)
                        let t = CGFloat(rawT < 0 ? rawT + 1.0 : rawT)
                        let pt = cubicBezierPoint(
                            t: t,
                            p0: start,
                            p1: CGPoint(x: start.x + dx, y: start.y),
                            p2: CGPoint(x: end.x - dx, y: end.y),
                            p3: end
                        )
                        let dotRect = CGRect(x: pt.x - 3.2, y: pt.y - 3.2, width: 6.4, height: 6.4)
                        context.fill(Path(ellipseIn: dotRect), with: .color(.green))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func cubicBezierPoint(t: CGFloat, p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint) -> CGPoint {
        let u = 1 - t
        let tt = t * t
        let uu = u * u
        let uuu = uu * u
        let ttt = tt * t

        let x = uuu * p0.x + 3 * uu * t * p1.x + 3 * u * tt * p2.x + ttt * p3.x
        let y = uuu * p0.y + 3 * uu * t * p1.y + 3 * u * tt * p2.y + ttt * p3.y
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Right-Side Diagnostic & Node Switching Inspector Drawer

private struct TopologyInspectorDrawer: View {
    @ObservedObject var state: AppState
    @ObservedObject var liveProxyStore: LiveProxyStore
    let lane: TopologyTargetLane
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            StatusPill(
                                lane.health == .error
                                    ? "链路异常"
                                    : (lane.health == .warning ? "链路预警" : (state.isCoreRunning ? "链路正常" : "静态预览")),
                                color: lane.health == .error ? .red : (lane.health == .warning ? .orange : (state.isCoreRunning ? .green : .secondary))
                            )
                            if let mode = lane.mode {
                                Text(lane.hasRelayHop ? "链式双跳出口" : mode.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(lane.name)
                            .font(.headline)
                    }
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("关闭详情面板")
                }

                if state.isCoreRunning && !lane.isRejectBuiltin {
                    FlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                        if lane.mode == .proxy {
                            let isTesting = liveProxyStore.testingGroups.contains(lane.name)
                                || (lane.relayGroupName.map { liveProxyStore.testingGroups.contains($0) } ?? false)
                            Button {
                                state.diagnoseTargetHops(targetName: lane.name)
                            } label: {
                                if isTesting {
                                    HStack(spacing: 4) {
                                        ProgressView().controlSize(.mini)
                                        Text("探测中…")
                                    }
                                } else {
                                    Label(lane.hasRelayHop ? "双跳测速定位" : "测速核实", systemImage: "stethoscope")
                                }
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .fixedSize(horizontal: true, vertical: false)
                            .disabled(isTesting)
                        }

                        Button {
                            state.selectedSection = .monitor
                        } label: {
                            Label("查看请求", systemImage: "waveform.path.ecg")
                        }
                        .controlSize(.small)
                        .fixedSize(horizontal: true, vertical: false)

                        Button {
                            state.copyText(exportDiagnosticReport(), label: "链路排障摘要")
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .controlSize(.small)
                        .help("复制此目标的链路排障摘要")
                    }
                }

                if let diag = lane.diagnosis {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            diag.headline,
                            systemImage: diag.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(diag.severity == .error ? .red : .orange)

                        Text(diag.detail)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill((diag.severity == .error ? Color.red : Color.orange).opacity(0.10))
                    )
                }

                Divider()

                // Hop-by-hop details & quick node switcher
                VStack(alignment: .leading, spacing: 10) {
                    Text("逐跳状态与节点切换")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(lane.hops) { hop in
                        inspectorHopSection(hop)
                    }
                }

                if !lane.branches.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("汇入的规则组 (\(lane.branches.count))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(lane.branches) { branch in
                            HStack(spacing: 6) {
                                Image(systemName: branch.icon)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)
                                Text(branch.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 6)
                                if branch.totalSpeed > 0 {
                                    Text("↓\(TrafficFormatter.shortSpeed(branch.downloadSpeed))")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.green)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                } else if branch.activeConnectionCount > 0 {
                                    Text("\(branch.activeConnectionCount) 活跃")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                        }
                    }
                }

                if !lane.recentErrors.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("最近拨号异常日志 (\(lane.recentErrors.count))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)

                        ForEach(lane.recentErrors.prefix(8)) { err in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(MonitorTimeFormatter.string(from: err.timestamp))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                    Text(err.outboundGroup)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(err.suspectedHop == .relay ? .purple : .blue)
                                    Spacer()
                                    Text(err.category.shortTitle)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.red)
                                }
                                if !err.destination.isEmpty {
                                    Text("目标：\(err.destination)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                                Text(err.reason)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.65))
                            )
                        }
                    }
                }

                if !lane.recentDNSFailures.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("关联代理 DoH 解析失败 (\(lane.recentDNSFailures.count))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)

                        ForEach(lane.recentDNSFailures.prefix(5)) { dns in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(dns.domain) (\(dns.recordType))")
                                    .font(.system(size: 11, design: .monospaced).weight(.medium))
                                Text(dns.answerSummary)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.65))
                            )
                        }
                    }
                }
            }
            .padding(16)
            .lockScrollDocumentWidth()
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    @ViewBuilder
    private func inspectorHopSection(_ hop: TopologyHopNode) -> some View {
        let accent: Color = hop.health == .error ? .red : (hop.health == .warning ? .orange : .green)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(hop.roleLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let gName = hop.groupName {
                    Text(hop.isAutoTest ? "自动测速" : "手动选择")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                    if state.isCoreRunning {
                        Button("单跳测速") {
                            state.testGroupDelay(group: gName)
                        }
                        .controlSize(.mini)
                        .fixedSize(horizontal: true, vertical: false)
                        .disabled(hop.isTesting || hop.candidateNodes == ["REJECT"])
                    }
                } else {
                    Spacer()
                }
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(state.isCoreRunning ? accent : .secondary)
                    .frame(width: 7, height: 7)
                Text(hop.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text(hop.statusText)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(state.isCoreRunning ? accent : .secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if state.isCoreRunning,
               let groupName = hop.groupName,
               !hop.isAutoTest,
               hop.candidateNodes.count > 1,
               hop.candidateNodes != ["REJECT"] {
                HStack(spacing: 6) {
                    Text("切换节点")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                    Picker("", selection: Binding(
                        get: { liveProxyStore.groupSelection[groupName] ?? hop.selectedRawNode ?? "" },
                        set: { state.selectNode(group: groupName, node: $0) }
                    )) {
                        ForEach(hop.candidateNodes, id: \.self) { candidate in
                            let displayName = TopologySnapshotBuilder.stripTargetNodePrefix(candidate, targetName: lane.name)
                            if hop.timedOutNodes.contains(candidate) {
                                Text("\(displayName) (超时)").tag(candidate)
                            } else if let d = hop.nodeDelays[candidate] {
                                Text("\(displayName) (\(d) ms)").tag(candidate)
                            } else {
                                Text(displayName).tag(candidate)
                            }
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .disabled(liveProxyStore.readsGroups)
                }
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
        )
    }

    private func exportDiagnosticReport() -> String {
        var lines: [String] = [
            "网络目标: \(lane.name)",
            "状态: \(lane.diagnosis?.headline ?? (state.isCoreRunning ? "连通正常" : "核心未运行"))",
        ]
        if let detail = lane.diagnosis?.detail {
            lines.append("诊断说明: \(detail)")
        }
        let hopDesc = lane.hops.map { "\($0.roleLabel)=\($0.title) [\($0.statusText)]" }.joined(separator: " -> ")
        lines.append("逐跳链路: \(hopDesc)")
        if !lane.affectedBranchNames.isEmpty {
            lines.append("关联规则组: \(lane.affectedBranchNames.joined(separator: "、"))")
        }
        for err in lane.recentErrors.prefix(5) {
            lines.append("最近报错: [\(MonitorTimeFormatter.string(from: err.timestamp))] \(err.outboundGroup) \(err.destination) -> \(err.reason)")
        }
        return lines.joined(separator: "\n")
    }
}
