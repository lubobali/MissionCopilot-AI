import Foundation
import Testing
@testable import MissionCopilot

/// The download's own log (#94, 94.0c), to set what the phone did beside the server's log: each piece asked
/// (file, range), each answer (status, Content-Range, bytes), files taken from the store, and why a run
/// ended. Technical facts only: no device id, no signature, nothing of a file's contents.
@Suite(.serialized) struct PackLogTests {
    @Test(.needsRepoFiles) func aCutShowsAsAskedThenStoppedAndTheNextRunStartsFromTheSavedBytes() async throws {
        let rig = try PackDownloaderTests.Rig()
        rig.server.dropOnce = 6

        #expect(await rig.run() == .paused(.offline))
        let first = rig.lines
        _ = await rig.run()
        let second = Array(rig.lines.dropFirst(first.count))

        #expect(first.first?.hasPrefix("run start") == true)
        #expect(first.contains { $0.hasPrefix("ask ") && $0.contains("bytes=") })
        #expect(first.last == "run end paused(offline)")
        let saved = try #require(second.first { $0.hasPrefix("run start") })
        #expect(!saved.contains("saved=0 "))  // the second run knows the bytes the first one saved
        #expect(second.last == "run end verified")
    }

    @Test(.needsRepoFiles) func everyAnswerSaysItsStatusAndRange() async throws {
        let rig = try PackDownloaderTests.Rig()

        _ = await rig.run()

        let answers = rig.lines.filter { $0.hasPrefix("got ") }
        #expect(!answers.isEmpty && answers.allSatisfy { $0.contains("status=206") && $0.contains("range=bytes ") })
    }

    @Test(.needsRepoFiles) func noLineCarriesTheDeviceTheSignatureOrAFilesText() async throws {
        let rig = try PackDownloaderTests.Rig()

        _ = await rig.run()

        let all = rig.lines.joined(separator: "\n")
        #expect(!all.contains("6f1d2c3a-1111-4000-8000-000000000007"))  // the device id
        #expect(!all.contains("Kandor"))  // file contents
        #expect(!all.contains("MEU") && !all.contains("signature"))
    }
}
