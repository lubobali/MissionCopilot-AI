import Foundation

/// Numbers said in words, in English and French ("four hundred eighty thousand", "quatre-vingt mille",
/// "eight point five million"), and month names (#142, step 6.6.7).
enum NumberWords {
    static let small: [String: Double] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "zéro": 0, "un": 1, "une": 1, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5, "sept": 7, "huit": 8,
        "neuf": 9, "dix": 10, "onze": 11, "douze": 12, "treize": 13, "quatorze": 14, "quinze": 15, "seize": 16
    ]
    static let tens: [String: Double] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80,
        "ninety": 90, "vingt": 20, "vingts": 20, "trente": 30, "quarante": 40, "cinquante": 50, "soixante": 60
    ]
    static let scales: [String: Double] = [
        "hundred": 100, "cent": 100, "cents": 100, "thousand": 1_000, "mille": 1_000,
        "million": 1_000_000, "millions": 1_000_000
    ]

    /// A word that is part of a number. "six" counts in both languages; "et" and "and" only join number words
    /// inside value(_:), so they are not number words on their own.
    static func isNumberWord(_ word: String) -> Bool {
        small[word] != nil || tens[word] != nil || scales[word] != nil
    }

    /// The value of number words in order; "point" starts a decimal part read digit by digit.
    static func value(_ words: [String]) -> Double? {
        var total = 0.0, current = 0.0, decimals = "", inDecimals = false
        for (index, word) in words.enumerated() {
            if word == "point" {
                inDecimals = true
            } else if inDecimals, let digit = small[word], digit < 10 {
                decimals += String(Int(digit))
            } else if let number = small[word] {
                current += number
            } else if let number = tens[word] {
                // French 80: "quatre-vingt(s)" is four twenties.
                let fourTwenties = number == 20 && index > 0 && words[index - 1] == "quatre"
                current += fourTwenties ? 80 - 4 : number
            } else if let scale = scales[word] {
                if scale == 100 {
                    current = max(current, 1) * 100
                } else {
                    let whole = (max(current, 1) + (Double("0.\(decimals)") ?? 0)) * scale
                    (total, current, decimals, inDecimals) = (total + whole, 0, "", false)
                }
            } else {
                return nil
            }
        }
        return total + current + (Double("0.\(decimals)") ?? 0)
    }

    /// A month's English name, from English or French ("mars" is March); nil for any other word.
    static func month(_ word: String) -> String? {
        let english = ["january", "february", "march", "april", "may", "june", "july", "august", "september",
                       "october", "november", "december"]
        let french = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre",
                      "octobre", "novembre", "décembre"]
        let index = english.firstIndex(of: word) ?? french.firstIndex(of: word)
        return index.map { english[$0].prefix(1).uppercased() + english[$0].dropFirst() }
    }
}
