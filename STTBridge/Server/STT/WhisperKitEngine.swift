import Foundation
import AVFoundation

// WhisperKit is an optional, externally-added Swift package
// (https://github.com/argmaxinc/argmax-oss-swift). The engine compiles only
// when the package is linked, so the project always builds out of the box.
// See README → "Enabling the WhisperKit engine" for the one-time setup.
#if canImport(WhisperKit)
import WhisperKit

/// Alternative STT backend using WhisperKit (CoreML/ANE Whisper, 99+ languages
/// incl. German). Selected via `STT_ENGINE=whisperkit`. WhisperKit does
/// windowed pseudo-streaming: we re-transcribe a growing in-memory buffer on a
/// fixed cadence to surface partials, and run one final pass on end-of-speech.
nonisolated final class WhisperKitEngine: STTEngine, @unchecked Sendable {
    let id = "whisperkit"

    private let modelName: String
    private let lock = NSLock()
    private var whisperKit: WhisperKit?
    private var loadTask: Task<WhisperKit, Error>?

    init(model: String) {
        self.modelName = model
    }

    func supportedLanguages() async -> [String] {
        // Multilingual Whisper models cover 99+ languages; advertise the common set.
        ["de-DE", "en-US", "fr-FR", "es-ES", "it-IT", "nl-NL", "pt-PT"]
    }

    func isOnDeviceAvailable(locale: Locale) async -> Bool { true }

    func prewarm(locale: Locale) async {
        _ = try? await instance()
    }

    func startSession(locale: Locale, requireOnDevice: Bool) async throws -> STTSession {
        let wk = try await instance()
        let lang = String(locale.identifier.prefix(2)).lowercased()
        return WhisperKitSession(whisperKit: wk, language: lang)
    }

    /// Lazily load + cache a single WhisperKit instance (downloads the CoreML
    /// model on first use). Concurrent callers share one load.
    private func instance() async throws -> WhisperKit {
        lock.lock()
        if let wk = whisperKit { lock.unlock(); return wk }
        if let existing = loadTask { lock.unlock(); return try await existing.value }
        let model = modelName
        let task = Task { () throws -> WhisperKit in
            let config = WhisperKitConfig(model: model, prewarm: true, load: true, download: true)
            return try await WhisperKit(config)
        }
        loadTask = task
        lock.unlock()

        let wk = try await task.value
        lock.lock(); whisperKit = wk; lock.unlock()
        return wk
    }
}

nonisolated final class WhisperKitSession: STTSession, @unchecked Sendable {
    let results: AsyncStream<STTResult>

    private let resultsCont: AsyncStream<STTResult>.Continuation
    private let whisperKit: WhisperKit
    private let language: String

    /// Partials only re-transcribe a bounded tail window (cheap, ~constant cost
    /// per tick); the full buffer is transcribed once at finishAudio. This
    /// avoids O(n²) re-transcription of the whole growing utterance.
    private let maxPartialSamples = 16_000 * 12 // ~12 s

    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var loopTask: Task<Void, Never>?
    private var finished = false

    init(whisperKit: WhisperKit, language: String) {
        self.whisperKit = whisperKit
        self.language = language

        var cont: AsyncStream<STTResult>.Continuation!
        results = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        resultsCont = cont

        startPartialLoop()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        var conv = converter
        lock.unlock()
        let floats = AudioBufferUtil.floatArray16kMono(from: buffer, converter: &conv)
        lock.lock()
        converter = conv
        samples.append(contentsOf: floats)
        lock.unlock()
    }

    func finishAudio() async {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let snap = samples
        lock.unlock()

        loopTask?.cancel()
        let text = await transcribe(snap)
        resultsCont.yield(STTResult(text: text, isFinal: true))
        resultsCont.finish()
    }

    func cancel() {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        lock.unlock()
        loopTask?.cancel()
        resultsCont.finish()
    }

    // MARK: - Internals

    private func startPartialLoop() {
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000) // ~400 ms cadence
                guard let self else { return }
                self.lock.lock()
                let done = self.finished
                let snap = Array(self.samples.suffix(self.maxPartialSamples)) // bounded tail
                self.lock.unlock()
                if done { return }
                guard snap.count > 8_000 else { continue } // ~0.5 s of 16 kHz audio
                let text = await self.transcribe(snap)
                if !text.isEmpty {
                    self.resultsCont.yield(STTResult(text: text, isFinal: false))
                }
            }
        }
    }

    private func transcribe(_ samples: [Float]) async -> String {
        guard !samples.isEmpty else { return "" }
        let options = DecodingOptions(task: .transcribe,
                                      language: language,
                                      skipSpecialTokens: true)
        let results = try? await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        return (results ?? []).map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#endif
