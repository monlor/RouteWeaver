import RoutingCore
import SwiftUI

struct MonitorAndStatsView: View {
    @EnvironmentObject private var model: MobileAppModel
    @State private var activeSegment: Segment = .requests
    @State private var searchText = ""
    @State private var activeOnly = true
    @State private var selectedConnection: RemoteConnectionDTO?
    @State private var statsWindow: TrafficRankingWindow = .today
    @State private var statsDimension: TrafficRankingDimension = .domain

    private enum Segment: String, CaseIterable, Identifiable {
        case requests = "实时请求"
        case dns = "DNS 日志"
        case stats = "流量统计"

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("监控视图", selection: $activeSegment) {
                        ForEach(Segment.allCases) { seg in
                            Text(seg.rawValue).tag(seg)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    .listRowBackground(Color.clear)
                }

                switch activeSegment {
                case .requests:
                    requestsContent
                case .dns:
                    dnsContent
                case .stats:
                    trafficStatsContent
                }
            }
            .navigationTitle("请求与统计")
            .searchable(text: $searchText, prompt: activeSegment == .dns ? "搜索域名" : "搜索域名 / 规则 / 出口")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if activeSegment == .requests {
                        Menu {
                            Toggle("仅显示活跃连接", isOn: $activeOnly)
                            Divider()
                            Button(role: .destructive) {
                                Task { await model.closeAllRemoteConnections() }
                            } label: {
                                Label("关闭全部连接", systemImage: "xmark.circle")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .disabled(model.activeHost == nil)
                    } else if activeSegment == .dns {
                        Button("清缓存") {
                            Task { await model.flushRemoteDNS() }
                        }
                        .disabled(model.activeHost == nil || model.isBusy)
                    } else {
                        Button {
                            Task { await model.syncNow() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(model.activeHost == nil || model.isSyncing)
                    }
                }
            }
            .refreshable {
                await model.refreshRemoteDashboard()
                if activeSegment == .stats {
                    await model.syncNow()
                }
            }
            .sheet(item: $selectedConnection) { conn in
                ConnectionDetailSheet(connection: conn)
                    .environmentObject(model)
            }
        }
    }

    // MARK: - 实时请求

    private var filteredConnections: [RemoteConnectionDTO] {
        let all = model.remoteSnapshot?.connections ?? []
        return all.filter { conn in
            if activeOnly && !conn.isActive { return false }
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return true }
            return conn.host.localizedCaseInsensitiveContains(q)
                || conn.rule.localizedCaseInsensitiveContains(q)
                || conn.chain.localizedCaseInsensitiveContains(q)
                || conn.destinationIP.localizedCaseInsensitiveContains(q)
        }
    }

    @ViewBuilder
    private var requestsContent: some View {
        if let status = model.remoteSnapshot?.status {
            Section {
                HStack(spacing: 12) {
                    statMetricBox(
                        title: "活跃连接",
                        value: "\(status.activeConnectionCount)",
                        color: .blue
                    )
                    statMetricBox(
                        title: "实时上传",
                        value: "\(TrafficFormatter.bytes(status.uploadSpeed))/s",
                        color: .orange
                    )
                    statMetricBox(
                        title: "实时下载",
                        value: "\(TrafficFormatter.bytes(status.downloadSpeed))/s",
                        color: .green
                    )
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            }
        }

        let items = filteredConnections
        if items.isEmpty {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text(model.activeHost == nil ? "尚未配对远程 PC" : "暂无匹配连接")
                        .font(.headline)
                    Text(model.activeHost == nil
                         ? "配对远程 PC 后将实时拉取请求、DNS 日志与流量排行。"
                         : "下拉刷新或关闭「仅显示活跃连接」查看更多记录。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        } else {
            Section("连接列表（\(items.count)）") {
                ForEach(items) { conn in
                    Button {
                        selectedConnection = conn
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(conn.isActive ? Color.green : Color.secondary.opacity(0.4))
                                    .frame(width: 7, height: 7)
                                Text(conn.host.isEmpty ? conn.destinationIP : conn.host)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer()
                                Text(conn.network.uppercased())
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.14), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 6) {
                                Text(conn.chain)
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                                    .lineLimit(1)
                                Spacer()
                                Text("↑\(TrafficFormatter.bytes(conn.upload))  ↓\(TrafficFormatter.bytes(conn.download))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }

                            Text(conn.matchedRuleSet.map { "\(conn.rule) (\($0))" } ?? conn.rule)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if conn.isActive {
                            Button(role: .destructive) {
                                Task { await model.closeRemoteConnection(id: conn.id) }
                            } label: {
                                Label("关闭", systemImage: "xmark")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - DNS 日志

    private var filteredDNSLogs: [RemoteDNSLogDTO] {
        let all = model.remoteSnapshot?.dnsLogs ?? []
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.domain.localizedCaseInsensitiveContains(q) || $0.result.localizedCaseInsensitiveContains(q)
        }
    }

    @ViewBuilder
    private var dnsContent: some View {
        let logs = filteredDNSLogs
        if logs.isEmpty {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass.circle")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("暂无 DNS 解析日志")
                        .font(.headline)
                    Text("请在 PC 端开启 Debug 日志级别或等待新 DNS 请求。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        } else {
            Section("最近 DNS 解析（\(logs.count)）") {
                ForEach(logs) { log in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(log.domain)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            Text(log.queryType)
                                .font(.caption2.monospaced().weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.12), in: Capsule())
                                .foregroundStyle(.blue)
                        }
                        Text(log.result)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        HStack {
                            if let upstream = log.upstream, !upstream.isEmpty {
                                Text(upstream)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(log.timestamp, style: .time)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - 流量统计

    @ViewBuilder
    private var trafficStatsContent: some View {
        if let status = model.remoteSnapshot?.status {
            Section("本次会话总流量") {
                HStack(spacing: 12) {
                    statMetricBox(
                        title: "累计上传",
                        value: TrafficFormatter.bytes(status.uploadTotal),
                        color: .orange
                    )
                    statMetricBox(
                        title: "累计下载",
                        value: TrafficFormatter.bytes(status.downloadTotal),
                        color: .green
                    )
                    statMetricBox(
                        title: "累计总计",
                        value: TrafficFormatter.bytes(status.uploadTotal + status.downloadTotal),
                        color: .blue
                    )
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            }
        }

        if let ranking = model.remoteFullState?.trafficRanking {
            let report = ranking.report(dimension: statsDimension, window: statsWindow)

            Section {
                Picker("统计维度", selection: $statsDimension) {
                    ForEach(TrafficRankingDimension.allCases) { dim in
                        Text(dim.title).tag(dim)
                    }
                }
                Picker("时间窗口", selection: $statsWindow) {
                    ForEach(TrafficRankingWindow.allCases) { win in
                        Text(win.title).tag(win)
                    }
                }
            } header: {
                Text("流量排行筛选")
            }

            Section {
                if report.items.isEmpty {
                    Text("当前时间窗口暂无统计数据。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(report.items.prefix(20))) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(item.key)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Spacer()
                                Text(TrafficFormatter.bytes(item.total))
                                    .font(.caption.monospacedDigit().weight(.semibold))
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.secondary.opacity(0.14))
                                    Capsule()
                                        .fill(Color.accentColor)
                                        .frame(width: max(4, geo.size.width * min(1, max(0, item.percentage))))
                                }
                            }
                            .frame(height: 5)
                            HStack {
                                Text("↑ \(TrafficFormatter.bytes(item.upload))  ↓ \(TrafficFormatter.bytes(item.download))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%.1f%%", item.percentage * 100))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            } header: {
                Text("Top \(statsDimension.title)（合计 \(TrafficFormatter.bytes(report.totalUpload + report.totalDownload))）")
            }
        } else {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("暂无历史流量排行")
                        .font(.headline)
                    Text("同步 PC 端完整状态后，可查看按域名、目标与设备的历史流量统计。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if model.activeHost != nil {
                        Button("拉取统计数据") {
                            Task { await model.syncNow() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        }
    }

    private func statMetricBox(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ConnectionDetailSheet: View {
    @EnvironmentObject private var model: MobileAppModel
    @Environment(\.dismiss) private var dismiss
    let connection: RemoteConnectionDTO

    var body: some View {
        NavigationStack {
            List {
                Section("连接目标") {
                    LabeledContent("域名 / 主机", value: connection.host.isEmpty ? "—" : connection.host)
                    LabeledContent("目标 IP", value: connection.destinationIP)
                    if let port = connection.destinationPort {
                        LabeledContent("目标端口", value: port)
                    }
                    LabeledContent("协议", value: connection.network.uppercased())
                    LabeledContent("状态", value: connection.isActive ? "活跃" : "已关闭")
                }

                Section("路由与代理链") {
                    LabeledContent("命中规则", value: connection.rule)
                    if let rs = connection.matchedRuleSet {
                        LabeledContent("规则集", value: rs)
                    }
                    LabeledContent("代理链", value: connection.chain)
                    LabeledContent("来源 IP", value: connection.sourceIP)
                    if let process = connection.process {
                        LabeledContent("进程", value: process)
                    }
                }

                Section("流量") {
                    LabeledContent("上传", value: TrafficFormatter.bytes(connection.upload))
                    LabeledContent("下载", value: TrafficFormatter.bytes(connection.download))
                }

                if connection.isActive {
                    Section {
                        Button(role: .destructive) {
                            Task {
                                await model.closeRemoteConnection(id: connection.id)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Spacer()
                                Text("断开此连接")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("连接详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
