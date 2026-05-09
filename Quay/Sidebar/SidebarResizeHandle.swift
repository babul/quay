import SwiftUI

/// A transparent 9 px drag area that resizes an overlay sidebar.
///
/// Captures the sidebar width at drag start via `@GestureState` so that
/// `translation.width` (total delta) can be applied cleanly without accumulation errors.
/// Persists width only on gesture end via `onCommit`.
struct SidebarResizeHandle: View {
    let edge: HorizontalEdge
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    let onCommit: (CGFloat) -> Void

    @GestureState private var startWidth: CGFloat? = nil

    var body: some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: edge == .leading ? .trailing : .leading))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($startWidth) { _, state, _ in
                        if state == nil { state = width }
                    }
                    .onChanged { value in
                        let start = startWidth ?? width
                        let delta = edge == .leading ? value.translation.width : -value.translation.width
                        width = min(range.upperBound, max(range.lowerBound, start + delta))
                    }
                    .onEnded { _ in onCommit(width) }
            )
    }
}
