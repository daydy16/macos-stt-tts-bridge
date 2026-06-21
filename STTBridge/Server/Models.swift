import Foundation

nonisolated struct Healthz: Codable, Sendable {
    let status: String
    let lang: String
    let engine: String
    let onDeviceSTT: Bool
}

nonisolated struct STTWord: Codable, Sendable {
    let token: String
    let start: Double
    let end: Double
}

nonisolated struct STTResponse: Codable, Sendable {
    let text: String
    let isFinal: Bool
    let confidence: Double?
    let words: [STTWord]
}

nonisolated struct TTSPayload: Codable, Sendable {
    let text: String
    let voiceId: String?
    let rate: Double?
    let pitch: Double?
    let speakLocal: Bool?
}

nonisolated struct VoiceInfo: Codable, Sendable {
    let name: String
    let identifier: String
    let language: String
    let quality: Int
}

nonisolated enum APIError: Error {
    case badRequest(String)
    case unauthorized(String)
    case conflict(String)
    case preconditionFailed(String)
    case internalError(String)

    var statusCode: Int {
        switch self {
        case .badRequest: return 400
        case .unauthorized: return 401
        case .conflict: return 409
        case .preconditionFailed: return 412
        case .internalError: return 500
        }
    }
    var message: String {
        switch self {
        case .badRequest(let s),
             .unauthorized(let s),
             .conflict(let s),
             .preconditionFailed(let s),
             .internalError(let s): return s
        }
    }
}
