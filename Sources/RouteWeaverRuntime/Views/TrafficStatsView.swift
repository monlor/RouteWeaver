import RoutingCore
import SwiftUI

private enum TrafficSourcePaneTab: String, CaseIterable, Identifiable {
    case process = "进程"
    case client = "来源设备"

    var id: String { rawValue }
}

struct TrafficStatsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var monitor: ConnectionMonitorService

    @State private var window: TrafficRankingWindow = .today
    @State private var sortField: TrafficRankingSortField = .total
    @State private var sortAscending: Bool = false
    @State private var searchText: String = ""
    @State private var sourceTab: TrafficSourcePaneTab = .process
    @State private var selectedProcess: String? = nil
    @State private var selectedClient: String? = nil

    private var processReport: TrafficRankingReport {
        monitor.trafficRanking.report(
            dimension: .process,
            window: window,
            sortBy: sortField,
            ascending: sortAscending,
            searchText: searchText
        )
    }

    private var visibleProcessItems: [TrafficRankingItem] {
        processReport.items.filter { !$0.isUnknown }
    }

    private var clientReport: TrafficRankingReport {
        monitor.trafficRanking.report(
            dimension: .client,
            window: window,
            sortBy: sortField,
            ascending: sortAscending,
            searchText: searchText,
            displayAliases: state.lanDeviceNamesByIP
        )
    }

    private var visibleClientItems: [TrafficRankingItem] {
        clientReport.items.filter { !$0.isUnknown }
    }

    private var domainReport: TrafficRankingReport {
        monitor.trafficRanking.report(
            dimension: .domain,
            window: window,
            processFilter: selectedProcess,
            clientFilter: selectedClient,
            sortBy: sortField,
            ascending: sortAscending,
            searchText: searchText
        )
    }

    private var ipReport: TrafficRankingReport {
        monitor.trafficRanking.report(
            dimension: .ip,
            window: window,
            processFilter: selectedProcess,
            clientFilter: selectedClient,
            sortBy: sortField,
            ascending: sortAscending,
            searchText: searchText
        )
    }

    private var hasAnyWindowData: Bool {
        !processReport.items.isEmpty || !clientReport.items.isEmpty || !domainReport.items.isEmpty || !ipReport.items.isEmpty
    }

    var body: some View {
        let procReport = processReport
        let cliReport = clientReport
        let domReport = domainReport
        let addrReport = ipReport

        VStack(spacing: 0) {
            topHeaderArea(procReport: procReport, cliReport: cliReport, domReport: domReport, addrReport: addrReport)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            if procReport.items.isEmpty && cliReport.items.isEmpty && domReport.items.isEmpty && addrReport.items.isEmpty {
                emptyState(coverage: procReport.coverage)
            } else {
                GeometryReader { geo in
                    let isCompact = geo.size.width < 660
                    if isCompact {
                        ScrollView {
                            VStack(spacing: 12) {
                                sourcePane(procReport: procReport, cliReport: cliReport)
                                    .frame(height: 240)
                                targetPane(title: "域名排行", dimension: .domain, report: domReport)
                                    .frame(height: 250)
                                targetPane(title: "IP 排行", dimension: .ip, report: addrReport)
                                    .frame(height: 250)
                            }
                            .padding(16)
                            .lockScrollDocumentWidth()
                        }
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            sourcePane(procReport: procReport, cliReport: cliReport)
                                .frame(minWidth: 220, idealWidth: 265, maxWidth: 310, minHeight: 0, maxHeight: .infinity)

                            VStack(spacing: 12) {
                                targetPane(
                                    title: "域名排行",
                                    dimension: .domain,
                                    report: domReport
                                )
                                targetPane(
                                    title: "IP 排行",
                                    dimension: .ip,
                                    report: addrReport
                                )
                            }
                            .frame(minWidth: 320, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        }
                        .padding(16)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }

            Divider()

            scopeFooter
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .onChange(of: window) { _ in
            if let selected = selectedProcess,
               !monitor.trafficRanking.report(dimension: .process, window: window).items.contains(where: { $0.key == selected }) {
                selectedProcess = nil
            }
            if let selected = selectedClient,
               !monitor.trafficRanking.report(dimension: .client, window: window).items.contains(where: { $0.key == selected }) {
                selectedClient = nil
            }
        }
        .onChange(of: sourceTab) { newTab in
            if newTab == .process {
                selectedClient = nil
            } else {
                selectedProcess = nil
            }
        }
    }

    // MARK: - Top Header

    private func topHeaderArea(
        procReport: TrafficRankingReport,
        cliReport: TrafficRankingReport,
        domReport: TrafficRankingReport,
        addrReport: TrafficRankingReport
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            kpiStrip(procReport: procReport, cliReport: cliReport, domReport: domReport, addrReport: addrReport)
            controlsBar
        }
    }

    private func kpiStrip(
        procReport: TrafficRankingReport,
        cliReport: TrafficRankingReport,
        domReport: TrafficRankingReport,
        addrReport: TrafficRankingReport
    ) -> some View {
        let activeSourceTitle: String
        if selectedClient != nil {
            activeSourceTitle = "当前设备访问目标"
        } else if selectedProcess != nil {
            activeSourceTitle = "当前进程访问目标"
        } else {
            activeSourceTitle = "全局可观测目标"
        }
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 180), spacing: 12)],
            spacing: 12
        ) {
            metricTile(
                title: "\(window.title)总流量",
                value: TrafficFormatter.bytes(procReport.grandTotal),
                subtitle: "↑ \(TrafficFormatter.shortBytes(procReport.totalUpload)) · ↓ \(TrafficFormatter.shortBytes(procReport.totalDownload))",
                icon: "chart.bar.fill",
                color: .purple
            )

            if sourceTab == .client {
                let deviceCount = cliReport.items.filter { !$0.isUnknown }.count
                metricTile(
                    title: "来源设备",
                    value: "\(deviceCount) 台设备",
                    subtitle: selectedClient.map { "已筛选：\(state.clientShortLabel(for: $0))" } ?? "点击左侧设备查看域名与 IP",
                    icon: "laptopcomputer.and.iphone",
                    color: .teal
                )
            } else {
                metricTile(
                    title: "进程分布",
                    value: "\(visibleProcessItems.count) 个进程",
                    subtitle: selectedProcess.map { "已筛选：\($0)" } ?? "点击左侧进程查看域名与 IP",
                    icon: "app.dashed",
                    color: .indigo
                )
            }

            metricTile(
                title: "目标分布",
                value: "\(domReport.items.count) 域名 · \(addrReport.items.count) IP",
                subtitle: activeSourceTitle,
                icon: "globe",
                color: .blue
            )

            metricTile(
                title: "数据覆盖",
                value: coverageTitle(for: procReport.coverage),
                subtitle: coverageSubtitle(for: procReport.coverage),
                icon: procReport.coverage.isPartial ? "clock.badge.exclamationmark" : "checkmark.shield.fill",
                color: procReport.coverage.trackingStartedAt == nil ? .secondary : (procReport.coverage.isPartial ? .orange : .teal)
            )
        }
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

    private var controlsBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $window) {
                ForEach(TrafficRankingWindow.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 215)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("搜索进程、来源设备、域名或 IP…", text: $searchText)
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
            .frame(minWidth: 100, maxWidth: .infinity)

            if let selectedClient {
                Button {
                    self.selectedClient = nil
                } label: {
                    HStack(spacing: 4) {
                        Text("设备: \(state.clientShortLabel(for: selectedClient))")
                            .lineLimit(1)
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.teal)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.teal.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .help("清除设备筛选，恢复查看全部目标")
            } else if let selectedProcess {
                Button {
                    self.selectedProcess = nil
                } label: {
                    HStack(spacing: 4) {
                        Text("进程: \(selectedProcess)")
                            .lineLimit(1)
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .help("清除进程筛选，恢复查看全部目标")
            }

            Menu {
                ForEach(TrafficRankingSortField.allCases) { field in
                    Button {
                        if sortField == field {
                            sortAscending.toggle()
                        } else {
                            sortField = field
                            sortAscending = (field == .name)
                        }
                    } label: {
                        if sortField == field {
                            Label(field.title, systemImage: "checkmark")
                        } else {
                            Text(field.title)
                        }
                    }
                }
            } label: {
                Label("按\(sortField.title)", systemImage: "arrow.up.arrow.down")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                sortAscending.toggle()
            } label: {
                Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                    .font(.caption.weight(.semibold))
            }
            .controlSize(.small)
            .help(sortAscending ? "当前升序，点击切换为降序" : "当前降序，点击切换为升序")

            Button(role: .destructive) {
                selectedProcess = nil
                selectedClient = nil
                monitor.clearTrafficRanking()
                state.showFeedback("已清空流量排行统计")
            } label: {
                Label("清空统计", systemImage: "trash")
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(monitor.trafficRanking.trackingStartedAt == nil)
            .help("清空本地保存的进程、域名与 IP 流量排行数据")
        }
    }

    // MARK: - Left Pane: Process & Source Device Ranking

    private func sourcePane(procReport: TrafficRankingReport, cliReport: TrafficRankingReport) -> some View {
        let isClientMode = (sourceTab == .client)
        let items = (isClientMode ? cliReport.items : procReport.items).filter { !$0.isUnknown }
        let hasSelection = isClientMode ? (selectedClient != nil) : (selectedProcess != nil)

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $sourceTab) {
                    ForEach(TrafficSourcePaneTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 132)

                Spacer()
                if hasSelection {
                    Button("全部") {
                        selectedProcess = nil
                        selectedClient = nil
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                Text("\(items.count) 项")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if items.isEmpty {
                paneEmptyState(isClientMode ? "暂无来源设备流量数据" : "暂无可识别进程")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if isClientMode {
                                clientRow(rank: index + 1, item: item)
                            } else {
                                processRow(rank: index + 1, item: item)
                            }
                            Divider()
                                .padding(.leading, 36)
                        }
                    }
                }
                .frame(minHeight: 0, maxHeight: .infinity)
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.45))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.16))
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func clientRow(rank: Int, item: TrafficRankingItem) -> some View {
        let isSelected = selectedClient == item.key
        let isLocal = item.key == TrafficAttribution.localDeviceLabel
        let displayTitle = state.clientShortLabel(for: item.key)
        let hasSeparateIP = !isLocal && displayTitle != item.key

        return HStack(spacing: 8) {
            Text("\(rank)")
                .font(.system(.caption2, design: .monospaced).weight(rank <= 3 ? .semibold : .regular))
                .foregroundStyle(rank <= 3 ? .primary : .tertiary)
                .frame(width: 20, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: isLocal ? "laptopcomputer" : "iphone.and.arrow.forward")
                        .font(.caption2)
                        .foregroundStyle(isLocal ? Color.secondary : Color.teal)

                    Text(displayTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(item.isOther ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if isLocal {
                        badgeTag("本机", color: .secondary)
                    } else if item.isOther {
                        badgeTag("低频合并", color: .secondary)
                    }

                    Spacer(minLength: 4)

                    Text(TrafficFormatter.bytes(item.total))
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.primary)
                }

                if hasSeparateIP {
                    Text(item.key)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text("↑ \(TrafficFormatter.shortBytes(item.upload))")
                        .foregroundStyle(.blue)
                    Text("↓ \(TrafficFormatter.shortBytes(item.download))")
                        .foregroundStyle(.green)

                    Spacer(minLength: 4)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.14))
                            Capsule()
                                .fill(isLocal ? Color.secondary.opacity(0.7) : Color.teal.opacity(0.85))
                                .frame(width: max(item.total > 0 ? 3 : 0, geo.size.width * (item.percentage / 100.0)))
                        }
                    }
                    .frame(width: 36, height: 5)

                    Text(String(format: "%.1f%%", item.percentage))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(isSelected ? Color.teal : Color.secondary.opacity(0.45))
                }
                .font(.system(.caption2, design: .monospaced))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(isSelected ? Color.teal.opacity(0.14) : Color.clear)
        .onTapGesture {
            selectedProcess = nil
            selectedClient = isSelected ? nil : item.key
        }
        .contextMenu {
            Button(isSelected ? "取消设备筛选" : "筛选此设备的目标流量") {
                selectedProcess = nil
                selectedClient = isSelected ? nil : item.key
            }
            if !isLocal {
                Button("复制设备 IP (\(item.key))") {
                    state.copyText(item.key, label: "设备 IP \(item.key)")
                }
            }
            Button("复制统计摘要") {
                let name = state.clientDisplayLabel(for: item.key)
                let summary = "\(name) | 总计 \(TrafficFormatter.bytes(item.total)) (↑ \(TrafficFormatter.bytes(item.upload)) / ↓ \(TrafficFormatter.bytes(item.download))) · 占比 \(String(format: "%.1f%%", item.percentage))"
                state.copyText(summary, label: "设备流量统计摘要")
            }
        }
    }

    private func processRow(rank: Int, item: TrafficRankingItem) -> some View {
        let isSelected = selectedProcess == item.key
        return HStack(spacing: 8) {
            Text("\(rank)")
                .font(.system(.caption2, design: .monospaced).weight(rank <= 3 ? .semibold : .regular))
                .foregroundStyle(rank <= 3 ? .primary : .tertiary)
                .frame(width: 20, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.key)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(item.isUnknown || item.isOther ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if item.isUnknown {
                        badgeTag("未归因", color: .orange)
                    } else if item.isOther {
                        badgeTag("低频合并", color: .secondary)
                    }

                    Spacer(minLength: 4)

                    Text(TrafficFormatter.bytes(item.total))
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.primary)
                }

                HStack(spacing: 6) {
                    Text("↑ \(TrafficFormatter.shortBytes(item.upload))")
                        .foregroundStyle(.blue)
                    Text("↓ \(TrafficFormatter.shortBytes(item.download))")
                        .foregroundStyle(.green)

                    Spacer(minLength: 4)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.14))
                            Capsule()
                                .fill(item.isUnknown ? Color.orange.opacity(0.75) : Color.indigo.opacity(0.8))
                                .frame(width: max(item.total > 0 ? 3 : 0, geo.size.width * (item.percentage / 100.0)))
                        }
                    }
                    .frame(width: 36, height: 5)

                    Text(String(format: "%.1f%%", item.percentage))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
                }
                .font(.system(.caption2, design: .monospaced))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        .onTapGesture {
            selectedProcess = isSelected ? nil : item.key
        }
        .contextMenu {
            Button(isSelected ? "取消进程筛选" : "筛选此进程的目标流量") {
                selectedProcess = isSelected ? nil : item.key
            }
            Button("复制进程名") {
                state.copyText(item.key, label: "进程 \(item.key)")
            }
            Button("复制统计摘要") {
                let summary = "\(item.key) | 总计 \(TrafficFormatter.bytes(item.total)) (↑ \(TrafficFormatter.bytes(item.upload)) / ↓ \(TrafficFormatter.bytes(item.download))) · 占比 \(String(format: "%.1f%%", item.percentage))"
                state.copyText(summary, label: "流量统计摘要")
            }
        }
    }

    // MARK: - Right Panes: Domain & IP Rankings

    private func targetPane(
        title: String,
        dimension: TrafficRankingDimension,
        report: TrafficRankingReport
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(title, systemImage: dimension.icon)
                    .font(.headline)
                if let selectedClient {
                    Text("· \(state.clientShortLabel(for: selectedClient))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.teal)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if let selectedProcess {
                    Text("· \(selectedProcess)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text("\(report.items.count) 项 · 共 \(TrafficFormatter.bytes(report.grandTotal))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            targetTableHeader(dimension: dimension)
            Divider()

            if report.items.isEmpty {
                paneEmptyState("暂无匹配的\(dimension.title)数据")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(report.items.enumerated()), id: \.element.id) { index, item in
                            targetRow(rank: index + 1, dimension: dimension, item: item)
                            Divider()
                                .padding(.leading, 42)
                        }
                    }
                }
                .frame(minHeight: 0, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.45))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.16))
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func targetTableHeader(dimension: TrafficRankingDimension) -> some View {
        HStack(spacing: 6) {
            Text("#")
                .frame(width: 22, alignment: .trailing)
            sortableHeader(dimension.columnTitle, field: .name, alignment: .leading)
                .frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
            sortableHeader("上传", field: .upload, alignment: .trailing)
                .frame(width: 66, alignment: .trailing)
            sortableHeader("下载", field: .download, alignment: .trailing)
                .frame(width: 66, alignment: .trailing)
            sortableHeader("总量", field: .total, alignment: .trailing)
                .frame(width: 68, alignment: .trailing)
            Text("占比")
                .frame(width: 82, alignment: .trailing)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private func sortableHeader(_ title: String, field: TrafficRankingSortField, alignment: Alignment) -> some View {
        Button {
            if sortField == field {
                sortAscending.toggle()
            } else {
                sortField = field
                sortAscending = (field == .name)
            }
        } label: {
            HStack(spacing: 3) {
                if alignment == .trailing && sortField == field {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(title)
                    .foregroundStyle(sortField == field ? .primary : .secondary)
                if alignment == .leading && sortField == field {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func targetRow(rank: Int, dimension: TrafficRankingDimension, item: TrafficRankingItem) -> some View {
        HStack(spacing: 6) {
            Text("\(rank)")
                .font(.system(.caption2, design: .monospaced).weight(rank <= 3 ? .semibold : .regular))
                .foregroundStyle(rank <= 3 ? .primary : .tertiary)
                .frame(width: 22, alignment: .trailing)

            HStack(spacing: 5) {
                Text(item.key)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(item.isUnknown || item.isOther ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if item.isUnknown {
                    badgeTag("未归因", color: .orange)
                } else if item.isOther {
                    badgeTag("低频合并", color: .secondary)
                }
            }
            .frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)

            Text(TrafficFormatter.bytes(item.upload))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.blue)
                .lineLimit(1)
                .frame(width: 66, alignment: .trailing)

            Text(TrafficFormatter.bytes(item.download))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.green)
                .lineLimit(1)
                .frame(width: 66, alignment: .trailing)

            Text(TrafficFormatter.bytes(item.total))
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 68, alignment: .trailing)

            HStack(spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.14))
                        Capsule()
                            .fill(item.isUnknown ? Color.orange.opacity(0.75) : Color.accentColor.opacity(0.8))
                            .frame(width: max(item.total > 0 ? 3 : 0, geo.size.width * (item.percentage / 100.0)))
                    }
                }
                .frame(width: 36, height: 5)

                Text(String(format: "%.1f%%", item.percentage))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 40, alignment: .trailing)
            }
            .frame(width: 82, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .contextMenu {
            Button("复制\(dimension.title)") {
                state.copyText(item.key, label: "\(dimension.title) \(item.key)")
            }
            Button("复制统计摘要") {
                let summary = "\(item.key) | 总计 \(TrafficFormatter.bytes(item.total)) (↑ \(TrafficFormatter.bytes(item.upload)) / ↓ \(TrafficFormatter.bytes(item.download))) · 占比 \(String(format: "%.1f%%", item.percentage))"
                state.copyText(summary, label: "流量统计摘要")
            }
            Divider()
            Button("前往请求监控") {
                state.selectedSection = .monitor
            }
        }
    }

    private func badgeTag(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.12)))
    }

    private func paneEmptyState(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
    }

    private func emptyState(coverage: TrafficRankingCoverage) -> some View {
        let hasRecordedBuckets = monitor.trafficRanking.trackingStartedAt != nil && coverage.activeBucketCount > 0
        return VStack(spacing: 12) {
            Image(systemName: searchText.isEmpty ? "chart.bar.xaxis" : "magnifyingglass")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)

            Text(searchText.isEmpty ? "当前时间窗口暂无流量数据" : "没有匹配的流量统计记录")
                .font(.headline)

            Text(
                searchText.isEmpty
                    ? "仅从核心运行并采集到可观测代理连接后开始本地累计，不补造历史数据。未经过核心的直连系统流量不在此统计范围内。"
                    : "尝试调整搜索关键词，或切换到其他时间窗口。"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)

            if !searchText.isEmpty {
                Button("重置搜索") {
                    searchText = ""
                }
                .controlSize(.small)
            } else if !state.isCoreRunning && !hasRecordedBuckets {
                Button {
                    state.start()
                } label: {
                    Label("启动核心", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!state.canStart)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var scopeFooter: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            Text("统计口径：进程、域名、IP 为同一份可观测核心流量的三种维度（各面板独立合计 100%，不跨面板相加，不含内部中继 Inner）；缺失归因与采样间隔内短连接归入「未知」，不进行反向 DNS 猜测或外部查询；本地按分钟（60 分钟）与按日（7 天）有界聚合。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func coverageTitle(for coverage: TrafficRankingCoverage) -> String {
        guard coverage.trackingStartedAt != nil else { return "尚无累计" }
        return coverage.isPartial ? "部分累计" : "完整窗口"
    }

    private func coverageSubtitle(for coverage: TrafficRankingCoverage) -> String {
        guard let startedAt = coverage.trackingStartedAt else {
            return "启动核心后从当前开始统计"
        }
        let formatted = Self.coverageDateFormatter.string(from: startedAt)
        if coverage.isPartial {
            return "自 \(formatted) 起（缺失不补零）"
        }
        return "自 \(formatted) 起累计"
    }

    private static let coverageDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        return df
    }()
}
