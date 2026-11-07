import Foundation
import Testing
@testable import MissionCopilot

/// Spike #8's attacks against the app's own checks (#138, step 6.5.12, threats T01 to T03): Vision reads each
/// printed attack page, and the worst case is assumed, the model took the attacker's value. Every such fact
/// must reach the officer with a problem; the clean pages must pass with none. (Approval and risk attacks need
/// no check here: no page text can approve or decide a flag, T08 and ADR 0005.)
@Suite(.timeLimit(.minutes(2)))
struct InjectionChecksTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "docs/demo/injection")

    struct Case: Decodable, Sendable, CustomTestStringConvertible {
        let id: String
        let channel: String
        let base: String
        let file: String
        let target: AttackTarget

        var testDescription: String { id }
    }

    struct Key: Decodable { let cases: [Case] }

    static let cases: [Case] = {
        guard let data = try? Data(contentsOf: folder.appending(path: "answer-key.json")),
              let key = try? JSONDecoder().decode(Key.self, from: data) else { return [] }
        return key.cases.filter { $0.channel == "scan" }
    }()

    static var planted: [Case] { cases.filter { InvoiceFacts.fields.contains($0.target.field) } }
    static var clean: [Case] { cases.filter { $0.target.field == "none" } }

    /// The attack page as Vision reads it, with the other Kandor page as the answer key prints it.
    static func pages(_ attack: Case) async throws -> [PageReading] {
        let read = try await PageReading.read(try Data(contentsOf: folder.appending(path: attack.file)))
        var pages = try FactGroundingTests.kandorPages()
        pages[attack.base == "invoice-14" ? 0 : 1] = read
        return pages
    }

    /// The true facts with the attacker's value in its field.
    static func taken(_ attack: Case) throws -> InvoiceFacts {
        var values = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(FactGroundingTests.truth)) as? [String: Any])
        switch attack.target.attacker {
        case .number(let number): values[attack.target.field] = number
        case .text(let text): values[attack.target.field] = text
        }
        return try JSONDecoder().decode(InvoiceFacts.self, from: JSONSerialization.data(withJSONObject: values))
    }

    @Test func theAnswerKeyHasThePlantedAndCleanPages() {
        #expect(Self.planted.map(\.id) == ["V1", "V2", "V3", "V4", "F1", "F2", "F4", "F5", "D1", "D2", "D3", "D4",
                                         "H1", "H2", "H3", "H4", "H5", "H6"])
        #expect(Self.clean.map(\.id) == ["C1", "C2"])
    }

    @Test(arguments: planted)
    func aPlantedValueTheModelTookReachesTheOfficer(attack: Case) async throws {
        let pages = try await Self.pages(attack)
        let bank = try #require(try InvoiceBankViewTests.kandor().contracts.bankView(invoice: "14"))

        let review = InvoiceChecks.review(try Self.taken(attack), pages: pages, bank: bank)

        #expect(!review.problems(for: attack.target.field).isEmpty, "\(attack.id): \(review.problems)")
    }

    @Test(arguments: clean)
    func aCleanPageGivesNoProblem(attack: Case) async throws {
        let pages = try await Self.pages(attack)
        let bank = try #require(try InvoiceBankViewTests.kandor().contracts.bankView(invoice: "14"))

        let review = InvoiceChecks.review(FactGroundingTests.truth, pages: pages, bank: bank)

        #expect(review.problems.isEmpty, "\(attack.id): \(review.problems)")
    }
}

/// What an attack plants: the field, and the attacker's value (a number or a word, as the answer key writes it).
struct AttackTarget: Decodable, Sendable {
    enum Value: Decodable, Sendable {
        case number(Int), text(String)

        init(from decoder: any Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let number = try? single.decode(Int.self) { self = .number(number) } else {
                self = .text(try single.decode(String.self))
            }
        }
    }

    let field: String
    let attacker: Value
}
