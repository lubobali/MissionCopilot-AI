import Foundation
import Testing
import UIKit
@testable import MissionCopilot

/// The Documents page (#138, step 6.5.5): scan, then every page is saved as signed evidence and read at
/// once; each page says where it is (reading, read with what was found, looks cropped, could not be read);
/// the page comes back as it was. The scanner is a fake here; the real one is proven on the iPhone (6.5.1).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DocumentsModelTests {
    let mission = "kandor-roads"

    private func model(pages: [UIImage], outcome: ScanOutcome? = nil) throws -> (DocumentsModel, MissionStore) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = MissionStore(store: try EncryptedStore.open(at: file, key: DataKey.random()),
                                 vault: SoftwareKeyVault())
        try store.create(mission: mission, title: "Kandor rural roads")
        let result = (outcome ?? .pages(pages.count), pages)
        return (DocumentsModel(mission: mission, store: store, signer: SoftwareEvidenceSigner(),
                               scanner: { result }), store)
    }

    @Test func aScanIsSavedAndEveryPageIsRead() async throws {
        let (documents, store) = try model(pages: [try PageReadingTests.demo("invoice-14"),
                                                   try PageReadingTests.demo("progress-report-2026-09")])

        await documents.scan()

        #expect(documents.outcome == .pages(2))
        #expect(documents.scans.count == 1)
        let states = documents.scans[0].pages.map(\.state)
        #expect(states.allSatisfy { if case .read = $0 { true } else { false } }, "\(states)")
        #expect(try store.reading(of: documents.scans[0].pages[0].seq, in: mission) != nil)
    }

    /// 6.5.11: read pages wait for the facts review until their facts are saved.
    @Test func readPagesWaitForTheFactsUntilTheyAreSaved() async throws {
        let (documents, store) = try model(pages: [try PageReadingTests.demo("invoice-14"),
                                                   try PageReadingTests.demo("progress-report-2026-09")])
        await documents.scan()
        #expect(documents.pagesForFacts == 2)

        let typed = Dictionary(uniqueKeysWithValues: InvoiceFacts.fields.map { ($0, FactDecision.correct("1")) })
        try store.confirmFacts(FactReview(facts: .blank, printedAt: [:], problems: []), decisions: typed,
                               pages: documents.scans[0].pages.map(\.seq), in: mission)
        await documents.loadAndRead()

        #expect(documents.pagesForFacts == 0)
    }

    @Test func aPageWithTheScreenAroundItSaysRetake() async throws {
        let page = try PageReadingTests.demo("invoice-14")
        let size = CGSize(width: page.size.width * 2, height: page.size.height * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let screen = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            page.draw(in: CGRect(x: size.width * 0.3, y: size.height * 0.3, width: size.width * 0.4,
                                 height: size.height * 0.4))
            ("Inbox - Mail - 3 unread" as NSString).draw(at: CGPoint(x: 30, y: 30),
                                                          withAttributes: [.font: UIFont.systemFont(ofSize: 60)])
        }
        let (documents, _) = try model(pages: [screen])

        await documents.scan()

        #expect(documents.scans[0].pages[0].state == .cropped)
    }

    @Test func aCancelledScanSavesNothing() async throws {
        let (documents, store) = try model(pages: [], outcome: .cancelled)

        await documents.scan()

        #expect(documents.outcome == .cancelled)
        #expect(documents.scans.isEmpty)
        #expect(try store.scans(in: mission).isEmpty)
    }

    @Test func thePageComesBackAsItWasWithItsReadings() async throws {
        let (documents, store) = try model(pages: [try PageReadingTests.demo("invoice-14")])
        await documents.scan()

        let again = DocumentsModel(mission: mission, store: store, signer: SoftwareEvidenceSigner(),
                                   scanner: { (.cancelled, []) })
        again.load()

        #expect(again.scans.map(\.id) == documents.scans.map(\.id))
        #expect(again.scans[0].pages[0].state == documents.scans[0].pages[0].state)
    }

    @Test func aPageThatWasNeverReadIsReadWhenThePageOpens() async throws {
        let (documents, store) = try model(pages: [])
        try store.addScan([try PageReadingTests.demo("progress-report-2026-09")], to: mission,
                          signer: SoftwareEvidenceSigner())

        await documents.loadAndRead()

        guard case .read = documents.scans[0].pages[0].state else {
            Issue.record("\(documents.scans[0].pages[0].state)")
            return
        }
    }

    @Test(arguments: [
        (DocumentsModel.PageState.reading, "Reading the page"),
        (.read(lines: 9, tables: 1), "Read: 9 lines · 1 table"),
        (.read(lines: 1, tables: 2), "Read: 1 line · 2 tables"),
        (.read(lines: 7, tables: 0), "Read: 7 lines"),
        (.cropped, "This page looks cropped wrong: other text reaches its edge. Scan it again, or keep it."),
        (.unreadable, "This page could not be read. Scan it again.")
    ])
    func eachPageStateInWords(state: DocumentsModel.PageState, words: String) {
        #expect(state.words == words)
    }

    @Test func theCardSaysHowManyScansAndPages() {
        #expect(DocumentsModel.summary(scans: 0, pages: 0) == "Scan an invoice or a progress report")
        #expect(DocumentsModel.summary(scans: 1, pages: 2) == "1 scan · 2 pages")
        #expect(DocumentsModel.summary(scans: 2, pages: 1) == "2 scans · 1 page")
    }
}
