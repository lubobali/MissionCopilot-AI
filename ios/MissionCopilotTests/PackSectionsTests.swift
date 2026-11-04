import Foundation
import Testing
@testable import MissionCopilot

/// The phone reads a pack's sections only as the contract says (#92, threat T51): every section and the
/// checklist there, each matching the pack sections schema, the very file the server's tests use. The
/// shared cases (docs/api/fixtures/pack-section-cases.json: real Kandor files with one small change each)
/// hold the phone's check to the reference validator's answers, never laxer and never stricter.
/// One shared case: a file of the pack, where in it, and the change ("add", "set", "delete", or "repeat":
/// the list there becomes its first item `count` times, to reach a limit).
struct SectionCase: Decodable {
    let file: String, path: [PackSectionsTests.Step], operation: String
    let value: PackSectionsTests.AnyJSON?
    let count: Int?
    enum CodingKeys: String, CodingKey { case file, path, operation = "op", value, count }
}

struct PackSectionsTests {
    static let api = PackVerifierTests.repo.appendingPathComponent("docs/api")

    static var files: [String: Data] {
        let manifest = try? JSONSerialization.jsonObject(with: PackVerifierTests.file("manifest.json"))
        let entries = (manifest as? [String: Any])?["files"] as? [[String: Any]] ?? []
        return entries.reduce(into: [:]) { all, entry in
            guard let path = entry["path"] as? String, let sha = entry["sha256"] as? String else { return }
            all[path] = PackVerifierTests.file("files/\(sha)")
        }
    }

    static var jsonFiles: [String: Data] { files.filter { $0.key.hasSuffix(".json") } }

    static func schema() throws -> PackSchema {
        try PackSchema(json: Data(contentsOf: api.appendingPathComponent("pack-sections.schema.json")))
    }

    enum Step: Decodable {
        case key(String), index(Int)
        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let index = try? single.decode(Int.self) { self = .index(index) } else {
                self = .key(try single.decode(String.self))
            }
        }
    }

    /// Any JSON value inside a case, kept as JSONValue.
    struct AnyJSON: Decodable {
        let value: JSONValue
        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if single.decodeNil() { value = .null } else if let flag = try? single.decode(Bool.self) {
                value = .bool(flag)
            } else if let number = try? single.decode(Double.self) { value = .number(number) } else if
                let text = try? single.decode(String.self) { value = .string(text) } else if
                let items = try? single.decode([AnyJSON].self) { value = .array(items.map(\.value)) } else {
                value = .object(try single.decode([String: AnyJSON].self).mapValues(\.value))
            }
        }
    }

    static var cases: (good: [SectionCase], bad: [SectionCase]) {
        struct All: Decodable { let good: [SectionCase], bad: [SectionCase] }
        let data = (try? Data(contentsOf: api.appendingPathComponent("fixtures/pack-section-cases.json"))) ?? Data()
        let all = try? JSONDecoder().decode(All.self, from: data)
        return (all?.good ?? [], all?.bad ?? [])
    }

    /// The document with one case's change, as scripts/make_pack_section_cases.py applies it.
    static func apply(_ change: SectionCase, at path: ArraySlice<Step>, to node: JSONValue) -> JSONValue {
        guard let step = path.first else {
            if change.operation == "repeat", case .array(let items) = node, let first = items.first {
                return .array(Array(repeating: first, count: change.count ?? 0))
            }
            return change.value?.value ?? .null
        }
        let last = path.count == 1
        switch (node, step) {
        case (.object(var fields), .key(let key)):
            if last, change.operation == "delete" { fields[key] = nil } else {
                fields[key] = apply(change, at: path.dropFirst(), to: fields[key] ?? .null)
            }
            return .object(fields)
        case (.array(var items), .index(let index)):
            if last, change.operation == "delete" { items.remove(at: index) } else if index == items.count {
                items.append(change.value?.value ?? .null)
            } else { items[index] = apply(change, at: path.dropFirst(), to: items[index]) }
            return .array(items)
        default:
            return node
        }
    }

    private func checks(_ change: SectionCase, _ schema: PackSchema) throws -> Bool {
        let document = try JSONValue.parse(try #require(Self.files[change.file]))
        let name = String(change.file.split(separator: "/").last?.dropLast(".json".count) ?? "")
        return schema.isValid(Self.apply(change, at: change.path[...], to: document), as: name)
    }

    // The schema and the real pack

    @Test(.needsRepoFiles) func theAppCarriesTheContractsSchemaByteForByte() throws {
        let bundled = try #require(Bundle.main.url(forResource: "pack-sections.schema", withExtension: "json"))

        #expect(try Data(contentsOf: bundled) == Data(contentsOf: Self.api.appendingPathComponent(
            "pack-sections.schema.json")))
        _ = try PackSchema.bundled()
    }

    @Test(.needsRepoFiles) func theKandorPacksSectionsPassAndItsProjectIsRead() throws {
        let project = try PackSections.check(Self.files, schema: Self.schema())

        #expect(project.title == "Kandor Rural Roads Project, Package 1")
        #expect(project.budget == 12_000_000 && project.currency == "USD" && project.closingDate == "2027-06-30")
    }

    // Held to the reference validator

    @Test(.needsRepoFiles) func everyChangeTheReferenceRefusesIsRefused() throws {
        let schema = try Self.schema(), bad = Self.cases.bad
        #expect(bad.count > 300)

        let accepted = try bad.filter { try checks($0, schema) }

        #expect(accepted.isEmpty, "laxer than the reference: \(accepted.prefix(3).map { "\($0.file) \($0.path)" })")
    }

    @Test(.needsRepoFiles) func everyChangeTheReferenceAcceptsIsAccepted() throws {
        let schema = try Self.schema(), good = Self.cases.good
        #expect(good.count > 100)

        let refused = try good.filter { try !checks($0, schema) }

        #expect(refused.isEmpty, "stricter than the reference: \(refused.prefix(3).map { "\($0.file) \($0.path)" })")
    }

    // Whole packs

    @Test(.needsRepoFiles) func aPackMissingASectionOrWithAnExtraOneIsRefused() throws {
        var missing = Self.files
        missing["sections/ratings.json"] = nil
        var extra = Self.files
        extra["sections/secret.json"] = Data("{}".utf8)

        #expect(throws: PackRefusal.badSection) { try PackSections.check(missing, schema: Self.schema()) }
        #expect(throws: PackRefusal.badSection) { try PackSections.check(extra, schema: Self.schema()) }
    }

    @Test(.needsRepoFiles) func aChecklistThatPassesTheContractButNobodyCouldFillIsRefused() throws {
        var files = Self.files
        let data = try #require(files["forms/road-checklist.json"])
        var form = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var survey = try #require(form["survey"] as? [[String: Any]])
        survey.append(survey[0])  // a name used twice: the contract allows it, the form check does not
        form["survey"] = survey
        files["forms/road-checklist.json"] = try JSONSerialization.data(withJSONObject: form)

        #expect(throws: PackRefusal.badChecklist) { try PackSections.check(files, schema: Self.schema()) }
    }

    @Test(.needsRepoFiles) func aSectionThatIsNotJSONIsRefused() throws {
        var broken = Self.files
        broken["sections/financing.json"] = Data("{\"loanId\":".utf8)

        #expect(throws: PackRefusal.badSection) { try PackSections.check(broken, schema: Self.schema()) }
    }

    @Test(.needsRepoFiles) func theDocumentsAreNotSectionsAndAreLeftForTheStore() throws {
        var files = Self.files
        files["documents/aide-memoire-2026-05.md"] = Data("not json".utf8)

        _ = try PackSections.check(files, schema: Self.schema())
    }

    // A schema the app cannot fully apply is refused, never half applied

    @Test(arguments: [#"{"$defs":{"x":{"type":"string","format":"date"}}}"#,
                      ##"{"$defs":{"x":{"$ref":"#/$defs/y"}}}"##,
                      #"{"$defs":{"x":{"type":"object","additionalProperties":{"type":"string"}}}}"#,
                      #"{"$defs":{"x":{"properties":{"y":{"uniqueItems":true}}}}}"#])
    func aSchemaWithAKeywordTheAppDoesNotApplyIsRefused(schema: String) {
        #expect(throws: PackSchema.Problem.self) { try PackSchema(json: Data(schema.utf8)) }
    }

    @Test func oneOfMeansExactlyOneEvenWhereTheContractsBranchesNeverOverlap() throws {
        let both = #"{"$defs":{"x":{"oneOf":[{"type":"number"},{"type":"integer"}]}}}"#
        let schema = try PackSchema(json: Data(both.utf8))

        #expect(schema.isValid(.number(1.5), as: "x"))  // a number only
        #expect(!schema.isValid(.number(2), as: "x"))  // both: refused
    }

    @Test func aLengthIsCountedInCodePointsAsTheReferenceCounts() throws {
        let schema = try PackSchema(json: Data(#"{"$defs":{"x":{"type":"string","maxLength":2}}}"#.utf8))

        #expect(schema.isValid(.string("e\u{301}"), as: "x"))  // one letter, two code points
        #expect(!schema.isValid(.string("e\u{301}e"), as: "x"))  // two letters, three code points
        #expect(!schema.isValid(.string("\u{1F44D}\u{1F3FD}x"), as: "x"))  // a toned thumb is two
        #expect(schema.isValid(.number(123), as: "x") == false && schema.isValid(.string("ab"), as: "x"))
    }

    @Test func maxItemsCountsTheItemsAndSaysNothingAboutAString() throws {
        let schema = try PackSchema(json: Data(#"{"$defs":{"x":{"maxItems":2}}}"#.utf8))

        #expect(schema.isValid(.array([.null, .null]), as: "x"))
        #expect(!schema.isValid(.array([.null, .null, .null]), as: "x"))
        #expect(schema.isValid(.string("three"), as: "x"))
    }

    @Test func trueAndOneAreNotTheSameAndOnePointZeroIsAnInteger() throws {
        let schema = try PackSchema(json: Data(#"{"$defs":{"n":{"type":"integer"},"e":{"enum":[1]}}}"#.utf8))

        #expect(schema.isValid(.number(1.0), as: "n") && !schema.isValid(.number(1.5), as: "n"))
        #expect(!schema.isValid(.bool(true), as: "n") && !schema.isValid(.bool(true), as: "e"))
        #expect(try JSONValue.parse(Data("true".utf8)) == .bool(true))
    }
}
