import RoutingCore
import SwiftUI

struct AppPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (InstalledAppInfo) -> Void

    @State private var apps: [InstalledAppInfo] = []
    @State private var query = ""

    private var filtered: [InstalledAppInfo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.executableName.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("选择 macOS 应用").font(.headline)
                Spacer()
                Button("完成") { dismiss() }
            }

            TextField("搜索应用名称或进程名…", text: $query)
                .textFieldStyle(.roundedBorder)

            List(filtered) { app in
                HStack(spacing: 10) {
                    Image(nsImage: app.icon)
                        .resizable()
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name).font(.subheadline.weight(.medium))
                        Text("进程名：\(app.executableName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("添加") {
                        onSelect(app)
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
            .frame(minHeight: 320)
        }
        .padding(18)
        .frame(width: 460, height: 460)
        .onAppear {
            apps = SystemInspector.discoverInstalledApps()
        }
    }
}

