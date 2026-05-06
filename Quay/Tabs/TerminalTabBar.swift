import AppKit
import SwiftUI

/// Horizontal tab strip reading directly from `TerminalTabManager`.
/// No reducer round-trip — high-frequency updates (title changes, phase
/// transitions) propagate via @Observable without going through TCA.
struct TerminalTabBar: View {
    var tabManager: TerminalTabManager
    var onEditConnection: (ConnectionProfile) -> Void = { _ in }
    var onOpenSFTP: (TerminalTabItem) -> Void = { _ in }
    @AppStorage(AppDefaultsKeys.showTabColorBars) private var showTabColorBars = true
    @AppStorage(AppDefaultsKeys.confirmCloseActiveSessions) private var confirmCloseActiveSessions = true

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
                        onEdit: { onEditConnection(tab.profile) },
                        onOpenSFTP: { onOpenSFTP(tab) },
                        onDisconnect: { tabManager.disconnectTab(tab) },
                        onReconnect: { tabManager.reconnectTab(tab) },
                        onClose: { requestClose(tab) },
                        onContextClose: { tabManager.closeTab(tab) }
                    )
                    .draggable(tab.id.uuidString) {
                        Text(tab.displayTitle)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.bar, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .dropDestination(for: String.self) { items, _ in
                        moveDroppedTab(items: items, before: tab.id)
                    }
                }
                Color.clear
                    .frame(width: 24)
                    .dropDestination(for: String.self) { items, _ in
                        moveDroppedTab(items: items, before: nil)
                    }
            }
        }
        .background(.bar)
        .frame(height: 36)
    }

    private func requestClose(_ tab: TerminalTabItem) {
        if !TerminalTabManager.shouldConfirmClose(
            phase: tab.phase,
            confirmActiveSessions: confirmCloseActiveSessions
        ) {
            tabManager.closeTab(tab)
            return
        }

        if confirmClosingTab(tab) {
            tabManager.closeTab(tab)
        }
    }

    private func moveDroppedTab(items: [String], before destinationID: UUID?) -> Bool {
        guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
        tabManager.moveTab(id: id, before: destinationID)
        return true
    }

    private func confirmClosingTab(_ tab: TerminalTabItem) -> Bool {
        NSAlert.confirmation(
            title: "Close Active Tab?",
            message: "\"\(tab.displayTitle)\" is still active. Closing the tab will disconnect this session.",
            confirmTitle: "Close Tab"
        )
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
    var onEdit: () -> Void
    var onOpenSFTP: () -> Void
    var onDisconnect: () -> Void
    var onReconnect: () -> Void
    var onClose: () -> Void
    var onContextClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    phaseDot
                    titleStack
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityTitle)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 26)
            .contentShape(Rectangle())
            .accessibilityLabel("Close Tab")
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .padding(.vertical, 5)
        .background(tabBackground)
        .contextMenu {
            Button(action: onReconnect) {
                Label("Reconnect", systemImage: "arrow.clockwise.circle")
            }

            Button(action: onDisconnect) {
                Label("Disconnect", systemImage: "bolt.horizontal.circle")
            }
            .disabled(!canDisconnect)

            Button(action: onOpenSFTP) {
                Label("Open SFTP", systemImage: "arrow.up.arrow.down")
            }

            Divider()

            Button(action: onEdit) {
                Label("Edit…", systemImage: "pencil")
            }

            Divider()

            Button(action: onContextClose) {
                Label("Close Tab", systemImage: "xmark.circle")
            }
        }
        .overlay(alignment: .top) {
            Rectangle()
                .frame(height: isSelected ? 3 : 2)
                .foregroundStyle(tabAccent)
                .opacity(showColorBar || isSelected ? 1 : 0)
        }
    }

    private var accessibilityTitle: String {
        subtitle.isEmpty ? title : "\(title), \(subtitle)"
    }

    private var titleStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: 56, maxWidth: 220, alignment: .leading)
    }

    private var tabAccent: Color {
        ConnectionColor.color(for: colorTag) ?? .accentColor
    }

    private var tabBackground: Color {
        isSelected ? tabAccent.opacity(0.14) : .clear
    }

    private var canDisconnect: Bool {
        switch phase {
        case .running, .starting:
            return true
        case .idle, .disconnected, .failed:
            return false
        }
    }

    @ViewBuilder
    private var phaseDot: some View {
        let color: Color = switch phase {
        case .idle:             .clear
        case .starting:         .yellow
        case .running:          .green
        case .disconnected,
             .failed:           .red
        }
        Circle().fill(color).frame(width: 6, height: 6)
    }
}

