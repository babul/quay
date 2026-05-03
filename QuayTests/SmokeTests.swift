import Testing
@testable import Quay

@Suite("Smoke")
struct SmokeTests {
    @Test("App target compiles + tests run")
    func appCompiles() {
        #expect(Bool(true))
    }
}
