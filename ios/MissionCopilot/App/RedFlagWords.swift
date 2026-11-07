import Foundation

/// The red flags in words (#134), English or French: each result as one sentence built from its own
/// computed value, its threshold, its rule and source, and where each input came from. The words never
/// add a judgement the rule did not make.
struct RedFlagWords: Sendable {
    let rules: RedFlagRules
    var language = "en"

    private var french: Bool { language == "fr" }

    enum Key: CaseIterable, Sendable {
        case redFlags, flag, clear, notChecked, computedFrom, live, stored, plainCode, finishedBefore
    }

    func text(_ key: Key) -> String {
        let pair = Self.table[key] ?? ("", "")
        return french ? pair.french : pair.english
    }

    private static let table: [Key: (english: String, french: String)] = [
        .redFlags: ("Red flags", "Alertes"),
        .flag: ("Flag", "Alerte"),
        .clear: ("Clear", "Sans alerte"),
        .notChecked: ("Not checked", "Non vérifiée"),
        .computedFrom: ("Computed from", "Calculé à partir de"),
        .live: ("Live: these change as the walk goes.", "En direct : elles changent au fil de la visite."),
        .stored: ("Stored when the walk was finished.", "Enregistrées à la fin de la visite."),
        .finishedBefore: ("This walk was finished before this version of the app checked red flags, so none "
                          + "were stored.",
                          "Cette visite a été terminée avant que cette version de l'application vérifie les alertes : "
                          + "aucune n'a été enregistrée."),
        .plainCode: ("Checked by fixed, cited rules in plain code, never by the AI. Each one can be computed again "
                     + "from the inputs it names.",
                     "Vérifiées par des règles fixes et citées, en code simple, jamais par l'IA. Chacune peut être "
                     + "recalculée à partir des données qu'elle cite.")
    ]

    // MARK: counts

    func summary(_ results: [RedFlagResult]) -> String {
        guard !results.isEmpty else { return french ? "Aucune enregistrée" : "None stored" }
        let flags = results.filter { $0.outcome == .flag }.count
        let clear = results.filter { $0.outcome == .clear }.count
        let open = results.count - flags - clear
        let parts = [
            flags > 0 ? count(flags, english: ("flag", "flags"), french: ("alerte", "alertes")) : nil,
            clear > 0 ? (french ? "\(clear) sans alerte" : "\(clear) clear") : nil,
            open > 0 ? count(open, english: ("not checked", "not checked"),
                             french: ("non vérifiée", "non vérifiées")) : nil
        ]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    private func count(_ value: Int, english: (one: String, many: String), french words: (one: String, many: String))
        -> String {
        let pair = french ? words : english
        return "\(value) " + (value == 1 ? pair.one : pair.many)
    }

    // MARK: one result

    func title(_ result: RedFlagResult) -> String {
        rules[result.rule.id]?.title.text(language) ?? result.rule.id
    }

    func source(_ result: RedFlagResult) -> String {
        "\(result.rule.id) v\(result.rule.version)" + (rules[result.rule.id].map { " · \($0.source)" } ?? "")
    }

    /// One sentence for a result; a result from a scanned invoice says so first (#138).
    func sentence(_ result: RedFlagResult) -> String {
        let said = plainSentence(result)
        guard let invoice = result.subject, invoice.hasPrefix(Self.scannedPrefix), let first = said.first else {
            return said
        }
        let number = invoice.dropFirst(Self.scannedPrefix.count)
        return (french ? "Facture scannée \(number) : " : "Scanned invoice \(number): ") + first.lowercased()
            + said.dropFirst()
    }

    private static let scannedPrefix = "Scanned invoice "

    private func plainSentence(_ result: RedFlagResult) -> String {
        if case .notChecked(let why) = result.outcome { return reason(why) }
        let value = number(result.computed ?? 0)
        let flagged = result.outcome == .flag
        switch result.rule.id {
        case "R068": return french ? "\(value) % du montant du marché payé." : "Paid \(value)% of the contract value."
        case "R067": return late(result.subject ?? "", value, flagged: flagged)
        case "MC-01": return ahead(result.computed ?? 0)
        case "MC-02": return invoice(result.subject ?? "", value, flagged: flagged)
        case "MC-04": return photo(result.subject ?? "", value, flagged: flagged)
        default: return "\(title(result)): \(value)"
        }
    }

    private func late(_ milestone: String, _ days: String, flagged: Bool) -> String {
        guard flagged else { return french ? "Aucun jalon en retard." : "No milestone is late." }
        return french ? "Le jalon \(milestone) a \(days) jours de retard et n'est pas atteint."
            : "Milestone \(milestone) is \(days) days late and not met."
    }

    private func ahead(_ points: Double) -> String {
        let value = number(abs(points))
        if points < 0 {
            return french ? "Les travaux réalisés ont \(value) points d'avance sur les paiements."
                : "The work built is \(value) points ahead of payments."
        }
        return french ? "Les paiements ont \(value) points d'avance sur les travaux réalisés."
            : "Payments are \(value) points ahead of the work built."
    }

    private func invoice(_ repeated: String, _ times: String, flagged: Bool) -> String {
        guard flagged else {
            return french ? "Aucune référence ni montant de facture n'apparaît deux fois."
                : "No invoice reference or amount appears twice."
        }
        return french ? "\(repeated) apparaît \(times) fois." : "\(repeated) appears \(times) times."
    }

    private func photo(_ subject: String, _ times: String, flagged: Bool) -> String {
        guard flagged else {
            return french ? "Aucune photo n'est utilisée deux fois sur ce téléphone."
                : "No photo is used twice on this phone."
        }
        let photo = subject.prefix(1).uppercased() + subject.dropFirst()
        return french ? "\(photo) apparaît \(times) fois sur ce téléphone."
            : "\(photo) appears \(times) times on this phone."
    }

    func threshold(_ result: RedFlagResult) -> String {
        let value = number(result.threshold.value)
        switch result.threshold.unit {
        case .percent: return french ? "Alerte au-dessus de \(value) %" : "Flags above \(value)%"
        case .days: return french ? "Alerte au-delà de \(value) jours de retard"
            : "Flags when more than \(value) days late"
        case .points: return french ? "Alerte au-dessus de \(value) points" : "Flags above \(value) points"
        case .count:
            return french ? "Alerte si vu plus de \(value) fois"
                : "Flags when seen more than \(value) time\(result.threshold.value == 1 ? "" : "s")"
        }
    }

    func reason(_ why: RedFlagResult.NotChecked) -> String {
        switch why {
        case .noContracts: french ? "Le pack ne contient aucun marché." : "The pack has no contracts."
        case .noMilestones: french ? "Le pack ne contient aucun jalon." : "The pack has no milestones."
        case .zeroValue: french ? "Le montant du marché est zéro." : "The contract value is zero."
        case .needsScan: french
            ? "Il faut les quantités facturées et mesurées, qui viendront avec le scan des documents."
            : "Needs the invoiced and measured quantities, which come with the document scan."
        case .needsPhotos: french ? "Aucune photo prise pour l'instant." : "No photo taken yet."
        case .unknownRule: french ? "Cette version de l'application ne sait pas calculer cette règle."
            : "This version of the app cannot compute this rule."
        }
    }

    func skipped(_ result: RedFlagResult) -> String? {
        let missions = result.skippedMissions
        guard missions > 0 else { return nil }
        if french {
            return missions == 1 ? "1 mission détruite n'a pas pu être lue."
                : "\(missions) missions détruites n'ont pas pu être lues."
        }
        return "\(missions) shredded mission\(missions == 1 ? "" : "s") could not be read."
    }

    func input(_ input: RedFlagResult.Input, mission: String) -> String {
        switch input {
        case .pack(let citation):
            return "\(citation.path.split(separator: "/").last.map(String.init) ?? citation.path) · \(citation.pointer)"
        case .evidence(let photo) where photo.mission == mission:
            return french ? "Photo \(photo.seq), cette mission" : "Photo \(photo.seq), this mission"
        case .evidence(let photo):
            return french ? "Photo \(photo.seq), une autre mission sur ce téléphone"
                : "Photo \(photo.seq), another mission on this phone"
        case .fact(let fact):
            return french ? "Facture scannée · \(Self.frenchFields[fact.name] ?? fact.name)"
                : "Scanned invoice · \(InvoiceFacts.name(fact.name))"
        }
    }

    /// The fields a red flag can cite, in French (#138).
    static let frenchFields = ["cumulativePaid": "Payé à ce jour", "contractValue": "Montant du marché",
                               "kmCompleted": "Route construite", "kmTotal": "Longueur de la route"]

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1))
            .locale(Locale(identifier: french ? "fr_FR" : "en_US")))
    }
}
