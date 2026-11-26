import RoutingCore
import SwiftUI

struct DNSRecordTypeBadge: View {
    let recordType: String

    private var color: Color {
        switch recordType.uppercased() {
        case "A": return .blue
        case "AAAA": return .indigo
        case "HTTPS", "SVCB": return .teal
        case "CNAME", "TXT", "SRV", "MX": return .orange
        default: return .secondary
        }
    }

    var body: some View {
        Text(recordType)
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
}

struct DNSLogListView: View {
    @ObservedObject var state: AppState
    @ObservedObject var monitor: ConnectionMonitorService
    let rows: [DNSLogRecord]
    @Binding var selectedDNSLogID: UUID?
    var availableWidth: CGFloat = 720
    let onResetFilters: () -> Void

    private var dnsDomainColumnWidth: CGFloat {
        if availableWidth < 600 { return 160 }
        return selectedDNSLogID == nil ? 240 : 196
    }

    private var dnsUpstreamColumnWidth: CGFloat {
        if availableWidth < 600 { return 124 }
        return selectedDNSLogID == nil ? 180 : 148
    }

    var body: some View {
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
                        Button("重置筛选", action: onResetFilters)
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
            Text(MonitorTimeFormatter.string(from: item.timestamp))
                .font(.system(.caption2, design: .monospaced).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 78, alignment: .leading)

            DNSRecordTypeBadge(recordType: item.recordType)
                .frame(width: 50, alignment: .leading)

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

            dnsAnswerCell(for: item)
                .frame(maxWidth: .infinity, alignment: .leading)

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
}
