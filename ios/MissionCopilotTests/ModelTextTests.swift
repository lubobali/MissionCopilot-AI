import Foundation
import Testing
@testable import MissionCopilot

/// #159: what the on-device model may write. Under the grammar it can eat a real space next to a number
/// ("Section3"), so no screen shows a sentence the model wrote: Ask's model only picks a label, the scan's model
/// fills numbers, a patterned date and an enum, and the one free string (the invoice number) is tidied by code
/// (ScanExtractionTests). Every word on screen is built by code from the records.
struct ModelTextTests {
    /// The properties of a schema the model may fill with any text: a string with no enum and no pattern.
    static func freeText(_ schema: String) throws -> [String] {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
        let properties = try #require(object["properties"] as? [String: [String: Any]])
        return properties.filter { _, rule in
            rule["type"] as? String == "string" && rule["enum"] == nil && rule["pattern"] == nil
        }.map(\.key).sorted()
    }

    @Test func asksModelOnlyPicksALabel() throws {
        for count in [1, 3, 12] {
            #expect(try Self.freeText(MissionAnswerer.schema(options: count)).isEmpty)
        }
    }

    @Test func theScansModelWritesNoSentence() throws {
        #expect(try Self.freeText(InvoiceFacts.schema) == ["invoiceNumber"], "the one free string, tidied by code")
    }
}
