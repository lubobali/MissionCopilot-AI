import CryptoKit
import Foundation
import GRDB

/// Measures what encryption costs on the phone (spike #16: "performance cost noted").
public enum SpeedTest {
    /// Milliseconds to insert `rows` small rows in one transaction.
    public static func insertMilliseconds(into pool: DatabasePool, rows: Int) throws -> Double {
        try pool.write { db in try db.execute(sql: "CREATE TABLE IF NOT EXISTS speed(n INTEGER, text TEXT)") }
        let start = Date()
        try pool.write { db in
            for index in 0..<rows {
                try db.execute(sql: "INSERT INTO speed VALUES (?, ?)", arguments: [index, "Km \(index) inspected"])
            }
        }
        return Date().timeIntervalSince(start) * 1000
    }

    /// Average milliseconds for one unwrap of a mission key by `vault`.
    public static func unwrapMilliseconds(vault: any MissionKeyVault, mission: String, runs: Int) throws -> Double {
        let wrapped = try vault.wrap(SymmetricKey(size: .bits256), for: mission)
        let start = Date()
        for _ in 0..<runs { _ = try vault.unwrap(wrapped, for: mission) }
        let average = Date().timeIntervalSince(start) * 1000 / Double(runs)
        try vault.destroy(mission: mission)
        return average
    }
}
