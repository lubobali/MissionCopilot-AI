import Foundation
import Testing
@testable import MissionCopilot

/// The red flags in words (#134, step 6.3.6): one sentence per result from its computed value, the
/// threshold, the rule and its source, and where every input came from, in English and French.
struct RedFlagWordsTests {
    static let english = RedFlagWords(rules: RedFlagEngineTests.rules, language: "en")
    static let french = RedFlagWords(rules: RedFlagEngineTests.rules, language: "fr")

    static func kandor() throws -> [RedFlagResult] {
        let contracts = try PackContracts.read(try PackFiguresTests.file(PackContracts.path))
        let milestones = try PackMilestones.read(try PackFiguresTests.file(PackMilestones.path))
        return RedFlagEngineTests.run(contracts: contracts, milestones: milestones)
    }

    @Test func theKandorSummaryCountsEachOutcome() throws {
        let results = try Self.kandor()

        #expect(Self.english.summary(results) == "2 flags · 2 clear · 2 not checked")
        #expect(Self.french.summary(results) == "2 alertes · 2 sans alerte · 2 non vérifiées")
        #expect(Self.english.summary(Array(results[1...1])) == "1 flag")
        #expect(Self.english.summary([]) == "None stored")
        #expect(Self.french.summary([]) == "Aucune enregistrée")
        #expect(Self.english.text(.finishedBefore)
                == "This walk was finished before this version of the app checked red flags, so none were stored.")
    }

    @Test func eachKandorResultIsOneSentenceFromItsNumbers() throws {
        let results = try Self.kandor()

        #expect(results.map(Self.english.sentence) == [
            "Paid 85% of the contract value.",
            "Milestone M3 is 41 days late and not met.",
            "Payments are 35 points ahead of the work built.",
            "No invoice reference or amount appears twice.",
            "Needs the invoiced and measured quantities, which come with the document scan.",
            "No photo taken yet."
        ])
        #expect(Self.french.sentence(results[1]) == "Le jalon M3 a 41 jours de retard et n'est pas atteint.")
        #expect(Self.french.sentence(results[2]) == "Les paiements ont 35 points d'avance sur les travaux réalisés.")
    }

    @Test func eachResultSaysItsRuleThresholdAndSource() throws {
        let results = try Self.kandor()

        #expect(Self.english.title(results[2]) == "Payments ahead of physical progress")
        #expect(Self.french.title(results[2]) == "Paiements en avance sur l'avancement physique")
        #expect(results.map(Self.english.threshold) == [
            "Flags above 100%", "Flags when more than 0 days late", "Flags above 20 points",
            "Flags when seen more than 1 time", "Flags above 100%", "Flags when seen more than 1 time"
        ])
        #expect(Self.english.source(results[0]) == "R068 v1 · Open Contracting red flags guide (2024)")
        #expect(Self.french.threshold(results[2]) == "Alerte au-dessus de 20 points")
    }

    @Test func everyInputSaysWhereItCameFrom() {
        let citation = PackCitation(path: "sections/contracts.json", sha256: "ab",
                                    pointer: "/contracts/0/contractValue")

        #expect(Self.english.input(.pack(citation), mission: "m") == "contracts.json · /contracts/0/contractValue")
        #expect(Self.english.input(.evidence(PhotoRef(mission: "m", seq: 3)), mission: "m")
                == "Photo 3, this mission")
        #expect(Self.english.input(.evidence(PhotoRef(mission: "x", seq: 1)), mission: "m")
                == "Photo 1, another mission on this phone")
        #expect(Self.french.input(.evidence(PhotoRef(mission: "m", seq: 3)), mission: "m") == "Photo 3, cette mission")
    }

    @Test func buildingAheadOfPaymentIsSaidTheOtherWayRound() throws {
        let result = RedFlagEngineTests.only("MC-01", RedFlagEngineTests.run(
            contracts: try RedFlagEngineTests.contracts(payments: [1_000], built: 64)))

        #expect(result.map(Self.english.sentence) == ["The work built is 90 points ahead of payments."])
    }

    @Test func aRepeatedInvoiceAPhotoAndASkippedMissionAreNamed() {
        let threshold = RedFlagRule.Threshold(value: 1, unit: .count)
        let invoice = RedFlagResult(rule: RuleRef(id: "MC-02", version: "1"), outcome: .flag, subject: "Invoice 6",
                                    computed: 2, threshold: threshold, inputs: [])
        var photo = RedFlagResult(rule: RuleRef(id: "MC-04", version: "1"), outcome: .flag, subject: "photo 3",
                                  computed: 2, threshold: threshold, inputs: [])
        photo.skippedMissions = 1

        #expect(Self.english.sentence(invoice) == "Invoice 6 appears 2 times.")
        #expect(Self.english.sentence(photo) == "Photo 3 appears 2 times on this phone.")
        #expect(Self.english.skipped(photo) == "1 shredded mission could not be read.")
        #expect(Self.french.skipped(photo) == "1 mission détruite n'a pas pu être lue.")
        #expect(Self.english.skipped(invoice) == nil)
    }

    @Test func everyReasonAndLabelHasBothLanguages() {
        for reason in RedFlagResult.NotChecked.allCases {
            #expect(!Self.english.reason(reason).isEmpty && Self.english.reason(reason) != Self.french.reason(reason))
        }
        for key in RedFlagWords.Key.allCases {
            #expect(!Self.english.text(key).isEmpty && Self.english.text(key) != Self.french.text(key), "\(key)")
        }
    }

    /// Found on the iPhone: a walk finished before red flags showed a green shield, which reads as all clear.
    @Test func onlyRealResultsLookClearOrFlagged() throws {
        let kandor = try Self.kandor()

        #expect(RedFlagsLook(results: kandor) == RedFlagsLook(icon: "flag.fill", role: .danger))
        #expect(RedFlagsLook(results: Array(kandor.prefix(1))) == RedFlagsLook(icon: "checkmark.shield.fill",
                                                                               role: .success))
        #expect(RedFlagsLook(results: []) == RedFlagsLook(icon: "minus.circle", role: .secondaryText))
    }
}
