import Foundation

/// How a request reaches the network; the app uses URLSessionTransport, tests a fake.
protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The real network: an ephemeral session, so no answer is cached and no cookie is kept on the phone.
struct URLSessionTransport: Transport {
    private let session = URLSession(configuration: Self.configuration())

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        return configuration
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// The app's only way to the server (#90). Every request is signed by the phone's chip key over exactly
/// the bytes the server checks (DeviceSigning), carries a number that only rises (RequestCounter), and
/// becomes one plain outcome. Only https, except plain http to this machine or the local network when the
/// Debug build allows it (the local server); only paths under /v1/.
struct ServerClient: Sendable {
    enum Kind: Equatable, Sendable {
        case success, refused, notFound, shredOrder, rangeOutside, slowDown, busy, appTooOld, offline, phoneLocked
        case failed, notSent
    }

    enum Outcome: Equatable, Sendable {
        case success(Data, status: Int, headers: [String: String])
        case refused  // 401: not enrolled, not approved yet, or a signature the server does not accept
        case notFound  // 404: missing, or not this phone's to see
        case shredOrder(Data)  // 410: a signed order to destroy every mission, to be checked first
        case rangeOutside  // 416
        case slowDown(Int)  // 429: seconds to wait
        case busy(Int?)  // 502, 503, 504: restarting or overloaded; seconds to wait, if the server said (#104)
        case appTooOld(Int?)  // 403 app_too_old: update the app; the server's minimum build, if it said (#104)
        case offline  // no signal or the server cannot be reached
        case phoneLocked  // locked: the chip key and request counter cannot be used; nothing was sent (#94)
        case failed(Int)  // any other answer, or a broken one (0)
        case notSent  // refused before sending: an address or path the phone never uses

        var kind: Kind {
            switch self {
            case .success: .success
            case .refused: .refused
            case .notFound: .notFound
            case .shredOrder: .shredOrder
            case .rangeOutside: .rangeOutside
            case .slowDown: .slowDown
            case .busy: .busy
            case .appTooOld: .appTooOld
            case .offline: .offline
            case .phoneLocked: .phoneLocked
            case .failed: .failed
            case .notSent: .notSent
            }
        }
    }

    let base: URL
    let deviceId: String
    let signer: EvidenceSigner
    let counter: RequestCounter
    var transport: Transport = URLSessionTransport()
    var now: @Sendable () -> Date = { Date() }
    var allowLocalHTTP = false
    /// The server's clock (#104): when set, requests are signed with the server's time, measured once from
    /// /v1/health and again after a refused GET.
    var clock: ServerClock?
    /// This app's build number, sent on every request (X-App-Build) so the server can say it is too old.
    var appBuild = ServerClient.thisBuild

    /// CFBundleVersion (CURRENT_PROJECT_VERSION): a whole number that rises with every build handed out.
    static let thisBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"

    func get(_ path: String, headers: [String: String] = [:]) async -> Outcome {
        await send("GET", path, body: Data(), headers: headers)
    }

    /// #173: `headers` adds the sync's Idempotency-Key; an evidence file goes as raw bytes (`contentType`).
    func post(_ path: String, body: Data, headers: [String: String] = [:],
              contentType: String = "application/json") async -> Outcome {
        await send("POST", path, body: body, headers: headers.merging(["Content-Type": contentType]) { _, new in new })
    }

    private func send(_ method: String, _ path: String, body: Data, headers: [String: String]) async -> Outcome {
        guard path.hasPrefix("/v1/"), Self.allowed(base, local: allowLocalHTTP),
              let url = URL(string: base.absoluteString + path) else { return .notSent }
        if let clock, !clock.isMeasured { _ = await measureClock(clock) }
        let first = await attempt(method, path, url: url, body: body, headers: headers)
        // A refused GET may be a clock that changed since it was measured: measure again, and if the
        // difference really moved, send it once more, signed afresh. A POST is never sent twice.
        guard first == .refused, method == "GET", let clock else { return first }
        let before = clock.offset
        guard await measureClock(clock), abs(clock.offset - before) >= ServerClock.meaningful else { return first }
        return await attempt(method, path, url: url, body: body, headers: headers)
    }

    private func attempt(_ method: String, _ path: String, url: URL, body: Data,
                         headers: [String: String]) async -> Outcome {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body.isEmpty ? nil : body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(appBuild, forHTTPHeaderField: "X-App-Build")
        do {
            for (name, value) in try await signedHeaders(method, path, body) {
                request.setValue(value, forHTTPHeaderField: name)  // after the extras: these always win
            }
        } catch {
            return Self.isPhoneLocked(error) ? .phoneLocked : .notSent
        }
        return await Self.outcome(now: now()) { try await transport.send(request) }
    }

    private func signedHeaders(_ method: String, _ path: String, _ body: Data) async throws -> [String: String] {
        let seq = try await counter.next()
        let time = clock?.time(now()) ?? Int(now().timeIntervalSince1970)
        let request = SignedRequest(method: method, path: path, deviceId: deviceId, seq: seq, time: time, body: body)
        let signature = try signer.sign(try DeviceSigning.requestMessage(request))
        return ["X-Device-Id": deviceId, "X-Device-Seq": String(seq), "X-Device-Time": String(time),
                "X-Device-Signature": signature.base64EncodedString()]
    }

    /// The Keychain's answer while the phone is locked: an item kept "when unlocked" (the chip key, the request
    /// counter) cannot be read, and the chip will not sign.
    static func isPhoneLocked(_ error: Error) -> Bool {
        if let failure = error as? KeychainFailure { return failure.status == errSecInteractionNotAllowed }
        let found = error as NSError
        return found.domain == NSOSStatusErrorDomain && found.code == Int(errSecInteractionNotAllowed)
    }

    /// GET /v1/health, plain: not signed, so no request number is used. True when the server's time came.
    private func measureClock(_ clock: ServerClock) async -> Bool {
        guard let url = URL(string: base.absoluteString + "/v1/health") else { return false }
        let sent = now()
        guard case .success(let data, 200, _) = await Self.outcome({ try await transport.send(URLRequest(url: url)) }),
              let answer = try? JSONDecoder().decode(Health.self, from: data) else { return false }
        clock.measure(sent: sent, received: now(), server: answer.time)
        return true
    }

    private struct Health: Decodable { let time: Int }

    /// The part of a 403 problem the phone acts on (#103 step 1.10).
    private struct Refusal: Decodable { let code: String?, minAppBuild: Int? }

    /// https anywhere; plain http only to this machine or a .local name, and only when allowed.
    static func allowed(_ base: URL, local: Bool) -> Bool {
        switch base.scheme {
        case "https": return true
        case "http":
            let host = base.host() ?? ""
            return local && (["127.0.0.1", "localhost", "::1"].contains(host) || host.hasSuffix(".local"))
        default: return false
        }
    }

    static func outcome(now: Date = Date(), _ call: () async throws -> (Data, HTTPURLResponse)) async -> Outcome {
        do {
            let (data, response) = try await call()
            return outcome(status: response.statusCode, data: data, response: response, now: now)
        } catch let error as URLError where offlineCodes.contains(error.code) {
            return .offline
        } catch {
            return .failed(0)
        }
    }

    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
        .dataNotAllowed, .internationalRoamingOff
    ]

    private static func outcome(status: Int, data: Data, response: HTTPURLResponse, now: Date) -> Outcome {
        let retryAfter = Backoff.retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now)
        switch status {
        case 200, 201, 206:
            let headers = response.allHeaderFields.reduce(into: [String: String]()) { all, field in
                if let name = field.key as? String, let value = field.value as? String {
                    all[name.lowercased()] = value
                }
            }
            return .success(data, status: status, headers: headers)
        case 401: return .refused
        case 403:
            let refusal = try? JSONDecoder().decode(Refusal.self, from: data)
            return refusal?.code == "app_too_old" ? .appTooOld(refusal?.minAppBuild) : .failed(403)
        case 404: return .notFound
        case 410: return .shredOrder(data)
        case 416: return .rangeOutside
        case 429: return .slowDown(retryAfter ?? 60)
        case 502, 503, 504: return .busy(retryAfter)
        default: return .failed(status)
        }
    }
}
