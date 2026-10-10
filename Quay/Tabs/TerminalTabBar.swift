import AppKit
import SwiftUI

/// Horizontal tab strip reading directly from `TerminalTabManager`.
/// No reducer round-trip — high-frequency updates (title changes, phase
/// transitions) propagate via @Observable without going through TCA.
struct TerminalTabBar: View {
    var tabManager: TerminalTabManager
    var onEditConnection: (ConnectionProfile) -> Void = { _ in }
    var onOpenSFTP: (TerminalTabItem) -> Void = { _ in }
    var onTabSelected: () -> Void = {}
    @AppStorage(AppDefaultsKeys.showTabColorBars) private var showTabColorBars = true

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(tabManager.tabs) { tab in
                    TabButton(
                        title: tab.displayTitle,
                        phase: tab.phase,
                        transportIsLive: tab.transportIsLive,
                        iconName: tab.profile.iconName,
                        colorTag: tab.profile.colorTag,
                        showColorBar: showTabColorBars,
                        isSelected: tab.id == tabManager.selectedTabID,
                        onSelect: { tabManager.select(tab); onTabSelected() },
                        onEdit: { onEditConnection(tab.profile) },
                        onOpenSFTP: { onOpenSFTP(tab) },
                        onDisconnect: { tabManager.disconnectTab(tab) },
                        onReconnect: { tabManager.reconnectTab(tab) },
                        onClose: { tabManager.requestClose(tab) },
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

    private func moveDroppedTab(items: [String], before destinationID: UUID?) -> Bool {
        guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
        tabManager.moveTab(id: id, before: destinationID)
        return true
    }

}

private struct TabButton: View {
    var title: String
    var phase: TerminalTabItem.Phase
    var transportIsLive: Bool
    var iconName: String?
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
                    Image(systemName: ConnectionIcon.systemName(for: iconName))
                        .imageScale(.small)
                        .foregroundStyle(tabAccent)
                        .frame(width: 14)
                    titleStack
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isIdle ? "\(title), idle" : title)
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
        // A plain colour background extends into the safe area by default,
        // which under the hidden title bar tints the strip above the tab.
        .background(tabBackground, ignoresSafeAreaEdges: [])
        .contextMenu {
            Button(action: onReconnect) {
                Label("Reconnect Tab", systemImage: "arrow.clockwise.circle")
            }
            .disabled(!phase.isReconnectable)

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

    private var titleStack: some View {
        Text(title)
            .font(.system(size: 12, weight: isSelected ? .medium : .regular))
            .lineLimit(1)
            .frame(minWidth: 56, maxWidth: 220, alignment: .leading)
    }

    private var tabAccent: Color {
        ConnectionColor.color(for: colorTag) ?? .accentColor
    }

    private var tabBackground: Color {
        isSelected ? tabAccent.opacity(0.14) : .clear
    }

    private var canDisconnect: Bool {
        // Disconnect is also how the user calls off a retry cycle.
        if case .waitingToRetry = phase { return true }
        return phase.hasLiveSession
    }

    /// A running session whose client holds no connection — lftp at an idle
    /// prompt — is still running, so the dot stays green but dims rather than
    /// claiming a transport that isn't there.
    private var isIdle: Bool { phase == .running && !transportIsLive }

    @ViewBuilder
    private var phaseDot: some View {
        let color: Color = switch phase {
        case .idle:             .clear
        case .starting,
             .reconnecting,
             .waitingToRetry:   .yellow
        case .running:          .green
        case .disconnected,
             .failed:           .red
        }
        Circle()
            .fill(color)
            .opacity(isIdle ? 0.4 : 1)
            .frame(width: 6, height: 6)
            .help(isIdle ? "Connected, idle — no live transport" : "")
    }
}

