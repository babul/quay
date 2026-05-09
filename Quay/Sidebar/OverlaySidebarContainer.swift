import SwiftUI

/// Shared overlay sidebar container for both the left (hover-driven) and right (click-driven) sidebars.
///
/// Animates visibility via `offset` (GPU-accelerated transform) rather than layout changes.
/// The 1 px separator line is always rendered; the optional `edgeHandle` (9 px drag area)
/// overlaps it to provide a resize affordance.
struct OverlaySidebarContainer<Content: View, EdgeHandle: View>: View {
    /// Extra padding added beyond `width` when offsetting offscreen, to ensure the shadow
    /// doesn't peek through during the hide animation.
    private static var hiddenOffsetPadding: CGFloat { 32 }
    /// Width of the invisible drag area overlapping the separator.
    private static var edgeHandleWidth: CGFloat { 9 }

    let isVisible: Bool
    let width: CGFloat
    let edge: HorizontalEdge
    @ViewBuilder let content: () -> Content
    @ViewBuilder let edgeHandle: () -> EdgeHandle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isLeading: Bool { edge == .leading }
    private var hiddenOffset: CGFloat {
        let magnitude = width + Self.hiddenOffsetPadding
        return isLeading ? -magnitude : magnitude
    }
    private var innerEdgeAlignment: Alignment { isLeading ? .trailing : .leading }
    private var containerAlignment: Alignment { isLeading ? .leading : .trailing }
    private var shadowOffsetX: CGFloat { isLeading ? 4 : -4 }

    var body: some View {
        content()
            .frame(width: width)
            .background(.ultraThinMaterial)
            .overlay(alignment: innerEdgeAlignment) {
                ZStack {
                    Rectangle().fill(.separator).frame(width: 1)
                    edgeHandle().frame(width: Self.edgeHandleWidth)
                }
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.18), radius: 14, x: shadowOffsetX, y: 0)
            .frame(maxWidth: .infinity, alignment: containerAlignment)
            .offset(x: isVisible ? 0 : hiddenOffset)
            .animation(
                reduceMotion ? .linear(duration: 0.12) : .snappy(duration: 0.3),
                value: isVisible
            )
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }
}

extension OverlaySidebarContainer where EdgeHandle == EmptyView {
    init(
        isVisible: Bool,
        width: CGFloat,
        edge: HorizontalEdge,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(isVisible: isVisible, width: width, edge: edge, content: content) { EmptyView() }
    }
}
