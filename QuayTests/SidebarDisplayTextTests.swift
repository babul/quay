import Foundation
import Testing
@testable import Quay

@Suite("Sidebar display text")
struct SidebarDisplayTextTests {
    @Test("redacts IPv4 connection subtitle")
    func redactsIPv4ConnectionSubtitle() {
        let profile = ConnectionProfile(name: "jumpbox", hostname: "5.161.194.242")

        #expect(SidebarDisplayText.connectionSubtitle(for: profile) == nil)
    }

    @Test("redacts IPv6 connection subtitle")
    func redactsIPv6ConnectionSubtitle() {
        let profile = ConnectionProfile(name: "jumpbox", hostname: "2001:db8::1")

        #expect(SidebarDisplayText.connectionSubtitle(for: profile) == nil)
        #expect(SidebarDisplayText.redactedHost("[fe80::1%en0]") == nil)
    }

    @Test("hides non-IP connection subtitle")
    func hidesNonIPConnectionSubtitle() {
        let profile = ConnectionProfile(name: "prod", hostname: "prod.example.com")

        #expect(SidebarDisplayText.connectionSubtitle(for: profile) == nil)
    }

    @Test("redacts literal IP ssh config aliases")
    func redactsLiteralIPSSHConfigAliases() {
        let profile = ConnectionProfile(
            name: "jumpbox",
            hostname: "ignored.example.com",
            authMethod: .sshConfigAlias,
            sshConfigAlias: "5.161.194.242"
        )
        let host = DiscoveredSSHHost(alias: "5.161.194.242", sourceFile: "/Users/me/.ssh/config")

        #expect(SidebarDisplayText.connectionSubtitle(for: profile) == nil)
        #expect(SidebarDisplayText.sshConfigHostTitle(for: host) == "SSH Config Host")
    }
}

@Suite("SidebarOrdering")
struct SidebarOrderingTests {
    @Test("folders sort by localized name before sort index")
    func foldersSortByNameBeforeSortIndex() {
        let beta = Folder(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Beta", sortIndex: 0)
        let alpha = Folder(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Alpha", sortIndex: 99)
        let prod2 = Folder(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "Prod 2", sortIndex: 2)
        let prod10 = Folder(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, name: "Prod 10", sortIndex: 1)

        let sorted = SidebarOrdering.foldersByName([beta, prod10, prod2, alpha])

        #expect(sorted.map(\.name) == ["Alpha", "Beta", "Prod 2", "Prod 10"])
    }

    @Test("connections sort by name before sort index")
    func connectionsSortByNameBeforeSortIndex() {
        let db = ConnectionProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            name: "db",
            hostname: "db.example.com",
            sortIndex: 0
        )
        let app = ConnectionProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            name: "app",
            hostname: "app.example.com",
            sortIndex: 99
        )
        let web2 = ConnectionProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
            name: "web 2",
            hostname: "web2.example.com",
            sortIndex: 2
        )
        let web10 = ConnectionProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!,
            name: "web 10",
            hostname: "web10.example.com",
            sortIndex: 1
        )

        let sorted = SidebarOrdering.connectionsByName([db, web10, web2, app])

        #expect(sorted.map(\.name) == ["app", "db", "web 2", "web 10"])
    }

    @Test("equal names fall back to sort index then id")
    func equalNamesUseStableFallbacks() {
        let later = ConnectionProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!,
            name: "prod",
            hostname: "later.example.com",
            sortIndex: 1
        )
        let second = ConnectionProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000024")!,
            name: "prod",
            hostname: "second.example.com",
            sortIndex: 0
        )
        let first = ConnectionProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000023")!,
            name: "prod",
            hostname: "first.example.com",
            sortIndex: 0
        )

        let sorted = SidebarOrdering.connectionsByName([later, second, first])

        #expect(sorted.map(\.hostname) == ["first.example.com", "second.example.com", "later.example.com"])
    }
}
