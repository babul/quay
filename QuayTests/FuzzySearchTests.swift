import Testing
@testable import Quay

@Suite("FuzzySearch")
struct FuzzySearchTests {

    @Test("subsequence match: exact substring scores higher than scattered")
    func subsequenceVsExact() {
        let exact = FuzzySearch.score("prod", in: "prod-web-1")
        let scattered = FuzzySearch.score("prod", in: "p-staging-r-on-d-server")
        #expect(exact != nil)
        #expect(scattered != nil)
        #expect(exact! > scattered!)
    }

    @Test("missing characters return nil")
    func missingChars() {
        #expect(FuzzySearch.score("xyz", in: "abcdef") == nil)
    }

    @Test("empty query matches anything with score 0")
    func emptyQuery() {
        #expect(FuzzySearch.score("", in: "anything") == 0)
    }

    @Test("case-insensitive")
    func caseInsensitive() {
        #expect(FuzzySearch.matches("WEB", in: "web-1.example.com"))
        #expect(FuzzySearch.matches("web", in: "WEB-1.EXAMPLE.COM"))
    }

    @Test("rank sorts by score descending")
    func rankOrder() {
        let inputs = ["staging-db", "prod-web-1", "prod-web-2", "dev-app"]
        let ranked = FuzzySearch.rank(inputs, query: "prod") { [$0] }
        #expect(ranked.count == 2)
        #expect(ranked.allSatisfy { $0.contains("prod") })
    }

    @Test("rank can match hidden partial IP hostname")
    func rankCanMatchHiddenPartialIPHostname() {
        let profiles = [
            ConnectionProfile(name: "jumpbox", hostname: "5.161.194.242"),
            ConnectionProfile(name: "prod", hostname: "prod.example.com")
        ]

        let leadingPartial = FuzzySearch.rank(profiles, query: "5.16") { profile in
            [profile.name, profile.hostname]
        }
        let middlePartial = FuzzySearch.rank(profiles, query: "194") { profile in
            [profile.name, profile.hostname]
        }

        #expect(leadingPartial.map(\.name) == ["jumpbox"])
        #expect(middlePartial.map(\.name) == ["jumpbox"])
    }
}
