import CryptoKit
import Foundation
import Testing
@testable import MissionCopilot

/// A newer pack reuses the files the phone already holds (#94, 94.0b). On the iPhone every new version
/// fetched all 13 files again: 15 MB over mobile data for one 357-byte change, because after a pack is in
/// the store its download folder is gone. Now a file whose SHA-256 (from the signed manifest) matches one
/// in the mission's encrypted store is taken from there, checked again, and only the changed file comes.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct PackReuseTests {
    static let changedPath = "documents/progress-report-2026-09.md"
    static let changed = Data("Kandor Rural Roads, progress report (fictional), changed in version 2.\n".utf8)
    let key = P256.Signing.PrivateKey()

    /// Version 2 of the fixture pack: one file changed, signed by this test's key over the exact bytes.
    func nextPack() throws -> FakePackServer.NextPack {
        var manifest = try #require(try JSONSerialization.jsonObject(with: FakePackServer.file("manifest.json"))
            as? [String: Any])
        let keyId = ServerConfig.keyId(key.publicKey.derRepresentation)
        manifest["version"] = 2
        manifest["keyId"] = keyId
        let sha = PackVerifier.hex(SHA256.hash(data: Self.changed))
        manifest["files"] = (manifest["files"] as? [[String: Any]] ?? []).map { file in
            guard file["path"] as? String == Self.changedPath else { return file }
            return file.merging(["sha256": sha, "size": Self.changed.count]) { $1 }
        }
        let bytes = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        let signed = try key.signature(for: PackVerifier.domain + bytes).derRepresentation.base64EncodedString()
        let signature = try JSONSerialization.data(withJSONObject: [
            "keyId": keyId, "algorithm": PackVerifier.algorithm, "signature": signed
        ])
        return FakePackServer.NextPack(manifest: bytes, signature: signature, files: [sha: Self.changed])
    }

    @Test(.needsRepoFiles) func aNewerPackFetchesOnlyTheFileThatChanged() async throws {
        let rig = try MissionListModelTests()
        let list = try rig.model(also: key.publicKey)
        await list.refresh()
        list.download(MissionListModelTests.roads)
        await list.downloadsEnded()
        #expect(rig.row(list, MissionListModelTests.roads)?.version == 1)

        let next = try nextPack()
        rig.server.nextPack = next
        rig.server.missionList = (200, FakePackServer.missions(version: 2))
        let before = rig.server.fileRequests
        await list.refresh()
        list.download(MissionListModelTests.roads)
        await list.downloadsEnded()

        #expect(rig.row(list, MissionListModelTests.roads)?.version == 2)
        #expect(rig.server.fileRequests - before == 1)  // only the changed file
        #expect(try rig.store.packFile(Self.changedPath, in: MissionListModelTests.roads) == Self.changed)
        let unchanged = "sections/project.json"
        #expect(try rig.store.packFile(unchanged, in: MissionListModelTests.roads)
                == FakePackServer.file("files/\(try sha(of: unchanged))"))
    }

    @Test(.needsRepoFiles) func aStoredFileThatNoLongerMatchesIsFetchedNotReused() async throws {
        let rig = try MissionListModelTests()
        let list = try rig.model(also: key.publicKey)
        await list.refresh()
        list.download(MissionListModelTests.roads)
        await list.downloadsEnded()

        // The next pack names the same file with another hash: reusing the stored one would be wrong.
        let next = try nextPack()
        rig.server.nextPack = next
        rig.server.missionList = (200, FakePackServer.missions(version: 2))
        await list.refresh()
        list.download(MissionListModelTests.roads)
        await list.downloadsEnded()

        #expect(try rig.store.packFile(Self.changedPath, in: MissionListModelTests.roads) == Self.changed)
    }

    private func sha(of path: String) throws -> String {
        let manifest = try #require(try JSONSerialization.jsonObject(with: FakePackServer.file("manifest.json"))
            as? [String: Any])
        let files = manifest["files"] as? [[String: Any]] ?? []
        return try #require(files.first { $0["path"] as? String == path }?["sha256"] as? String)
    }
}
