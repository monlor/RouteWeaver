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
            HStack(spacing: 8) {
                Label(title, systemImage: icon)
                    .font(.headline)
                Spacer()
                trailing()
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
                .frame(width: labelWidth, alignment: .leading)
            content()
        }
    }
}

struct StatusPill: View {
    let text: String
    let systemImage: String?
    let color: Color

    init(_ text: String, systemImage: String? = nil, color: Color) {
        self.text = text
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(text)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 3.5)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

struct ChainFlowBadge: View {
    let steps: [String]
    let isDirect: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if index > 0 {
                    Image(systemName: "arrow.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                Text(step)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(color(for: index))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(color(for: index).opacity(0.11))
                    )
                    .lineLimit(1)
            }
        }
    }

    private func color(for index: Int) -> Color {
        if isDirect {
            return index == 0 ? .green : .secondary
        }
        if index == 0 { return .blue }
        if index == steps.count - 1 { return .secondary }
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
