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

    private let lock = NSLock()
    private var didFinish = false
    private var finalContinuation: CheckedContinuation<Void, Never>?

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
                self.complete()
                return
            }
            guard let result else { return }
            let text = result.bestTranscription.formattedString
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
        request.append(buffer)
    }

    func finishAudio() async {
        request.endAudio()
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
