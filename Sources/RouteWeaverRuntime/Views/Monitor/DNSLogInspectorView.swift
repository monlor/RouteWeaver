import RoutingCore
import SwiftUI

struct DNSLogInspectorView: View {
    @ObservedObject var state: AppState
    let item: DNSLogRecord
    let onClose: () -> Void

    private var statusTitle: String {
        if item.status == .failed { return "解析失败" }
        if item.isSuspiciousLoopback { return "疑似回环" }
        if !item.hasAnswers { return "无记录" }
        return "解析成功"
    }

    private var statusIcon: String {
        if item.status == .failed { return "xmark.circle.fill" }
        if item.isSuspiciousLoopback { return "exclamationmark.triangle.fill" }
        if !item.hasAnswers { return "minus.circle" }
        return "checkmark.circle.fill"
    }

    private var statusColor: Color {
        if item.status == .failed { return .red }
        if item.isSuspiciousLoopback { return .orange }
        if !item.hasAnswers { return .secondary }
        return .green
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            StatusPill(statusTitle, systemImage: statusIcon, color: statusColor)
                            DNSRecordTypeBadge(recordType: item.recordType)
                        }
                        Text(item.domain)
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

                VStack(alignment: .leading, spacing: 6) {
                    Text("查询信息")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    MonitorInspectorRow(label: "来源类型", value: dnsSourceLabel(for: item.upstreamKind))
                    MonitorInspectorRow(label: "上游地址", value: item.upstream, monospaced: true)
                    if let expire = item.cacheExpireAt, !expire.isEmpty {
                        MonitorInspectorRow(label: "缓存过期时间", value: expire, monospaced: true)
                    }
                    MonitorInspectorRow(label: "记录类型", value: item.recordType, monospaced: true)
                    MonitorInspectorRow(label: "查询时间", value: MonitorTimeFormatter.string(from: item.timestamp), monospaced: true)
                }

                Divider()

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
            .lockScrollDocumentWidth()
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
}
