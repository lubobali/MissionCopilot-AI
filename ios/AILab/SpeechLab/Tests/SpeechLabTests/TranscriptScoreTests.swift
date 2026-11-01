import Foundation
import Testing
@testable import SpeechLab

struct NormalizerTests {
    @Test func englishUnitsNumbersAndPunctuation() {
        #expect(Normalizer.words("At kilometre 18, I measured 4.9 metres.", language: "en")
            == ["at", "km", "18", "i", "measured", "4.9", "m"])
    }

    @Test func frenchDecimalCommaAndAccents() {
        #expect(Normalizer.words("Au kilomètre 18, j’ai mesuré 4,9 mètres.", language: "fr")
            == ["au", "km", "18", "j'ai", "mesuré", "4.9", "m"])
    }

    @Test(arguments: ["480,000 dollars", "480 000 dollars", "480\u{202F}000 dollars", "480000 dollars"])
    func thousandsSeparatorsAllMeanTheSameNumber(text: String) {
        #expect(Normalizer.words(text, language: "en") == ["480000", "dollars"])
    }

    @Test func percentAndMillionsInBothLanguages() {
        #expect(Normalizer.words("85% of 8.5 million", language: "en") == ["85", "percent", "of", "8.5", "million"])
        #expect(Normalizer.words("85 pour cent, 8,5 millions", language: "fr") == ["85", "percent", "8.5", "million"])
        #expect(Normalizer.words("85 per cent", language: "en") == ["85", "percent"])
    }

    @Test func spellingVariantsOfUnitsMatch() {
        #expect(Normalizer.words("7 meters, 64 kilometers", language: "en") == ["7", "m", "64", "km"])
    }

    @Test func sentenceEndDoesNotStickToNumbers() {
        #expect(Normalizer.words("in 2026. End of debrief.", language: "en") == ["in", "2026", "end", "of", "debrief"])
    }
}

struct WordErrorRateTests {
    @Test func identicalTextHasNoErrors() {
        let result = WordErrorRate.compute(reference: ["a", "b", "c"], hypothesis: ["a", "b", "c"])

        #expect(result.rate == 0)
    }

    @Test func oneWrongWordInFour() {
        let result = WordErrorRate.compute(reference: ["the", "bridge", "not", "started"],
                                           hypothesis: ["the", "ridge", "not", "started"])

        #expect(result.substitutions == 1 && result.rate == 0.25)
    }

    @Test func missingWordIsADeletion() {
        let result = WordErrorRate.compute(reference: ["road", "width", "low"], hypothesis: ["road", "low"])

        #expect(result.deletions == 1 && result.insertions == 0 && result.substitutions == 0)
    }

    @Test func extraWordIsAnInsertion() {
        let result = WordErrorRate.compute(reference: ["road", "low"], hypothesis: ["road", "very", "low"])

        #expect(result.insertions == 1 && result.deletions == 0 && result.substitutions == 0)
    }

    @Test func emptyTranscriptMissesEverything() {
        #expect(WordErrorRate.compute(reference: ["a", "b"], hypothesis: []).rate == 1)
    }
}

struct FactScoreTests {
    struct AnswerKey: Decodable {
        struct Language: Decodable { let text: String; let facts: [SpokenFact] }
        let en: Language
        let fr: Language
    }

    static let key: AnswerKey = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/demo/audio/answer-key.json")
        // A missing answer key must fail loudly, not skip.
        guard let data = try? Data(contentsOf: url), let key = try? JSONDecoder().decode(AnswerKey.self, from: data) else {
            fatalError("answer key not found at \(url.path)")
        }
        return key
    }()

    @Test func ourOwnScriptsContainAllElevenFacts() {
        // Proves the normalizer understands both scripts before any engine runs.
        for (language, script) in [("en", Self.key.en), ("fr", Self.key.fr)] {
            let score = FactScore.score(script.facts, in: script.text, language: language)
            #expect(score.found.count == 11, "\(language) missing: \(score.missing)")
        }
    }

    @Test func spellingVariantsOfAFactStillCount() {
        let facts = [SpokenFact(name: "roadWidthMeasured", value: "4.9 m", spoken: "4.9 metres")]

        #expect(FactScore.score(facts, in: "I measured 4.9 meters", language: "en").missing.isEmpty)
    }

    @Test func numbersWrittenAsWordsAreAMiss() {
        // Code downstream needs digits; words are reported, never guessed into numbers.
        let facts = [SpokenFact(name: "roadWidthMeasured", value: "4.9 m", spoken: "4.9 metres")]

        #expect(FactScore.score(facts, in: "four point nine metres", language: "en").missing == ["roadWidthMeasured"])
    }

    @Test func factWordsMustBeInOrder() {
        let facts = [SpokenFact(name: "kmBuilt", value: "32", spoken: "32 of 64")]

        #expect(FactScore.score(facts, in: "64 of 32 kilometres", language: "en").missing == ["kmBuilt"])
    }

    @Test func wrongNumberIsAMiss() {
        let facts = [SpokenFact(name: "invoiceAmount", value: "480000", spoken: "480,000")]

        #expect(FactScore.score(facts, in: "asks for 418,000 dollars", language: "en").missing == ["invoiceAmount"])
    }
}
