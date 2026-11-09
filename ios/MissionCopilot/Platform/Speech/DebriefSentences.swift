import Foundation

/// One sentence that was said, with where it is in the transcript (counted in characters, like TextSpan).
struct DebriefSentence: Equatable, Sendable {
    let text: String
    let found: TextSpan
}

/// A transcript as the sentences that were said (#152): split after ".", "!" or "?" and a space, never after a
/// title ("Mr. Okafor", "M. Diallo", found in the Mac probe); at most 40, each with its place.
enum DebriefSentences {
    static let maxSentences = 40

    static func split(_ transcript: String) -> [DebriefSentence] {
        let characters = Array(transcript)
        var sentences: [DebriefSentence] = []
        var start = 0
        var index = 0
        while index < characters.count, sentences.count < maxSentences {
            let ends = ".!?".contains(characters[index])
                && (index + 1 == characters.count || characters[index + 1].isWhitespace)
            if ends, !isTitle(characters, end: index) || characters[index] != "." {
                sentences += sentence(characters, from: start, to: index + 1)
                start = index + 1
            }
            index += 1
        }
        if sentences.count < maxSentences { sentences += sentence(characters, from: start, to: characters.count) }
        return sentences
    }

    private static let titles: Set = ["mr", "mrs", "ms", "dr", "m", "mme", "mlle", "no", "st", "prof"]

    /// The word before a full stop is a title ("Mr", "M", "Mme").
    private static func isTitle(_ characters: [Character], end: Int) -> Bool {
        var first = end
        while first > 0, characters[first - 1].isLetter { first -= 1 }
        let word = String(characters[first..<end]).lowercased()
        return titles.contains(word) && (first == 0 || !characters[first - 1].isLetter)
    }

    private static func sentence(_ characters: [Character], from start: Int, to end: Int) -> [DebriefSentence] {
        var first = start, last = end
        while first < last, characters[first].isWhitespace { first += 1 }
        while last > first, characters[last - 1].isWhitespace { last -= 1 }
        guard first < last else { return [] }
        return [DebriefSentence(text: String(characters[first..<last]),
                                found: TextSpan(offset: first, length: last - first))]
    }
}
