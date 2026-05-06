import AppKit

enum AppearanceIconCatalog {
    struct Symbol: Identifiable, Hashable {
        let id: String
        let label: String
    }

    struct Section: Identifiable, Hashable {
        let id: String
        let title: String
        let symbols: [Symbol]
    }

    static let sections: [Section] = [
        .init(id: "servers", title: "Servers", symbols: [
            .init(id: "terminal.fill", label: "Terminal"),
            .init(id: "server.rack", label: "Server Rack"),
            .init(id: "cpu.fill", label: "CPU"),
            .init(id: "memorychip", label: "Memory"),
            .init(id: "externaldrive.connected.to.line.below", label: "Connected Drive"),
            .init(id: "desktopcomputer", label: "Desktop"),
            .init(id: "laptopcomputer", label: "Laptop"),
            .init(id: "display", label: "Display"),
            .init(id: "macpro.gen3.fill", label: "Mac Pro"),
            .init(id: "macmini.fill", label: "Mac Mini"),
            .init(id: "apple.terminal.fill", label: "Apple Terminal"),
            .init(id: "xserve", label: "Xserve"),
        ]),
        .init(id: "network", title: "Network", symbols: [
            .init(id: "network", label: "Network"),
            .init(id: "globe", label: "Globe"),
            .init(id: "globe.americas.fill", label: "Americas"),
            .init(id: "globe.europe.africa.fill", label: "Europe"),
            .init(id: "globe.asia.australia.fill", label: "Asia Pacific"),
            .init(id: "wifi", label: "Wi-Fi"),
            .init(id: "wifi.router.fill", label: "Router"),
            .init(id: "antenna.radiowaves.left.and.right", label: "Antenna"),
            .init(id: "dot.radiowaves.left.and.right", label: "Wireless"),
            .init(id: "link", label: "Link"),
            .init(id: "arrow.left.arrow.right", label: "Transfer"),
            .init(id: "point.3.connected.trianglepath.dotted", label: "Connections"),
        ]),
        .init(id: "cloud", title: "Cloud", symbols: [
            .init(id: "cloud.fill", label: "Cloud"),
            .init(id: "cloud.bolt.fill", label: "Cloud Lightning"),
            .init(id: "cloud.rain.fill", label: "Cloud Rain"),
            .init(id: "icloud.fill", label: "iCloud"),
            .init(id: "icloud.and.arrow.up.fill", label: "Upload"),
            .init(id: "icloud.and.arrow.down.fill", label: "Download"),
            .init(id: "arrow.triangle.2.circlepath.icloud.fill", label: "iCloud Sync"),
            .init(id: "cylinder.fill", label: "Database"),
        ]),
        .init(id: "security", title: "Security", symbols: [
            .init(id: "lock.fill", label: "Lock"),
            .init(id: "lock.shield.fill", label: "Secure"),
            .init(id: "lock.open.fill", label: "Unlocked"),
            .init(id: "key.fill", label: "Key"),
            .init(id: "key.horizontal.fill", label: "API Key"),
            .init(id: "shield.fill", label: "Shield"),
            .init(id: "shield.lefthalf.filled", label: "Half Shield"),
            .init(id: "checkmark.shield.fill", label: "Verified"),
            .init(id: "xmark.shield.fill", label: "Blocked"),
            .init(id: "eye.fill", label: "Monitor"),
            .init(id: "eye.slash.fill", label: "Hidden"),
            .init(id: "person.badge.key.fill", label: "User Auth"),
        ]),
        .init(id: "storage", title: "Storage", symbols: [
            .init(id: "internaldrive.fill", label: "Internal Drive"),
            .init(id: "externaldrive.fill", label: "External Drive"),
            .init(id: "externaldrive.badge.checkmark", label: "Verified Drive"),
            .init(id: "externaldrive.badge.timemachine", label: "Time Machine"),
            .init(id: "opticaldiscdrive.fill", label: "Optical Drive"),
            .init(id: "tray.full.fill", label: "Tray Full"),
            .init(id: "tray.2.fill", label: "Multi Tray"),
            .init(id: "archivebox.fill", label: "Archive"),
            .init(id: "cylinder.split.1x2.fill", label: "Split Storage"),
            .init(id: "sdcard.fill", label: "SD Card"),
        ]),
        .init(id: "containers", title: "Containers", symbols: [
            .init(id: "shippingbox.fill", label: "Container"),
            .init(id: "shippingbox.and.arrow.backward.fill", label: "Pull Container"),
            .init(id: "cube.fill", label: "Cube"),
            .init(id: "square.stack.3d.up.fill", label: "Stack"),
            .init(id: "square.3.layers.3d", label: "Layers"),
            .init(id: "square.grid.3x3.fill", label: "Grid"),
            .init(id: "circle.grid.3x3.fill", label: "Dot Grid"),
            .init(id: "hexagon.fill", label: "Hexagon"),
        ]),
        .init(id: "devices", title: "Devices", symbols: [
            .init(id: "iphone", label: "iPhone"),
            .init(id: "ipad", label: "iPad"),
            .init(id: "printer.fill", label: "Printer"),
            .init(id: "scanner.fill", label: "Scanner"),
            .init(id: "keyboard.fill", label: "Keyboard"),
            .init(id: "applewatch", label: "Apple Watch"),
            .init(id: "homepod.fill", label: "HomePod"),
            .init(id: "airpods", label: "AirPods"),
            .init(id: "tv.fill", label: "TV"),
            .init(id: "speaker.fill", label: "Speaker"),
        ]),
        .init(id: "locations", title: "Locations", symbols: [
            .init(id: "house.fill", label: "Home"),
            .init(id: "building.fill", label: "Building"),
            .init(id: "building.2.fill", label: "Office"),
            .init(id: "building.columns.fill", label: "Institution"),
            .init(id: "mappin.and.ellipse", label: "Location Pin"),
            .init(id: "mappin", label: "Pin"),
            .init(id: "map.fill", label: "Map"),
            .init(id: "location.fill", label: "Location"),
            .init(id: "signpost.right.fill", label: "Signpost"),
            .init(id: "person.3.fill", label: "Team"),
        ]),
        .init(id: "tools", title: "Tools", symbols: [
            .init(id: "hammer.fill", label: "Hammer"),
            .init(id: "wrench.fill", label: "Wrench"),
            .init(id: "wrench.and.screwdriver.fill", label: "Tools"),
            .init(id: "screwdriver.fill", label: "Screwdriver"),
            .init(id: "gearshape.fill", label: "Gear"),
            .init(id: "gearshape.2.fill", label: "Gears"),
            .init(id: "slider.horizontal.3", label: "Sliders"),
            .init(id: "command", label: "Command"),
            .init(id: "play.fill", label: "Run"),
            .init(id: "wand.and.stars", label: "Magic"),
            .init(id: "paintbrush.fill", label: "Paint"),
            .init(id: "swift", label: "Swift"),
        ]),
        .init(id: "status", title: "Status", symbols: [
            .init(id: "bolt.fill", label: "Fast"),
            .init(id: "flag.fill", label: "Flag"),
            .init(id: "flame.fill", label: "Flame"),
            .init(id: "star.fill", label: "Star"),
            .init(id: "checkmark.circle.fill", label: "Done"),
            .init(id: "xmark.circle.fill", label: "Failed"),
            .init(id: "exclamationmark.triangle.fill", label: "Warning"),
            .init(id: "bell.fill", label: "Alert"),
            .init(id: "bell.badge.fill", label: "Notification"),
            .init(id: "pin.fill", label: "Pinned"),
            .init(id: "tag.fill", label: "Tag"),
            .init(id: "bookmark.fill", label: "Bookmark"),
        ]),
        .init(id: "files", title: "Files", symbols: [
            .init(id: "folder.fill", label: "Folder"),
            .init(id: "folder.fill.badge.gearshape", label: "Config Folder"),
            .init(id: "folder.fill.badge.person.crop", label: "User Folder"),
            .init(id: "doc.fill", label: "Document"),
            .init(id: "doc.text.fill", label: "Text File"),
            .init(id: "doc.zipper", label: "Archive"),
            .init(id: "text.alignleft", label: "Text"),
            .init(id: "chevron.left.forwardslash.chevron.right", label: "Code"),
            .init(id: "curlybraces", label: "JSON"),
            .init(id: "terminal", label: "Terminal"),
        ]),
        .init(id: "general", title: "General", symbols: [
            .init(id: "circle.fill", label: "Circle"),
            .init(id: "square.fill", label: "Square"),
            .init(id: "triangle.fill", label: "Triangle"),
            .init(id: "diamond.fill", label: "Diamond"),
            .init(id: "heart.fill", label: "Heart"),
            .init(id: "sparkles", label: "Sparkles"),
            .init(id: "infinity", label: "Infinity"),
            .init(id: "circle.dashed", label: "Dashed"),
            .init(id: "person.fill", label: "Person"),
            .init(id: "person.2.fill", label: "People"),
        ]),
    ]

    static let allSymbols: [Symbol] = sections.flatMap(\.symbols)

    static func search(_ query: String) -> [Section] {
        guard !query.isEmpty else { return sections }
        let lower = query.lowercased()
        return sections.compactMap { section in
            let matches = section.symbols.filter {
                $0.id.lowercased().contains(lower) || $0.label.lowercased().contains(lower)
            }
            return matches.isEmpty ? nil : Section(id: section.id, title: section.title, symbols: matches)
        }
    }

    static func validate(custom name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }
}
