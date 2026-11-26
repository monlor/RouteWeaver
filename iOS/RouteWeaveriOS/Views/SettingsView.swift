import RoutingCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: MobileAppModel

    var body: some View {
        NavigationStack {
            List {
                Section("连接与分流") {
                    NavigationLink {
                        NetworkPolicyView(embedded: true)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("网络切换策略")
                                Text("按 Wi-Fi SSID / 蜂窝网络自动切换 VPN 模式")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(.blue)
                        }
                    }

                    NavigationLink {
                        InterfaceRelayView(embedded: true)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("中继与链式入口")
                                Text(model.relayConfig.isEnabled ? "已从 PC 自动同步中继" : "未启用中继")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "network.badge.shield.half.filled")
                                .foregroundStyle(.purple)
                        }
                    }
                }

                Section("远程主机") {
                    NavigationLink {
                        RemotePCView(embedded: true)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("远程 PC 管理与配对")
                                Text(model.activeHost.map { "当前主机：\($0.hostName)" } ?? "尚未配对远程 PC")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(.teal)
                        }
                    }
                }

                Section("已同步配置与运行环境") {
                    if let synced = model.syncedHostState {
                        LabeledContent("来源主机", value: synced.savedHost.hostName)
                        LabeledContent("配置方案", value: synced.profile.name)
                        LabeledContent("规则组", value: "\(synced.profile.ruleGroups.count) 组")
                        LabeledContent("规则引用网卡", value: "\(model.referencedPCInterfaceNames.count) 张")
                        LabeledContent("上次同步") {
                            Text(synced.lastSyncedAt, style: .relative)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("尚未从 PC 同步配置。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let status = model.runtimeStatus {
                        LabeledContent("本地内核", value: status.engineVersion)
                    }

                    if model.activeHost != nil {
                        Button {
                            Task { await model.syncNow() }
                        } label: {
                            Label(model.isSyncing ? "正在同步…" : "立即从 PC 同步最新配置", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(model.isSyncing)
                    }
                }
            }
            .navigationTitle("设置")
        }
    }
}
