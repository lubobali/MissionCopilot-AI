import Testing
@testable import MissionCopilot

struct ClassificationTests {
    @Test func newNotesAreOfficialUseOnlyByDefault() {
        let note = FieldNote(text: "Met the deputy minister")

        #expect(note.classification == .officialUseOnly)
    }

    @Test func officialUseOnlyIsNeverPublic() {
        #expect(Classification.officialUseOnly.isPublic == false)
        #expect(Classification.public.isPublic == true)
    }
}
