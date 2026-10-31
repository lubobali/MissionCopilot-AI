import Foundation
import os

struct BenchRun: Codable, Sendable {
    let engine: String
    let test: String
    let run: Int
    let timeToFirstTokenMs: Double
    let tokensPerSecond: Double
    let generatedTokens: Int
    let freeMemoryAfterMB: Int
    let output: String
}

struct BenchReport: Codable, Sendable {
    let engine: String
    let model: String
    let device: String
    let date: Date
    let loadSeconds: Double
    let freeMemoryBeforeLoadMB: Int
    let freeMemoryAfterLoadMB: Int
    var runs: [BenchRun]
}

enum DeviceInfo {
    static func freeMemoryMB() -> Int { Int(os_proc_available_memory() / 1_048_576) }

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func save(_ report: BenchReport) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = documents.appendingPathComponent("bench-\(report.engine)-\(Int(report.date.timeIntervalSince1970)).json")
        try encoder.encode(report).write(to: url)
        return url
    }
}
