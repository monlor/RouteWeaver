import RoutingCore
import SwiftUI

struct RuleSetPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (SubconverterRuleSet, SubconverterMirror) -> Void

    @State private var source: Int = 0
    @State private var mirror: SubconverterMirror = .monlorProxy
    @State private var query = ""

    private var currentList: [SubconverterRuleSet] {
        source == 0 ? SubconverterCatalog.allRuleSets : SubconverterCatalog.monlorRuleSets
    }

    private var filtered: [SubconverterRuleSet] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return currentList }
        return currentList.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.path.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("添加在线规则集（ACL4SSR / monlor）").font(.headline)
                Spacer()
                Button("完成") { dismiss() }
            }

            Picker("", selection: $source) {
                Text("全部 ACL4SSR (\(SubconverterCatalog.allRuleSets.count))").tag(0)
                Text("monlor/subconverter-rules (\(SubconverterCatalog.monlorRuleSets.count))").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 10) {
                TextField("搜索规则集（如 OpenAi、Claude、kiro、wallet、vowifi）…", text: $query)
                    .textFieldStyle(.roundedBorder)

                Picker("", selection: $mirror) {
                    ForEach(SubconverterMirror.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .labelsHidden()
                .frame(width: 145)
            }

            List(filtered) { rs in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rs.name).font(.subheadline.weight(.medium))
                        Text(rs.path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("添加") {
                        onSelect(rs, mirror)
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
            .frame(minHeight: 320)
        }
        .padding(18)
        .frame(width: 560, height: 500)
    }
}
