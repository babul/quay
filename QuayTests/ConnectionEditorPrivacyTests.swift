import Testing
@testable import Quay

@Suite("Connection editor privacy")
struct ConnectionEditorPrivacyTests {
    @Test("connection target fields are sensitive")
    func connectionTargetFieldsAreSensitive() {
        for field in ConnectionEditorPrivacy.Field.allCases {
            #expect(ConnectionEditorPrivacy.isSensitive(field))
        }
    }
}
