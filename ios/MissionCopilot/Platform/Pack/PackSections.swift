import Foundation

/// The project as the pack's project section says it (OC4IDS names), read only after the schema check.
struct PackProject: Codable, Sendable, Equatable {
    let projectRef, title, country, sector, status, developmentObjective, implementingAgency: String
    let approvalDate, closingDate, site, currency, note: String
    let budget: Int
}

/// A pack's sections and checklist, checked before anything of them is used (#92, threat T51): a signed
/// pack proves who sent it, and this proves the app can read it as the contract says. Every section and
/// the checklist must be there, each must match its definition in the pack sections schema (an unknown
/// field refused), and nothing else may sit in their folders; the checklist must also be one a person
/// could fill (ChecklistForm, #93). The other sections get typed readers when
/// the rule engine needs them (Phase 6); until then they are checked here and stored as they came.
enum PackSections {
    static let sections = ["project", "components", "ratings", "results", "financing", "contracts", "milestones",
                           "safeguards", "agreed-actions"]
    static let required: Set<String> = Set(sections.map { "sections/\($0).json" } + ["forms/road-checklist.json"])

    /// Checks the pack's JSON files (path to bytes) and gives back the project.
    static func check(_ files: [String: Data], schema: PackSchema) throws(PackRefusal) -> PackProject {
        let checked = files.filter { $0.key.hasPrefix("sections/") || $0.key.hasPrefix("forms/") }
        guard Set(checked.keys) == required else { throw .badSection }
        for (path, data) in checked {
            let name = String(path.split(separator: "/").last?.dropLast(".json".count) ?? "")
            guard let value = try? JSONValue.parse(data), schema.isValid(value, as: name) else {
                throw .badSection
            }
        }
        guard let checklist = checked["forms/road-checklist.json"], (try? ChecklistForm.read(checklist)) != nil
        else { throw .badChecklist }
        guard let project = checked["sections/project.json"],
              let decoded = try? JSONDecoder().decode(PackProject.self, from: project) else { throw .badSection }
        return decoded
    }
}
