import Foundation

/// A red flag's pack input in words (#154), found in the Phase 6 proof: "Computed from" showed raw paths
/// ("contracts.json · /contracts/0/contractValue"). Now the record's name as its source card says it, then the
/// field ("Milestone · Section 3 bridge complete · due date"); without the names, the path in words.
extension RedFlagWords {
    /// Every pack record's card title, by "path#pointer", from the pack's files.
    static func recordNames(from packFiles: [String: Data]) -> [String: String] {
        let pack = MissionSources.build(SourceInputs(packFiles: packFiles)).filter { $0.kind == .pack }
        let named = pack.map { (String($0.id.dropFirst("pack:".count)), SourceWords.card($0).title) }
        return Dictionary(named) { first, _ in first }
    }

    func record(_ citation: PackCitation) -> String {
        let parts = citation.pointer.split(separator: "/").map(String.init)
        for kept in stride(from: parts.count, through: 1, by: -1) {
            let pointer = "/" + parts.prefix(kept).joined(separator: "/")
            guard let name = recordNames["\(citation.path)#\(pointer)"] else { continue }
            return ([name] + parts.dropFirst(kept).map(Self.plain)).joined(separator: " · ")
        }
        var words: [String] = []
        for part in parts {
            if let index = Int(part), let list = words.popLast() {
                words.append("\(list.hasSuffix("s") ? String(list.dropLast()) : list) \(index + 1)")
            } else {
                words.append(Self.plain(part))
            }
        }
        return words.joined(separator: " · ").capitalized(firstOnly: true)
    }

    private static func plain(_ key: String) -> String { AnswerLines.statusWords(key, .english) }
}
