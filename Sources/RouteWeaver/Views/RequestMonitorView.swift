import RoutingCore
import SwiftUI

private enum MonitorTab: String, CaseIterable, Identifiable {
    case connections
    case dns

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connections: return "连接请求"
        case .dns: return "DNS 解析"
        }
    }
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

    private struct ResolvedRelayChain {
        let relayGroupName: String
        let relayNode: String?
    }

    private var ruleIndex: RuleMatchDisplayIndex {
        RuleMatchDisplayIndex(profile: state.profile)
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
        guard !item.isInner, !item.isDirect, !item.isRejected else { return nil }
        let relayGroupName = "\(item.primaryTarget)·链式"
        let configuredRelay = state.profile.targets.contains { target in
            target.name == item.primaryTarget && target.mode == .proxy && target.relayGroupID != nil
        }
        let runtimeGroup = state.groupStatus[relayGroupName]
        let runtimeSelection = state.groupSelection[relayGroupName]
        guard configuredRelay || runtimeGroup != nil || runtimeSelection != nil else {
            return nil
        }
        let rawNode = runtimeGroup?.now.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackNode = runtimeSelection?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedNode = (rawNode?.isEmpty == false ? rawNode : nil)
            ?? (fallbackNode?.isEmpty == false ? fallbackNode : nil)
        return ResolvedRelayChain(relayGroupName: relayGroupName, relayNode: resolvedNode)
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
                    dnsLogListPane
                    if let selected = selectedDNSLog {
                        Divider()
                        dnsInspectorPane(for: selected)
                            .frame(width: 336)
                    }
                }
            } else {
                HStack(spacing: 0) {
                    connectionListPane
                    if let selected = selectedConnection {
                        Divider()
                        inspectorPane(for: selected)
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
        if !state.engine.isRunning {
            return "核心未运行"
        }
        if monitor.isPaused {
            return "界面已暂停刷新"
        }
        if monitor.isStreaming {
            return "实时监控中"
        }
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
            // Row 1: Tab switcher + Search + Actions
            HStack(spacing: 8) {
                Picker("", selection: $activeTab) {
                    Text("连接请求").tag(MonitorTab.connections)
                    Text(monitor.failedDNSCount > 0 ? "DNS 解析 (\(monitor.dnsLogs.count) · \(monitor.failedDNSCount)异常)" : "DNS 解析 (\(monitor.dnsLogs.count))")
                        .tag(MonitorTab.dns)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)

                // Search input
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

                // Pause / Resume
                Button {
                    monitor.togglePause()
                } label: {
                    Label(monitor.isPaused ? "继续" : "暂停", systemImage: monitor.isPaused ? "play.fill" : "pause.fill")
                }
                .controlSize(.small)
                .disabled(!state.engine.isRunning)
                .help(monitor.isPaused ? "恢复实时刷新" : "暂停界面刷新以便查看细节")

                if activeTab == .dns {
                    Button {
                        selectedDNSLogID = nil
                        monitor.clearDNSLogs()
                    } label: {
                        Label("清空 DNS", systemImage: "trash")
                    }
                    .controlSize(.small)
                    .disabled(monitor.dnsLogs.isEmpty)
                    .help("清空当前 DNS 解析日志（上限 \(monitor.maxDNSLogs) 条自动淘汰）")
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

            // Row 2: Scope, Target & Sort filters
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

                    // Target filter
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

                    // Sort order
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

    // MARK: - DNS Query Log List

    private var dnsDomainColumnWidth: CGFloat {
        selectedDNSLog == nil ? 256 : 196
    }

    private var dnsUpstreamColumnWidth: CGFloat {
        selectedDNSLog == nil ? 188 : 148
    }

    private var dnsLogListPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("时间")
                    .frame(width: 78, alignment: .leading)
                Text("类型")
                    .frame(width: 50, alignment: .leading)
                Text("域名")
                    .frame(width: dnsDomainColumnWidth, alignment: .leading)
                Text("解析结果 / 状态")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("来源 / 上游")
                    .frame(width: dnsUpstreamColumnWidth, alignment: .leading)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))

            Divider()

            let rows = filteredDNSLogs
            if rows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: monitor.dnsLogs.isEmpty ? "network.badge.shield.half.filled" : "magnifyingglass")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text(monitor.dnsLogs.isEmpty ? "等待 DNS 解析请求…" : "没有匹配的 DNS 日志")
                        .font(.headline)
                    Text(
                        monitor.dnsLogs.isEmpty
                            ? "所有经过 Mihomo 的 DNS 查询结果与失败原因将实时显示在这里（最多保留 \(monitor.maxDNSLogs) 条）。"
                            : "尝试调整搜索关键词、来源筛选或取消“隐藏无记录”。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)

                    if !monitor.dnsLogs.isEmpty {
                        Button("重置筛选") {
                            searchText = ""
                            dnsScope = .all
                            dnsSourceFilter = .all
                            hideEmptyDNSAnswers = false
                        }
                        .controlSize(.small)
                        .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { item in
                            dnsLogRow(item)
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dnsLogRow(_ item: DNSLogRecord) -> some View {
        let isSelected = selectedDNSLogID == item.id
        let dotColor = dnsStatusColor(for: item)

        return HStack(alignment: .center, spacing: 10) {
            // Timestamp
            Text(formattedTimestamp(item.timestamp))
                .font(.system(.caption2, design: .monospaced).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 78, alignment: .leading)

            // Record type badge (fixed column so domains align cleanly)
            dnsRecordTypeBadge(item.recordType)
                .frame(width: 50, alignment: .leading)

            // Status dot + Domain
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Text(item.domain)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(item.hasAnswers || item.status == .failed ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: dnsDomainColumnWidth, alignment: .leading)
            .help(item.domain)

            // Compact single-line answer / error summary
            dnsAnswerCell(for: item)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Source / Upstream DNS
            dnsUpstreamCell(for: item)
                .frame(width: dnsUpstreamColumnWidth, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        .onTapGesture {
            selectedDNSLogID = isSelected ? nil : item.id
        }
        .contextMenu {
            Button("复制域名") {
                state.copyText(item.domain, label: "域名 \(item.domain)")
            }
            Button("复制解析结果") {
                state.copyText(item.answerSummary, label: "DNS 解析结果")
            }
            if item.upstreamKind == .upstream {
                Button("复制上游 DNS") {
                    state.copyText(item.upstream, label: "上游 DNS")
                }
            }
            Divider()
            Button("复制完整日志") {
                state.copyText(item.rawPayload, label: "DNS 原始日志")
            }
        }
    }

    private func dnsStatusColor(for item: DNSLogRecord) -> Color {
        if item.status == .failed { return .red }
        if item.isSuspiciousLoopback { return .orange }
        if !item.hasAnswers { return Color.secondary.opacity(0.4) }
        return .green
    }

    private func dnsRecordTypeColor(_ recordType: String) -> Color {
        switch recordType.uppercased() {
        case "A": return .blue
        case "AAAA": return .indigo
        case "HTTPS", "SVCB": return .teal
        case "CNAME", "TXT", "SRV", "MX": return .orange
        default: return .secondary
        }
    }

    private func dnsRecordTypeBadge(_ recordType: String) -> some View {
        let color = dnsRecordTypeColor(recordType)
        return Text(recordType)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color.opacity(0.12))
            )
    }

    @ViewBuilder
    private func dnsAnswerCell(for item: DNSLogRecord) -> some View {
        if item.status == .failed {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                Text(item.errorMessage ?? "解析失败")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .help(item.errorMessage ?? "解析失败")
        } else if item.answers.isEmpty {
            Text("无记录")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        } else {
            let hasIPv6 = item.answers.first?.contains(":") == true
            let visibleLimit = hasIPv6 ? 1 : 2
            let visibleText = item.answers.prefix(visibleLimit).joined(separator: ", ")
            let remainingCount = max(0, item.answers.count - visibleLimit)

            HStack(spacing: 5) {
                if item.isSuspiciousLoopback {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text(visibleText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(item.isSuspiciousLoopback ? .orange : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if remainingCount > 0 {
                    Text("+\(remainingCount)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(Color.secondary.opacity(0.12))
                        )
                        .fixedSize()
                }
            }
            .help(item.answers.joined(separator: "\n"))
        }
    }

    @ViewBuilder
    private func dnsUpstreamCell(for item: DNSLogRecord) -> some View {
        switch item.upstreamKind {
        case .cache:
            HStack(spacing: 5) {
                Text("缓存")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.teal)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.teal.opacity(0.12))
                    )
                    .fixedSize()
                if let shortExpire = item.shortExpireTime {
                    Text(shortExpire)
                        .font(.system(.caption2, design: .monospaced).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .help(item.cacheExpireAt.map { "缓存命中 · 过期时间 \($0)" } ?? "缓存命中")

        case .fakeIP:
            Text("Fake-IP")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.purple)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.purple.opacity(0.12))
                )
                .help("Fake-IP 虚拟地址池分配")

        case .local:
            Text("本地")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.blue)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.blue.opacity(0.12))
                )
                .help("本地 Hosts / 内置解析结果")

        case .upstream:
            let parts = item.upstreamDisplayParts
            HStack(spacing: 4) {
                if let badge = parts.schemeBadge {
                    Text(badge)
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .fill(Color.secondary.opacity(0.12))
                        )
                        .fixedSize()
                }
                Text(parts.endpoint)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(item.upstream)
        }
    }

    private func dnsInspectorPane(for item: DNSLogRecord) -> some View {
        let statusTitle: String = {
            if item.status == .failed { return "解析失败" }
            if item.isSuspiciousLoopback { return "疑似回环" }
            if !item.hasAnswers { return "无记录" }
            return "解析成功"
        }()
        let statusIcon: String = {
            if item.status == .failed { return "xmark.circle.fill" }
            if item.isSuspiciousLoopback { return "exclamationmark.triangle.fill" }
            if !item.hasAnswers { return "minus.circle" }
            return "checkmark.circle.fill"
        }()
        let statusColor: Color = {
            if item.status == .failed { return .red }
            if item.isSuspiciousLoopback { return .orange }
            if !item.hasAnswers { return .secondary }
            return .green
        }()

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            StatusPill(statusTitle, systemImage: statusIcon, color: statusColor)
                            dnsRecordTypeBadge(item.recordType)
                        }
                        Text(item.domain)
                            .font(.system(.headline, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button {
                        selectedDNSLogID = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("关闭详情面板")
                }

                HStack(spacing: 8) {
                    Button {
                        state.copyText(item.domain, label: "域名 \(item.domain)")
                    } label: {
                        Label("复制域名", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)

                    Button {
                        state.copyText(item.answerSummary, label: "DNS 解析结果")
                    } label: {
                        Label("复制结果", systemImage: "list.bullet.rectangle")
                    }
                    .controlSize(.small)

                    Button {
                        state.copyText(item.exportSummary(), label: "DNS 详情")
                    } label: {
                        Label("复制摘要", systemImage: "doc.plaintext")
                    }
                    .controlSize(.small)
                }

                Divider()

                // Answers / Error section
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.status == .failed ? "错误原因" : "解析结果 (\(item.answers.count))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if item.status == .failed {
                        Text(item.errorMessage ?? "解析失败")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.red.opacity(0.08))
                            )
                    } else if item.answers.isEmpty {
                        Text("上游未返回 \(item.recordType) 记录。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(item.answers, id: \.self) { answer in
                                HStack(spacing: 6) {
                                    Text(answer)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(
                                            (answer == "127.0.0.1" || answer == "0.0.0.0" || answer == "::1")
                                                ? .orange : .primary
                                        )
                                        .textSelection(.enabled)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    Button {
                                        state.copyText(answer, label: "IP \(answer)")
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("复制 \(answer)")
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color(nsColor: .textBackgroundColor))
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(Color.secondary.opacity(0.14))
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                    }
                }

                Divider()

                // Query metadata
                VStack(alignment: .leading, spacing: 6) {
                    Text("查询信息")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    inspectorRow("来源类型", dnsSourceLabel(for: item.upstreamKind))
                    inspectorRow("上游地址", item.upstream, monospaced: true)
                    if let expire = item.cacheExpireAt, !expire.isEmpty {
                        inspectorRow("缓存过期时间", expire, monospaced: true)
                    }
                    inspectorRow("记录类型", item.recordType, monospaced: true)
                    inspectorRow("查询时间", formattedTimestamp(item.timestamp), monospaced: true)
                }

                Divider()

                // Raw log
                VStack(alignment: .leading, spacing: 6) {
                    Text("原始日志")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(item.rawPayload)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.secondary.opacity(0.14))
                                .allowsHitTesting(false)
                        }
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private func dnsSourceLabel(for kind: DNSUpstreamKind) -> String {
        switch kind {
        case .upstream: return "上游 DNS 服务器"
        case .cache: return "Mihomo DNS 缓存命中"
        case .fakeIP: return "Fake-IP 虚拟地址"
        case .local: return "本地 / Hosts 解析"
        }
    }

    // MARK: - Connection List

    private var connectionListPane: some View {
        VStack(spacing: 0) {
            listHeaderRow
            Divider()

            let rows = filteredConnections
            if rows.isEmpty {
                filteredEmptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { item in
                            connectionRow(item)
                            Divider()
                                .padding(.leading, 28)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listHeaderRow: some View {
        HStack(spacing: 10) {
            Text("目标 / 规则")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("出口链路")
                .frame(width: 215, alignment: .leading)
            Text("流量 (↑ / ↓)")
                .frame(width: 112, alignment: .trailing)
            Text("时长")
                .frame(width: 58, alignment: .trailing)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    private func connectionRow(_ item: MonitoredConnection) -> some View {
        let isSelected = selectedConnectionID == item.id
        let matchedRule = ruleIndex.resolve(rule: item.rule, payload: item.rulePayload)
        return HStack(alignment: .center, spacing: 10) {
            // Host + metadata subline
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(item.isActive ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayAddress)
                        .font(.system(.subheadline, design: .monospaced).weight(.medium))
                        .foregroundStyle(item.isActive ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 6) {
                        Text(item.protocolLabel)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))

                        if !item.processDisplayName.isEmpty {
                            Text(item.processDisplayName)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.indigo)
                                .lineLimit(1)
                        }

                        if let matchedRule {
                            Text(matchedRule.groupName)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.teal)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.teal.opacity(0.12)))
                                .lineLimit(1)

                            if let note = matchedRule.ruleNote, !note.isEmpty {
                                Text(note)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            } else if !item.rulePayload.isEmpty {
                                Text(item.ruleSummary)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        } else {
                            Text(item.ruleSummary)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Routing chain summary
            let relayInfo = resolvedRelayChain(for: item)
            let exitNodeLabel = item.compactFinalNode
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.primaryTarget)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(targetColor(for: item))
                        .lineLimit(1)
                    if relayInfo != nil {
                        Text("链式")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.purple.opacity(0.12)))
                    }
                }
                if let relayNode = relayInfo?.relayNode, exitNodeLabel != item.primaryTarget {
                    HStack(spacing: 3) {
                        Text(relayNode)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text(exitNodeLabel)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("中转：\(relayNode) → 落地：\(exitNodeLabel)")
                } else if exitNodeLabel != item.primaryTarget {
                    Text(exitNodeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(width: 215, alignment: .leading)

            // Upload / Download
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 3) {
                    Text("↑")
                        .foregroundStyle(.blue.opacity(0.8))
                    Text(TrafficFormatter.bytes(item.upload))
                        .foregroundStyle(.secondary)
                }
                .font(.system(.caption2, design: .monospaced))

                HStack(spacing: 3) {
                    Text("↓")
                        .foregroundStyle(.green.opacity(0.85))
                    Text(TrafficFormatter.bytes(item.download))
                        .foregroundStyle(item.isActive ? .primary : .secondary)
                }
                .font(.system(.caption2, design: .monospaced))
            }
            .frame(width: 112, alignment: .trailing)

            // Duration
            Text(TrafficFormatter.duration(item.duration()))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        .onTapGesture {
            selectedConnectionID = isSelected ? nil : item.id
        }
        .contextMenu {
            Button("复制域名 / 目标") {
                state.copyText(item.hostOnly, label: "目标域名 \(item.hostOnly)")
            }
            Button("复制目标地址（含端口）") {
                state.copyText(item.displayAddress, label: "目标地址 \(item.displayAddress)")
            }
            if item.destinationIPAddress != "—" {
                Button("复制目标 IP") {
                    state.copyText(item.metadata.destinationIP.isEmpty ? item.metadata.remoteDestination : item.metadata.destinationIP, label: "目标 IP")
                }
            }
            if !item.processDisplayName.isEmpty {
                Button("复制进程名") {
                    state.copyText(item.processDisplayName, label: "进程名 \(item.processDisplayName)")
                }
            }
            Divider()
            Button("复制完整请求摘要") {
                state.copyText(item.exportSummary(), label: "请求摘要")
            }
            if item.isActive && state.engine.isRunning {
                Divider()
                Button("断开此连接", role: .destructive) {
                    state.closeMonitoredConnection(id: item.id)
                }
            }
        }
    }

    private func targetColor(for item: MonitoredConnection) -> Color {
        if item.isRejected { return .red }
        if item.isDirect { return .green }
        return .blue
    }

    // MARK: - Inspector Pane

    private func inspectorPane(for item: MonitoredConnection) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            StatusPill(
                                item.isActive ? "活跃连接" : "已结束",
                                systemImage: item.isActive ? "circle.fill" : "checkmark.circle",
                                color: item.isActive ? .green : .secondary
                            )
                            Text(item.protocolLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(item.displayAddress)
                            .font(.system(.headline, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button {
                        selectedConnectionID = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("关闭详情面板")
                }

                HStack(spacing: 8) {
                    Button {
                        state.copyText(item.hostOnly, label: "目标域名")
                    } label: {
                        Label("复制域名", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)

                    Button {
                        state.copyText(item.exportSummary(), label: "请求详情")
                    } label: {
                        Label("复制详情", systemImage: "doc.plaintext")
                    }
                    .controlSize(.small)

                    if item.isActive && state.engine.isRunning {
                        Spacer()
                        Button(role: .destructive) {
                            state.closeMonitoredConnection(id: item.id)
                        } label: {
                            Label("断开", systemImage: "xmark.circle")
                        }
                        .controlSize(.small)
                    }
                }

                Divider()

                // Routing chain
                let inspectorRelay = resolvedRelayChain(for: item)
                VStack(alignment: .leading, spacing: 6) {
                    Text("分流与代理链路")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if !item.displayChain.isEmpty {
                        let fullSteps: [String] = {
                            if let relay = inspectorRelay {
                                let middle = relay.relayNode ?? relay.relayGroupName
                                if item.compactFinalNode != item.primaryTarget {
                                    return [item.primaryTarget, middle, item.compactFinalNode]
                                }
                                return [item.primaryTarget, middle]
                            }
                            return item.displayChain
                        }()
                        ScrollView(.horizontal, showsIndicators: false) {
                            ChainFlowBadge(steps: fullSteps, isDirect: item.isDirect)
                        }
                    }
                    if let inspectorRelay {
                        inspectorRow(
                            "链式中转",
                            inspectorRelay.relayNode.map { "\(inspectorRelay.relayGroupName) · \($0)" } ?? inspectorRelay.relayGroupName
                        )
                    }
                    let matchedRule = ruleIndex.resolve(rule: item.rule, payload: item.rulePayload)
                    if let matchedRule {
                        inspectorRow("命中规则组", matchedRule.groupName)
                        if let note = matchedRule.ruleNote, !note.isEmpty {
                            inspectorRow("规则来源", note)
                        }
                    }
                    inspectorRow("命中规则", item.ruleSummary, monospaced: true)
                }

                Divider()

                // Traffic
                VStack(alignment: .leading, spacing: 6) {
                    Text("流量数据")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    inspectorRow("上传总量", TrafficFormatter.bytes(item.upload), monospaced: true)
                    inspectorRow("下载总量", TrafficFormatter.bytes(item.download), monospaced: true)
                    if item.isActive {
                        inspectorRow("上传速率", TrafficFormatter.speed(item.uploadSpeed), monospaced: true)
                        inspectorRow("下载速率", TrafficFormatter.speed(item.downloadSpeed), monospaced: true)
                    }
                    inspectorRow("持续时长", TrafficFormatter.duration(item.duration()), monospaced: true)
                }

                Divider()

                // Network metadata
                VStack(alignment: .leading, spacing: 6) {
                    Text("连接元数据")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    inspectorRow("目标域名", item.metadata.host.isEmpty ? "—" : item.metadata.host, monospaced: true)
                    inspectorRow("目标 IP", item.destinationIPAddress, monospaced: true)
                    inspectorRow("来源地址", item.sourceAddress, monospaced: true)
                    if !item.metadata.dnsMode.isEmpty {
                        inspectorRow("DNS 模式", item.metadata.dnsMode, monospaced: true)
                    }
                    if !item.processDisplayName.isEmpty {
                        inspectorRow("来源进程", item.processDisplayName)
                    }
                    if !item.metadata.processPath.isEmpty {
                        inspectorRow("进程路径", item.metadata.processPath, monospaced: true)
                    }
                    inspectorRow("开始时间", formattedTimestamp(item.startDate ?? item.firstSeenAt), monospaced: true)
                    if let closed = item.closedAt {
                        inspectorRow("结束时间", formattedTimestamp(closed), monospaced: true)
                    }
                    inspectorRow("连接 ID", item.id, monospaced: true)
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private func inspectorRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
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

    private func formattedTimestamp(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    // MARK: - Empty States

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

    private var filteredEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: monitor.tracker.recordsByID.isEmpty ? "network" : "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(monitor.tracker.recordsByID.isEmpty ? "等待请求流量…" : "没有匹配的请求记录")
                .font(.headline)
            Text(
                monitor.tracker.recordsByID.isEmpty
                    ? "请将应用或终端代理指向 \(state.localProxyAddress)，连接建立后会实时展示在此。"
                    : "尝试调整搜索关键词、状态范围或出口筛选条件。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)

            if !monitor.tracker.recordsByID.isEmpty {
                Button("重置筛选") {
                    searchText = ""
                    scope = .all
                    selectedTarget = nil
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
