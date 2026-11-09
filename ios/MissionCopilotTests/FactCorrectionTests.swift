import Foundation
import Testing
@testable import MissionCopilot

/// A correction must come from the page (#151). Found in the Phase 6 proof: the model invented three values
/// (1 km, 10000000 km, Completed), code locked Confirm, and the same values were typed back in Correct and saved.
/// Now a typed value is checked on the scanned pages like the model's, the rejected value is refused, the values
/// printed on the page are offered, and a value not on the page needs a second tap and stays "typed by you".
@MainActor
struct FactCorrectionTests {
    let mission = "kandor-roads"

    /// The model's three inventions from the iPhone (Nov 8).
    static let invented = ScanExtractionTests.answer
        .replacingOccurrences(of: #""kmCompleted":32"#, with: #""kmCompleted":1"#)
        .replacingOccurrences(of: #""kmTotal":64"#, with: #""kmTotal":10000000"#)
        .replacingOccurrences(of: #""bridgeStatus":"not_started""#, with: #""bridgeStatus":"completed""#)

    private func reviewed(_ answer: String = invented) async throws -> (FactReviewModel, MissionStore) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = MissionStore(store: try EncryptedStore.open(at: file, key: DataKey.random()),
                                 vault: SoftwareKeyVault())
        try store.create(mission: mission, title: "Kandor rural roads")
        let scan = try store.addScan([try ScanStoreTests.page(), try ScanStoreTests.page()], to: mission,
                                     signer: SoftwareEvidenceSigner())
        for (seq, reading) in zip(scan.pages, try FactGroundingTests.kandorPages()) {
            _ = try await store.readPage(seq, in: mission, read: { _ in reading })
        }
        let model = FactReviewModel(mission: mission, store: store,
                                    contracts: try InvoiceBankViewTests.kandor().contracts,
                                    model: FieldModel(engine: FieldModelTests.FakeEngine(answer: answer)))
        await model.read()
        return (model, store)
    }

    private func line(_ model: FactReviewModel, _ field: String) throws -> FactReviewModel.Line {
        try #require(model.lines.first { $0.field == field })
    }

    @Test func theValueThePageCheckRejectedCannotBeKept() async throws {
        let (model, _) = try await reviewed()

        for (field, typed) in [("kmCompleted", "1"), ("kmTotal", "10,000,000"), ("bridgeStatus", "Completed")] {
            #expect(!model.correct(field, to: typed), "\(field)")
            #expect(model.problem == FactReviewModel.rejectedWords, "\(field)")
            #expect(!model.correct(field, to: typed, anyway: true), "\(field): not even with a second tap")
            #expect(try line(model, field).decision == nil, "\(field)")
        }
        #expect(FactReviewModel.rejectedWords
                == "This is the value that was not found on the pages. Type the value printed on the page.")
    }

    @Test func aTypedValueOnThePageKeepsItsPageAndWords() async throws {
        let (model, store) = try await reviewed()

        #expect(model.correct("kmCompleted", to: "32"))
        #expect(try line(model, "kmCompleted").decision == "Corrected to 32 km, on page 2")
        #expect(model.problem == nil)

        for field in InvoiceFacts.fields.prefix(5) { model.confirm(field) }
        #expect(model.correct("kmTotal", to: "64"))
        #expect(model.correct("bridgeStatus", to: "not started"))
        model.save()

        let facts = try store.facts(in: mission)
        let road = try #require(facts.first { $0.name == "kmCompleted" })
        let pages = try #require(try store.scans(in: mission).first?.pages)
        #expect(road.value == "32" && road.rule == MissionStore.officerRule)
        #expect(road.sources.count == 1 && road.sources[0].seq == pages[1])
        let reading = try #require(try store.reading(of: pages[1], in: mission))
        #expect(FactGrounding.printed(try #require(road.sources[0].region), in: reading) == "32 of 64 km")
        #expect(facts.allSatisfy { !$0.typedNotOnPage })
    }

    @Test func aTypedValueNotOnThePageNeedsASecondTap() async throws {
        let (model, store) = try await reviewed()

        #expect(!model.correct("kmCompleted", to: "30"))
        #expect(model.problem == "30 km is not on the scanned pages. Check the page, or keep it anyway.")
        #expect(try line(model, "kmCompleted").notOnPage == "30")
        #expect(try line(model, "kmCompleted").decision == nil)

        #expect(model.correct("kmCompleted", to: "30", anyway: true))
        #expect(try line(model, "kmCompleted").decision == "Corrected to 30 km, not on the page")
        #expect(try line(model, "kmCompleted").notOnPage == nil)

        for field in InvoiceFacts.fields.prefix(5) { model.confirm(field) }
        #expect(model.correct("kmTotal", to: "64"))
        #expect(model.correct("bridgeStatus", to: "not started"))
        model.save()
        let road = try #require(try store.facts(in: mission).first { $0.name == "kmCompleted" })
        #expect(road.sources.allSatisfy { $0.region == nil })
        #expect(road.typedNotOnPage)
    }

    /// A second tap is for the value the officer typed, not for a later one.
    @Test func theSecondTapKeepsOnlyTheValueItWasAskedFor() async throws {
        let (model, _) = try await reviewed()

        #expect(!model.correct("kmCompleted", to: "29", anyway: true))  // never asked: no second tap to take
        #expect(try line(model, "kmCompleted").decision == nil)
        #expect(!model.correct("kmCompleted", to: "30"))
        #expect(!model.correct("kmCompleted", to: "31", anyway: true))  // asked for 30, not 31
        #expect(try line(model, "kmCompleted").notOnPage == "31")
        model.undo("kmCompleted")
        #expect(try line(model, "kmCompleted").notOnPage == nil)
    }

    @Test func thePageOffersTheValuesPrintedForEachFact() async throws {
        let (model, _) = try await reviewed()

        #expect(try line(model, "kmCompleted").choices.map(\.words) == ["32 km"])
        #expect(try line(model, "kmTotal").choices.map(\.words) == ["64 km"])
        #expect(try line(model, "bridgeStatus").choices.map(\.words) == ["Not started"])

        for field in ["kmCompleted", "kmTotal", "bridgeStatus"] {
            let choice = try #require(try line(model, field).choices.first)
            #expect(model.correct(field, to: choice.value), "\(field)")
            #expect(try line(model, field).decision?.hasSuffix(", on page 2") == true, "\(field)")
        }
    }

    /// The value the check rejected is never offered, and there are at most three.
    @Test func choicesNeverOfferTheRejectedValue() throws {
        let pages = [FactGroundingTests.page("Road built: 1 of 64 km. Road built: 2 of 64 km. Road built: 3 of 64 km. "
                                             + "Road built: 4 of 64 km. Road built: 5 of 64 km.")]

        let choices = FactReviewModel.choices("kmCompleted", rejected: "1", pages: pages)

        #expect(choices.map(\.value) == ["2", "3", "4"])
        #expect(FactReviewModel.maxChoices == 3)
        #expect(FactReviewModel.choices("invoiceNumber", rejected: nil,
                                        pages: try FactGroundingTests.kandorPages()).map(\.value) == ["14"])
        #expect(FactReviewModel.choices("invoiceDate", rejected: nil,
                                        pages: try FactGroundingTests.kandorPages()).map(\.words)
                == ["12 October 2026"])
    }

    /// Typed by hand when the assistant could not answer: still checked on the pages.
    @Test func handTypedFactsAreCheckedOnThePagesToo() async throws {
        let (model, store) = try await reviewed("not JSON")
        model.enterYourself()

        let typed = ["14", "2026-10-12", "480000", "8500000", "10000000", "32", "64", "not started"]
        for (field, value) in zip(InvoiceFacts.fields, typed) { #expect(model.correct(field, to: value), "\(field)") }
        model.save()

        let facts = try store.facts(in: mission)
        #expect(facts.count == 8)
        #expect(facts.allSatisfy { $0.rule == MissionStore.officerRule && $0.sources.first?.region != nil })
    }

    /// Ask and the red flags say whose word a fact is.
    @Test func aFactNotOnThePageIsCitedAsTypedByTheOfficer() {
        let typed = Fact(id: "t", name: "kmCompleted", value: "30", unit: "km", rule: MissionStore.officerRule,
                         classification: .officialUseOnly, sources: [FactSource(seq: 1, region: nil)])
        let printed = Fact(id: "p", name: "kmCompleted", value: "32", unit: "km", rule: MissionStore.officerRule,
                           classification: .officialUseOnly,
                           sources: [FactSource(seq: 1, region: "vision text 3+11")])
        let note = Fact(id: "n", name: "debrief.action", value: "{}", unit: nil, rule: MissionStore.officerRule,
                        classification: .officialUseOnly, sources: [FactSource(seq: 1, region: nil)])

        #expect(typed.typedNotOnPage && !printed.typedNotOnPage && !note.typedNotOnPage)
        #expect(AnswerLines.line(MissionSources.fact(typed)).text
                == "You typed this, it is not on the scanned page: Road built: 30 km.")
        #expect(AnswerLines.line(MissionSources.fact(printed)).text == "From your scanned invoice: Road built: 32 km.")
        let words = RedFlagWordsTests.english
        #expect(words.input(.fact(FactRef(id: "t", name: "kmCompleted", typed: true)), mission: mission)
                == "Scanned invoice · Road built (you typed it, not on the page)")
        #expect(words.input(.fact(FactRef(id: "p", name: "kmCompleted")), mission: mission)
                == "Scanned invoice · Road built")
        let invoice = InvoiceFacts.fields.map { field in
            field == "kmCompleted" ? typed
                : Fact(id: field, name: field, value: ["invoiceNumber": "14"][field] ?? "64", unit: nil,
                       rule: MissionStore.scanRule, classification: .officialUseOnly,
                       sources: [FactSource(seq: 1, region: "vision text 0+2")])
        }
        let invoices = ScannedInvoice.all(from: invoice)
        #expect(invoices.first?.facts["kmCompleted"]?.typed == true)
        #expect(invoices.first?.facts["kmTotal"]?.typed == nil)
    }
}
