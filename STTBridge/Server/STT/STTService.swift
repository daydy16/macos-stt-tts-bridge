import Foundation
import AVFoundation

/// Engine-agnostic STT coordinator. Owns the configured ``STTEngine``, warms it
/// at startup, and exposes both streaming sessions (for the WebSocket and
/// Wyoming transports) and one-shot transcription (for `POST /stt`). No
/// recognition logic lives in the transport layer.
nonisolated final class STTService: @unchecked Sendable {
    let cfg: Config
    let engine: STTEngine

    init(config: Config) {
        self.cfg = config

        switch config.sttEngine {
        case .speechAnalyzer:
            engine = SpeechAnalyzerEngine()
        case .legacy:
            engine = LegacySFEngine()
        case .whisperKit:
            #if canImport(WhisperKit)
            engine = WhisperKitEngine(model: config.whisperModel)
            #else
            NSLog("STT_ENGINE=whisperkit requested but WhisperKit is not linked; using SpeechAnalyzer.")
            engine = SpeechAnalyzerEngine()
            #endif
        }
        NSLog("STT engine: \(engine.id)")

        // Warm the default locale so the first request avoids a cold start (§7.3).
        let warmEngine = engine
        let lang = config.defaultLang
        Task.detached { await warmEngine.prewarm(locale: Locale(identifier: lang)) }
    }

    var engineId: String { engine.id }

    func languages() async -> [String] {
        await engine.supportedLanguages()
    }

    func onDeviceSupported(lang: String) async -> Bool {
        await engine.isOnDeviceAvailable(locale: Locale(identifier: lang))
    }

    /// Begin a streaming session. `requireOnDevice` forces offline recognition.
    func startSession(lang: String, requireOnDevice: Bool) async throws -> STTSession {
        try await engine.startSession(locale: Locale(identifier: lang),
                                      requireOnDevice: requireOnDevice || cfg.offlineOnly)
    }

    /// One-shot transcription of a complete buffer, driving a streaming session
    /// to completion. Used by `POST /stt`.
    func transcribeOneShot(buffer: AVAudioPCMBuffer,
                           lang: String,
                           requireOnDevice: Bool) async throws -> STTResponse {
        let session = try await startSession(lang: lang, requireOnDevice: requireOnDevice)
        session.append(buffer)
        await session.finishAudio()

        var text = ""
        var confidence: Double?
        for await result in session.results where result.isFinal {
            text = result.text
            confidence = result.confidence
        }
        return STTResponse(text: text, isFinal: true, confidence: confidence, words: [])
    }

    /// Decode raw PCM (with sample-rate/channel headers) or a WAV container
    /// in-memory, then transcribe one-shot.
    func transcribeRaw(data: Data,
                       sampleRate: Double?,
                       channels: Int?,
                       lang: String,
                       requireOnDevice: Bool) async throws -> STTResponse {
        let buffer: AVAudioPCMBuffer
        if let sr = sampleRate, let ch = channels {
            guard let b = AudioBufferUtil.int16Buffer(from: data, sampleRate: sr, channels: ch) else {
                throw APIError.badRequest("Ungültige PCM-Daten")
            }
            buffer = b
        } else if let b = AudioBufferUtil.pcm16BufferFromWAV(data) {
            buffer = b
        } else {
            throw APIError.badRequest("Audio konnte nicht gelesen werden (erwarte 16-bit PCM/WAV).")
        }
        return try await transcribeOneShot(buffer: buffer, lang: lang, requireOnDevice: requireOnDevice)
    }
}
