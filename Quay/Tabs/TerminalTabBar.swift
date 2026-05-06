import SwiftUI
import UniformTypeIdentifiers

/// Horizontal tab strip reading directly from `TerminalTabManager`.
/// No reducer round-trip — high-frequency updates (title changes, phase
/// transitions) propagate via @Observable without going through TCA.
struct TerminalTabBar: View {
    var tabManager: TerminalTabManager
    var onEditConnection: (ConnectionProfile) -> Void = { _ in }
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
                        onEdit: { onEditConnection(tab.profile) },
                        onDisconnect: { tabManager.disconnectTab(tab) },
                        onReconnect: { tabManager.reconnectTab(tab) },
                        onClose: { tabManager.closeTab(tab) }
                    )
                    .onDrag {
                        NSItemProvider(object: tab.id.uuidString as NSString)
                    }
                    .onDrop(
                        of: [.plainText],
                        delegate: TabDropDelegate(
                            tabManager: tabManager,
                            destinationID: tab.id
                        )
                    )
                }
                Color.clear
                    .frame(width: 24)
                    .onDrop(
                        of: [.plainText],
                        delegate: TabDropDelegate(
                            tabManager: tabManager,
                            destinationID: nil
                        )
                    )
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
    var onEdit: () -> Void
    var onDisconnect: () -> Void
    var onReconnect: () -> Void
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
                .frame(minWidth: 56, maxWidth: 220, alignment: .leading)
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
        .contextMenu {
            Button(action: onEdit) {
                Label("Edit…", systemImage: "pencil")
            }

            Button(action: onDisconnect) {
                Label("Disconnect", systemImage: "bolt.horizontal.circle")
            }
            .disabled(!canDisconnect)

            Button(action: onReconnect) {
                Label("Reconnect", systemImage: "arrow.clockwise.circle")
            }
        }
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

private struct TabDropDelegate: DropDelegate {
    let tabManager: TerminalTabManager
    let destinationID: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.plainText.identifier])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        moveDroppedTab(info: info)
    }

    func performDrop(info: DropInfo) -> Bool {
        moveDroppedTab(info: info)
    }

    @discardableResult
    private func moveDroppedTab(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.plainText.identifier]).first else {
            return false
        }

        provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let rawID = value as? NSString,
                  let id = UUID(uuidString: String(rawID))
            else { return }

            Task { @MainActor in
                tabManager.moveTab(id: id, before: destinationID)
            }
        }
        return true
    }
}
