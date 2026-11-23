import RoutingCore
import SwiftUI

struct ProcessPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (RunningProcessInfo) -> Void

    @State private var processes: [RunningProcessInfo] = []
    @State private var query = ""

    private var filtered: [RunningProcessInfo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return processes }
        return processes.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("选择当前运行中的进程").font(.headline)
                Spacer()
                Button("刷新") { processes = SystemInspector.discoverRunningProcesses() }
                    .controlSize(.small)
                Button("完成") { dismiss() }
            }

            TextField("搜索进程名（如 Claude、node、curl、ssh）…", text: $query)
                .textFieldStyle(.roundedBorder)

            List(filtered) { proc in
                HStack(spacing: 10) {
                    Image(systemName: proc.isGUIApp ? "app" : "terminal")
                        .foregroundStyle(proc.isGUIApp ? .blue : .secondary)
                        .frame(width: 18)
                    Text(proc.name)
                        .font(.system(.subheadline, design: .monospaced))
                    Spacer()
                    Button("添加") {
                        onSelect(proc)
                    }
                    .controlSize(.small)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 320)
        }
        .padding(18)
        .frame(width: 440, height: 460)
        .onAppear {
            processes = SystemInspector.discoverRunningProcesses()
        }
    }
}

