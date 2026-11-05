import Foundation
@testable import MissionCopilot

/// A stand-in for the server's pack routes (#91), serving the real signed Kandor fixture
/// (docs/api/fixtures/pack-v2-kandor) with byte ranges like pack_routes, and switches for every trouble
/// a phone meets: a lost signal, a changed file, a server that ignores Range or answers 416, a new pack
/// published between the manifest and its signature, a forced status for the manifest, and a busy server.
final class FakePackServer: Transport, @unchecked Sendable {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/api/fixtures/pack-v2-kandor")

    var dropOnce: Int?  // the n-th file request (1-based) loses the signal, once
    var corrupt: [String: Int] = [:]  // sha256 -> how many times to answer it changed
    var ignoreRange = false
    var rangeOutsideOnce: Set<String> = []
    var rangeOutsideAlways: Set<String> = []
    var publishInBetween = 0  // how many signature answers belong to another manifest
    var manifestStatus: (Int, Data)?
    var onFileRequest: (@Sendable (Int) -> Void)?  // told the number of each file request
    var cancelCutsOff = false  // like URLSession: a request whose task was cancelled throws
    var offline = false  // every request: no signal
    var busyAt: Set<Int> = []  // these file requests (1-based) answer 503, once each (#104)
    var busyFrom: Int?  // every file request from this one on answers 503
    var busyRetryAfter: String?  // the Retry-After header on those 503 answers
    var nextPack: NextPack?  // a newer version, served instead (#94)

    /// A newer pack version: its manifest, its signature and the files it adds or changes (by SHA-256).
    struct NextPack { let manifest: Data, signature: Data, files: [String: Data] }
    var missionList: (status: Int, body: Data)?  // GET /v1/missions; nil: roads with the fixture's pack, bridges none
    private(set) var requests: [URLRequest] = []
    private(set) var fileRequests = 0
    private(set) var bytesSent = 0
    private let lock = NSLock()

    /// The list the server gives officer-7: roads with the fixture's pack (as `version`), bridges with none.
    static func missions(version: Int, expires: String? = nil) -> Data {
        let manifest = (try? JSONSerialization.jsonObject(with: file("manifest.json"))) as? [String: Any] ?? [:]
        let pack: [String: Any] = ["version": version, "createdAt": manifest["createdAt"] ?? "",
                                   "expiresAt": expires ?? manifest["expiresAt"] ?? ""]
        let list: [String: Any] = ["orgId": "kandor-works", "missions": [
            ["id": "6f1d2c3a-0000-4000-8000-000000000001", "title": "Kandor Rural Roads Project, Package 1",
             "pack": pack],
            ["id": "6f1d2c3a-0000-4000-8000-000000000002", "title": "Kandor Bridges", "pack": NSNull()]
        ]]
        return (try? JSONSerialization.data(withJSONObject: list)) ?? Data()
    }

    static func file(_ path: String) -> Data {
        // swiftlint:disable:next force_try
        try! Data(contentsOf: folder.appending(path: path))
    }

    /// One answer of the stand-in server.
    private struct Answer {
        let status: Int, headers: [String: String], body: Data

        init(_ status: Int, _ headers: [String: String] = [:], _ body: Data = Data()) {
            self.status = status
            self.headers = headers
            self.body = body
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let found = try lock.withLock { () throws -> Answer in
            requests.append(request)
            return try answer(request)
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: found.status, httpVersion: nil,
                                             headerFields: found.headers)
        else { throw URLError(.badURL) }
        return (found.body, response)
    }

    private func answer(_ request: URLRequest) throws -> Answer {
        let path = request.url?.path() ?? ""
        if offline { throw URLError(.notConnectedToInternet) }
        if path == MissionList.path {
            if let missionList { return Answer(missionList.status, [:], missionList.body) }
            return Answer(200, [:], Self.missions(version: 1))
        }
        if path.hasSuffix("/pack/manifest") {
            if let (status, body) = manifestStatus { return Answer(status, [:], body) }
            if let nextPack { return Answer(200, ["ETag": "\"m2\""], nextPack.manifest) }
            return Answer(200, ["ETag": "\"m\""], Self.file("manifest.json"))
        }
        if path.hasSuffix("/pack/signature") {
            if publishInBetween > 0 {
                publishInBetween -= 1
                // The fixture's own key (read, so a new fixture key cannot leave it stale), another signature.
                let fixture = try? JSONSerialization.jsonObject(with: Self.file("signature.json")) as? [String: Any]
                let keyId = fixture?["keyId"] as? String ?? ""
                let other = #"{"keyId":"\#(keyId)","algorithm":"ecdsa-p256-sha256","signature":"MEUCIQD/"}"#
                return Answer(200, [:], Data(other.utf8))
            }
            if let nextPack { return Answer(200, [:], nextPack.signature) }
            return Answer(200, [:], Self.file("signature.json"))
        }
        guard let sha = path.split(separator: "/").last.map(String.init) else { return Answer(404, [:], Data()) }
        return try fileAnswer(sha, request)
    }

    private func fileAnswer(_ sha: String, _ request: URLRequest) throws -> Answer {
        fileRequests += 1
        onFileRequest?(fileRequests)
        if cancelCutsOff, Task.isCancelled { throw URLError(.cancelled) }
        if busyAt.remove(fileRequests) != nil || busyFrom.map({ fileRequests >= $0 }) == true {
            return Answer(503, busyRetryAfter.map { ["Retry-After": $0] } ?? [:])
        }
        if dropOnce == fileRequests {
            dropOnce = nil
            throw URLError(.networkConnectionLost)
        }
        var data = nextPack?.files[sha] ?? Self.file("files/\(sha)")
        if let times = corrupt[sha], times > 0 {
            corrupt[sha] = times - 1
            data[0] ^= 0x01
        }
        let etag = "\"\(sha)\""
        guard let range = request.value(forHTTPHeaderField: "Range"), !ignoreRange,
              request.value(forHTTPHeaderField: "If-Range").map({ $0 == etag }) ?? true else {
            bytesSent += data.count
            return Answer(200, ["ETag": etag], data)
        }
        if rangeOutsideOnce.remove(sha) != nil || rangeOutsideAlways.contains(sha) {
            return Answer(416, ["Content-Range": "bytes */\(data.count)"], Data())
        }
        let bounds = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        let first = Int(bounds[0]) ?? 0, last = min(Int(bounds[1]) ?? (data.count - 1), data.count - 1)
        guard first < data.count else { return Answer(416, ["Content-Range": "bytes */\(data.count)"], Data()) }
        let part = data[first...last]
        bytesSent += part.count
        return Answer(206, ["ETag": etag, "Content-Range": "bytes \(first)-\(last)/\(data.count)"], Data(part))
    }
}
