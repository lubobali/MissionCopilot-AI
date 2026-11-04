import Foundation
import Testing
@testable import MissionCopilot

/// The site checklist read into questions and groups (#93): both ways KoBo writes a select, groups nested
/// up to 3 deep, English and French, and every form a person could not fill refused with the row to fix.
/// A row is the question's place in the survey, counting from 1 (the sheet's row less its header row).
struct ChecklistFormTests {
    static var yesNo: [[String: Any]] {
        [["list_name": "yes_no", "name": "yes", "label": "Yes"], ["list_name": "yes_no", "name": "no", "label": "No"]]
    }

    static func form(_ survey: [[String: Any]], choices: [[String: Any]] = yesNo) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "settings": ["form_id": "check", "form_title": "Check", "version": "1"], "survey": survey,
            "choices": choices
        ])
    }

    static func question(_ name: String, _ type: String = "text", _ extra: [String: Any] = [:]) -> [String: Any] {
        ["type": type, "name": name, "label": name.capitalized].merging(extra) { $1 }
    }

    static var end: [String: Any] { ["type": "end_group"] }

    // The Kandor checklist

    @Test(.needsRepoFiles) func theKandorChecklistReadsWithItsBridgeGroupInEnglishAndFrench() throws {
        let data = try #require(PackSectionsTests.files["forms/road-checklist.json"])

        let form = try ChecklistForm.read(data)

        #expect(form.title == "Site supervision checklist, Package 1 road" && form.version == "2026110401")
        #expect(form.questions.map(\.name) == ["bridge_started", "road_width_m", "drainage_present", "defects",
                                                "board_ref", "piers_built", "bridge_work_started", "stand_note",
                                                "sample_point", "sample_photo"])
        #expect(form.questions.map(\.kind) == [.selectOne("yes_no"), .decimal, .selectOne("yes_no"),
                                                .selectMultiple("defects"), .text, .integer, .date, .note,
                                                .geopoint, .image])
        #expect(form.questions.map(\.required) == [true, true, true, true, false, true, false, false, true, false])
        let width = form.questions[1]
        #expect(width.constraint == ". > 0 and . < 20")
        #expect(width.constraintMessage?.english == "A road width is between 0 and 20 metres")
        #expect(width.hint?.english == "Tape across the paved surface, edge to edge")
        #expect(width.label.text(for: "fr") == "Largeur de chaussée mesurée au point d'échantillonnage (m)")
        guard case .group(let bridge)? = form.items.first(where: { if case .group = $0 { true } else { false } })
        else { Issue.record("no bridge group"); return }
        #expect(bridge.relevant == "${bridge_started} = 'yes'" && bridge.items.count == 2)
        #expect(form.choices["yes_no"]?.map(\.name) == ["yes", "no"] && form.choices["defects"]?.count == 4)
        #expect(form.hasFrench)
    }

    // What a form can hold

    @Test func bothWaysOfWritingASelectReadTheSame() throws {
        let joined = try ChecklistForm.read(Self.form([Self.question("ok", "select_multiple yes_no")]))
        let split = try ChecklistForm.read(Self.form([Self.question("ok", "select_multiple",
                                                                    ["select_from_list_name": "yes_no"])]))

        #expect(joined.questions == split.questions)
        #expect(joined.questions.first?.kind == .selectMultiple("yes_no"))
    }

    @Test func groupsNestAndKeepTheirOwnRelevant() throws {
        let form = try ChecklistForm.read(Self.form([
            Self.question("site", "begin_group", ["relevant": "${first} = 'yes'"]), Self.question("first"),
            Self.question("bridge", "begin_group"), Self.question("deck"), Self.end, Self.end, Self.question("last")
        ]))

        #expect(form.questions.map(\.name) == ["first", "deck", "last"])
        guard case .group(let site) = form.items.first, case .group(let bridge) = site.items.last else {
            Issue.record("not nested: \(form.items)")
            return
        }
        #expect(site.relevant == "${first} = 'yes'" && bridge.name == "bridge" && bridge.items.count == 1)
        #expect(form.items.count == 2)
    }

    @Test func requiredIsYesOrTrueAndAnythingElseIsNo() throws {
        let form = try ChecklistForm.read(Self.form([
            Self.question("one", "text", ["required": "yes"]), Self.question("two", "text", ["required": "true"]),
            Self.question("three", "text", ["required": true]), Self.question("four", "text", ["required": "no"]),
            Self.question("five", "text", ["required": false]), Self.question("six")
        ]))

        #expect(form.questions.map(\.required) == [true, true, true, false, false, false])
    }

    @Test func aFrenchPhoneSeesFrenchWhereTheFormHasItAndEnglishElsewhere() throws {
        let form = try ChecklistForm.read(Self.form([
            Self.question("width", "decimal", ["label::French (fr)": "Largeur", "hint": "Edge to edge"])
        ], choices: [["list_name": "yes_no", "name": "yes", "label": "Yes", "label::French (fr)": "Oui"]]))
        let width = try #require(form.questions.first)

        #expect(width.label.text(for: "fr") == "Largeur" && width.label.text(for: "en") == "Width")
        #expect(width.label.text(for: "de") == "Width")  // not one of the two: English
        #expect(width.hint?.text(for: "fr") == "Edge to edge")  // no French hint: English
        #expect(form.choices["yes_no"]?.first?.label.text(for: "fr") == "Oui")
        #expect(form.hasFrench)
    }

    @Test func aFormKnowsWhetherItHasFrenchEvenWhenOnlyAChoiceHasIt() throws {
        let english = try ChecklistForm.read(Self.form([Self.question("a", "select_one yes_no")]))
        let choiceOnly = try ChecklistForm.read(Self.form([Self.question("a", "select_one yes_no")], choices: [
            ["list_name": "yes_no", "name": "yes", "label": "Yes", "label::French (fr)": "Oui"]
        ]))

        #expect(!english.hasFrench && choiceOnly.hasFrench)
    }

    // Refused, with the row to fix

    /// A form that must be refused: what is wrong, its survey rows, and the problem with the row.
    struct Refusal {
        let what: String, survey: [[String: Any]], problem: ChecklistProblem
        init(_ what: String, _ survey: [[String: Any]], _ problem: ChecklistProblem) {
            (self.what, self.survey, self.problem) = (what, survey, problem)
        }
    }

    static var refusals: [Refusal] { [
        Refusal("an unknown type", [question("a"), question("b", "calculate")], .unknownType(row: 2, "calculate")),
        Refusal("two questions named the same", [question("a"), question("b"), question("a")],
                .duplicateName(row: 3, "a")),
        Refusal("a group named like a question", [question("a"), question("a", "begin_group"), question("b"), end],
         .duplicateName(row: 2, "a")),
        Refusal("a select with or_other (not read by the app)", [question("a", "select_one yes_no or_other")],
                .unknownType(row: 1, "select_one yes_no or_other")),
        Refusal("a group relevant naming no question",
                [question("g", "begin_group", ["relevant": "${gone} = 'yes'"]), question("a"), end],
                .unknownReference(row: 1, "gone")),
        Refusal("a select with no such list", [question("a", "select_one colours")], .noSuchList(row: 1, "colours")),
        Refusal("a select with no list", [question("a", "select_one")], .noList(row: 1)),
        Refusal("a select with two different lists",
                [question("a", "select_one yes_no", ["select_from_list_name": "other"])], .noList(row: 1)),
        Refusal("a group end with no start", [question("a"), end], .unbalancedGroup(row: 2)),
        Refusal("a group never ended", [question("g", "begin_group"), question("a")], .unbalancedGroup(row: 1)),
        Refusal("groups four deep", [question("g1", "begin_group"), question("g2", "begin_group"),
                              question("g3", "begin_group"), question("g4", "begin_group"), question("a"),
                              end, end, end, end], .tooDeep(row: 4)),
        Refusal("a relevant naming no question", [question("a"), question("b", "text", ["relevant": "${nope} = 1"])],
         .unknownReference(row: 2, "nope")),
        Refusal("a constraint naming no question", [question("a", "integer", ["constraint": ". < ${max}"])],
         .unknownReference(row: 1, "max")),
        Refusal("a default naming no question", [question("a", "text", ["default": "${who}"])],
         .unknownReference(row: 1, "who"))
    ] }

    @Test(arguments: refusals.indices)
    func aFormNobodyCouldFillIsRefusedWithTheRow(index: Int) throws {
        let refusal = Self.refusals[index]

        #expect(throws: refusal.problem, "\(refusal.what)") { try ChecklistForm.read(Self.form(refusal.survey)) }
    }

    @Test func aListWithTheSameChoiceTwiceIsRefused() throws {
        let twice = Self.yesNo + [["list_name": "yes_no", "name": "yes", "label": "Yes again"]]

        #expect(throws: ChecklistProblem.duplicateChoice(list: "yes_no", "yes")) {
            try ChecklistForm.read(Self.form([Self.question("a", "select_one yes_no")], choices: twice))
        }
    }

    @Test func aFileThatIsNotAChecklistIsRefused() {
        #expect(throws: ChecklistProblem.unreadable) { try ChecklistForm.read(Data("[1, 2]".utf8)) }
        #expect(throws: ChecklistProblem.unreadable) { try ChecklistForm.read(Data("{\"survey\": [".utf8)) }
    }

    @Test func eachProblemTellsTheAdminWhatToFixInPlainWords() {
        #expect(ChecklistProblem.duplicateName(row: 3, "a").text == "Row 3: the name \"a\" is used twice.")
        #expect(ChecklistProblem.unknownReference(row: 2, "nope").text
            == "Row 2: ${nope} names no question in this form.")
        #expect(ChecklistProblem.tooDeep(row: 4).text == "Row 4: groups can be at most 3 deep.")
    }
}
