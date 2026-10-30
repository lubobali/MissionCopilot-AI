import Testing
@testable import MissionCopilot

struct ClassificationTests {
    @Test func newNotesAreOfficialUseOnlyByDefault() {
        let note = FieldNote(text: "Met the deputy minister")

        #expect(note.classification == .officialUseOnly)
    }

    @Test func onlyPublicIsPublic() {
        #expect(Classification.strictlyConfidential.isPublic == false)
        #expect(Classification.officialUseOnly.isPublic == false)
        #expect(Classification.public.isPublic == true)
    }

    @Test func labelsMatchTheAPIContract() {
        // Same raw values as docs/api/openapi.yaml (Classification enum).
        #expect(Classification.allCases.map(\.rawValue) == ["strictly_confidential", "official_use_only", "public"])
    }

    @Test func strictestLabelWins() {
        #expect(Classification.strictest([.public, .officialUseOnly]) == .officialUseOnly)
        #expect(Classification.strictest([.officialUseOnly, .strictlyConfidential, .public]) == .strictlyConfidential)
        #expect(Classification.strictest([]) == .officialUseOnly)
    }
}
