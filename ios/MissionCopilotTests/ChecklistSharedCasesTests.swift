import Foundation
import Testing
@testable import MissionCopilot

/// The forms in docs/api/fixtures/checklist-form-cases.json, read by the phone (#93). The server's check
/// reads the same file (backend/tests/unit/test_checklist_check.py), so the two refuse the same forms
/// and the server never publishes a checklist every phone would refuse.
struct ChecklistSharedCasesTests {
    struct Case {
        let name: String
        let form: Data
        let kind: String?
        let row: Int?
    }

    static var cases: [Case] {
        let url = PackSectionsTests.api.appendingPathComponent("fixtures/checklist-form-cases.json")
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let all = file["cases"] as? [[String: Any]] else { return [] }
        return all.compactMap { item in
            guard let name = item["name"] as? String, let survey = item["survey"] as? [[String: Any]],
                  let form = try? JSONSerialization.data(withJSONObject: [
                      "settings": ["form_id": "check", "form_title": "Check", "version": "1"], "survey": survey,
                      "choices": item["choices"] ?? file["choices"] ?? []
                  ]) else { return nil }
            let problem = item["problem"] as? [String: Any]
            return Case(name: name, form: form, kind: problem?["kind"] as? String, row: problem?["row"] as? Int)
        }
    }

    /// The problem's kind and row as the file names them.
    static func named(_ problem: ChecklistProblem) -> (String, Int?) {
        switch problem {
        case .unreadable: ("unreadable", nil)
        case .unknownType(let row, _): ("unknownType", row)
        case .duplicateName(let row, _): ("duplicateName", row)
        case .noSuchList(let row, _): ("noSuchList", row)
        case .noList(let row): ("noList", row)
        case .unbalancedGroup(let row): ("unbalancedGroup", row)
        case .tooDeep(let row): ("tooDeep", row)
        case .unknownReference(let row, _): ("unknownReference", row)
        case .duplicateChoice: ("duplicateChoice", nil)
        case .unsafePattern(let row): ("unsafePattern", row)
        }
    }

    @Test(.needsRepoFiles) func thePhoneSaysWhatTheSharedFileSaysForEveryForm() throws {
        let cases = Self.cases
        #expect(cases.count >= 25)

        for item in cases {
            var found: (String, Int?)?
            do { _ = try ChecklistForm.read(item.form) } catch { found = Self.named(error) }

            #expect(found?.0 == item.kind && found?.1 == item.row, "\(item.name): \(String(describing: found))")
        }
    }
}
