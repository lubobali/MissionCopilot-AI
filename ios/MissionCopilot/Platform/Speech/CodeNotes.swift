import Foundation

/// A debrief's notes written by code (#152, decided A): each labelled sentence becomes a note, word for word,
/// citing its place; who is a role found in it, by when the date words the number finder found in it. Every
/// note still goes through NoteGrounding. Sentences with no label wait for the officer to tag them.
enum CodeNotes {
    struct Draft: Sendable, Equatable {
        let notes: [NoteCheck]
        let untagged: [DebriefSentence]
    }

    static func draft(_ transcript: String) -> Draft {
        var notes: [NoteCheck] = [], untagged: [DebriefSentence] = []
        for sentence in DebriefSentences.split(transcript) {
            if let kind = NoteCues.kind(of: sentence.text) {
                notes.append(note(sentence, kind: kind, transcript: transcript))
            } else {
                untagged.append(sentence)
            }
        }
        return Draft(notes: notes, untagged: untagged)
    }

    /// One sentence as a note of a kind, grounded in the transcript.
    static func note(_ sentence: DebriefSentence, kind: DebriefNote.Kind, transcript: String) -> NoteCheck {
        let note = DebriefNote(kind: kind, text: sentence.text, who: who(in: sentence.text),
                               byWhen: byWhen(in: sentence.text), quote: sentence.text)
        let checked = NoteGrounding.check([note], transcript: transcript)[0]
        return NoteCheck(note: checked.note, found: checked.found ?? sentence.found, problems: checked.problems)
    }

    /// Who, as said: a role ("the contractor", "L'entreprise"), the first one in the sentence; empty otherwise.
    static func who(in sentence: String) -> String {
        let straight = AnswerText.straight(sentence)
        guard let range = straight.range(of: "\\b((the|le|la) |l')?(" + roles.joined(separator: "|") + ")\\b",
                                         options: [.regularExpression, .caseInsensitive]) else { return "" }
        let start = straight.distance(from: straight.startIndex, to: range.lowerBound)
        let length = straight.distance(from: range.lowerBound, to: range.upperBound)
        let from = sentence.index(sentence.startIndex, offsetBy: start)
        return String(sentence[from..<sentence.index(from, offsetBy: length)])
    }

    /// By when, as said: the first date or time the number finder heard ("30 November", "vendredi", "two weeks"),
    /// or "next week" style words; never turned into a calendar date.
    static func byWhen(in sentence: String) -> String {
        if let heard = SpokenNumbers.find(sentence).first(where: { $0.kind == .date || $0.kind == .time }) {
            return heard.words
        }
        let pattern = "\\b(next|this) (week|month|year)\\b|\\b(today|tomorrow)\\b"
            + "|semaine prochaine|mois prochain|demain"
        return sentence.range(of: pattern, options: [.regularExpression, .caseInsensitive]).map { String(sentence[$0]) }
            ?? ""
    }

    private static let roles = ["contractor", "engineer", "ministry", "minister", "bank", "agency", "director",
                                "consultant", "supervisor", "utility", "government", "mayor", "office", "team",
                                "entreprise", "ingénieur", "ministère", "ministre", "banque", "agence", "directeur",
                                "mairie", "gouvernement"]
}
