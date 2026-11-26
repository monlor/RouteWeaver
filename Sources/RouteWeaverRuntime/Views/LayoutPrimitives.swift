import SwiftUI

// MARK: - L1: Horizontal Overflow Isolation & Width Budget Contract

/// Prevents deeply nested wide subviews from inflating `NavigationSplitView`'s minimum
/// intrinsic width beyond the window frame (which would otherwise cause `NSHostingView`
/// to center-clip both the left sidebar and the right edge of the window).
struct WidthBudgetContainer: Layout {
    var minReportedWidth: CGFloat = 480

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let first = subviews.first else { return .zero }
        let width: CGFloat
        if let proposedWidth = proposal.width, proposedWidth.isFinite {
            width = max(proposedWidth, minReportedWidth)
        } else {
            let ideal = first.sizeThatFits(.unspecified).width
            width = max(min(ideal, 980), minReportedWidth)
        }
        let childSize = first.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        let height: CGFloat
        if let proposedHeight = proposal.height, proposedHeight.isFinite {
            height = max(proposedHeight, 0)
        } else {
            height = childSize.height
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let first = subviews.first else { return }
        first.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

/// Constrains a vertical `ScrollView`'s inner document width to the exact viewport width
/// so a long `Picker` or unwrapped row inside a drawer cannot push sibling rows off-screen.
struct ScrollDocumentWidthLock: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let first = subviews.first else { return .zero }
        if let proposedWidth = proposal.width, proposedWidth.isFinite, proposedWidth > 0 {
            let measured = first.sizeThatFits(ProposedViewSize(width: proposedWidth, height: nil))
            return CGSize(width: proposedWidth, height: measured.height)
        }
        return first.sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let first = subviews.first else { return }
        first.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

extension View {
    func isolateHorizontalOverflow(minWidth: CGFloat = 480) -> some View {
        WidthBudgetContainer(minReportedWidth: minWidth) {
            self
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipped()
    }

    func lockScrollDocumentWidth() -> some View {
        ScrollDocumentWidthLock {
            self
        }
    }
}

// MARK: - L1: Adaptive Master-Detail Inspector Scaffold

/// Unified master-detail stage for right-hand diagnostic/detail drawers.
/// - When `stageWidth >= minContentWidth + inspectorWidth + 1`, docks the inspector side-by-side.
/// - When narrower, keeps the primary canvas at 100% width and presents the inspector as a
///   right-hand overlay drawer with a click-to-dismiss scrim.
struct AdaptiveInspectorScaffold<Content: View, Inspector: View>: View {
    let isInspectorPresented: Bool
    var inspectorWidth: CGFloat = 344
    var minContentWidth: CGFloat = 540
    let onDismiss: () -> Void
    @ViewBuilder let content: (_ availableContentWidth: CGFloat) -> Content
    @ViewBuilder let inspector: () -> Inspector

    /// Helper used by callers/tests to determine whether a given stage width docks inline.
    static func docksInline(
        stageWidth: CGFloat,
        isInspectorPresented: Bool,
        inspectorWidth: CGFloat = 344,
        minContentWidth: CGFloat = 540
    ) -> Bool {
        isInspectorPresented && stageWidth >= (minContentWidth + inspectorWidth + 1)
    }

    var body: some View {
        GeometryReader { geo in
            let stageWidth = max(0, geo.size.width)
            let docksInline = Self.docksInline(
                stageWidth: stageWidth,
                isInspectorPresented: isInspectorPresented,
                inspectorWidth: inspectorWidth,
                minContentWidth: minContentWidth
            )
            let contentWidth = docksInline
                ? max(0, stageWidth - inspectorWidth - 1)
                : stageWidth
            let overlayWidth = min(inspectorWidth, max(260, stageWidth - 44))

            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    content(contentWidth)
                        .frame(width: contentWidth)
                        .frame(maxHeight: .infinity)
                        .clipped()

                    if docksInline {
                        Divider()
                        inspector()
                            .frame(width: inspectorWidth)
                            .frame(maxHeight: .infinity)
                            .clipped()
                    }
                }
                .frame(width: stageWidth, height: geo.size.height, alignment: .leading)

                if isInspectorPresented && !docksInline {
                    Color.black.opacity(0.10)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onDismiss)
                        .transition(.opacity)
                        .zIndex(1)

                    HStack(spacing: 0) {
                        Divider()
                        inspector()
                            .frame(width: overlayWidth)
                            .frame(maxHeight: .infinity)
                            .background(Color(nsColor: .windowBackgroundColor))
                            .clipped()
                    }
                    .shadow(color: Color.black.opacity(0.16), radius: 14, x: -4, y: 0)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(2)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: isInspectorPresented)
            .animation(.easeInOut(duration: 0.18), value: docksInline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - L2: Multi-Line Wrapping Flow Layout & Responsive Split Header

/// Native macOS 13+ `Layout` that arranges pills, badges, and buttons horizontally and wraps
/// onto subsequent rows when horizontal space tightens—reporting only a single item's width
/// as its minimum intrinsic width so parent containers never overflow the window.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 6

    struct CacheData {}

    func makeCache(subviews: Subviews) -> CacheData {
        CacheData()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) -> CGSize {
        guard !subviews.isEmpty else { return .zero }

        // When SwiftUI probes minimum width (.zero), report only the widest single child
        // (capped reasonably) rather than the sum of all children.
        if let proposedWidth = proposal.width, proposedWidth <= 0 {
            var maxMinWidth: CGFloat = 0
            var totalHeight: CGFloat = 0
            for (idx, subview) in subviews.enumerated() {
                let s = subview.sizeThatFits(.unspecified)
                maxMinWidth = max(maxMinWidth, min(s.width, 180))
                totalHeight += s.height + (idx > 0 ? verticalSpacing : 0)
            }
            return CGSize(width: maxMinWidth, height: totalHeight)
        }

        let maxRowWidth: CGFloat
        if let proposedWidth = proposal.width, proposedWidth.isFinite {
            maxRowWidth = proposedWidth
        } else {
            maxRowWidth = .greatestFiniteMagnitude
        }

        let arrangement = arrange(maxWidth: maxRowWidth, subviews: subviews)
        return arrangement.totalSize
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) {
        guard !subviews.isEmpty else { return }
        let arrangement = arrange(maxWidth: max(1, bounds.width), subviews: subviews)
        for item in arrangement.items {
            let origin = CGPoint(
                x: bounds.minX + item.frame.minX,
                y: bounds.minY + item.frame.minY
            )
            subviews[item.index].place(
                at: origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(width: item.frame.width, height: nil)
            )
        }
    }

    private struct PlacedItem {
        let index: Int
        let frame: CGRect
    }

    private struct Arrangement {
        let items: [PlacedItem]
        let totalSize: CGSize
    }

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> Arrangement {
        var items: [PlacedItem] = []
        items.reserveCapacity(subviews.count)

        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var usedMaxWidth: CGFloat = 0

        let itemProposal = maxWidth.isFinite
            ? ProposedViewSize(width: maxWidth, height: nil)
            : .unspecified

        for (index, subview) in subviews.enumerated() {
            let rawSize = subview.sizeThatFits(itemProposal)
            let clampedWidth = maxWidth.isFinite ? min(rawSize.width, maxWidth) : rawSize.width
            let size = CGSize(width: max(0, clampedWidth), height: max(0, rawSize.height))

            if cursorX > 0 && (cursorX + size.width > maxWidth + 0.5) {
                cursorX = 0
                cursorY += currentRowHeight + verticalSpacing
                currentRowHeight = 0
            }

            let rect = CGRect(origin: CGPoint(x: cursorX, y: cursorY), size: size)
            items.append(PlacedItem(index: index, frame: rect))

            usedMaxWidth = max(usedMaxWidth, rect.maxX)
            currentRowHeight = max(currentRowHeight, size.height)
            cursorX += size.width + horizontalSpacing
        }

        let totalHeight = cursorY + currentRowHeight
        return Arrangement(
            items: items,
            totalSize: CGSize(width: usedMaxWidth, height: totalHeight)
        )
    }
}

/// Header container that keeps `leading` and `trailing` on a single horizontal line when they
/// comfortably fit, and cleanly stacks `trailing` onto a second leading-aligned line when narrow.
struct SplitHeaderBar<Leading: View, Trailing: View>: View {
    var horizontalSpacing: CGFloat = 12
    var verticalSpacing: CGFloat = 8
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: horizontalSpacing) {
                leading()
                Spacer(minLength: horizontalSpacing)
                trailing()
            }

            VStack(alignment: .leading, spacing: verticalSpacing) {
                leading()
                trailing()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
