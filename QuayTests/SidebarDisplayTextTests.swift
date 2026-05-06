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
