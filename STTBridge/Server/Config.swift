import Foundation

/// Which speech-to-text backend the bridge uses.
///
/// The default is ``speechAnalyzer`` (Apple's modern on-device `SpeechAnalyzer`
/// API, macOS 26+). The legacy `SFSpeechRecognizer` path is kept selectable for
/// A/B comparison, and WhisperKit can be enabled if the package is linked.
nonisolated enum STTEngineKind: String {
    case speechAnalyzer = "speechanalyzer"
    case legacy         = "legacy"
    case whisperKit     = "whisperkit"

    init(envValue: String?) {
        switch (envValue ?? "").lowercased() {
        case "legacy", "sf", "sfspeechrecognizer": self = .legacy
        case "whisperkit", "whisper":              self = .whisperKit
        default:                                   self = .speechAnalyzer
        }
    }
}

nonisolated struct Config: Sendable {
    // HTTP / WebSocket (browser test UI + existing HA custom integration)
    let port: Int
    let bindHost: String
    let authToken: String?
    let defaultLang: String
    let offlineOnly: Bool

    // STT engine selection
    let sttEngine: STTEngineKind

    // WhisperKit
    let whisperModel: String

    // Wyoming TCP transport (native Home Assistant integration)
    let wyomingEnabled: Bool
    let wyomingPort: Int
    let wyomingBindHost: String
    let wyomingAdvertiseBonjour: Bool
    let serviceName: String

    // TTS streaming
    let ttsSampleRate: Int

    init(env: [String: String] = ProcessInfo.processInfo.environment) {
        port = Int(env["PORT"] ?? "") ?? 8787
        bindHost = env["BIND_HOST"] ?? "127.0.0.1"
        authToken = env["AUTH_TOKEN"]
        defaultLang = env["DEFAULT_LANG"] ?? "de-DE"
        offlineOnly = (env["OFFLINE_ONLY"] ?? "false").lowercased() == "true"

        sttEngine = STTEngineKind(envValue: env["STT_ENGINE"])
        whisperModel = env["WHISPER_MODEL"] ?? "large-v3-v20240930_626MB"

        wyomingEnabled = (env["WYOMING_ENABLED"] ?? "true").lowercased() == "true"
        wyomingPort = Int(env["WYOMING_PORT"] ?? "") ?? 10700
        // Wyoming must be reachable by Home Assistant, so default to all interfaces.
        wyomingBindHost = env["WYOMING_BIND_HOST"] ?? "0.0.0.0"
        wyomingAdvertiseBonjour = (env["WYOMING_BONJOUR"] ?? "true").lowercased() == "true"
        serviceName = env["SERVICE_NAME"] ?? "macOS STT/TTS Bridge"

        ttsSampleRate = Int(env["TTS_SAMPLE_RATE"] ?? "") ?? 22050
    }
}
