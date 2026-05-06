import SwiftUI

enum ConnectionColor {
    struct Tag: Identifiable, Equatable {
        let id: String
        let label: String
        let color: Color
    }

    static let tags: [Tag] = [
        Tag(id: "red", label: "Red", color: Color(red: 0.88, green: 0.20, blue: 0.24)),
        Tag(id: "orange", label: "Orange", color: Color(red: 0.90, green: 0.43, blue: 0.12)),
        Tag(id: "yellow", label: "Yellow", color: Color(red: 0.82, green: 0.62, blue: 0.12)),
        Tag(id: "green", label: "Green", color: Color(red: 0.25, green: 0.62, blue: 0.33)),
        Tag(id: "blue", label: "Blue", color: Color(red: 0.20, green: 0.42, blue: 0.86)),
        Tag(id: "purple", label: "Purple", color: Color(red: 0.55, green: 0.34, blue: 0.82)),
        Tag(id: "gray", label: "Gray", color: Color(red: 0.45, green: 0.48, blue: 0.52))
    ]

    static var allTagIDs: [String] {
        tags.map(\.id)
    }

    static func tag(for id: String?) -> Tag? {
        guard let id else { return nil }
        return tags.first { $0.id == id }
    }

    static func color(for id: String?) -> Color? {
        tag(for: id)?.color
    }

    static func label(for id: String) -> String {
        tag(for: id)?.label ?? id
    }

    static func isKnown(_ id: String?) -> Bool {
        tag(for: id) != nil
    }
}

enum AppearanceIcon {
    struct Option: Identifiable, Equatable {
        let id: String
        let label: String
    }

    static var options: [Option] {
        AppearanceIconCatalog.allSymbols.map { Option(id: $0.id, label: $0.label) }
    }

    static var allNames: [String] {
        options.map(\.id)
    }

    static func systemName(for iconName: String?, fallback: String) -> String {
        guard let iconName, !iconName.isEmpty else { return fallback }
        return iconName
    }

    static func isKnown(_ iconName: String?) -> Bool {
        guard let iconName else { return false }
        return options.contains { $0.id == iconName }
    }
}

enum ConnectionIcon {
    static let fallback = "terminal.fill"

    static func systemName(for iconName: String?) -> String {
        AppearanceIcon.systemName(for: iconName, fallback: fallback)
    }

    static func isKnown(_ iconName: String?) -> Bool {
        AppearanceIcon.isKnown(iconName)
    }
}

enum FolderIcon {
    static let fallback = "folder"

    static func systemName(for iconName: String?) -> String {
        AppearanceIcon.systemName(for: iconName, fallback: fallback)
    }

    static func isKnown(_ iconName: String?) -> Bool {
        AppearanceIcon.isKnown(iconName)
    }
}

struct AppearanceIconPicker: View {
    let title: String
    let defaultSystemName: String
    let defaultHelp: String
    let accessibilityLabel: String
    @Binding var selection: String?

    @State private var presented = false

    var body: some View {
        LabeledContent(title) {
            Button {
                presented = true
            } label: {
                Image(systemName: selection ?? defaultSystemName)
                    .imageScale(.medium)
                    .frame(width: 24, height: 24)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.secondary.opacity(0.4), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help(AppearanceIconCatalog.allSymbols.first { $0.id == selection }?.label ?? defaultHelp)
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                AppearanceIconGrid(
                    selection: $selection,
                    defaultSystemName: defaultSystemName,
                    defaultHelp: defaultHelp
                )
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct AppearanceIconGrid: View {
    @Binding var selection: String?
    let defaultSystemName: String
    let defaultHelp: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private let columns = Array(repeating: GridItem(.fixed(36), spacing: 6), count: 6)

    private var visibleSections: [AppearanceIconCatalog.Section] {
        AppearanceIconCatalog.search(query)
    }

    private var customSymbol: AppearanceIconCatalog.Symbol? {
        guard !query.isEmpty, visibleSections.isEmpty,
              AppearanceIconCatalog.validate(custom: query) else { return nil }
        return AppearanceIconCatalog.Symbol(id: query, label: "Custom")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search symbols", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .focused($searchFocused)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12, pinnedViews: .sectionHeaders) {
                    defaultRow
                    if let custom = customSymbol {
                        sectionView(title: "Custom", symbols: [custom])
                    } else {
                        ForEach(visibleSections) { section in
                            sectionView(title: section.title, symbols: section.symbols)
                        }
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 320, height: 360)
        .onAppear { searchFocused = true }
    }

    private var defaultRow: some View {
        Button {
            selection = nil
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: defaultSystemName)
                    .frame(width: 24, height: 24)
                Text("Default")
                    .font(.subheadline)
                Spacer()
                if selection == nil {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .help(defaultHelp)
    }

    private func sectionView(title: String, symbols: [AppearanceIconCatalog.Symbol]) -> some View {
        Section {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(symbols) { symbol in
                    iconButton(symbol)
                }
            }
        } header: {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private func iconButton(_ symbol: AppearanceIconCatalog.Symbol) -> some View {
        Button {
            selection = symbol.id
            dismiss()
        } label: {
            ZStack {
                Image(systemName: symbol.id)
                    .imageScale(.medium)
                if selection == symbol.id {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(.primary, lineWidth: 1.5)
                        .frame(width: 26, height: 24)
                }
            }
        }
        .frame(width: 28, height: 28)
        .buttonStyle(.plain)
        .help(symbol.label)
    }
}
