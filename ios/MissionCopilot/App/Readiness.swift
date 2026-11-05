import Foundation
import Observation

/// Gathers the facts for one mission's "Before you go" (#125): the model inside the app, the speech files
/// for the languages the mission's checklist uses, and free space; Install runs from a line's button.
/// The model is checked once per run: its files are inside the signed app and cannot change meanwhile.
@MainActor @Observable
final class Readiness {
    private(set) var check: BeforeYouGo?
    private(set) var installing: SpeechLanguage?
    private(set) var problem: String?

    private let checkModel: @Sendable () async -> BundledModel.State
    private let speech: any SpeechFiles
    private let freeBytes: @Sendable () -> Int64
    private let words: MissionWords
    private var model: BundledModel.State?

    init(model: @escaping @Sendable () async -> BundledModel.State = {
             await BundledModel.check(resources: Bundle.main.resourceURL)
         },
         speech: any SpeechFiles = AppleSpeechFiles(),
         freeBytes: @escaping @Sendable () -> Int64 = { Readiness.liveFreeBytes() },
         words: MissionWords = MissionWords()) {
        self.checkModel = model
        self.speech = speech
        self.freeBytes = freeBytes
        self.words = words
    }

    func refresh(_ row: MissionRow) async {
        let model: BundledModel.State
        if let known = self.model {
            model = known
        } else {
            model = await checkModel()
            self.model = model
        }
        var languages: [SpeechLanguage: SpeechFileStatus] = [:]
        for language in SpeechLanguage.needed(for: row.pack?.checklist) {
            languages[language] = await speech.status(of: language)
        }
        check = BeforeYouGo(pack: row.status, facts: row.pack, model: model, speech: languages,
                            freeBytes: freeBytes(), words: words)
    }

    /// Needs a connection: Apple downloads the files. A failure is said, and the line stays to do.
    func install(_ language: SpeechLanguage, for row: MissionRow) async {
        installing = language
        problem = nil
        do {
            try await speech.install(language)
        } catch {
            problem = "\(language.name) could not be installed. Check the connection and try again."
        }
        installing = nil
        await refresh(row)
    }

    /// The space iOS says an app may use for things the person asked for, the measure Apple advises.
    nonisolated static func liveFreeBytes() -> Int64 {
        let home = URL(filePath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
