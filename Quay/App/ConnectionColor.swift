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

enum ConnectionIcon {
    struct Option: Identifiable, Equatable {
        let id: String
        let label: String
    }

    static let fallback = "terminal.fill"

    static let options: [Option] = [
        Option(id: "terminal.fill", label: "Terminal"),
        Option(id: "server.rack", label: "Server"),
        Option(id: "network", label: "Network"),
        Option(id: "globe", label: "Globe"),
        Option(id: "cloud.fill", label: "Cloud"),
        Option(id: "lock.shield.fill", label: "Secure"),
        Option(id: "externaldrive.connected.to.line.below", label: "Storage"),
        Option(id: "cpu.fill", label: "Compute"),
        Option(id: "shippingbox.fill", label: "Container"),
        Option(id: "house.fill", label: "Home"),
        Option(id: "building.2.fill", label: "Office"),
        Option(id: "bolt.fill", label: "Fast")
    ]

    static var allNames: [String] {
        options.map(\.id)
    }

    static func systemName(for iconName: String?) -> String {
        guard let iconName, !iconName.isEmpty else { return fallback }
        return iconName
    }

    static func isKnown(_ iconName: String?) -> Bool {
        guard let iconName else { return false }
        return options.contains { $0.id == iconName }
    }
}
