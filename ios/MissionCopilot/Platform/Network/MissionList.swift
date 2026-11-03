import Foundation

/// The newest pack the server has for a mission: enough to show the row before any download.
struct ListedPack: Codable, Equatable, Sendable {
    let version: Int
    let createdAt: Date
    let expiresAt: Date
}

struct ListedMission: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let pack: ListedPack?
}

/// This phone's missions as the server lists them (listMyMissions, #92), and its organization, which every
/// pack it accepts must name. Kept in the encrypted store, so the list still shows with no signal.
struct MissionList: Codable, Equatable, Sendable {
    let orgId: String
    let missions: [ListedMission]

    static let path = "/v1/missions"

    struct NotAList: Error {}

    static func decode(_ data: Data) throws -> MissionList {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            // Postgres times may carry microseconds; both forms are ISO 8601.
            let fractional = ISO8601DateFormatter(), whole = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = fractional.date(from: text) ?? whole.date(from: text) else { throw NotAList() }
            return date
        }
        return try decoder.decode(MissionList.self, from: data)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

extension MissionStore {
    static let listKey = "missions.list"

    /// The last list the server gave, for when there is no signal.
    func cachedMissionList() throws -> MissionList? {
        guard let text = try store.info(Self.listKey) else { return nil }
        return try? MissionList.decode(Data(text.utf8))
    }

    func cacheMissionList(_ list: MissionList) throws {
        guard let text = String(bytes: try list.encoded(), encoding: .utf8) else { throw MissionList.NotAList() }
        try store.setInfo(Self.listKey, text)
    }
}
