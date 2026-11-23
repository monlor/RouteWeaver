import RoutingCore
import SwiftUI

struct ConnectionListView: View {
    @ObservedObject var state: AppState
    @ObservedObject var monitor: ConnectionMonitorService
    let rows: [MonitoredConnection]
    let ruleIndex: RuleMatchDisplayIndex
    @Binding var selectedConnectionID: String?
    let resolveRelayChain: (MonitoredConnection) -> ResolvedRelayChain?
    let onResetFilters: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            listHeaderRow
            Divider()

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

            let relayInfo = resolveRelayChain(item)
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
                Button("重置筛选", action: onResetFilters)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
