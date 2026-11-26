import RoutingCore
import SwiftUI

struct ConnectionInspectorView: View {
    @ObservedObject var state: AppState
    let item: MonitoredConnection
    let ruleIndex: RuleMatchDisplayIndex
    let relayChain: ResolvedRelayChain?
    let onClose: () -> Void

    var body: some View {
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
                    Button(action: onClose) {
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

                    if item.isActive && state.isCoreRunning {
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

                VStack(alignment: .leading, spacing: 6) {
                    Text("分流与代理链路")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if !item.displayChain.isEmpty {
                        let fullSteps: [String] = {
                            if let relay = relayChain {
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
                    if let relayChain {
                        MonitorInspectorRow(
                            label: "链式中转",
                            value: relayChain.relayNode.map { "\(relayChain.relayGroupName) · \($0)" } ?? relayChain.relayGroupName
                        )
                    }
                    let matchedRule = ruleIndex.resolve(rule: item.rule, payload: item.rulePayload)
                    if let matchedRule {
                        MonitorInspectorRow(label: "命中规则组", value: matchedRule.groupName)
                        if let note = matchedRule.ruleNote, !note.isEmpty {
                            MonitorInspectorRow(label: "规则来源", value: note)
                        }
                    }
                    MonitorInspectorRow(label: "命中规则", value: item.ruleSummary, monospaced: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("流量数据")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    MonitorInspectorRow(label: "上传总量", value: TrafficFormatter.bytes(item.upload), monospaced: true)
                    MonitorInspectorRow(label: "下载总量", value: TrafficFormatter.bytes(item.download), monospaced: true)
                    if item.isActive {
                        MonitorInspectorRow(label: "上传速率", value: TrafficFormatter.speed(item.uploadSpeed), monospaced: true)
                        MonitorInspectorRow(label: "下载速率", value: TrafficFormatter.speed(item.downloadSpeed), monospaced: true)
                    }
                    MonitorInspectorRow(label: "持续时长", value: TrafficFormatter.duration(item.duration()), monospaced: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("连接元数据")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    MonitorInspectorRow(label: "目标域名", value: item.metadata.host.isEmpty ? "—" : item.metadata.host, monospaced: true)
                    MonitorInspectorRow(label: "目标 IP", value: item.destinationIPAddress, monospaced: true)
                    MonitorInspectorRow(label: "来源地址", value: item.sourceAddress, monospaced: true)
                    if !item.metadata.dnsMode.isEmpty {
                        MonitorInspectorRow(label: "DNS 模式", value: item.metadata.dnsMode, monospaced: true)
                    }
                    if !item.processDisplayName.isEmpty {
                        MonitorInspectorRow(label: "来源进程", value: item.processDisplayName)
                    }
                    if !item.metadata.processPath.isEmpty {
                        MonitorInspectorRow(label: "进程路径", value: item.metadata.processPath, monospaced: true)
                    }
                    MonitorInspectorRow(label: "开始时间", value: MonitorTimeFormatter.string(from: item.startDate ?? item.firstSeenAt), monospaced: true)
                    if let closed = item.closedAt {
                        MonitorInspectorRow(label: "结束时间", value: MonitorTimeFormatter.string(from: closed), monospaced: true)
                    }
                    MonitorInspectorRow(label: "连接 ID", value: item.id, monospaced: true)
                }
            }
            .padding(16)
            .lockScrollDocumentWidth()
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }
}
