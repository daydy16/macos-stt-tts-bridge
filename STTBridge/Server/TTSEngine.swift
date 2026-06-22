import Foundation
import AVFoundation

@MainActor
final class TTSEngine: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private let resampler = AudioResampler()

    func listVoices() -> [VoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices().map { v in
            VoiceInfo(name: v.name, identifier: v.identifier, language: v.language, quality: v.quality.rawValue)
        }
    }

    func speakLocal(_ text: String, voiceId: String?, rate: Double?, pitch: Double?) {
        let u = makeUtterance(text: text, voiceId: voiceId, rate: rate, pitch: pitch)
        synth.speak(u)
    }

    /// Hinweis zu besseren Stimmen:
    /// macOS → Systemeinstellungen → Bedienungshilfen → Gesprochene Inhalte → "Stimmen".
    /// Für die gewünschte Sprache (z. B. Deutsch) eine "Erweiterte"/"Enhanced" Stimme herunterladen.
    /// AVSpeechSynthesizer kann **Siri**-Stimmen nicht direkt nutzen, aber Enhanced‑Stimmen sind deutlich hochwertiger.
    /// Die neuen AFM-3 / "expressive" Stimmen sind Drittanbietern nicht zugänglich.
    func makeUtterance(text: String, voiceId: String?, rate: Double?, pitch: Double?, language: String? = nil) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)

        // Choose voice: explicit, non-empty identifier wins
        if let id = voiceId, !id.isEmpty, let v = AVSpeechSynthesisVoice(identifier: id) {
            u.voice = v
        } else {
            // Otherwise pick the highest-quality voice for the language
            // (Premium > Enhanced > Default). Download Premium voices in
            // System Settings → Accessibility → Spoken Content → System Voice.
            let targetLang = language ?? "de-DE"
            let langPrefix = String(targetLang.prefix(2)).lowercased()
            let all = AVSpeechSynthesisVoice.speechVoices()
            var candidates = all.filter { $0.language == targetLang }
            if candidates.isEmpty {
                candidates = all.filter { $0.language.lowercased().hasPrefix(langPrefix) }
            }
            if let best = candidates.max(by: { $0.quality.rawValue < $1.quality.rawValue }) {
                u.voice = best
            }
        }

        u.prefersAssistiveTechnologySettings = true

        if let r = rate {
            let clamped = max(0.5, min(2.0, r))
            u.rate = Float(clamped) * AVSpeechUtteranceDefaultSpeechRate
        } else {
            u.rate = AVSpeechUtteranceDefaultSpeechRate
        }

        if let p = pitch {
            let mapped = max(0.0, min(2.0, 1.0 + p))
            u.pitchMultiplier = Float(mapped)
        }

        return u
    }

    // MARK: - One-shot (back-compat: GET/POST /tts)

    /// Synthesize → 16 kHz mono PCM16 WAV.
    func synthesizeToWAV(text: String, voiceId: String?, rate: Double?, pitch: Double?, language: String? = nil) async throws -> Data {
        let utterance = makeUtterance(text: text, voiceId: voiceId, rate: rate, pitch: pitch, language: language)
        let buffer = try await renderPCM16Buffer(utterance: utterance, sampleRate: 16_000)
        return try resampler.wavData(from: buffer, sampleRate: 16_000)
    }

    // MARK: - Streaming (Phase 2: sentence-boundary chunking)

    /// Synthesize sentence by sentence, emitting raw little-endian PCM16 (mono,
    /// at `sampleRate`) for each sentence the moment it is ready. This lets a
    /// consumer (Wyoming, the streaming HTTP endpoint) start playback long
    /// before the full response is synthesized — the biggest win on long
    /// answers (§7.5).
    nonisolated func synthesizeStream(text: String,
                                      voiceId: String?,
                                      rate: Double?,
                                      pitch: Double?,
                                      language: String? = nil,
                                      sampleRate: Int) -> AsyncStream<Data> {
        AsyncStream { continuation in
            Task { @MainActor in
                let sentences = Self.splitSentences(text)
                for sentence in sentences {
                    let utterance = self.makeUtterance(text: sentence, voiceId: voiceId, rate: rate, pitch: pitch, language: language)
                    if let buffer = try? await self.renderPCM16Buffer(utterance: utterance, sampleRate: sampleRate) {
                        continuation.yield(Self.rawPCM(from: buffer))
                    }
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Internals

    /// Render an utterance to a single interleaved Int16 mono buffer at `sampleRate`.
    private func renderPCM16Buffer(utterance: AVSpeechUtterance, sampleRate: Int) async throws -> AVAudioPCMBuffer {
        var collected: [AVAudioPCMBuffer] = []
        var sourceFormat: AVAudioFormat?
        var continuation: CheckedContinuation<AVAudioPCMBuffer, Error>?

        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            self.synth.write(utterance) { buffer in
                guard continuation != nil else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }

                if pcm.frameLength > 0 {
                    collected.append(pcm)
                    if sourceFormat == nil { sourceFormat = pcm.format }
                    return
                }

                // Final zero-length buffer: stitch, convert, resume.
                do {
                    guard let f = sourceFormat, !collected.isEmpty else {
                        throw AudioError.io("TTS lieferte keine Audiodaten")
                    }
                    let stitched = try Self.stitch(collected, format: f)
                    let dst = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: Double(sampleRate),
                                            channels: 1,
                                            interleaved: true)!
                    let mono: AVAudioPCMBuffer
                    if f == dst {
                        mono = stitched
                    } else {
                        guard let conv = AVAudioConverter(from: f, to: dst),
                              let out = AudioBufferUtil.convert(stitched, using: conv, to: dst) else {
                            throw AudioError.conversionFailed("tts resample")
                        }
                        mono = out
                    }
                    continuation?.resume(returning: mono)
                    continuation = nil
                } catch {
                    continuation?.resume(throwing: error)
                    continuation = nil
                }
            }
        }
    }

    private static func stitch(_ buffers: [AVAudioPCMBuffer], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let total = buffers.reduce(0) { $0 + Int($1.frameLength) }
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)) else {
            throw AudioError.conversionFailed("alloc stitched")
        }
        out.frameLength = AVAudioFrameCount(total)
        var cursor = 0
        for b in buffers {
            let n = Int(b.frameLength)
            if format.commonFormat == .pcmFormatFloat32 {
                out.floatChannelData![0].advanced(by: cursor).update(from: b.floatChannelData![0], count: n)
            } else if format.commonFormat == .pcmFormatInt16 {
                out.int16ChannelData![0].advanced(by: cursor).update(from: b.int16ChannelData![0], count: n)
            }
            cursor += n
        }
        return out
    }

    private static func rawPCM(from buffer: AVAudioPCMBuffer) -> Data {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let byteCount = frames * channels * 2
        guard byteCount > 0, let src = buffer.int16ChannelData else { return Data() }
        var data = Data(count: byteCount)
        data.withUnsafeMutableBytes { raw in
            if let dst = raw.baseAddress { memcpy(dst, src[0], byteCount) }
        }
        return data
    }

    /// Split text into sentence-sized chunks for incremental synthesis.
    nonisolated static func splitSentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" || ch == ";" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.append(trimmed) }
        return result.isEmpty ? [text] : result
    }
}
