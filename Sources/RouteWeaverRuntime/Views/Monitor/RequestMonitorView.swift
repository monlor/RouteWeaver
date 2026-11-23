import RoutingCore
import SwiftUI

enum MonitorTimeFormatter {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}

struct MonitorInspectorRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private enum MonitorTab: String, CaseIterable, Identifiable {
    case connections
    case dns

    var id: String { rawValue }
}

struct RequestMonitorView: View {
    @ObservedObject var state: AppState
    @ObservedObject var monitor: ConnectionMonitorService

    @State private var activeTab: MonitorTab = .connections
    @State private var searchText = ""
    @State private var scope: ConnectionFilterScope = .all
    @State private var dnsScope: DNSLogFilterScope = .all
    @State private var dnsSourceFilter: DNSLogSourceFilter = .all
    @State private var hideEmptyDNSAnswers = false
    @State private var selectedTarget: String? = nil
    @State private var sortOrder: ConnectionSortOrder = .newest
    @State private var selectedConnectionID: String? = nil
    @State private var selectedDNSLogID: UUID? = nil
    @State private var showSpeedChart = true
    @State private var showInnerConnections = false

    private var ruleIndex: RuleMatchDisplayIndex {
        state.ruleMatchDisplayIndex
    }

    private var filteredConnections: [MonitoredConnection] {
        monitor.tracker.filtered(
            scope: scope,
            searchText: searchText,
            targetFilter: selectedTarget,
            sortOrder: sortOrder,
            ruleIndex: ruleIndex,
            includeInner: showInnerConnections
        )
    }

    private var filteredDNSLogs: [DNSLogRecord] {
        monitor.filteredDNSLogs(
            scope: dnsScope,
            sourceFilter: dnsSourceFilter,
            hideEmptyAnswers: hideEmptyDNSAnswers,
            searchText: searchText
        )
    }

    private var selectedConnection: MonitoredConnection? {
        guard let id = selectedConnectionID else { return nil }
        return monitor.tracker.recordsByID[id]
    }

    private var selectedDNSLog: DNSLogRecord? {
        guard let id = selectedDNSLogID else { return nil }
        return monitor.dnsLogs.first(where: { $0.id == id })
    }

    private var availableTargets: [String] {
        monitor.tracker.availableTargets(includeInner: showInnerConnections)
    }

    private func resolvedRelayChain(for item: MonitoredConnection) -> ResolvedRelayChain? {
        let currentNodes = state.liveProxyStore.groupStatus.mapValues(\.now)
        return RelayChainResolver.resolve(
            for: item,
            profile: state.profile,
            runtimeCurrentNodes: currentNodes,
            runtimeSelections: state.liveProxyStore.groupSelection
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            topHeaderArea
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            if !state.engine.isRunning && monitor.tracker.recordsByID.isEmpty && monitor.dnsLogs.isEmpty {
                idleEmptyState
            } else if activeTab == .dns {
                HStack(spacing: 0) {
                    DNSLogListView(
                        state: state,
                        monitor: monitor,
                        rows: filteredDNSLogs,
                        selectedDNSLogID: $selectedDNSLogID,
                        onResetFilters: {
                            searchText = ""
                            dnsScope = .all
                            dnsSourceFilter = .all
                            hideEmptyDNSAnswers = false
                        }
                    )
                    if let selected = selectedDNSLog {
                        Divider()
                        DNSLogInspectorView(
                            state: state,
                            item: selected,
                            onClose: { selectedDNSLogID = nil }
                        )
                        .frame(width: 336)
                    }
                }
            } else {
                HStack(spacing: 0) {
                    ConnectionListView(
                        state: state,
                        monitor: monitor,
                        rows: filteredConnections,
                        ruleIndex: ruleIndex,
                        selectedConnectionID: $selectedConnectionID,
                        resolveRelayChain: resolvedRelayChain(for:),
                        onResetFilters: {
                            searchText = ""
                            scope = .all
                            selectedTarget = nil
                        }
                    )
                    if let selected = selectedConnection {
                        Divider()
                        ConnectionInspectorView(
                            state: state,
                            item: selected,
                            ruleIndex: ruleIndex,
                            relayChain: resolvedRelayChain(for: selected),
                            onClose: { selectedConnectionID = nil }
                        )
                        .frame(width: 336)
                    }
                }
            }
        }
    }

    // MARK: - Top Metrics & Filter Bar

    private var topHeaderArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            metricsStrip
            if showSpeedChart && activeTab == .connections && (state.engine.isRunning || !monitor.tracker.speedHistory.isEmpty) {
                LiveSpeedSparklineCard(monitor: monitor, isRunning: state.engine.isRunning)
            }
            filterControlBar
        }
    }

    private var metricsStrip: some View {
        HStack(spacing: 12) {
            metricTile(
                title: "实时上传",
                value: TrafficFormatter.speed(monitor.tracker.uploadSpeed),
                subtitle: "累计 \(TrafficFormatter.bytes(monitor.tracker.uploadTotal))",
                icon: "arrow.up.circle.fill",
                color: .blue
            )

            metricTile(
                title: "实时下载",
                value: TrafficFormatter.speed(monitor.tracker.downloadSpeed),
                subtitle: "累计 \(TrafficFormatter.bytes(monitor.tracker.downloadTotal))",
                icon: "arrow.down.circle.fill",
                color: .green
            )

            let displayedActiveCount = showInnerConnections ? monitor.tracker.activeCount : monitor.tracker.businessActiveCount
            let displayedClosedCount = showInnerConnections ? monitor.tracker.closedCount : monitor.tracker.businessClosedCount
            let hiddenInnerCount = showInnerConnections ? 0 : monitor.tracker.innerCount
            metricTile(
                title: "连接统计",
                value: "\(displayedActiveCount) 活跃",
                subtitle: hiddenInnerCount > 0
                    ? "历史 \(displayedClosedCount) 条 · 隐藏 \(hiddenInnerCount) 条内部"
                    : "历史 \(displayedClosedCount) 条 · 上限 \(monitor.tracker.maxClosedHistory)",
                icon: "link.circle.fill",
                color: .purple
            )

            metricTile(
                title: "内核内存",
                value: monitor.tracker.memoryUsage > 0
                    ? TrafficFormatter.bytes(monitor.tracker.memoryUsage)
                    : "—",
                subtitle: streamStatusSubtitle,
                icon: "memorychip",
                color: .orange
            )
        }
    }

    private var streamStatusSubtitle: String {
        if !state.engine.isRunning { return "核心未运行" }
        if monitor.isPaused { return "界面已暂停刷新" }
        if monitor.isStreaming { return "实时监控中" }
        return monitor.lastError ?? "正在连接接口…"
    }

    private func metricTile(
        title: String,
        value: String,
        subtitle: String,
        icon: String,
        color: Color
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.16))
                .allowsHitTesting(false)
        }
    }

    private var filterControlBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: $activeTab) {
                    Text("连接请求").tag(MonitorTab.connections)
                    Text(monitor.failedDNSCount > 0 ? "DNS 解析 (\(monitor.dnsLogs.count) · \(monitor.failedDNSCount)异常)" : "DNS 解析 (\(monitor.dnsLogs.count))")
                        .tag(MonitorTab.dns)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField(
                        activeTab == .dns ? "搜索域名、IP、上游 DNS 或错误…" : "搜索域名、IP、进程、规则或节点…",
                        text: $searchText
                    )
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.22))
                        .allowsHitTesting(false)
                }
                .frame(minWidth: 140, maxWidth: .infinity)

                if activeTab == .connections {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showSpeedChart.toggle()
                        }
                    } label: {
                        Label("曲线", systemImage: "chart.xyaxis.line")
                    }
                    .controlSize(.small)
                    .help(showSpeedChart ? "隐藏实时吞吐曲线" : "显示实时吞吐曲线")
                }

                Button {
                    monitor.togglePause()
                } label: {
                    Label(monitor.isPaused ? "继续" : "暂停", systemImage: monitor.isPaused ? "play.fill" : "pause.fill")
                }
                .controlSize(.small)
                .disabled(!state.engine.isRunning)
                .help(monitor.isPaused ? "恢复实时刷新" : "暂停界面刷新以便查看细节")

                if activeTab == .dns {
                    Menu {
                        Button {
                            selectedDNSLogID = nil
                            state.clearDNSLogsAndCache(includeFakeIP: false)
                        } label: {
                            Label("清空日志与 DNS 缓存", systemImage: "trash")
                        }
                        .disabled(!state.engine.isRunning)

                        Button {
                            state.flushDNSCache(includeFakeIP: false)
                        } label: {
                            Label("仅清空内核 DNS 缓存", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(!state.engine.isRunning)

                        if state.profile.effectiveTunEnabled && state.profile.tunDNSMode == .fakeIP {
                            Button {
                                selectedDNSLogID = nil
                                state.clearDNSLogsAndCache(includeFakeIP: true)
                            } label: {
                                Label("清空日志、DNS 与 Fake-IP 缓存", systemImage: "flame")
                            }
                            .disabled(!state.engine.isRunning)
                        }

                        Divider()

                        Button {
                            selectedDNSLogID = nil
                            monitor.clearDNSLogs()
                        } label: {
                            Label("仅清空界面日志", systemImage: "list.bullet.rectangle")
                        }
                        .disabled(monitor.dnsLogs.isEmpty)
                    } label: {
                        Label("清空 DNS", systemImage: "trash")
                    } primaryAction: {
                        selectedDNSLogID = nil
                        if state.engine.isRunning {
                            state.clearDNSLogsAndCache(includeFakeIP: false)
                        } else {
                            monitor.clearDNSLogs()
                        }
                    }
                    .controlSize(.small)
                    .disabled((!state.engine.isRunning && monitor.dnsLogs.isEmpty) || monitor.isFlushingDNSCache)
                    .help("点击清空 DNS 日志并刷新内核 DNS 缓存；下拉可选择仅清空日志、仅清缓存或同时清空 Fake-IP 缓存")
                } else {
                    Button {
                        state.closeAllMonitoredConnections()
                    } label: {
                        Label("断开全部", systemImage: "xmark.circle")
                    }
                    .controlSize(.small)
                    .disabled(!state.engine.isRunning || monitor.tracker.activeCount == 0 || monitor.isClosingConnections)
                    .help("强制断开当前所有活跃连接")

                    Button {
                        if let id = selectedConnectionID, monitor.tracker.recordsByID[id]?.isActive == false {
                            selectedConnectionID = nil
                        }
                        monitor.clearClosed()
                    } label: {
                        Label("清空历史", systemImage: "trash")
                    }
                    .controlSize(.small)
                    .disabled(monitor.tracker.closedCount == 0)
                    .help("清空所有已结束的历史连接记录")
                }
            }

            HStack(spacing: 10) {
                if activeTab == .dns {
                    Picker("", selection: $dnsScope) {
                        ForEach(DNSLogFilterScope.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)

                    Menu {
                        ForEach(DNSLogSourceFilter.allCases) { source in
                            Button {
                                dnsSourceFilter = source
                            } label: {
                                if dnsSourceFilter == source {
                                    Label(source.title, systemImage: "checkmark")
                                } else {
                                    Text(source.title)
                                }
                            }
                        }
                    } label: {
                        Label(dnsSourceFilter.title, systemImage: "line.3.horizontal.decrease.circle")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Toggle(isOn: $hideEmptyDNSAnswers) {
                        Text("隐藏无记录")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("隐藏未返回 IP 的空响应（如常见无 IPv6 记录的 AAAA 查询）")

                    Spacer()

                    let cacheCount = monitor.cacheHitDNSCount
                    let failedCount = monitor.failedDNSCount
                    Text(
                        failedCount > 0
                            ? "显示 \(filteredDNSLogs.count) / \(monitor.dnsLogs.count) 条 · 缓存 \(cacheCount) · 异常 \(failedCount)"
                            : "显示 \(filteredDNSLogs.count) / \(monitor.dnsLogs.count) 条 · 缓存 \(cacheCount)"
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                } else {
                    Picker("", selection: $scope) {
                        ForEach(ConnectionFilterScope.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)

                    Menu {
                        Button("全部出口") { selectedTarget = nil }
                        if !availableTargets.isEmpty {
                            Divider()
                            ForEach(availableTargets, id: \.self) { target in
                                Button {
                                    selectedTarget = target
                                } label: {
                                    if selectedTarget == target {
                                        Label(target, systemImage: "checkmark")
                                    } else {
                                        Text(target)
                                    }
                                }
                            }
                        }
                    } label: {
                        Label(selectedTarget ?? "全部出口", systemImage: "line.3.horizontal.decrease.circle")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Menu {
                        ForEach(ConnectionSortOrder.allCases) { order in
                            Button {
                                sortOrder = order
                            } label: {
                                if sortOrder == order {
                                    Label(order.title, systemImage: "checkmark")
                                } else {
                                    Text(order.title)
                                }
                            }
                        }
                    } label: {
                        Label(sortOrder.title, systemImage: "arrow.up.arrow.down")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    let innerCount = monitor.tracker.innerCount
                    Toggle(isOn: $showInnerConnections) {
                        Text(innerCount > 0 ? "内部连接 (\(innerCount))" : "内部连接")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("显示 Mihomo 链式代理等内部隧道连接（Inner），默认隐藏以减少列表重复干扰")
                    .onChange(of: showInnerConnections) { newValue in
                        if !newValue, let selectedTarget, !availableTargets.contains(selectedTarget) {
                            self.selectedTarget = nil
                        }
                    }

                    Spacer()

                    let visibleBaseTotal = showInnerConnections
                        ? monitor.tracker.recordsByID.count
                        : (monitor.tracker.recordsByID.count - innerCount)
                    Text(
                        !showInnerConnections && innerCount > 0
                            ? "显示 \(filteredConnections.count) / \(visibleBaseTotal) 条（已隐藏 \(innerCount) 条内部）"
                            : "显示 \(filteredConnections.count) / \(monitor.tracker.recordsByID.count) 条连接"
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var idleEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("核心未运行")
                .font(.headline)
            Text("启动 Mihomo 核心后，经过 \(state.localProxyAddress) 的实时请求、命中规则与流量数据将在此显示。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button {
                state.start()
            } label: {
                Label("启动核心", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!state.canStart)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
