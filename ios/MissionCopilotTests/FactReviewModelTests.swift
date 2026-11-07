import Foundation
import Testing
@testable import MissionCopilot

/// The review page's model (#138, step 6.5.11): the read pages not yet confirmed go through the extraction and
/// the checks; each fact shows its value, where it was printed and its problems; the officer confirms or
/// corrects every one, then saves. When the assistant cannot answer, the officer enters the facts.
@MainActor
struct FactReviewModelTests {
    let mission = "kandor-roads"

    /// A store with two scanned pages read as the Kandor invoice and report.
    private func store() async throws -> MissionStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = MissionStore(store: try EncryptedStore.open(at: file, key: DataKey.random()),
                                 vault: SoftwareKeyVault())
        try store.create(mission: mission, title: "Kandor rural roads")
        let scan = try store.addScan([try ScanStoreTests.page(), try ScanStoreTests.page()], to: mission,
                                     signer: SoftwareEvidenceSigner())
        for (seq, reading) in zip(scan.pages, try FactGroundingTests.kandorPages()) {
            _ = try await store.readPage(seq, in: mission, read: { _ in reading })
        }
        return store
    }

    private func model(_ store: MissionStore, answer: String = ScanExtractionTests.answer) throws -> FactReviewModel {
        FactReviewModel(mission: mission, store: store, contracts: try InvoiceBankViewTests.kandor().contracts,
                        model: FieldModel(engine: FieldModelTests.FakeEngine(answer: answer)))
    }

    @Test func theKandorPagesAreReadAndEveryFactPassesItsChecks() async throws {
        let model = try model(try await store())

        await model.read()

        #expect(model.stage == .review)
        #expect(model.lines.map(\.name) == InvoiceFacts.fields.map(InvoiceFacts.name))
        #expect(model.lines.map(\.value) == ["14", "12 October 2026", "USD 480,000", "USD 8,500,000",
                                             "USD 10,000,000", "32 km", "64 km", "Not started"])
        #expect(model.lines[2].found == "Page 1: “480,000”")
        #expect(model.lines[7].found == "Page 2: “bridge: not started”")
        #expect(model.lines.allSatisfy { $0.problems.isEmpty && $0.canConfirm })
        #expect(model.summary == "8 facts · 0 of 8 decided")
    }

    @Test func aFactWithAProblemShowsItsWordsAndOneNotPrintedCannotBeConfirmed() async throws {
        let answer = ScanExtractionTests.answer.replacingOccurrences(of: #""kmCompleted":32"#,
                                                                     with: #""kmCompleted":33"#)
        let model = try model(try await store(), answer: answer)

        await model.read()

        let road = model.lines[5]
        #expect(road.found == "Not found on the pages. Correct it to keep it.")
        #expect(road.problems.first == "Not found on the scanned pages.")
        #expect(!road.canConfirm)
        model.confirm("kmCompleted")  // a button cannot get round it either
        #expect(model.lines[5].decision == nil)
        #expect(model.summary == "8 facts · 1 to check · 0 of 8 decided")
    }

    @Test func theOfficerDecidesEachFactThenSavesThemAll() async throws {
        let store = try await store()
        let model = try model(store)
        await model.read()

        for field in InvoiceFacts.fields.dropLast() { model.confirm(field) }
        #expect(!model.canSave)
        #expect(model.correct("bridgeStatus", to: "in progress"))
        #expect(model.lines[7].decision == "Corrected to In progress")
        #expect(model.canSave)
        model.save()

        #expect(model.stage == .saved(8))
        let facts = try store.facts(in: mission)
        #expect(facts.count == 8)
        #expect(facts.last?.value == "in_progress")
        #expect(facts.last?.rule == MissionStore.officerRule)
    }

    @Test func aCorrectionMustFitItsField() async throws {
        let model = try model(try await store())
        await model.read()

        #expect(!model.correct("amountDue", to: "about half a million"))
        #expect(model.problem == "Enter a whole number, like 480000.")
        #expect(model.correct("amountDue", to: "480,000"))
        #expect(model.lines[2].decision == "Corrected to USD 480,000")
        #expect(model.problem == nil)
        #expect(!model.correct("invoiceDate", to: "12/10/2026"))
        #expect(model.problem == "Enter the date as year-month-day, like 2026-10-12.")
        #expect(model.correct("invoiceDate", to: "2026-10-12"))
        #expect(!model.correct("bridgeStatus", to: "maybe"))
        #expect(model.problem == "Enter not started, in progress or completed.")
        #expect(!model.correct("invoiceNumber", to: "  "))
    }

    @Test func whenTheAssistantCannotAnswerTheOfficerEntersTheFacts() async throws {
        let store = try await store()
        let model = try model(store, answer: "not JSON")

        await model.read()
        #expect(model.stage == .toOfficer(.notUsable))

        model.enterYourself()
        #expect(model.stage == .review)
        #expect(model.lines.allSatisfy { !$0.canConfirm && $0.value == "Enter it from the page" })
        let typed = ["14", "2026-10-12", "480000", "8500000", "10000000", "32", "64", "not started"]
        for (field, value) in zip(InvoiceFacts.fields, typed) { #expect(model.correct(field, to: value)) }
        model.save()
        #expect(try store.facts(in: mission).map(\.rule).allSatisfy { $0 == MissionStore.officerRule })
    }

    @Test func confirmedPagesAreNotReadAgain() async throws {
        let store = try await store()
        let first = try model(store)
        await first.read()
        for field in InvoiceFacts.fields { first.confirm(field) }
        first.save()

        let again = try model(store)
        await again.read()

        #expect(again.stage == .noPages)
        #expect(try store.confirmedPages(in: mission).count == 2)
    }
}
