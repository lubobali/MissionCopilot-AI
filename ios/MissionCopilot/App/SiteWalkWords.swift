import Foundation

/// What the site walk's screens say (#129), in the walk's language: English, or French with Français on
/// (found on the iPhone: the form switched but the page around it stayed English). The form's own words
/// come from the pack; the agreed actions are as the pack gives them.
struct SiteWalkWords: Sendable {
    var missions = MissionWords()
    var timeZone = TimeZone.current
    var language = "en"

    enum Key: CaseIterable, Sendable {
        case agreedActions, actionsAsGiven, checklist, overdue, note, pickFirst, yourAnswer, number, setDate, clear
        case recordLocation, recordAgain, finding, photosLater, stillToDo, finish, finishQuestion, finishWarning
        case finishConfirm, notYet, locked, agreedAction, required, notStarted, finishedOn, languageLabel
    }

    func text(_ key: Key) -> String {
        let pair = Self.table[key] ?? ("", "")
        return language == "fr" ? pair.french : pair.english
    }

    private static let table: [Key: (english: String, french: String)] = [
        .agreedActions: ("Agreed actions", "Actions convenues"),
        .actionsAsGiven: ("As the pack gives them.", "Telles que le pack les donne, en anglais."),
        .checklist: ("Site checklist", "Liste de contrôle du site"),
        .overdue: ("Overdue", "En retard"),
        .note: ("Note (optional)", "Note (facultative)"),
        .pickFirst: ("Pick what you saw first; then you can add a note.",
                     "Choisissez d'abord ce que vous avez vu, puis ajoutez une note si besoin."),
        .yourAnswer: ("Your answer", "Votre réponse"),
        .number: ("Number", "Nombre"),
        .setDate: ("Set the date", "Indiquer la date"),
        .clear: ("Clear", "Effacer"),
        .recordLocation: ("Record location", "Enregistrer la position"),
        .recordAgain: ("Record again", "Enregistrer à nouveau"),
        .finding: ("Finding your position", "Recherche de votre position"),
        .photosLater: ("Taking photos comes in the next update of the app.",
                       "La prise de photos arrive dans la prochaine mise à jour de l'application."),
        .stillToDo: ("Still to do before you can finish", "À faire avant de pouvoir terminer"),
        .finish: ("Finish the site walk", "Terminer la visite de site"),
        .finishQuestion: ("Finish the site walk?", "Terminer la visite de site ?"),
        .finishWarning: ("After this the answers cannot change.", "Ensuite, les réponses ne pourront plus changer."),
        .finishConfirm: ("Finish", "Terminer"),
        .notYet: ("Not yet", "Pas encore"),
        .locked: ("This walk is finished. Its answers are locked.",
                  "Cette visite est terminée. Ses réponses sont verrouillées."),
        .agreedAction: ("Agreed action: ", "Action convenue : "),
        .required: ("Required", "Obligatoire"),
        .notStarted: ("Not started", "Pas commencée"),
        .finishedOn: ("Finished", "Terminée le"),
        .languageLabel: ("Checklist language", "Langue de la liste")
    ]

    func progress(_ progress: SiteWalk.Progress, finished: FinishedWalk?) -> String {
        if let finished { return "\(text(.finishedOn)) \(day(finished.finishedAt))" }
        guard progress.answered > 0 || progress.actionsChecked > 0 else { return text(.notStarted) }
        if language == "fr" {
            return "\(progress.answered) question\(progress.answered > 1 ? "s" : "") sur \(progress.questions) · "
                + "\(progress.actionsChecked) action\(progress.actionsChecked > 1 ? "s" : "") sur \(progress.actions)"
        }
        return "\(progress.answered) of \(progress.questions) questions · "
            + "\(progress.actionsChecked) of \(progress.actions) actions"
    }

    func seen(_ seen: ActionSeen) -> String {
        guard language == "fr" else { return Self.seen(seen) }
        switch seen {
        case .done: return "Fait"
        case .inProgress: return "En cours"
        case .notStarted: return "Pas commencé"
        case .couldNotCheck: return "Impossible à vérifier"
        }
    }

    static func seen(_ seen: ActionSeen) -> String {
        switch seen {
        case .done: "Done"
        case .inProgress: "In progress"
        case .notStarted: "Not started"
        case .couldNotCheck: "Could not check"
        }
    }

    static func icon(_ seen: ActionSeen) -> String {
        switch seen {
        case .done: "checkmark.circle.fill"
        case .inProgress: "circle.lefthalf.filled"
        case .notStarted: "circle.dashed"
        case .couldNotCheck: "eye.slash"
        }
    }

    func due(_ action: AgreedActions.Action) -> String {
        // A deadline is a day, not a moment: shown as that day whatever the phone's time zone.
        let deadline = date(fromAnswer: action.deadline, in: .gmt).map { day($0, in: .gmt) } ?? action.deadline
        return "\(action.responsible) · \(language == "fr" ? "échéance" : "due") \(deadline)"
    }

    /// A date answer: the officer's own day, yyyy-MM-dd, as XLSForm wants it.
    func dateAnswer(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }

    /// The day a date answer names, at noon in the officer's time zone, or nil if it is not a date.
    func date(fromAnswer answer: String) -> Date? { date(fromAnswer: answer, in: timeZone) }

    private func date(fromAnswer answer: String, in zone: TimeZone) -> Date? {
        let parts = answer.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, answer.count == 10 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    private func day(_ date: Date, in zone: TimeZone? = nil) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: missions.locale)
        style.timeZone = zone ?? missions.timeZone
        return date.formatted(style)
    }

    static func place(_ place: Place, language: String = "en") -> String {
        let metres = max(1, Int(place.accuracy.rounded()))
        let within = language == "fr" ? "à \(metres) m près" : "within \(metres) m"
        return String(format: "%.5f, %.5f", place.latitude, place.longitude) + " · " + within
    }

    /// What still stops the finish, named as the walk shows it.
    static func missing(_ missing: SiteWalk.Missing, in walk: SiteWalk) -> String {
        switch missing {
        case .question(let name):
            walk.form.questions.first { $0.name == name }?.label.text(for: walk.language) ?? name
        case .action(let key):
            SiteWalkWords(language: walk.language).text(.agreedAction)
                + (walk.actions.actions.first { $0.key == key }?.action ?? "")
        }
    }
}
