import SwiftUI
import Testing
import UIKit
@testable import MissionCopilot

/// Phase 6's field-flow screens on the theme background (#138, #142), drawn like the others in
/// ScreenshotTests (kept apart so each file stays readable).
extension ScreenshotTests {
    /// #138: the Documents page after scanning the two demo pages, each read on the "phone".
    @Test(arguments: [Look.light, .dark, .largestText])
    func theDocumentsAreOnTheThemeBackground(look: Look) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = MissionStore(store: try EncryptedStore.open(at: file, key: DataKey.random()),
                                 vault: SoftwareKeyVault())
        try store.create(mission: "kandor-roads", title: "Kandor rural roads")
        let pages = [try PageReadingTests.demo("invoice-14"), try PageReadingTests.demo("progress-report-2026-09")]
        let documents = DocumentsModel(mission: "kandor-roads", store: store, signer: SoftwareEvidenceSigner(),
                                       scanner: { (.pages(2), pages) })
        await documents.scan()
        try check(DocumentsView(model: documents).fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: .infinity, alignment: .top).fieldScreen(), look: look, name: "documents")
    }

    /// #138: the facts review, two facts decided and one the pages do not print (its problems in words).
    @Test(arguments: [Look.light, .dark, .largestText])
    func theFactsReviewIsOnTheThemeBackground(look: Look) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = MissionStore(store: try EncryptedStore.open(at: file, key: DataKey.random()),
                                 vault: SoftwareKeyVault())
        try store.create(mission: "kandor-roads", title: "Kandor rural roads")
        let scan = try store.addScan([try ScanStoreTests.page(), try ScanStoreTests.page()], to: "kandor-roads",
                                     signer: SoftwareEvidenceSigner())
        for (seq, reading) in zip(scan.pages, try FactGroundingTests.kandorPages()) {
            _ = try await store.readPage(seq, in: "kandor-roads", read: { _ in reading })
        }
        let answer = ScanExtractionTests.answer.replacingOccurrences(of: #""kmCompleted":32"#,
                                                                     with: #""kmCompleted":33"#)
        let review = FactReviewModel(mission: "kandor-roads", store: store,
                                     contracts: try InvoiceBankViewTests.kandor().contracts,
                                     model: FieldModel(engine: FieldModelTests.FakeEngine(answer: answer)))
        await review.read()
        review.confirm("invoiceNumber")
        review.correct("invoiceDate", to: "2026-10-12")
        try check(FactReviewView(model: review).fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: .infinity, alignment: .top).fieldScreen(), look: look, name: "facts")
    }

    /// #142: the Debrief page with two kept debriefs: one read into text, one where no words were heard.
    @Test(arguments: [Look.light, .dark, .largestText])
    func theDebriefsAreOnTheThemeBackground(look: Look) async throws {
        let store = try DebriefModelTests.store()
        let engine = DebriefTranscriptTests.FakeTranscriber(.success(
            "Met the deputy minister. Section 3 bridge not started. Invoice 14 for 480,000."))
        try store.addDebrief(try DebriefStoreTests.recording(seconds: 42), language: .english, to: "kandor-roads",
                             signer: SoftwareEvidenceSigner())
        let model = try DebriefModelTests.model(DebriefModelTests.FakeRecorder(), store: store, transcriber: engine)
        await model.loadAndRead()
        engine.answer = .failure(.nothingHeard)
        try store.addDebrief(try DebriefStoreTests.recording(seconds: 4), language: .french, to: "kandor-roads",
                             signer: SoftwareEvidenceSigner())
        await model.loadAndRead()
        model.consent = true
        try check(DebriefView(model: model).fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: .infinity, alignment: .top).fieldScreen(), look: look, name: "debriefs")
    }

    /// #142: the notes review, one note confirmed, one not said in the debrief, and the heard numbers.
    @Test(arguments: [Look.light, .dark, .largestText])
    func theDebriefNotesAreOnTheThemeBackground(look: Look) async throws {
        let store = try DebriefModelTests.store()
        let debrief = try store.addDebrief(try DebriefStoreTests.recording(), language: .english, to: "kandor-roads",
                                           signer: SoftwareEvidenceSigner())
        _ = try await store.transcribe(debrief, in: "kandor-roads", engine: DebriefTranscriptTests.FakeTranscriber(
            .success("Section 3 bridge still not started. Invoice 14 for 48,000 dollars.")))
        let answer = #"{"notes":[{"kind":"risk","text":"The Section 3 bridge has not started.","who":"","#
            + #""byWhen":"","quote":"Section 3 bridge still not started"},{"kind":"decision","text":"Invoice "#
            + #"approved.","who":"","byWhen":"","quote":"the minister approved invoice 14"}]}"#
        let review = DebriefReviewModel(mission: "kandor-roads", debrief: debrief, store: store,
                                        contracts: try InvoiceBankViewTests.kandor().contracts,
                                        model: FieldModel(engine: FieldModelTests.FakeEngine(answer: answer)))
        await review.draft()
        review.decide(note: 0, .confirm)
        try check(DebriefNotesView(model: review).fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: .infinity, alignment: .top).fieldScreen(), look: look, name: "debrief-notes")
    }
}
