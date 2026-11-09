import Foundation
import UIKit

/// The mission's own names, for speech (#153). Universal: a name is a word of the pack's text that the phone's
/// dictionary (UITextChecker, offline, English or French) does not know: "Kandor", "KRRP", a contractor's or a
/// place's name, never "Section" or "contractor"; a word in capitals is an acronym, so a name. The most frequent
/// first, at most 100 (Apple's limit for contextual strings). Read from the values people read, never from JSON
/// keys or file paths.
enum MissionNames {
    static let maxNames = 100
    static let dictionaries = ["en_US", "fr_FR"]

    static func from(packFiles: [String: Data]) -> [String] {
        var counts: [String: Int] = [:], order: [String] = []
        for path in packFiles.keys.sorted() where path.hasSuffix(".json") {
            guard let data = packFiles[path], let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            for word in strings(in: json).flatMap(words) {
                if counts[word] == nil { order.append(word) }
                counts[word, default: 0] += 1
            }
        }
        let checker = UITextChecker()
        // An acronym ("KRRP") is a name: the spell checker passes words in capitals.
        let unknown = order.filter { word in
            word.allSatisfy(\.isUppercase) || !dictionaries.contains { known(word, language: $0, checker: checker) }
        }
        let ranked = unknown.enumerated().sorted { first, second in
            let (one, two) = (counts[first.element] ?? 0, counts[second.element] ?? 0)
            return one == two ? first.offset < second.offset : one > two
        }
        return Array(ranked.map(\.element).prefix(maxNames))
    }

    private static func strings(in json: Any) -> [String] {
        switch json {
        case let text as String: [text]
        case let list as [Any]: list.flatMap(strings)
        case let object as [String: Any]: object.keys.sorted().flatMap { strings(in: object[$0] ?? "") }
        default: []
        }
    }

    /// Words of three letters or more, letters only ("KRRP-P1" gives "KRRP").
    private static func words(_ text: String) -> [String] {
        text.split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 }
    }

    private static func known(_ word: String, language: String, checker: UITextChecker) -> Bool {
        guard UITextChecker.availableLanguages.contains(language) else { return false }
        let whole = NSRange(location: 0, length: (word as NSString).length)
        let range = checker.rangeOfMisspelledWord(in: word, range: whole, startingAt: 0, wrap: false,
                                                  language: language)
        return range.location == NSNotFound
    }
}

/// A heard word that sounds like one of the mission's names (#153): "Counter" for "Kandor". Offered to the
/// officer, never changed by itself; the transcript stays as heard (it is evidence).
enum CloseNames {
    struct Suggestion: Equatable, Sendable {
        let heard: String
        let name: String
    }

    static func suggestions(in text: String, names: [String]) -> [Suggestion] {
        let sounds = Dictionary(names.map { (sound($0), $0) }) { first, _ in first }
        var seen: Set<String> = []
        return text.split { !$0.isLetter }.map(String.init).compactMap { heard in
            let code = sound(heard)
            guard heard.count >= 3, let name = sounds[code], name.lowercased() != heard.lowercased(),
                  seen.insert(heard.lowercased()).inserted else { return nil }
            return Suggestion(heard: heard, name: name)
        }
    }

    /// Soundex, but for every letter (the first too, so "Counter" and "Kandor" meet) and never cut to four
    /// (so "contractor" stays far from "Kandor"): letters that sound alike share a digit, vowels separate.
    static func sound(_ word: String) -> String {
        var code = "", last: Character?
        for letter in word.lowercased().folding(options: .diacriticInsensitive, locale: nil) {
            let digit = groups.first { $0.key.contains(letter) }?.value
            if let digit, digit != last { code.append(digit) }
            if "hw".contains(letter) { continue }
            last = digit
        }
        return code
    }

    private static let groups: [String: Character] = ["bfpv": "1", "cgjkqsxz": "2", "dt": "3", "l": "4", "mn": "5",
                                                       "r": "6"]
}
