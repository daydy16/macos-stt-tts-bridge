import Foundation
import Speech
import AVFoundation

/// Legacy STT backend wrapping `SFSpeechRecognizer`. Kept selectable behind the
/// `STT_ENGINE=legacy` flag for A/B comparison against `SpeechAnalyzer` until the
/// new path is proven (hard requirement §3.7).
nonisolated final class LegacySFEngine: STTEngine, @unchecked Sendable {
    let id = "legacy"

    private let lock = NSLock()
    private var cache: [String: SFSpeechRecognizer] = [:]

    func supportedLanguages() async -> [String] {
        SFSpeechRecognizer.supportedLocales().map { $0.identifier }.sorted()
    }

    func isOnDeviceAvailable(locale: Locale) async -> Bool {
        recognizer(for: locale)?.supportsOnDeviceRecognition ?? false
    }

    func prewarm(locale: Locale) async {
        _ = recognizer(for: locale)
    }

    func startSession(locale: Locale, requireOnDevice: Bool) async throws -> STTSession {
        guard let rec = recognizer(for: locale) else {
            throw APIError.badRequest("Unsupported language \(locale.identifier)")
        }
        return try LegacySFSession(recognizer: rec, requireOnDevice: requireOnDevice)
    }

    private func recognizer(for locale: Locale) -> SFSpeechRecognizer? {
        lock.lock(); defer { lock.unlock() }
        let key = locale.identifier
        if let cached = cache[key] { return cached }
        guard let rec = SFSpeechRecognizer(locale: locale) else { return nil }
        cache[key] = rec
        return rec
    }
}

/// One streaming utterance for `SFSpeechRecognizer`.
nonisolated final class LegacySFSession: STTSession, @unchecked Sendable {
    let results: AsyncStream<STTResult>

    private let resultsCont: AsyncStream<STTResult>.Continuation
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?

    /// Safety net: SFSpeechRecognizer occasionally neither delivers a final
    /// result nor an error after `endAudio()` (e.g. very short/silent audio).
    /// Without this, `finishAudio()` would await forever.
    private let finalizeTimeout: TimeInterval = 8

    private let lock = NSLock()
    private var didFinish = false
    private var finalContinuation: CheckedContinuation<Void, Never>?
    private var lastText = ""
    private var converter: AVAudioConverter?

    init(recognizer: SFSpeechRecognizer, requireOnDevice: Bool) throws {
        var cont: AsyncStream<STTResult>.Continuation!
        results = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        resultsCont = cont

        request.shouldReportPartialResults = true
        if requireOnDevice {
            guard recognizer.supportsOnDeviceRecognition else {
                throw APIError.preconditionFailed("offline=true angefragt, On-Device nicht verfügbar.")
            }
            request.requiresOnDeviceRecognition = true
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let error {
                NSLog("Legacy STT error: \(error.localizedDescription)")
                self.resultsCont.yield(.failure("Spracherkennung fehlgeschlagen: \(error.localizedDescription)"))
                self.complete()
                return
            }
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            self.lock.lock(); self.lastText = text; self.lock.unlock()
            if result.isFinal {
                let segs = result.transcriptions.first?.segments ?? []
                let conf = segs.isEmpty
                    ? nil
                    : segs.reduce(0.0) { $0 + Double($1.confidence) } / Double(segs.count)
                self.resultsCont.yield(STTResult(text: text, isFinal: true, confidence: conf))
                self.complete()
            } else {
                self.resultsCont.yield(STTResult(text: text, isFinal: false))
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        // Restore the old behavior of feeding a consistent 16 kHz mono format.
        let canonical = AudioBufferUtil.canonicalFormat
        if buffer.format == canonical {
            request.append(buffer)
            return
        }
        lock.lock()
        if converter == nil { converter = AVAudioConverter(from: buffer.format, to: canonical) }
        let conv = converter
        lock.unlock()
        if let conv, let out = AudioBufferUtil.convert(buffer, using: conv, to: canonical) {
            request.append(out)
        } else {
            request.append(buffer)
        }
    }

    func finishAudio() async {
        request.endAudio()

        // Arm a timeout that finalizes with the best partial we have.
        let timeout = finalizeTimeout
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self else { return }
            self.lock.lock()
            let done = self.didFinish
            let text = self.lastText
            self.lock.unlock()
            guard !done else { return }
            NSLog("Legacy STT finalize timed out; returning best partial.")
            self.resultsCont.yield(STTResult(text: text, isFinal: true))
            self.complete()
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if didFinish {
                lock.unlock()
                cont.resume()
                return
            }
            finalContinuation = cont
            lock.unlock()
        }
    }

    func cancel() {
        task?.cancel()
        complete()
    }

    private func complete() {
        lock.lock()
        if didFinish { lock.unlock(); return }
        didFinish = true
        let cont = finalContinuation
        finalContinuation = nil
        lock.unlock()
        resultsCont.finish()
        cont?.resume()
    }
}
