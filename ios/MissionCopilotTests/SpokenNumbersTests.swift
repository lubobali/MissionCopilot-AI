import Foundation
import Testing
@testable import MissionCopilot

/// Spoken numbers (#142, step 6.6.7): code finds every number, amount, percent and date in the transcript, in
/// digits and in words, English and French, each with its unit and the words around it, so the officer can
/// confirm or correct it ("heard" until then). Known pack values are cross-checked: an amount after "invoice 14"
/// against the pack's invoice 14, a "paid" amount against the bank's payments, km against the road's length.
struct SpokenNumbersTests {
    /// The iPhone proof's real transcript (PR 1): the engine wrote "nut", "in voice" and "hours".
    static let heardOnThePhone = """
        Met the deputy minister transport section 3, bridge nut started in voice 14 for 480,000 hours. The \
        contractor will send a new work plan into 2 weeks.
        """

    static func values(_ transcript: String) -> [String] { SpokenNumbers.find(transcript).map(\.value) }

    @Test func digitsAreFoundWithTheirUnitAndTheWordsAround() throws {
        let heard = SpokenNumbers.find(Self.heardOnThePhone)

        #expect(heard.map(\.value) == ["3", "14", "480000", "2"])
        let amount = try #require(heard.first { $0.value == "480000" })
        #expect(amount.words == "480,000")
        #expect(amount.unit == "hours")  // shown as heard: the officer sees "hours" next to an amount
        #expect(amount.context == "in voice 14 for 480,000 hours. The contractor")
        let start = Self.heardOnThePhone.index(Self.heardOnThePhone.startIndex, offsetBy: amount.found.offset)
        #expect(Self.heardOnThePhone[start...].hasPrefix("480,000"))
        #expect(heard.last?.unit == "weeks")
    }

    @Test func numbersInWordsAreReadAsNumbers() {
        #expect(Self.values("a new work plan in two weeks") == ["2"])
        #expect(Self.values("invoice fourteen for four hundred eighty thousand dollars") == ["14", "480000"])
        #expect(Self.values("paid eight point five million so far") == ["8500000"])
        #expect(Self.values("paid 8.5 million so far") == ["8500000"])
        #expect(Self.values("about 3 months late, 32 of 64 km") == ["3", "32", "64"])
        #expect(Self.values("twenty one days") == ["21"])
    }

    @Test func frenchNumbersInWordsAreReadToo() {
        #expect(Self.values("la facture quatorze de quatre cent quatre-vingt mille dollars") == ["14", "480000"])
        #expect(Self.values("un nouveau plan dans deux semaines") == ["2"])  // a lone "un" is "a", not a number
        #expect(Self.values("un kilomètre de route") == ["1"])
        #expect(Self.values("soixante-quatre kilomètres") == ["64"])
    }

    /// Found on the iPhone: "March 15th" and "$480,000" were missed.
    @Test func ordinalsAndDollarSignsAreRead() throws {
        let heard = SpokenNumbers.find("extend the deadline to March 15th, but only if. In voice 14, for $480,000, "
                                       + "payments look high. Due on the 3rd.")

        #expect(heard.map(\.value) == ["March 15", "14", "480000", "3"])
        let amount = try #require(heard.first { $0.value == "480000" })
        #expect(amount.kind == .amount)
        #expect(amount.words == "$480,000")
        #expect(amount.unit == "dollars")
    }

    @Test func datesAndPercentsKeepTheirMeaning() throws {
        let heard = SpokenNumbers.find("extend the deadline to March 15, paid 85 percent, le 15 mars, by Friday")

        #expect(heard.map(\.value) == ["March 15", "85", "15 mars", "Friday"])
        #expect(heard.map(\.kind) == [.date, .percent, .date, .date])
    }

    @Test func anInvoiceAmountIsCheckedAgainstThePack() throws {
        let contracts = try InvoiceBankViewTests.kandor().contracts

        let right = SpokenNumbers.check(SpokenNumbers.find("invoice 14 for 480,000 dollars"), contracts: contracts)
        let wrong = SpokenNumbers.check(SpokenNumbers.find("invoice 14 for 48,000 dollars"), contracts: contracts)
        let unknown = SpokenNumbers.check(SpokenNumbers.find("invoice 22 for 5,000 dollars"), contracts: contracts)

        #expect(right.flatMap(\.problems) == [])
        #expect(wrong.first { $0.value == "48000" }?.problems == ["The pack's invoice 14 is 480,000, not 48,000."])
        // Found on the iPhone: the engine wrote "$180,000" for "480,000"; the pack's value is offered.
        #expect(wrong.first { $0.value == "48000" }?.expected == "480000")
        #expect(right.first { $0.value == "480000" }?.expected == nil)
        // Found on the iPhone: "invoice 14" was heard as "invoice 36"; the pack's invoices help the officer see it.
        #expect(unknown.first { $0.value == "5000" }?.problems
                == ["Invoice 22 is not in the pack. The pack has invoices 6, 9, 11, 13 and 14."])
    }

    @Test func aPaidAmountIsCheckedAgainstTheBanksPayments() throws {
        let contracts = try InvoiceBankViewTests.kandor().contracts

        let wrong = SpokenNumbers.check(SpokenNumbers.find("they say they were paid 85 million"), contracts: contracts)
        let right = SpokenNumbers.check(SpokenNumbers.find("paid 8.5 million so far"), contracts: contracts)

        #expect(wrong.first?.problems == ["The bank's payments add up to 8,500,000, not 85,000,000."])
        #expect(wrong.first?.expected == "8500000")
        #expect(right.first?.problems == [])
    }

    @Test func kilometresAreCheckedAgainstTheRoad() throws {
        let contracts = try InvoiceBankViewTests.kandor().contracts

        let checked = SpokenNumbers.check(SpokenNumbers.find("32 km built, then 80 km of road"), contracts: contracts)

        #expect(checked.map(\.problems) == [[], ["The road is 64 km long; 80 km is more than all of it."]])
    }

    @Test func withoutAPackNothingIsCheckedAgainstIt() {
        #expect(SpokenNumbers.check(SpokenNumbers.find("invoice 14 for 48,000"), contracts: nil).flatMap(\.problems)
                == [])
    }
}
