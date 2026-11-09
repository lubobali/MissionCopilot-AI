import Foundation

/// The common questions answered by code (#145, steps 6.7.12 to 6.7.14): the app knows the pack's sections,
/// so it recognizes a payment by its invoice number, the total paid, the last payment, what is not done or
/// next, whether something started or is done, what was promised, the contract, the risk rating and red
/// flags, in English and French, and writes the answer from the records (AnswerLines). When the walk and the
/// bank disagree, both are said. Anything else returns nil and goes to the chooser (6.7.15).
struct CodeAnswers: Sendable {
    static let maxLines = 5

    let sources: [MissionSource]

    func direct(_ question: String) -> [CodeLine]? {
        let asked = AnswerText.straight(question).lowercased()
        let language = AnswerLanguage(question: question)
        let write = { (records: [MissionSource]) in
            records.map { AnswerLines.line($0, question: question, language: language) }
        }
        let lines: [CodeLine]
        if let number = Self.invoice(in: asked) {
            lines = write(payments.filter { reference(of: $0) == number })
        } else if has(asked, Self.flagWords) {
            let twice = has(asked, "twice|duplicat|deux fois")
            lines = write(flags.filter { !twice || ($0.title + $0.text).lowercased().contains("twice") })
        } else if has(asked, Self.lastWords), has(asked, Self.paidWords) {
            lines = write(Array(payments.max { date(of: $0) < date(of: $1) }.map { [$0] } ?? []))
        } else if has(asked, Self.howMuchWords), has(asked, Self.paidWords) {
            lines = write(sources.filter { $0.id.hasSuffix("#paid") })
        } else if has(asked, Self.openWords) {
            lines = write(open)
        } else if has(asked, Self.doneWords) {
            lines = write(done)
        } else if has(asked, Self.statusWords) {
            lines = status(question, language: language)
        } else if has(asked, Self.promiseWords) {
            lines = write(actions)
        } else if has(asked, Self.contractWords) {
            lines = write(sources.filter { $0.kind == .pack && $0.id.contains(/#\/contracts\/\d+$/) })
        } else if has(asked, Self.riskWords) {
            let ratings = sources.filter { $0.id.hasPrefix("pack:sections/ratings.json#/") }
            let overall = ratings.filter { $0.id.hasSuffix("/overallRisk") }
            lines = write(has(asked, "overall|global") && !overall.isEmpty ? overall : ratings)
        } else {
            return nil
        }
        return lines.isEmpty ? nil : Array(lines.prefix(Self.maxLines))
    }

    // MARK: records

    private var payments: [MissionSource] {
        sources.filter { $0.kind == .pack && $0.id.contains(/\/payments\/\d+$/) }
    }

    private var actions: [MissionSource] {
        sources.filter { $0.kind == .pack && $0.id.contains(/#\/actions\/\d+$/) }
    }

    private var milestones: [MissionSource] {
        sources.filter { $0.kind == .pack && $0.id.contains(/#\/milestones\/\d+$/) }
    }

    private var flags: [MissionSource] { sources.filter { $0.kind == .redFlag } }

    /// Agreed actions not completed and milestones not met, in the pack's order.
    private var open: [MissionSource] {
        actions.filter { !field("status", $0).lowercased().contains("completed") }
            + milestones.filter { !["met", "complete"].contains(field("status", $0).lowercased()) }
    }

    /// Milestones met, completed actions, and what the walk saw done.
    private var done: [MissionSource] {
        milestones.filter { ["met", "complete"].contains(field("status", $0).lowercased()) }
            + actions.filter { field("status", $0).lowercased().contains("completed") }
            + sources.filter { $0.kind == .walkAnswer && $0.text.lowercased().contains("seen: done") }
    }

    /// "Was the Section 3 bridge started?": the bank's actions and milestones and the walk's answers about the
    /// same thing; when the walk says done and the bank says not, a first line says they disagree.
    private func status(_ question: String, language: AnswerLanguage) -> [CodeLine] {
        // A lone letter ("s" of "what's") is not a topic: it matched "contractor's" (found on the iPhone).
        let topic = Set(MissionSearch.expanded(question)).subtracting(Self.statusStems)
            .filter { $0.count > 1 || $0.allSatisfy(\.isNumber) }
        guard !topic.isEmpty else { return [] }
        let about = { (source: MissionSource) -> Bool in
            let shared = topic.intersection(MissionSearch.expanded(source.title + " " + source.text)).count
            return shared >= max(1, (topic.count + 1) / 2)
        }
        let bank = (actions + milestones).filter(about)
        let walk = sources.filter { $0.kind == .walkAnswer && about($0) }
        guard !bank.isEmpty || !walk.isEmpty else { return [] }
        let notDone = ["not started", "notmet", "scheduled"]
        let bankNotDone = bank.contains { notDone.contains(field("status", $0).lowercased()) }
        let walkDone = walk.contains { walked in
            walked.text.lowercased().hasSuffix("yes") || walked.text.lowercased().contains("seen: done")
        }
        let lines = (bank + walk).map { AnswerLines.line($0, question: question, language: language) }
        guard bankNotDone, walkDone else { return lines }
        let disagree = language.pick("The bank's records and your site walk disagree.",
                                     "Les registres de la banque et votre visite sont en désaccord.")
        return [CodeLine(text: disagree, sources: (bank + walk).map(\.id))] + lines
    }

    private func field(_ name: String, _ source: MissionSource) -> String {
        source.text.split(separator: "\n").first { $0.hasPrefix(name + ": ") }
            .map { String($0.dropFirst(name.count + 2)) } ?? ""
    }

    private func reference(of payment: MissionSource) -> String? {
        field("reference", payment).firstMatch(of: /(\d+)/).map { String($0.1) }
    }

    private func date(of payment: MissionSource) -> String { field("date", payment) }

    // MARK: words (English and French)

    private func has(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// The number after "invoice", "facture" or "factura" ("invoice 14", "facture n° 14").
    static func invoice(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: invoiceNumber),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 2), in: text) else { return nil }
        return String(text[range])
    }

    private static let invoiceNumber = "(invoice|facture|factura)\\s*(?:n[o°]\\.?\\s*|#\\s*)?(\\d+)"
    private static let flagWords = "red flag|flags?\\b|signal|twice|duplicat|deux fois"
    private static let lastWords = "\\b(last|latest|most recent|dernier|dernière)\\b"
    private static let paidWords = "paid|pay|disburs|payé|paye|versé|verse"
    private static let howMuchWords = "how much|total|to date|so far|combien|à ce jour|au total"
    private static let openWords = "not (yet )?done|still open|what is open|open items|pending|outstanding|"
        + "what('s| is) next|next steps?|left to do|remaining|overdue|pas (encore )?fait|reste à faire|"
        + "prochaine? étape|en retard"
    private static let doneWords = "what('s| is| has been| was) (already )?(done|completed?|finished)|"
        + "qu'est-ce qui est (fait|terminé)|ce qui est fait"
    private static let statusWords = "start|begun|began|finish|complet|done|commenc|démarr|achev|termin|fini"
    private static let promiseWords = "promis|commit|agreed|engag|convenu"
    private static let contractWords = "contract value|value of the contract|contract amount|montant du contrat|"
        + "who is the contractor|supplier|fournisseur"
    private static let riskWords = "risk|rating|risque|notation"
    private static let statusStems: Set = ["start", "begun", "began", "finish", "complet", "done", "commenc", "démarr",
                                           "achev", "termin", "fini", "work", "don"]
}
