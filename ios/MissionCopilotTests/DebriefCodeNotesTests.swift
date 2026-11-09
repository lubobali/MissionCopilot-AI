import Foundation
import Testing
@testable import MissionCopilot

/// Debrief notes by code (#152, decided A). Found in the Phase 6 proof: the model changed the words it quoted,
/// added words never said and invented a note. Measured on the Mac (issue #152): the same model labelled
/// sentences right 15 of 21 at best; code cue words 50 of 51, any sector. Now code splits the transcript into
/// the sentences that were said and labels each one decision, action, risk or none; a note is its sentence,
/// word for word. No model.
struct DebriefCodeNotesTests {
    typealias Kind = DebriefNote.Kind

    struct Case: CustomTestStringConvertible, Sendable {
        let sentence: String
        /// The right labels (nil: none); either is right when two are given.
        let kinds: Set<Kind?>
        var testDescription: String { sentence }
        init(_ sentence: String, _ kinds: Kind?...) { (self.sentence, self.kinds) = (sentence, Set(kinds)) }
    }

    /// The 51 sentences of the Mac probe (issue #152), answers written before each run: today's iPhone debrief,
    /// the bakeoff's T1 in English and French, 15 new ones, and 15 from other sectors.
    static let key: [Case] = [
        Case("Counter route visit, we met the contractor at the section 3 site.", nil),
        Case("The bridge works have not started.", .risk, nil),
        Case("The contractor says 40 workers are on the site and 12 kilometers of drains are cleaned.", nil),
        Case("They promised to start the bridge by 15th of December.", .action, .decision),
        Case("Action, the contractor sends a new work plan by 30 November action.", .action),
        Case("The rainy season may delay, the works by 2 months.", .risk),
        Case("ok so just met the deputy minister of transport, Mr. Okafor, and the road agency director.", nil),
        Case("they agreed to extend the contractor deadline to march 15 but only if the contractor shows a new work "
             + "plan in two weeks.", .decision),
        Case("the contractor is about 3 months late, they say the rains and fuel shortages.", .risk),
        Case("section 3 bridge still not started.", .risk, nil),
        Case("the minister asked the bank to send an engineer in january.", .action),
        Case("also the payments look high compared to what we saw on the road, need to check invoice 14.",
             .risk, .action),
        Case("procurement for the second package is stuck, waiting for the no-objection from our side.", .risk),
        Case("I promised to send the no-objection by friday.", .action),
        Case("Réunion avec le vice-ministre des transports, M. Okafor, et le directeur de l'agence routière.", nil),
        Case("Ils acceptent de prolonger le délai de l'entreprise jusqu'au 15 mars, à condition qu'elle présente un "
             + "nouveau plan de travail dans deux semaines.", .decision),
        Case("L'entreprise a environ trois mois de retard à cause des pluies et des pénuries de carburant.", .risk),
        Case("Le pont de la section 3 n'est pas commencé.", .risk, nil),
        Case("Le ministre demande à la Banque d'envoyer un ingénieur en janvier.", .action),
        Case("Les paiements semblent élevés par rapport aux travaux réalisés, il faut vérifier la facture 14.",
             .risk, .action),
        Case("We agreed that the ministry will pay the contractor within 30 days.", .decision, .action),
        Case("The road agency will send the new drawings by Monday.", .action),
        Case("There is a risk that the bridge is not finished before the rains.", .risk),
        Case("Weather was good today.", nil),
        Case("Need to follow up with the finance team on invoice 9.", .action),
        Case("The supervision engineer was not on site.", .risk, nil),
        Case("It was decided to stop payments until the audit.", .decision),
        Case("The contractor asked for more time.", nil, .risk),
        Case("Risk: fuel prices went up by 20 percent.", .risk),
        Case("Je vais envoyer le rapport vendredi.", .action),
        Case("Il a été décidé de suspendre les paiements.", .decision),
        Case("Les travaux sont en retard de deux mois.", .risk),
        Case("Nous avons visité le chantier le matin.", nil),
        Case("Le ministère doit nommer un nouvel ingénieur.", .action),
        Case("Decision: the second package goes to tender in March.", .decision),
        Case("The clinic ran out of malaria test kits last month.", .risk, nil),
        Case("The district health office will hire two more nurses by June.", .action),
        Case("We agreed to move the vaccination campaign to April.", .decision),
        Case("Teachers have not been paid for three months.", .risk, nil),
        Case("The ministry must deliver the textbooks before the school year starts.", .action),
        Case("Classrooms in the north are overcrowded, a real risk for learning.", .risk),
        Case("Action, the water utility repairs the broken pump this week.", .action),
        Case("The borehole drilling is delayed because of the rains.", .risk),
        Case("It was decided to add solar panels to the health centers.", .decision),
        Case("We visited three schools and one hospital.", nil),
        Case("Le versement des allocations est bloqué depuis mars.", .risk),
        Case("La mairie doit publier la liste des bénéficiaires.", .action),
        Case("Il a été convenu de réviser les critères d'éligibilité.", .decision),
        Case("Risque : le générateur n'a plus de carburant.", .risk),
        Case("Nous avons rencontré le directeur de l'hôpital.", nil)
    ]

    @Test(arguments: key)
    func theAnswerKey(item: Case) {
        let kind = NoteCues.kind(of: item.sentence)
        #expect(item.kinds.contains(kind), "\(String(describing: kind))")
    }

    /// The probe's one miss stays a sentence for the officer to tag: no cue word, so no label.
    @Test func aSentenceWithNoCueWordIsLeftForTheOfficer() {
        #expect(NoteCues.kind(of: "The engineer checks the road quality next week.") == nil)
    }

    /// Universal: the words say how people speak about decisions, tasks and problems, never a mission's topic.
    @Test func theCueWordsHoldNoMissionWords() {
        let topics = ["road", "bridge", "km", "invoice", "contract", "payment", "school", "clinic", "health", "water",
                      "kandor", "route", "pont", "facture", "paiement", "école", "eau"]
        let words = NoteCues.languages.flatMap { $0.spoken.map(\.1) + $0.cues.map(\.1) }.joined(separator: " ")
        #expect(!words.isEmpty)
        for topic in topics { #expect(!words.lowercased().contains(topic), "\(topic)") }
    }

    /// The officer's spoken label comes first, whatever else the sentence says.
    @Test func theOfficersSpokenLabelComesFirst() {
        #expect(NoteCues.kind(of: "Risk, the contractor will be late.") == .risk)
        #expect(NoteCues.kind(of: "Decision: we will stop the works.") == .decision)
        #expect(NoteCues.kind(of: "À faire : appeler le ministère.") == .action)
    }

    @Test func sentencesKeepTitlesTogetherAndTheirPlace() {
        let transcript = "Met Mr. Okafor and Dr. Ali today. They agreed!  Is the bridge late? M. Diallo doit appeler."

        let sentences = DebriefSentences.split(transcript)

        #expect(sentences.map(\.text) == ["Met Mr. Okafor and Dr. Ali today.", "They agreed!", "Is the bridge late?",
                                          "M. Diallo doit appeler."])
        for sentence in sentences {
            let start = transcript.index(transcript.startIndex, offsetBy: sentence.found.offset)
            let end = transcript.index(start, offsetBy: sentence.found.length)
            #expect(String(transcript[start..<end]) == sentence.text)
        }
    }

    @Test func atMostFortySentences() {
        let long = (1...60).map { "Sentence number \($0) is here." }.joined(separator: " ")
        #expect(DebriefSentences.split(long).count == DebriefSentences.maxSentences)
        #expect(DebriefSentences.maxSentences == 40)
        #expect(DebriefSentences.split("  \n ").isEmpty)
    }

    /// Today's iPhone debrief (Nov 8): the notes are the sentences that were said, word for word, with who and
    /// by when found by code; every one passes the grounding check; the rest wait to be tagged.
    @Test func notesAreTheSentencesWordForWord() throws {
        let transcript = "Counter route visit, we met the contractor at the section 3 site. The bridge works have not "
            + "started. They promised to start the bridge by 15th of December. Action, the contractor sends a new "
            + "work plan by 30 November action. The engineer checks the road quality next week. The rainy season "
            + "may delay, the works by 2 months."

        let drafted = CodeNotes.draft(transcript)

        #expect(drafted.notes.map(\.note.kind) == [.action, .action, .risk])
        #expect(drafted.notes.allSatisfy { $0.problems.isEmpty && $0.found != nil })
        #expect(drafted.notes.allSatisfy { $0.note.text == $0.note.quote })
        let plan = drafted.notes[1].note
        #expect(plan.text == "Action, the contractor sends a new work plan by 30 November action.")
        #expect(plan.who == "the contractor")
        #expect(plan.byWhen == "30 November")
        #expect(drafted.untagged.map(\.text) == ["Counter route visit, we met the contractor at the section 3 site.",
                                                 "The bridge works have not started.",
                                                 "The engineer checks the road quality next week."])
    }

    /// Every labelled sentence of the answer key passes the grounding check by construction.
    @Test func everyNoteOfTheKeyPassesGrounding() {
        let transcript = Self.key.map(\.sentence).joined(separator: " ")

        let drafted = CodeNotes.draft(transcript)

        #expect(drafted.notes.count + drafted.untagged.count == DebriefSentences.split(transcript).count)
        #expect(drafted.notes.filter { !$0.problems.isEmpty }.map(\.note.text) == [])
    }

    @Test func curlyApostrophesAndFrenchWhoAndWhen() throws {
        let drafted = CodeNotes.draft("L\u{2019}entreprise doit livrer le pont d\u{2019}ici vendredi.")

        let note = try #require(drafted.notes.first?.note)
        #expect(note.kind == .action)
        #expect(note.who == "L\u{2019}entreprise")
        #expect(note.byWhen == "vendredi")
        #expect(drafted.notes.first?.problems == [])
    }
}
