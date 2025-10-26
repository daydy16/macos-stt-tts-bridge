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
    /// Für die gewünschte Sprache (z. B. Deutsch) eine "Erweiterte"/"Enhanced" Stimme herunterladen.
    /// AVSpeechSynthesizer kann **Siri**-Stimmen nicht direkt nutzen, aber Enhanced‑Stimmen sind deutlich hochwertiger.
    private func makeUtterance(text: String, voiceId: String?, rate: Double?, pitch: Double?) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)

        // Choose voice: explicit, non-empty identifier wins
        if let id = voiceId, !id.isEmpty, let v = AVSpeechSynthesisVoice(identifier: id) {
            u.voice = v
        } else {
            // 2) Bevorzugt: Anna (de-DE), höchste Qualität
            let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "de-DE" }
            if let annaBest = candidates
                .filter({ $0.name == "Anna" })
                .sorted(by: { $0.quality.rawValue > $1.quality.rawValue })
                .first
            {
                u.voice = annaBest
            } else if let bestDE = candidates.sorted(by: { $0.quality.rawValue > $1.quality.rawValue }).first {
                // 3) Fallback: beste deutsche Stimme
                u.voice = bestDE
            }
        }

        // Optional sinnvoll:
        u.prefersAssistiveTechnologySettings = true

        // Rate: map 0.5..2.0 around default for natural prosody
        if let r = rate {
            let clamped = max(0.5, min(2.0, r))
            u.rate = Float(clamped) * AVSpeechUtteranceDefaultSpeechRate
        } else {
            u.rate = AVSpeechUtteranceDefaultSpeechRate
        }

        // Pitch: -1..1 → 0.5..2.0
        if let p = pitch {
            let mapped = max(0.0, min(2.0, 1.0 + p))
            u.pitchMultiplier = Float(mapped)
        }

        return u
    }

    /// Synthesize → 16kHz mono PCM16 WAV
    func synthesizeToWAV(text: String, voiceId: String?, rate: Double?, pitch: Double?) async throws -> Data {
        let utterance = makeUtterance(text: text, voiceId: voiceId, rate: rate, pitch: pitch)
        var collected: [AVAudioPCMBuffer] = []
        var fmt: AVAudioFormat?

        var nullableContinuation: CheckedContinuation<Data, Error>?
        let wav: Data = try await withCheckedThrowingContinuation { cont in
            nullableContinuation = cont
            self.synth.write(utterance) { buffer in
                // Only proceed if the continuation hasn't been resumed yet.
                guard nullableContinuation != nil else { return }

                guard let pcm = buffer as? AVAudioPCMBuffer else {
                    // Non-PCM buffer might indicate an issue, but we wait for the final zero-length buffer.
                    return
                }

                if pcm.frameLength > 0 {
                    collected.append(pcm)
                    if fmt == nil { fmt = pcm.format }
                    return // Still collecting data
                }

                // Final callback (frameLength == 0). This is where we process and resume.
                do {
                    guard let f = fmt, !collected.isEmpty else {
                        throw AudioError.io("TTS lieferte keine Audiodaten")
                    }
                    let total = collected.reduce(0) { $0 + Int($1.frameLength) }
                    guard let stitched = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(total)) else {
                        throw AudioError.conversionFailed("alloc")
                    }
                    stitched.frameLength = AVAudioFrameCount(total)
                    var cursor = 0
                    for b in collected {
                        let n = Int(b.frameLength)
                        if f.commonFormat == .pcmFormatFloat32 {
                            stitched.floatChannelData![0].advanced(by: cursor).update(from: b.floatChannelData![0], count: n)
                        } else if f.commonFormat == .pcmFormatInt16 {
                            stitched.int16ChannelData![0].advanced(by: cursor).update(from: b.int16ChannelData![0], count: n)
                        }
                        cursor += n
                    }
                    let dstFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
                    let mono = try self.resampler.convert(stitched, to: dstFmt)
                    let data = try self.resampler.wavData(from: mono, sampleRate: 16000)
                    
                    nullableContinuation?.resume(returning: data)
                    nullableContinuation = nil
                } catch {
                    nullableContinuation?.resume(throwing: error)
                    nullableContinuation = nil
                }
            }
        }
        return wav
    }
}

