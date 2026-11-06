import Foundation
import Testing
@testable import MissionCopilot

/// What the site walk's screens say (#129, step 6.2.5), in plain words, with the phone's dates.
struct SiteWalkWordsTests {
    let words = SiteWalkWords(missions: MissionWordsTests.words, timeZone: .gmt)

    @Test func progressSaysWhereTheWalkIs() {
        let none = SiteWalk.Progress(answered: 0, questions: 7, actionsChecked: 0, actions: 3)
        let some = SiteWalk.Progress(answered: 3, questions: 7, actionsChecked: 1, actions: 3)

        #expect(words.progress(none, finished: nil) == "Not started")
        #expect(words.progress(some, finished: nil) == "3 of 7 questions · 1 of 3 actions")
        let done = FinishedWalk(version: "2026110401", finishedAt: MissionWordsTests.nov3)
        let day = MissionWordsTests.words.day(MissionWordsTests.nov3)
        #expect(words.progress(some, finished: done) == "Finished \(day)")
    }

    @Test func everyWayAnActionWasSeenHasItsOwnWordsAndIcon() {
        let all = ActionSeen.allCases

        #expect(all.map(SiteWalkWords.seen) == ["Done", "In progress", "Not started", "Could not check"])
        #expect(Set(all.map(SiteWalkWords.icon)).count == all.count)
    }

    @Test func anActionSaysWhoAndByWhen() throws {
        let bridge = try AgreedActions.read(AgreedActionsTests.section).actions[0]

        #expect(words.due(bridge) == "Contractor · due Jul 31, 2026")
    }

    @Test func aDateAnswerIsTheDayTheFormWants() throws {
        // XLSForm dates are yyyy-MM-dd, the day in the officer's own time zone.
        let late = try #require(ISO8601DateFormatter().date(from: "2026-08-01T04:30:00Z"))
        let chicago = SiteWalkWords(missions: MissionWordsTests.words,
                                    timeZone: try #require(TimeZone(identifier: "America/Chicago")))

        #expect(chicago.dateAnswer(late) == "2026-07-31")
        #expect(words.dateAnswer(late) == "2026-08-01")
        #expect(words.date(fromAnswer: "2026-08-01").map(words.dateAnswer) == "2026-08-01")
        #expect(words.date(fromAnswer: "August 1") == nil)
    }

    @Test func aRecordedPlaceShowsWhereAndHowSure() {
        #expect(SiteWalkWords.place(PlaceTests.kmEighteen) == "1.06000, 1.05000 · within 4 m")
        #expect(SiteWalkWords.place(Place(latitude: 1, longitude: 2, altitude: 0, accuracy: 0.4))
                == "1.00000, 2.00000 · within 1 m")
    }

    @Test func whatIsMissingIsNamedInTheWalksLanguage() throws {
        let (form, actions) = try SiteWalkTests.kandor()
        let english = try SiteWalkTests.walk()
        let french = try SiteWalkTests.walk(language: "fr")

        #expect(SiteWalkWords.missing(.question("road_width_m"), in: english)
                == "Measured carriageway width at the sample point (m)")
        #expect(SiteWalkWords.missing(.question("road_width_m"), in: french)
                == "Largeur de chaussée mesurée au point d'échantillonnage (m)")
        #expect(SiteWalkWords.missing(.action(actions.actions[1].key), in: english)
                == "Agreed action: Submit a revised work plan")
        #expect(form.formId == "kandor_road_check")
    }
}

/// With Français on, the whole walk speaks French, not only the form (found on the iPhone, #129).
struct SiteWalkFrenchTests {
    let french = SiteWalkWords(missions: MissionWords(locale: Locale(identifier: "fr_FR"), timeZone: .gmt),
                               timeZone: .gmt, language: "fr")

    @Test func theWalksOwnWordsAreFrench() {
        #expect(french.text(.agreedActions) == "Actions convenues")
        #expect(french.text(.checklist) == "Liste de contrôle du site")
        #expect(french.text(.finish) == "Terminer la visite de site")
        #expect(french.text(.stillToDo) == "À faire avant de pouvoir terminer")
        #expect(french.text(.note) == "Note (facultative)")
        #expect(french.text(.recordLocation) == "Enregistrer la position")
        #expect(ActionSeen.allCases.map(french.seen)
                == ["Fait", "En cours", "Pas commencé", "Impossible à vérifier"])
    }

    @Test func everyWordHasBothLanguages() {
        let english = SiteWalkWords(timeZone: .gmt)
        for key in SiteWalkWords.Key.allCases {
            #expect(!english.text(key).isEmpty && !french.text(key).isEmpty)
            #expect(english.text(key) != french.text(key), "\(key) is the same in both")
        }
    }

    @Test func progressAndDatesAreFrench() throws {
        let some = SiteWalk.Progress(answered: 3, questions: 7, actionsChecked: 1, actions: 3)
        let bridge = try AgreedActions.read(AgreedActionsTests.section).actions[0]

        #expect(french.progress(some, finished: nil) == "3 questions sur 7 · 1 action sur 3")
        let one = SiteWalk.Progress(answered: 1, questions: 7, actionsChecked: 2, actions: 3)
        #expect(french.progress(one, finished: nil) == "1 question sur 7 · 2 actions sur 3")
        #expect(french.progress(SiteWalk.Progress(answered: 0, questions: 7, actionsChecked: 0, actions: 3),
                                finished: nil) == "Pas commencée")
        #expect(french.due(bridge) == "Contractor · échéance 31 juil. 2026")
    }

    @Test func theAgreedActionsSayTheyAreInThePacksLanguage() {
        #expect(french.text(.actionsAsGiven) == "Telles que le pack les donne, en anglais.")
    }
}

/// The walk's messages follow its language too.
@MainActor
struct SiteWalkFrenchMessagesTests {
    @Test func placeProblemsAndThePlaceItselfAreFrench() {
        #expect(PlaceReading.noFix.problem(app: "MC Staging", language: "fr")
                == "Pas encore de position. Placez-vous sous un ciel dégagé, patientez, puis réessayez.")
        #expect(PlaceReading.denied.problem(app: "MC Staging", language: "fr")
                == "La localisation est désactivée pour MC Staging. Activez-la dans Réglages, puis réessayez.")
        #expect(PlaceReading.offForPhone.problem(app: "MC Staging", language: "fr")?.isEmpty == false)
        #expect(PlaceReading.restricted.problem(app: "MC Staging", language: "fr")?.isEmpty == false)
        #expect(SiteWalkWords.place(PlaceTests.kmEighteen, language: "fr") == "1.06000, 1.05000 · à 4 m près")
    }

    @Test func aFinishedWalkSaysWhyInFrench() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = MissionStore(store: try EncryptedStore.open(at: file, key: DataKey.random()),
                                 vault: SoftwareKeyVault())
        try store.create(mission: "kandor-roads", title: "Kandor rural roads")
        let (form, actions) = try SiteWalkTests.kandor()
        let walk = try SiteWalkModel(form: form, actions: actions, mission: "kandor-roads", store: store,
                                     now: { SiteWalkTests.walkDay }, timeZone: .gmt, preferred: ["fr-FR"])
        let (answers, checks) = try SiteWalkTests.complete()
        for (question, value) in answers { walk.answer(value, to: question) }
        for (key, check) in checks { walk.check(check.seen, note: nil, action: key) }
        #expect(walk.finish())

        walk.answer("7.0", to: "road_width_m")

        #expect(walk.problem == "Cette visite est terminée. Ses réponses ne peuvent plus changer.")
    }
}

/// The walk's screens' own small rules (#129, step 6.2.5).
@MainActor
struct SiteWalkScreenRulesTests {
    @Test func tappingAChoiceTurnsItOnOrOffAndKeepsTheFormsOrder() throws {
        let (form, _) = try SiteWalkTests.kandor()
        let defects = try #require(form.choices["defects"])

        #expect(QuestionCard.toggled("standing_water", in: [], order: defects) == "standing_water")
        #expect(QuestionCard.toggled("potholes", in: ["standing_water"], order: defects)
                == "potholes standing_water")
        #expect(QuestionCard.toggled("potholes", in: ["potholes", "standing_water"], order: defects)
                == "standing_water")
        #expect(QuestionCard.toggled("none", in: ["none"], order: defects) == "")
        // The form lists potholes before edge breaks: the answer follows the form, not the alphabet.
        #expect(QuestionCard.toggled("edge_breaks", in: ["potholes"], order: defects) == "potholes edge_breaks")
    }

    @Test func aMissionWithoutItsPackHasNoSiteWalkCard() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = MissionStore(store: try EncryptedStore.open(at: file, key: DataKey.random()),
                                 vault: SoftwareKeyVault())
        let row = MissionRow(id: "kandor-bridges", title: "Kandor Bridges", status: .notDownloaded(available: true),
                             pack: nil, updateAvailable: false, canDownload: true, note: nil)

        #expect(MissionWorkspaceScreen.walkProgress(row, store: store) == nil)
        #expect(MissionWorkspaceScreen.walkProgress(ScreenshotTests.sampleRows[0], store: nil) == nil)
    }
}

/// What a typed answer saves (#129, found on the iPhone: the number pad kept the dot out and stayed open).
struct TypedAnswerTests {
    @Test func aDecimalSavesWithThePointTheFormWantsWhicheverSeparatorWasTyped() {
        #expect(TypedAnswer.saved("6.2", kind: .decimal) == "6.2")
        #expect(TypedAnswer.saved("6,2", kind: .decimal) == "6.2")
        #expect(TypedAnswer.saved(" 6.2 ", kind: .decimal) == "6.2")
    }

    @Test func textKeepsItsCommasAndLosesOnlyOuterSpaces() {
        #expect(TypedAnswer.saved(" KN-0042 ", kind: .text) == "KN-0042")
        #expect(TypedAnswer.saved("a, b", kind: .text) == "a, b")
    }
}
