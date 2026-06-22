import Foundation
import Speech
import AVFoundation

/// Default STT backend: Apple's modern on-device `SpeechAnalyzer` +
/// `SpeechTranscriber` (Speech framework, macOS 26+). Runs on the Apple Neural
/// Engine, streams volatile (partial) results live, and finalizes the instant
/// the audio stream ends — no whole-clip re-recognition.
///
/// Language assets are system-managed (downloaded once via `AssetInventory`,
/// not bundled with the app). German (`de-DE`) is supported.
///
/// Finalized results carry a per-run confidence attribute
/// (`.transcriptionConfidence`), averaged into ``STTResult/confidence`` so callers
/// can gate low-confidence commands without giving up `SpeechTranscriber`'s
/// accuracy (which, unlike `DictationTranscriber`, cannot be vocabulary-biased).
nonisolated final class SpeechAnalyzerEngine: STTEngine, @unchecked Sendable {
    let id = "speechanalyzer"

    func supportedLanguages() async -> [String] {
        (await SpeechTranscriber.supportedLocales)
            .map { $0.identifier(.bcp47) }
            .sorted()
    }

    func isOnDeviceAvailable(locale: Locale) async -> Bool {
        (await SpeechTranscriber.installedLocales)
            .contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    /// Download `de-DE` (or the requested locale) assets and reserve the locale
    /// at startup so the first request isn't penalized by a cold start.
    func prewarm(locale: Locale) async {
        do { try await ensureModel(locale: locale) }
        catch { NSLog("SpeechAnalyzer prewarm failed for \(locale.identifier): \(error)") }
    }

    func startSession(locale: Locale, requireOnDevice: Bool) async throws -> STTSession {
        // SpeechAnalyzer is always on-device; `requireOnDevice` is implicitly satisfied.
        try await ensureModel(locale: locale)

        let transcriber = makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        return try await SpeechAnalyzerSession(analyzer: analyzer,
                                               transcriber: transcriber,
                                               analyzerFormat: format)
    }

    // MARK: - Internals

    private func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        // `.transcriptionConfidence` attaches a confidence attribute to finalized
        // result runs so callers can gate low-confidence commands (surfaced on the
        // HTTP/WS path and logged on Wyoming). `SpeechTranscriber` itself stays the
        // high-accuracy module — it cannot be biased with contextual strings, so
        // confidence is our no-trade-off reliability lever (see
        // docs/research/2026-06-stt-context-enrichment.md).
        SpeechTranscriber(locale: locale,
                          transcriptionOptions: [],
                          reportingOptions: [.volatileResults],
                          attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }

    /// Verify the locale is supported, install its assets if missing, and
    /// reserve it (assets are limited to `AssetInventory.maximumReservedLocales`).
    private func ensureModel(locale: Locale) async throws {
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw APIError.preconditionFailed(
                "SpeechAnalyzer unterstützt die Sprache \(locale.identifier) nicht.")
        }

        let probe = makeTranscriber(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try await request.downloadAndInstall()
        }

        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            _ = try await AssetInventory.reserve(locale: locale)
        }
    }
}

/// One streaming utterance for `SpeechAnalyzer`. Bridges the analyzer's
/// `AsyncStream<AnalyzerInput>` input and `transcriber.results` output to the
/// transport-agnostic ``STTSession`` contract.
nonisolated final class SpeechAnalyzerSession: STTSession, @unchecked Sendable {
    let results: AsyncStream<STTResult>

    private let resultsCont: AsyncStream<STTResult>.Continuation
    private let analyzer: SpeechAnalyzer
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private let analyzerFormat: AVAudioFormat?

    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var resultsTask: Task<Void, Never>?
    private var finished = false

    init(analyzer: SpeechAnalyzer,
         transcriber: SpeechTranscriber,
         analyzerFormat: AVAudioFormat?) async throws {
        self.analyzer = analyzer
        self.analyzerFormat = analyzerFormat

        var cont: AsyncStream<STTResult>.Continuation!
        self.results = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.resultsCont = cont

        let (inputSequence, inputCont) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputBuilder = inputCont

        // Pump the transcriber's results into our transport-facing stream.
        let resultsCont = self.resultsCont
        self.resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let confidence = Self.averageConfidence(of: result.text)
                    resultsCont.yield(STTResult(text: text,
                                                isFinal: result.isFinal,
                                                confidence: confidence))
                }
            } catch {
                NSLog("SpeechAnalyzer results error: \(error)")
                resultsCont.yield(.failure("Spracherkennung fehlgeschlagen: \(error.localizedDescription)"))
            }
            resultsCont.finish()
        }

        // Kick off analysis; buffers are pulled as they are yielded.
        try await analyzer.start(inputSequence: inputSequence)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let fmt = analyzerFormat else {
            inputBuilder.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if buffer.format == fmt {
            inputBuilder.yield(AnalyzerInput(buffer: buffer))
            return
        }
        lock.lock()
        if converter == nil { converter = AVAudioConverter(from: buffer.format, to: fmt) }
        let conv = converter
        lock.unlock()
        guard let conv, let out = AudioBufferUtil.convert(buffer, using: conv, to: fmt) else { return }
        inputBuilder.yield(AnalyzerInput(buffer: out))
    }

    func finishAudio() async {
        lock.lock()
        let already = finished
        finished = true
        lock.unlock()
        guard !already else { return }

        inputBuilder.finish()
        do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
        catch { NSLog("SpeechAnalyzer finalize error: \(error)") }
        await resultsTask?.value
    }

    func cancel() {
        lock.lock()
        let already = finished
        finished = true
        lock.unlock()
        guard !already else { return }

        inputBuilder.finish()
        resultsTask?.cancel()
        let analyzer = self.analyzer
        Task { await analyzer.cancelAndFinishNow() }
        resultsCont.finish()
    }

    /// Average the per-run confidence attribute (present on finalized results when
    /// `.transcriptionConfidence` is requested). Returns `nil` for volatile results
    /// or when the OS attaches no confidence. Read via the attribute key type to
    /// avoid depending on the dynamic-member spelling.
    private static func averageConfidence(of text: AttributedString) -> Double? {
        var sum = 0.0
        var count = 0
        for run in text.runs {
            if let value = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] {
                sum += Double(value)
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : nil
    }
}
