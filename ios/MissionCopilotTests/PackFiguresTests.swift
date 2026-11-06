import Foundation
import Testing
@testable import MissionCopilot

/// The pack's contracts and milestones, typed (#134, step 6.3.2): the numbers the red-flag rules use, each
/// citable as the pack file (path and SHA-256, the same hash the signed manifest lists) plus a JSON Pointer
/// to the exact field, so a flag's input can be read again from the pack it came from.
struct PackFiguresTests {
    static func file(_ path: String) throws -> Data { try #require(PackSectionsTests.files[path]) }

    @Test func theKandorContractIsReadWithItsPaymentsAndProgress() throws {
        let read = try PackContracts.read(try Self.file(PackContracts.path))
        let contract = try #require(read.contracts.first)

        #expect(read.contracts.count == 1)
        #expect(contract.ocid == "ocds-kandor-krrp-p1-w01")
        #expect(contract.contractValue == 10_000_000)
        #expect(contract.payments.count == 6)
        #expect(contract.payments.map(\.amount).reduce(0, +) == 8_500_000)
        #expect(contract.payments[2] == .init(amount: 1_800_000, date: "2026-01-31", reference: "Invoice 9"))
        #expect(contract.physicalProgress == .init(asOf: "2026-09-30", kmBuilt: 32, kmTotal: 64,
                                                   unit: "km of asphalt"))
        #expect(contract.status == .active)
    }

    @Test func theKandorMilestonesAreReadWithWhatWasMet() throws {
        let read = try PackMilestones.read(try Self.file(PackMilestones.path))

        #expect(read.asOf == "2026-11-10")
        #expect(read.milestones.map(\.id) == ["M1", "M2", "M3", "M4"])
        #expect(read.milestones[2] == .init(id: "M3", title: "Section 3 bridge complete", dueDate: "2026-09-30",
                                            dateMet: nil, status: .notMet))
        #expect(read.milestones[1].dateMet == "2026-07-20")
    }

    @Test func theFileIsNamedByTheHashTheSignedManifestLists() throws {
        let contracts = try PackContracts.read(try Self.file(PackContracts.path))
        let milestones = try PackMilestones.read(try Self.file(PackMilestones.path))

        let manifestSHA = "76510d186a53faec029112755179cca0ef76212b581700816af39b706a6da79a"
        #expect(contracts.file == PackFileRef(path: "sections/contracts.json", sha256: manifestSHA))
        #expect(milestones.file.sha256 == "061fe12456fa15b79e78cf04d1cc36059d46673ab0fd1a805f16afb5b330beb0")
    }

    @Test func aCitationReadsBackTheValueItNames() throws {
        let data = try Self.file(PackContracts.path)
        let read = try PackContracts.read(data)

        let value = read.file.cite("/contracts/0/payments/2/amount")

        #expect(value == PackCitation(path: "sections/contracts.json", sha256: read.file.sha256,
                                      pointer: "/contracts/0/payments/2/amount"))
        #expect(try value.value(in: data) == .number(1_800_000))
        #expect(try read.file.cite("/contracts/0/contractValue").value(in: data) == .number(10_000_000))
        #expect(try read.file.cite("/contracts/0/physicalProgress/kmBuilt").value(in: data) == .number(32))
    }

    @Test func aCitationNeverReadsAnotherFileOrAMissingField() throws {
        let contracts = try Self.file(PackContracts.path)
        let read = try PackContracts.read(contracts)

        // A changed copy of the same file: the field is there, but these are not the bytes the manifest signed.
        let changed = try #require(String(data: contracts, encoding: .utf8)?
            .replacingOccurrences(of: "10000000", with: "90000000").data(using: .utf8))
        #expect(throws: PackCitation.CannotRead.self) {
            try read.file.cite("/contracts/0/contractValue").value(in: changed)
        }
        // "X" + a path: only the leading-slash rule refuses it (RFC 6901 pointers start with "/").
        for pointer in ["/contracts/1/contractValue", "/contracts/0/nothing", "Xcontracts/0/contractValue"] {
            #expect(throws: PackCitation.CannotRead.self, "\(pointer)") {
                try read.file.cite(pointer).value(in: contracts)
            }
        }
    }

    @Test func aMilestoneWithAnUnknownStatusIsRefused() {
        let data = Data(#"""
            {"asOf": "2026-11-10", "locations": [], "milestones": [{"id": "M1", "title": "x",
             "dueDate": "2026-01-01", "dateMet": null, "status": "skipped"}]}
            """#.utf8)

        #expect(throws: (any Error).self) { try PackMilestones.read(data) }
    }
}
