import SwiftUI

struct SectionCard<Content: View, Trailing: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content

    init(
        _ title: String,
        icon: String,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if Trailing.self == EmptyView.self {
                Label(title, systemImage: icon)
                    .font(.headline)
                    .lineLimit(1)
            } else {
                SplitHeaderBar(horizontalSpacing: 10, verticalSpacing: 8) {
                    Label(title, systemImage: icon)
                        .font(.headline)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } trailing: {
                    trailing()
                }
            }
            content()
        }
        .padding(16)
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
}

struct FormRow<Content: View>: View {
    let title: String
    let labelWidth: CGFloat
    @ViewBuilder let content: () -> Content

    init(_ title: String, labelWidth: CGFloat = 128, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.labelWidth = labelWidth
        self.content = content
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(width: labelWidth, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Atomic status pill with built-in single-line anti-squashing invariants so pills can never
/// deform into vertical single-character columns under tight `HStack` proposals.
struct StatusPill: View {
    let text: String
    let systemImage: String?
    let color: Color
    var maxWidth: CGFloat?

    init(_ text: String, systemImage: String? = nil, color: Color, maxWidth: CGFloat? = nil) {
        self.text = text
        self.systemImage = systemImage
        self.color = color
        self.maxWidth = maxWidth
    }

    var body: some View {
        Group {
            if let maxWidth {
                pillLabel
                    .frame(maxWidth: maxWidth, alignment: .leading)
            } else {
                pillLabel
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private var pillLabel: some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(text)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, 9)
        .padding(.vertical, 3.5)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

/// Atomic single-line monospaced metric readout (speeds, byte counts, active connection counts)
/// guaranteed never to wrap character-by-character vertically.
struct MonospacedMetricText: View {
    let text: String
    var color: Color = .secondary
    var font: Font = .system(.caption, design: .monospaced).weight(.medium)

    init(
        _ text: String,
        color: Color = .secondary,
        font: Font = .system(.caption, design: .monospaced).weight(.medium)
    ) {
        self.text = text
        self.color = color
        self.font = font
    }

    var body: some View {
        Text(text)
            .font(font)
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

struct ChainFlowBadge: View {
    let steps: [String]
    let isDirect: Bool
    var aliasStepCount: Int = 0

    var body: some View {
        FlowLayout(horizontalSpacing: 6, verticalSpacing: 5) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if index > 0 {
                    Image(systemName: "arrow.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                }
                Text(step)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(color(for: index))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(color(for: index).opacity(0.11))
                    )
            }
        }
    }

    private func color(for index: Int) -> Color {
        if index < aliasStepCount {
            return .indigo
        }
        let leafIndex = index - aliasStepCount
        let leafCount = steps.count - aliasStepCount
        if isDirect {
            return leafIndex == 0 ? .green : .secondary
        }
        if leafIndex == 0 { return .blue }
        if leafIndex == leafCount - 1 { return .secondary }
        return .purple
    }
}

struct InlineNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct InlineValidationMessage: View {
    let message: String?
    let isError: Bool

    init(_ message: String?, isError: Bool = true) {
        self.message = message
        self.isError = isError
    }

    var body: some View {
        if let message, !message.isEmpty {
            Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(isError ? Color.red : Color.green)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
