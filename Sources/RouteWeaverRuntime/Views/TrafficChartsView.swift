import AppKit
import Charts
import RoutingCore
import SwiftUI

// MARK: - Subscription Usage Bar

struct SubscriptionUsageBar: View {
    let usage: SubscriptionUsage
    var compact: Bool = false

    private var now: Date { Date() }

    private var isExpired: Bool {
        usage.isExpired(referenceNow: now)
    }

    private var progressColor: Color {
        if isExpired || usage.isOverLimit || usage.usageFraction >= 0.9 {
            return .red
        }
        if usage.usageFraction >= 0.75 {
            return .orange
        }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 6) {
            if usage.total > 0 {
                HStack(spacing: 8) {
                    Text("已用 \(TrafficFormatter.bytes(usage.used)) / \(TrafficFormatter.bytes(usage.total))")
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .foregroundStyle(.primary)

                    Text(String(format: "%.1f%%", usage.usagePercentage))
                        .font(.system(.caption2, design: .monospaced).weight(.semibold))
                        .foregroundStyle(progressColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(progressColor.opacity(0.14)))

                    Spacer()

                    Text("剩余 \(TrafficFormatter.bytes(usage.remaining))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(usage.isOverLimit ? .red : .secondary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.16))
                        Capsule()
                            .fill(progressColor)
                            .frame(width: max(usage.used > 0 ? 4 : 0, geo.size.width * usage.usageFraction))
                    }
                }
                .frame(height: compact ? 5 : 6)
            } else {
                HStack(spacing: 8) {
                    Text("已用 \(TrafficFormatter.bytes(usage.used))")
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                    StatusPill("不限总量", color: .teal)
                    Spacer()
                }
            }

            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Text("↑")
                        .foregroundStyle(.blue)
                    Text(TrafficFormatter.bytes(usage.upload))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("↓")
                        .foregroundStyle(.green)
                    Text(TrafficFormatter.bytes(usage.download))
                        .foregroundStyle(.secondary)
                }
                .font(.system(.caption2, design: .monospaced))

                Spacer()

                expireBadge

                if let webURLString = usage.webPageURL, let webURL = URL(string: webURLString) {
                    Button {
                        NSWorkspace.shared.open(webURL)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("打开机场官网：\(webURLString)")
                }
            }
        }
        .padding(.horizontal, compact ? 10 : 12)
        .padding(.vertical, compact ? 8 : 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.14))
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var expireBadge: some View {
        if let expireDate = usage.expireDate {
            let days = usage.daysUntilExpire(referenceNow: now) ?? 0
            let dateText = Self.dateFormatter.string(from: expireDate)
            if isExpired {
                Label("已过期 (\(dateText))", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.red)
            } else if days <= 7 {
                Label("剩余 \(days) 天 · \(dateText)", systemImage: "clock.badge.exclamationmark")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
            } else {
                Label("剩余 \(days) 天 · \(dateText)", systemImage: "calendar")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Label("长期有效", systemImage: "infinity")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()
}

// MARK: - Traffic Overview Card (Charts)

enum TrafficChartMode: String, CaseIterable, Identifiable {
    case liveSpeed
    case todayHourly
    case last7Days
    case last30Days
    case byTarget

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liveSpeed: return "实时速率"
        case .todayHourly: return "今日分时"
        case .last7Days: return "近 7 天"
        case .last30Days: return "近 30 天"
        case .byTarget: return "出口分布"
        }
    }
}

enum TargetDistributionRange: String, CaseIterable, Identifiable {
    case session
    case today
    case last7Days
    case last30Days

    var id: String { rawValue }

    var title: String {
        switch self {
        case .session: return "本次运行"
        case .today: return "今日"
        case .last7Days: return "近 7 天"
        case .last30Days: return "近 30 天"
        }
    }
}

private struct ChartSpeedPoint: Identifiable {
    let id: String
    let index: Int
    let series: String
    let speed: Double
}

private struct ChartTrafficBarPoint: Identifiable {
    let id: String
    let label: String
    let series: String
    let bytes: Double
}

struct TrafficOverviewCard: View {
    @ObservedObject var state: AppState
    @ObservedObject var monitor: ConnectionMonitorService
    @State private var chartMode: TrafficChartMode = .liveSpeed
    @State private var selectedTarget: String? = nil
    @State private var targetDistRange: TargetDistributionRange = .today

    private var directTargetNames: Set<String> {
        Set(state.profile.targets.filter { $0.mode == .direct }.map(\.name))
    }

    private var availableFilterTargets: [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        for target in state.profile.targets {
            if seen.insert(target.name).inserted {
                ordered.append(target.name)
            }
        }
        let extra = Set(monitor.tracker.targetTrafficStats.map(\.target))
            .union(monitor.trafficHistory.availableTargets())
            .subtracting(seen)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        ordered.append(contentsOf: extra)
        return ordered
    }

    private var activeFilterTarget: String? {
        guard chartMode != .byTarget, let selected = selectedTarget, !selected.isEmpty else {
            return nil
        }
        return selected
    }

    private var currentLiveSpeed: (upload: Int64, download: Int64) {
        if let target = activeFilterTarget {
            let speed = monitor.tracker.liveSpeed(for: target)
            return (speed.upload, speed.download)
        }
        return (monitor.tracker.uploadSpeed, monitor.tracker.downloadSpeed)
    }

    private var sessionTraffic: (upload: Int64, download: Int64) {
        if let target = activeFilterTarget {
            let bytes = monitor.tracker.sessionTraffic(for: target)
            return (bytes.upload, bytes.download)
        }
        return (monitor.tracker.uploadTotal, monitor.tracker.downloadTotal)
    }

    private var todayRecord: DailyTrafficRecord {
        monitor.trafficHistory.todayRecord(target: activeFilterTarget)
    }

    private var last7Total: (upload: Int64, download: Int64) {
        monitor.trafficHistory.totalBytes(lastNDays: 7, target: activeFilterTarget)
    }

    private var sessionTotal: Int64 {
        sessionTraffic.upload + sessionTraffic.download
    }

    private var activeTargetStats: [TargetTrafficStat] {
        switch targetDistRange {
        case .session:
            return monitor.tracker.targetTrafficStats(directTargetNames: directTargetNames)
        case .today:
            return monitor.trafficHistory.targetTrafficStats(lastNDays: 1, directTargetNames: directTargetNames)
        case .last7Days:
            return monitor.trafficHistory.targetTrafficStats(lastNDays: 7, directTargetNames: directTargetNames)
        case .last30Days:
            return monitor.trafficHistory.targetTrafficStats(lastNDays: 30, directTargetNames: directTargetNames)
        }
    }

    var body: some View {
        SectionCard("流量消耗与速率趋势", icon: "chart.xyaxis.line") {
            HStack(spacing: 8) {
                if chartMode == .byTarget {
                    Picker("", selection: $targetDistRange) {
                        ForEach(TargetDistributionRange.allCases) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 96)
                    .help("切换出口分布统计周期")
                } else if !availableFilterTargets.isEmpty {
                    Picker("", selection: $selectedTarget) {
                        Text("全部目标").tag(String?.none)
                        Divider()
                        ForEach(availableFilterTargets, id: \.self) { name in
                            Text(name).tag(String?.some(name))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 136)
                    .help("按网络目标筛选流量与速率")
                }

                Picker("", selection: $chartMode) {
                    ForEach(TrafficChartMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 310)

                Menu {
                    Button("前往请求监控") {
                        state.selectedSection = .monitor
                    }
                    if selectedTarget != nil {
                        Button("重置为全部目标") {
                            selectedTarget = nil
                        }
                    }
                    Divider()
                    Button("清空历史流量统计", role: .destructive) {
                        monitor.clearTrafficHistory()
                        state.showFeedback("已清空历史流量统计")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("流量统计选项")
            }
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                kpiStrip

                chartCanvas
                    .frame(height: 186)

                chartFooterLegend
            }
        }
    }

    private var kpiStrip: some View {
        HStack(spacing: 10) {
            kpiTile(
                title: activeFilterTarget == nil ? "实时速率" : "目标速率",
                primary: "↓ \(TrafficFormatter.speed(currentLiveSpeed.download))",
                secondary: "↑ \(TrafficFormatter.speed(currentLiveSpeed.upload))",
                accent: .green,
                icon: "speedometer"
            )

            kpiTile(
                title: "本次运行",
                primary: TrafficFormatter.bytes(sessionTotal),
                secondary: "↑ \(TrafficFormatter.shortBytes(sessionTraffic.upload)) · ↓ \(TrafficFormatter.shortBytes(sessionTraffic.download))",
                accent: .blue,
                icon: "bolt.horizontal.circle.fill"
            )

            kpiTile(
                title: "今日消耗",
                primary: TrafficFormatter.bytes(todayRecord.total),
                secondary: "↑ \(TrafficFormatter.shortBytes(todayRecord.upload)) · ↓ \(TrafficFormatter.shortBytes(todayRecord.download))",
                accent: .teal,
                icon: "sun.max.fill"
            )

            kpiTile(
                title: "近 7 天累计",
                primary: TrafficFormatter.bytes(last7Total.upload + last7Total.download),
                secondary: "↑ \(TrafficFormatter.shortBytes(last7Total.upload)) · ↓ \(TrafficFormatter.shortBytes(last7Total.download))",
                accent: .purple,
                icon: "calendar"
            )
        }
    }

    private func kpiTile(
        title: String,
        primary: String,
        secondary: String,
        accent: Color,
        icon: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(accent)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(primary)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                Text(secondary)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.14))
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var chartCanvas: some View {
        switch chartMode {
        case .liveSpeed:
            liveSpeedChart
        case .todayHourly:
            hourlyBarChart
        case .last7Days:
            dailyBarChart(days: 7)
        case .last30Days:
            dailyBarChart(days: 30)
        case .byTarget:
            targetDistributionChart
        }
    }

    @ViewBuilder
    private var liveSpeedChart: some View {
        let samples = monitor.tracker.speedHistory(for: activeFilterTarget)
        if samples.count < 2 {
            emptyChartPlaceholder(
                icon: "waveform.path.ecg",
                title: state.engine.isRunning ? "正在采集实时速率…" : "核心未运行",
                subtitle: state.engine.isRunning
                    ? "建立代理流量后将在此绘制最近 60 秒的上传/下载速率曲线。"
                    : "启动核心后即可实时查看上传与下载速率波动，历史消耗仍可在「今日分时 / 近 7 天」查看。"
            )
        } else {
            let points: [ChartSpeedPoint] = samples.enumerated().flatMap { idx, sample in
                [
                    ChartSpeedPoint(id: "d-\(sample.id)", index: idx, series: "下载", speed: Double(sample.downloadSpeed)),
                    ChartSpeedPoint(id: "u-\(sample.id)", index: idx, series: "上传", speed: Double(sample.uploadSpeed)),
                ]
            }
            let peakSpeed = max(1024.0, Double(samples.map { max($0.downloadSpeed, $0.uploadSpeed) }.max() ?? 1024))

            Chart(points) { point in
                AreaMark(
                    x: .value("时间", point.index),
                    y: .value("速率", point.speed)
                )
                .foregroundStyle(by: .value("方向", point.series))
                .opacity(0.18)
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("时间", point.index),
                    y: .value("速率", point.speed)
                )
                .foregroundStyle(by: .value("方向", point.series))
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.catmullRom)
            }
            .chartForegroundStyleScale([
                "下载": Color.green,
                "上传": Color.blue,
            ])
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .chartYScale(domain: 0...(peakSpeed * 1.15))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .foregroundStyle(Color.secondary.opacity(0.25))
                    AxisValueLabel {
                        if let raw = value.as(Double.self) {
                            Text(TrafficFormatter.shortSpeed(Int64(max(0, raw))))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.top, 4)
            .clipped()
        }
    }

    @ViewBuilder
    private var hourlyBarChart: some View {
        let buckets = monitor.trafficHistory.todayHourlyBuckets(target: activeFilterTarget)
        let hasData = buckets.contains { $0.total > 0 }
        if !hasData {
            emptyChartPlaceholder(
                icon: "chart.bar",
                title: activeFilterTarget.map { "「\($0)」今日暂无流量记录" } ?? "今日暂无流量记录",
                subtitle: "启动核心并产生流量后，系统会自动按小时累计上传与下载消耗。"
            )
        } else {
            let points: [ChartTrafficBarPoint] = buckets.flatMap { bucket in
                [
                    ChartTrafficBarPoint(id: "d-\(bucket.hour)", label: bucket.shortLabel, series: "下载", bytes: Double(bucket.download)),
                    ChartTrafficBarPoint(id: "u-\(bucket.hour)", label: bucket.shortLabel, series: "上传", bytes: Double(bucket.upload)),
                ]
            }

            Chart(points) { point in
                BarMark(
                    x: .value("时段", point.label),
                    y: .value("流量", point.bytes)
                )
                .foregroundStyle(by: .value("方向", point.series))
                .cornerRadius(2)
            }
            .chartForegroundStyleScale([
                "下载": Color.green,
                "上传": Color.blue,
            ])
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: ["00", "04", "08", "12", "16", "20", "23"]) { value in
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text("\(label)时")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .foregroundStyle(Color.secondary.opacity(0.25))
                    AxisValueLabel {
                        if let raw = value.as(Double.self) {
                            Text(TrafficFormatter.shortBytes(Int64(max(0, raw))))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.top, 4)
            .clipped()
        }
    }

    @ViewBuilder
    private func dailyBarChart(days: Int) -> some View {
        let records = monitor.trafficHistory.lastNDays(days, target: activeFilterTarget)
        let hasData = records.contains { $0.total > 0 }
        if !hasData {
            emptyChartPlaceholder(
                icon: "chart.bar.xaxis",
                title: activeFilterTarget.map { "「\($0)」近 \(days) 天暂无流量记录" } ?? "近 \(days) 天暂无流量记录",
                subtitle: "流量消耗会自动按天与网络目标持久化保存到本地，重启应用或核心不会清零。"
            )
        } else {
            let points: [ChartTrafficBarPoint] = records.flatMap { rec in
                [
                    ChartTrafficBarPoint(id: "d-\(rec.dayKey)", label: rec.shortLabel, series: "下载", bytes: Double(rec.download)),
                    ChartTrafficBarPoint(id: "u-\(rec.dayKey)", label: rec.shortLabel, series: "上传", bytes: Double(rec.upload)),
                ]
            }
            let visibleXLabels: [String] = {
                if days <= 7 {
                    return records.map(\.shortLabel)
                }
                return records.enumerated().compactMap { idx, rec in
                    (idx == 0 || idx == records.count - 1 || idx % 5 == 0) ? rec.shortLabel : nil
                }
            }()

            Chart(points) { point in
                BarMark(
                    x: .value("日期", point.label),
                    y: .value("流量", point.bytes)
                )
                .foregroundStyle(by: .value("方向", point.series))
                .cornerRadius(days <= 7 ? 3 : 2)
            }
            .chartForegroundStyleScale([
                "下载": Color.green,
                "上传": Color.blue,
            ])
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: visibleXLabels) { value in
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(label)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .foregroundStyle(Color.secondary.opacity(0.25))
                    AxisValueLabel {
                        if let raw = value.as(Double.self) {
                            Text(TrafficFormatter.shortBytes(Int64(max(0, raw))))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.top, 4)
            .clipped()
        }
    }

    @ViewBuilder
    private var targetDistributionChart: some View {
        let allStats = activeTargetStats
        let stats = Array(allStats.prefix(7))
        let grandTotal = max(Int64(1), allStats.reduce(0) { $0 + $1.total })
        if stats.isEmpty {
            emptyChartPlaceholder(
                icon: "arrow.triangle.branch",
                title: "\(targetDistRange.title)暂无分流出口流量",
                subtitle: "核心运行并产生连接后，将按网络目标持久化统计各周期流量占比。"
            )
        } else {
            Chart(stats) { stat in
                BarMark(
                    x: .value("流量", Double(stat.total)),
                    y: .value("出口", stat.target)
                )
                .foregroundStyle(targetBarColor(stat))
                .cornerRadius(4)
                .annotation(position: .trailing, alignment: .leading, spacing: 6) {
                    let pct = Double(stat.total) * 100.0 / Double(grandTotal)
                    Text("\(TrafficFormatter.bytes(stat.total)) (\(String(format: "%.0f%%", pct)))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .foregroundStyle(Color.secondary.opacity(0.25))
                    AxisValueLabel {
                        if let raw = value.as(Double.self) {
                            Text(TrafficFormatter.shortBytes(Int64(max(0, raw))))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let name = value.as(String.self) {
                            Text(name)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.trailing, 76)
            .padding(.top, 4)
            .clipped()
        }
    }

    private func targetBarColor(_ stat: TargetTrafficStat) -> Color {
        if stat.isRejected { return .red }
        if stat.isDirect { return .green }
        return .blue
    }

    private var chartFooterLegend: some View {
        HStack(spacing: 14) {
            if chartMode == .byTarget {
                legendDot("代理出口", color: .blue)
                legendDot("直连出口", color: .green)
                legendDot("拦截", color: .red)
            } else {
                legendDot("下载流量", color: .green)
                legendDot("上传流量", color: .blue)
            }

            Spacer()

            switch chartMode {
            case .liveSpeed:
                let samples = monitor.tracker.speedHistory(for: activeFilterTarget)
                if let peakDown = samples.map(\.downloadSpeed).max(), peakDown > 0 {
                    Text("\(activeFilterTarget.map { "\($0) · " } ?? "")近 1 分钟峰值：↓ \(TrafficFormatter.speed(peakDown))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                } else if let target = activeFilterTarget {
                    Text("已筛选目标：\(target)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            case .todayHourly:
                Text("\(activeFilterTarget.map { "\($0) · " } ?? "")今日共 \(TrafficFormatter.bytes(todayRecord.total))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            case .last7Days:
                let total = last7Total.upload + last7Total.download
                Text("\(activeFilterTarget.map { "\($0) · " } ?? "")7 天共 \(TrafficFormatter.bytes(total))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            case .last30Days:
                let month = monitor.trafficHistory.totalBytes(lastNDays: 30, target: activeFilterTarget)
                Text("\(activeFilterTarget.map { "\($0) · " } ?? "")30 天共 \(TrafficFormatter.bytes(month.upload + month.download))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            case .byTarget:
                let stats = activeTargetStats
                let total = stats.reduce(Int64(0)) { $0 + $1.total }
                Text("共 \(stats.count) 个出口 · \(targetDistRange.title)共 \(TrafficFormatter.bytes(total))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func legendDot(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func emptyChartPlaceholder(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.4))
        )
    }
}

// MARK: - Compact Live Speed Strip (for RequestMonitorView)

struct LiveSpeedSparklineCard: View {
    @ObservedObject var monitor: ConnectionMonitorService
    let isRunning: Bool

    var body: some View {
        let samples = monitor.tracker.speedHistory
        let peakDown = samples.map(\.downloadSpeed).max() ?? 0
        let peakUp = samples.map(\.uploadSpeed).max() ?? 0
        let maxY = max(1024.0, Double(max(peakDown, peakUp)))

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Label("实时吞吐曲线（近 60 秒）", systemImage: "chart.xyaxis.line")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("下载")
                    }
                    HStack(spacing: 4) {
                        Circle().fill(Color.blue).frame(width: 6, height: 6)
                        Text("上传")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)

                Spacer()

                if peakDown > 0 || peakUp > 0 {
                    Text("峰值 ↓ \(TrafficFormatter.speed(peakDown)) · ↑ \(TrafficFormatter.speed(peakUp))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            if samples.count < 2 {
                HStack {
                    Text(isRunning ? "正在采集实时速率样本…" : "核心未运行")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 68)
            } else {
                let points: [ChartSpeedPoint] = samples.enumerated().flatMap { idx, sample in
                    [
                        ChartSpeedPoint(id: "d-\(sample.id)", index: idx, series: "下载", speed: Double(sample.downloadSpeed)),
                        ChartSpeedPoint(id: "u-\(sample.id)", index: idx, series: "上传", speed: Double(sample.uploadSpeed)),
                    ]
                }

                Chart(points) { point in
                    AreaMark(
                        x: .value("时间", point.index),
                        y: .value("速率", point.speed)
                    )
                    .foregroundStyle(by: .value("方向", point.series))
                    .opacity(0.16)
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("时间", point.index),
                        y: .value("速率", point.speed)
                    )
                    .foregroundStyle(by: .value("方向", point.series))
                    .lineStyle(StrokeStyle(lineWidth: 1.75))
                    .interpolationMethod(.catmullRom)
                }
                .chartForegroundStyleScale([
                    "下载": Color.green,
                    "上传": Color.blue,
                ])
                .chartLegend(.hidden)
                .chartXAxis(.hidden)
                .chartYScale(domain: 0...(maxY * 1.15))
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                            .foregroundStyle(Color.secondary.opacity(0.2))
                        AxisValueLabel {
                            if let raw = value.as(Double.self) {
                                Text(TrafficFormatter.shortSpeed(Int64(max(0, raw))))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .frame(height: 68)
                .clipped()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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
}
