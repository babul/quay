import SwiftUI

/// Horizontal tab strip reading directly from `TerminalTabManager`.
/// No reducer round-trip — high-frequency updates (title changes, phase
/// transitions) propagate via @Observable without going through TCA.
struct TerminalTabBar: View {
    var tabManager: TerminalTabManager
    @AppStorage("appearance.showTabColorBars") private var showTabColorBars = true

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(tabManager.tabs) { tab in
                    TabButton(
                        title: tab.displayTitle,
                        subtitle: tab.displayHost,
                        phase: tab.phase,
                        colorTag: tab.profile.colorTag,
                        showColorBar: showTabColorBars,
                        isSelected: tab.id == tabManager.selectedTabID,
                        onSelect: { tabManager.select(tab) },
                        onClose: { tabManager.closeTab(tab) }
                    )
                }
            }
        }
        .background(.bar)
        .frame(height: 36)
    }
}

private struct TabButton: View {
    var title: String
    var subtitle: String
    var phase: TerminalTabItem.Phase
    var colorTag: String?
    var showColorBar: Bool
    var isSelected: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                phaseDot
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: 120, alignment: .leading)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tabBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            Rectangle()
                .frame(height: isSelected ? 3 : 2)
                .foregroundStyle(tabAccent)
                .opacity(showColorBar || isSelected ? 1 : 0)
        }
    }

    private var tabAccent: Color {
        ConnectionColor.color(for: colorTag) ?? .accentColor
    }

    private var tabBackground: Color {
        isSelected ? tabAccent.opacity(0.14) : .clear
    }

    @ViewBuilder
    private var phaseDot: some View {
        let color: Color = switch phase {
        case .idle:             .clear
        case .starting:         .yellow
        case .running:          .green
        case .failed:           .red
        }
        Circle().fill(color).frame(width: 6, height: 6)
    }
}
