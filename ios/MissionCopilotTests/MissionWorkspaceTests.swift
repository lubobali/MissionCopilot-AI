import SwiftUI
import Testing
@testable import MissionCopilot

/// The mission workspace (#125): each "Before you go" state has its own icon and words, so color is
/// never the only signal (WCAG 1.4.1), like the pack states.
struct MissionWorkspaceTests {
    @Test func everyStateHasItsOwnIconAndItsOwnWords() {
        let states: [BeforeYouGo.State] = [.ready, .working, .toDo, .cannot]

        #expect(Set(states.map(\.icon)).count == states.count)
        #expect(Set(states.map(\.words)).count == states.count)
        #expect(states.map(\.words) == ["Ready", "Getting ready", "To do", "Not available"])
    }

    @Test func readyIsTheSuccessColorAndProblemsAreNot() {
        #expect(BeforeYouGo.State.ready.color == .success)
        #expect(BeforeYouGo.State.toDo.color == .warning)
        #expect(BeforeYouGo.State.cannot.color == .danger)
        #expect(BeforeYouGo.State.working.color == .accent)
    }

    @Test func aMissionLinkCarriesOnlyTheMissionsId() {
        // The workspace reads the live row by id, so a download's progress shows while it is open.
        #expect(MissionLink(id: "a") == MissionLink(id: "a"))
        #expect(MissionLink(id: "a") != MissionLink(id: "b"))
    }
}
