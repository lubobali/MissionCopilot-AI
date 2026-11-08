import Foundation

/// The words the answer checks read (#145, step 6.7.5): months, status words, negations and common words.
extension AnswerEvidence {
    static let monthWords = ["January", "February", "March", "April", "May", "June", "July", "August",
                             "September", "October", "November", "December"]

    /// Month words as the terms write them (lower case, endings trimmed), English and French.
    static let monthNumbers: [String: Int] = {
        let english = monthWords.map { $0.lowercased() }
        let french = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre",
                      "octobre", "novembre", "décembre"]
        var table: [String: Int] = [:]
        for (index, name) in (english + french).enumerated() {
            let month = index % 12 + 1
            table[name] = month
            table[MissionSearch.stem(name)] = month
            if name.count > 3, index < 12 { table[String(name.prefix(3))] = month }
        }
        table["sept"] = 9
        return table
    }()

    static let ambiguousMonths: Set = ["may", "mai", "march", "mars", "mar"]

    /// Done forms of status words, each to one meaning: "begun" and "commencé" are "start", "finished" is
    /// "complet" (French forms with their feminine and plural endings).
    static let statusForms: [String: String] = {
        let groups: [String: [String]] = [
            "start": ["started", "begun", "began", "commenced", "underway", "commencé", "démarré"],
            "complet": ["completed", "complete", "finished", "done", "achevé", "terminé", "complété", "fini"],
            "approv": ["approved", "approuvé"], "rais": ["raised", "soulevé"], "sign": ["signed", "signé"],
            "receiv": ["received", "reçu"], "clos": ["closed", "fermé", "clôturé"],
            "paid": ["paid", "payé", "versé", "réglé"]
        ]
        var table: [String: String] = [:]
        for (meaning, forms) in groups {
            for form in forms {
                for ending in ["", "e", "s", "es"] where form.hasSuffix("é") || form.hasSuffix("u") || ending.isEmpty {
                    table[form + ending] = meaning
                }
            }
        }
        return table
    }()

    /// The words (as terms) that back each status in a source.
    static let statusBacking: [String: [String]] = [
        "start": ["start", "commenc", "begin", "began", "begun", "démarr", "underway"],
        "complet": ["complet", "finish", "done", "achev", "termin", "fini"],
        "approv": ["approv", "approuv"], "rais": ["rais", "soulev"], "sign": ["sign"],
        "receiv": ["receiv", "reçu", "paid", "payment", "disburs"], "clos": ["clos", "ferm", "clôtur"],
        "paid": ["paid", "payé", "payment", "disburs", "vers", "régl"]
    ]

    static let negators: Set = ["not", "no", "never", "pas", "jamais", "non", "hasn", "hasnt", "isn", "wasn",
                                "didn", "doesn", "haven", "aren", "weren", "cannot", "aucun", "yet", "n"]

    /// Words that only say where something is written; the source tag already shows that.
    static let commonWords: Set = [
        "bank", "record", "report", "site", "walk", "visit", "debrief", "note", "document", "pack", "sourc",
        "accord", "say", "said", "show", "stat", "mission", "data", "also", "about", "their", "would", "should",
        "selon", "mais", "plus", "avec", "dans", "pour", "rapport", "visite", "donné", "indiqu", "your", "you"
    ]

    /// The glossary read backwards, so "payment" in a sentence finds "paid" in a source.
    static let reverse: [String: [String]] = {
        var table: [String: [String]] = [:]
        for (word, others) in MissionSearch.related { for other in others { table[other, default: []].append(word) } }
        return table
    }()
}
