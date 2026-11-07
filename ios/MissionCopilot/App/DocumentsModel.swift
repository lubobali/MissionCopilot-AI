import Foundation
import Observation
import UIKit

/// The Documents page (#138): scan, save every page as signed evidence, read it at once, and say for each
/// page where it is. Opened again, it comes back as it was, and any page not read yet is read then.
@Observable @MainActor
final class DocumentsModel {
    enum PageState: Equatable, Sendable {
        case reading
        case read(lines: Int, tables: Int)
        case cropped
        case unreadable

        var words: String {
            switch self {
            case .reading: return "Reading the page"
            case .read(let lines, let tables):
                let read = "Read: \(lines) line\(lines == 1 ? "" : "s")"
                return tables == 0 ? read : read + " · \(tables) table\(tables == 1 ? "" : "s")"
            case .cropped:
                return "This page looks cropped wrong: other text reaches its edge. Scan it again, or keep it."
            case .unreadable: return "This page could not be read. Scan it again."
            }
        }

        init(_ reading: PageReading) {
            if reading.layout?.looksCropped == true {
                self = .cropped
            } else {
                let lines = reading.transcript.split(separator: "\n").filter { !$0.allSatisfy(\.isWhitespace) }
                self = .read(lines: lines.count, tables: reading.tables.count)
            }
        }
    }

    struct Page: Identifiable, Equatable, Sendable {
        let seq: Int
        var state: PageState
        var id: Int { seq }
    }

    struct Scan: Identifiable, Equatable, Sendable {
        let id: String
        let scannedAt: Date
        var pages: [Page]
    }

    typealias Scanner = @MainActor () async -> (outcome: ScanOutcome, pages: [UIImage])

    private(set) var scans: [Scan] = []
    private(set) var outcome: ScanOutcome?
    /// Read pages whose facts are not saved yet: the review can read them (6.5.11).
    private(set) var pagesForFacts = 0
    let mission: String
    private let store: MissionStore
    private let signer: any EvidenceSigner
    private let scanner: Scanner
    @ObservationIgnored private var thumbnails: [Int: UIImage] = [:]

    init(mission: String, store: MissionStore,
         signer: any EvidenceSigner = SecureEnclaveEvidenceSigner(user: AppSession.localProfile),
         scanner: @escaping Scanner = { await DocumentScanner.shared.scan() }) {
        (self.mission, self.store, self.signer, self.scanner) = (mission, store, signer, scanner)
    }

    static func summary(scans: Int, pages: Int) -> String {
        guard scans > 0 else { return "Scan an invoice or a progress report" }
        return "\(scans) scan\(scans == 1 ? "" : "s") · \(pages) page\(pages == 1 ? "" : "s")"
    }

    var summary: String { Self.summary(scans: scans.count, pages: scans.reduce(0) { $0 + $1.pages.count }) }

    /// The scans as stored; a page with no reading yet shows as reading.
    func load() {
        scans = ((try? store.scans(in: mission)) ?? []).map { scan in
            Scan(id: scan.id, scannedAt: scan.scannedAt, pages: scan.pages.map { seq in
                Page(seq: seq, state: (try? store.reading(of: seq, in: mission)).flatMap { $0 }.map(PageState.init)
                     ?? .reading)
            })
        }
    }

    func loadAndRead() async {
        load()
        await readWaitingPages()
        countPagesForFacts()
    }

    private func countPagesForFacts() {
        let confirmed = (try? store.confirmedPages(in: mission)) ?? []
        let usable = { (state: PageState) -> Bool in  // a cropped page the officer kept is still a page
            switch state {
            case .read, .cropped: true
            case .reading, .unreadable: false
            }
        }
        pagesForFacts = scans.flatMap(\.pages).filter { usable($0.state) && !confirmed.contains($0.seq) }.count
    }

    /// The camera, then every page saved as signed evidence and read.
    func scan() async {
        let (outcome, images) = await scanner()
        guard outcome.scanned else {
            self.outcome = outcome
            return
        }
        do {
            try store.addScan(images, to: mission, signer: signer)
            self.outcome = outcome
        } catch {
            self.outcome = .notSaved
        }
        await loadAndRead()
    }

    private func readWaitingPages() async {
        for scanIndex in scans.indices {
            for pageIndex in scans[scanIndex].pages.indices where scans[scanIndex].pages[pageIndex].state == .reading {
                let seq = scans[scanIndex].pages[pageIndex].seq
                let state: PageState
                do {
                    state = PageState(try await store.readPage(seq, in: mission))
                } catch {
                    state = .unreadable
                }
                scans[scanIndex].pages[pageIndex].state = state
            }
        }
    }

    /// A page's thumbnail (600 px), opened from its sealed file in memory only.
    func thumbnail(_ seq: Int) -> UIImage? {
        if let opened = thumbnails[seq] { return opened }
        guard let file = try? store.evidenceFile(in: mission, seq: seq), let image = UIImage(data: file),
              let thumbnail = image.preparingThumbnail(of: SiteWalkModel.thumbnailSize(of: image.size)) else {
            return nil
        }
        thumbnails[seq] = thumbnail
        return thumbnail
    }
}
