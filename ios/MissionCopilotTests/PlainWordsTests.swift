import Foundation
import Testing
@testable import MissionCopilot

/// Plain words everywhere (#154), found in the Phase 6 proof: a source card said "Status: notMet", a red flag's
/// "Computed from" showed raw record paths, and "What's done?" listed the bridge as seen done with no word that
/// the bank's records say it is not started.
struct PlainWordsTests {
    static let sources = MissionSources.build(SourceInputs(packFiles: PackSectionsTests.files))

    static func card(_ id: String) throws -> SourceCardWords {
        SourceWords.card(try #require(sources.first { $0.id == id }))
    }

    @Test func sourceCardsSayStatusesInPlainWords() throws {
        let milestone = try Self.card("pack:sections/milestones.json#/milestones/2")
        let action = try Self.card("pack:sections/agreed-actions.json#/actions/0")

        #expect(milestone.lines.contains("Status: Not met"), "\(milestone.lines)")
        #expect(action.lines.contains("Status: Not started"), "\(action.lines)")
        #expect(!(milestone.lines + action.lines).joined().contains("notMet"))
    }

    @Test func computedFromNamesTheRecordNotItsPath() throws {
        let words = RedFlagWords(rules: RedFlagEngineTests.rules, language: "en",
                                 recordNames: RedFlagWords.recordNames(from: PackSectionsTests.files))
        let due = PackCitation(path: "sections/milestones.json", sha256: "x", pointer: "/milestones/2/dueDate")
        let value = PackCitation(path: "sections/contracts.json", sha256: "x", pointer: "/contracts/0/contractValue")
        let contract = try Self.card("pack:sections/contracts.json#/contracts/0").title

        #expect(words.input(.pack(due), mission: "m") == "Milestone · Section 3 bridge complete · due date")
        #expect(words.input(.pack(value), mission: "m") == "\(contract) · contract value")
        #expect(words.input(.pack(PackCitation(path: "sections/milestones.json", sha256: "x",
                                               pointer: "/milestones/2")), mission: "m")
                == "Milestone · Section 3 bridge complete")
    }

    /// Without the pack's names, a path is still said in words, never as a pointer.
    @Test func withoutTheNamesAPathIsStillWords() {
        let words = RedFlagWordsTests.english
        let citation = PackCitation(path: "sections/contracts.json", sha256: "ab",
                                    pointer: "/contracts/0/payments/5/amount")

        #expect(words.input(.pack(citation), mission: "m") == "Contract 1 · payment 6 · amount")
    }

    @Test func doneSaysWhenTheBankDisagrees() throws {
        for (question, says) in [("What's done?", "The bank's records say not started."),
                                 ("Qu'est-ce qui est fait ?", "Selon les registres de la banque : pas commencé.")] {
            let lines = try #require(CodeAnswersTests.answers.direct(question), "\(question)")
            let walked = try #require(lines.first { $0.sources.contains("walk:action-53f6e638bcf6") }, "\(question)")

            #expect(walked.text.hasSuffix(says), "\(walked.text)")
            #expect(walked.sources.contains(CodeAnswersTests.action), "\(question)")
        }
    }

    /// A walk item the bank agrees is done gets no such words.
    @Test func noDisagreementWhenTheBankAgrees() throws {
        let walk = [WordedLine(key: "action-x", title: "Agreed action: Clear the drains", text: "Seen: done.")]
        let done = MissionSource(id: "pack:sections/agreed-actions.json#/actions/9", kind: .pack,
                                 title: "Agreed Actions › actions 10",
                                 text: "action: Clear the drains\ndeadline: 2026-05-01\nresponsible: Contractor\n"
                                     + "status: Completed",
                                 origin: .walk(question: "x"))
        let answers = CodeAnswers(sources: MissionSources.build(SourceInputs(packFiles: PackSectionsTests.files,
                                                                             walk: walk)) + [done])

        let lines = try #require(answers.direct("What's done?"))
        let walked = try #require(lines.first { $0.sources.contains("walk:action-x") })

        #expect(!walked.text.contains("bank"), "\(walked.text)")
        #expect(walked.sources == ["walk:action-x"])
    }
}
