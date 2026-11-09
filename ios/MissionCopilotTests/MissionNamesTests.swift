import Foundation
import Testing
@testable import MissionCopilot

/// The mission's names for speech (#153). Found in the Phase 6 proof: Lubo said "Kandor road visit" and the
/// engine wrote "Counter route visit"; every field officer has an accent, and so do the people they meet.
/// Universal: a name is a word of the pack that the phone's own dictionary does not know (no list per mission),
/// at most 100 (Apple's limit for contextual strings). A heard word that sounds like a name is offered as that
/// name; the officer accepts it, nothing changes by itself.
struct MissionNamesTests {
    @Test func theKandorPacksNamesAreTheWordsNoDictionaryKnows() {
        let names = MissionNames.from(packFiles: PackSectionsTests.files)

        #expect(names.contains("Kandor"), "\(names)")
        #expect(names.contains("KRRP"), "\(names)")
        for word in ["Section", "contractor", "French", "Invoice", "bridge", "Pont", "Status"] {
            #expect(!names.contains(word), "\(word) is a dictionary word")
        }
        #expect(names.count <= MissionNames.maxNames)
        #expect(MissionNames.maxNames == 100)
    }

    /// The most frequent names first, each once, and never more than 100.
    @Test func atMostAHundredMostFrequentFirst() throws {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        let words: [String] = (0..<150).map { index in
            let pair: String = String(letters[index / 26]) + String(letters[index % 26])
            return "Zqx" + pair + "vw"
        }
        let text = (["Kandor", "Kandor", "Kandor"] + words).joined(separator: " ")
        let file = try JSONSerialization.data(withJSONObject: ["note": text])

        let names = MissionNames.from(packFiles: ["sections/notes.json": file])

        #expect(names.first == "Kandor")
        #expect(names.count == 100)
        #expect(Set(names).count == names.count)
    }

    /// JSON keys and file paths are not names: only the values people read.
    @Test func onlyValuesNotKeys() throws {
        let file = try JSONSerialization.data(withJSONObject: ["zqxkeyname": "Okafor met the team"])

        #expect(MissionNames.from(packFiles: ["sections/zqxfile.json": file]) == ["Okafor"])
    }

    @Test func aHeardWordThatSoundsLikeANameIsOffered() {
        let names = ["Kandor", "Okafor", "KRRP"]

        #expect(CloseNames.suggestions(in: "Counter route visit, we met the contractor.", names: names)
                == [CloseNames.Suggestion(heard: "Counter", name: "Kandor")])
        #expect(CloseNames.suggestions(in: "We met Mr. Okafur today.", names: names)
                == [CloseNames.Suggestion(heard: "Okafur", name: "Okafor")])
        // Already right, a dictionary word that sounds different, or nothing close: nothing is offered.
        #expect(CloseNames.suggestions(in: "Kandor road visit.", names: names).isEmpty)
        #expect(CloseNames.suggestions(in: "The bridge works have not started.", names: names).isEmpty)
    }

    @Test func theSoundCodeGroupsLettersThatSoundAlike() {
        #expect(CloseNames.sound("Counter") == CloseNames.sound("Kandor"))
        #expect(CloseNames.sound("Okafur") == CloseNames.sound("Okafor"))
        #expect(CloseNames.sound("Kandor") != CloseNames.sound("Ministry"))
        #expect(CloseNames.sound("") == "")
        #expect(CloseNames.sound("Ashkar") == CloseNames.sound("Askar"))  // "h" and "w" do not separate sounds
    }
}
