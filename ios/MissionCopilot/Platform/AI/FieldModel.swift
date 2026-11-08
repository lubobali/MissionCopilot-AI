import Foundation

/// Everything a model call is given (#136): a prompt, the JSON schema its answer must fit, and a token cap.
/// Nothing else: no tools, no functions, no chat history, no network address. A call with tools cannot be
/// written, because there is nowhere to put them (threat T08, #63).
struct ModelRequest: Sendable, Equatable {
    let prompt: String
    let schema: String
    let maxTokens: Int
}

/// Why the model cannot answer at all, in words the screens can say (6.4.5).
enum ModelUnavailable: Error, Equatable, Sendable, Codable {
    /// Debug builds and builds made without the model (CI).
    case notInThisBuild
    /// The signature check refused it: never loaded (T46).
    case failedCheck
    /// It passed the check but could not be loaded (memory, a broken file).
    case couldNotLoad
}

/// The model itself: the real one is MLX on the iPhone (6.4.4); tests use a fake.
protocol ModelEngine: Sendable {
    func generate(_ request: ModelRequest) async throws -> String
}

/// A question for the model and the shape its answer must have.
struct ModelTask<Output: Decodable & Sendable>: Sendable {
    let prompt: String
    let schema: String
    let maxTokens: Int
}

/// What the app gets back. Only `answered` can be used; the rest go to a person or are shown as why not.
enum ModelAnswer<Output: Sendable>: Sendable {
    enum Refusal: Sendable, Equatable {
        case inputTooLong(characters: Int)
        case notSchemaValid
        case unavailable(ModelUnavailable)
        case failed
    }

    case answered(Output)
    case stopped
    case refused(Refusal)

    var usable: Output? {
        if case .answered(let output) = self { output } else { nil }
    }
}

extension ModelAnswer: Equatable where Output: Equatable {}

/// The one door to the model (#136, threats T06 and T08): the input cap before the model (its reading of the
/// prompt cannot be stopped, #48), the time limit on the answer (#62), the schema checked again by decoding,
/// and a fresh request every time.
struct FieldModel: Sendable {
    /// A normal page is a few thousand characters; 130,000 took 158 s and obeyed a buried instruction (#48).
    static let maxInputCharacters = 20_000

    let engine: any ModelEngine
    var limit = TimeLimit.model

    func run<Output: Decodable & Sendable>(_ task: ModelTask<Output>) async -> ModelAnswer<Output> {
        let characters = task.prompt.count
        guard characters <= Self.maxInputCharacters else { return .refused(.inputTooLong(characters: characters)) }
        let request = ModelRequest(prompt: task.prompt, schema: task.schema, maxTokens: task.maxTokens)
        let engine = engine
        let outcome: ModelOutcome<String>
        do {
            outcome = try await limit.run { try await engine.generate(request) }
        } catch let why as ModelUnavailable {
            return .refused(.unavailable(why))
        } catch {
            return .refused(.failed)
        }
        guard case .answered(let raw) = outcome else { return .stopped }
        guard let output = try? JSONDecoder().decode(Output.self, from: Data(raw.utf8)) else {
            return .refused(.notSchemaValid)
        }
        return .answered(output)
    }
}
