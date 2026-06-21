import Foundation
import AVFoundation

/// A single transcription result emitted while a stream is in flight.
///
/// `isFinal == false` is a *volatile* (partial) guess that may still change.
/// `isFinal == true` is a stabilized result that will not change.
nonisolated struct STTResult: Sendable {
    let text: String
    let isFinal: Bool
    let confidence: Double?

    init(text: String, isFinal: Bool, confidence: Double? = nil) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
    }
}

/// A live, streaming transcription session over a single utterance.
///
/// The contract is deliberately transport-agnostic: HTTP/WebSocket, Wyoming and
/// the one-shot `POST /stt` path all drive the same session shape. Audio is
/// pushed in incrementally via ``append(_:)``; partial and final results come
/// out of ``results``; ``finishAudio()`` promotes the last volatile result to
/// final the instant the audio stream ends (no re-recognition of the whole clip).
nonisolated protocol STTSession: AnyObject, Sendable {
    /// Partial + final results, in order. Completes after ``finishAudio()`` (or
    /// ``cancel()``) once the engine has flushed everything.
    var results: AsyncStream<STTResult> { get }

    /// Feed an audio buffer as soon as it is captured. The session converts it
    /// to whatever format the underlying engine requires. Safe to call from any
    /// thread.
    func append(_ buffer: AVAudioPCMBuffer)

    /// Signal end-of-speech and finalize immediately. Resolves once the final
    /// result has been emitted on ``results``.
    func finishAudio() async

    /// Abort without finalizing (e.g. client disconnected).
    func cancel()
}

/// A swappable speech-to-text backend. Backends are factories that hand out
/// per-utterance ``STTSession`` instances; no recognition state lives in the
/// transport layer.
nonisolated protocol STTEngine: AnyObject, Sendable {
    /// Stable identifier, surfaced in `/healthz` and logs.
    var id: String { get }

    /// Locales the engine can serve, as BCP-47 identifiers (e.g. `de-DE`).
    func supportedLanguages() async -> [String]

    /// Whether the engine can transcribe `locale` fully on-device right now
    /// (assets installed). Used to honor `offline=true`.
    func isOnDeviceAvailable(locale: Locale) async -> Bool

    /// Pre-load / download assets and warm the model so the first request is
    /// not penalized by a cold start.
    func prewarm(locale: Locale) async

    /// Begin a new streaming session for one utterance.
    ///
    /// `requireOnDevice` forces fully-offline recognition (no network egress).
    /// `SpeechAnalyzer` and WhisperKit are always on-device and ignore it; the
    /// legacy `SFSpeechRecognizer` honors it and throws if on-device assets are
    /// unavailable.
    func startSession(locale: Locale, requireOnDevice: Bool) async throws -> STTSession
}
