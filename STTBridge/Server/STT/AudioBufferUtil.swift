import Foundation
import AVFoundation

/// Shared, allocation-light audio helpers used by every STT engine and both
/// transports. Everything operates in-memory — no temp files, no disk I/O
/// (see latency checklist §7.4).
nonisolated enum AudioBufferUtil {

    /// The canonical wire format used by the browser UI and Home Assistant:
    /// 16 kHz, mono, signed 16-bit little-endian PCM, interleaved.
    static let canonicalFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true)!

    /// Wrap raw interleaved Int16 PCM bytes in an `AVAudioPCMBuffer` without
    /// copying through a file.
    static func int16Buffer(from data: Data, sampleRate: Double, channels: Int) -> AVAudioPCMBuffer? {
        guard channels > 0,
              let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: sampleRate,
                                      channels: AVAudioChannelCount(channels),
                                      interleaved: true)
        else { return nil }

        let bytesPerFrame = 2 * channels
        let frames = data.count / bytesPerFrame
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }

        buf.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(buf.int16ChannelData![0], base, frames * bytesPerFrame)
            }
        }
        return buf
    }

    /// Convert one buffer through a (reused) converter into `format`. Reusing
    /// the converter across calls preserves sample-rate-conversion state, so
    /// chunked streaming stays continuous. The converter sets the correct
    /// output `frameLength` itself.
    static func convert(_ src: AVAudioPCMBuffer,
                        using converter: AVAudioConverter,
                        to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / src.format.sampleRate
        let capacity = AVAudioFrameCount(Double(src.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var fed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, inStatus in
            if fed {
                inStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inStatus.pointee = .haveData
            return src
        }
        if status == .error || err != nil { return nil }
        return out
    }

    /// Parse a 16-bit PCM WAV container fully in-memory (no temp file) and wrap
    /// its samples in a buffer at the WAV's native rate/channels. Returns nil if
    /// the data isn't a 16-bit PCM RIFF/WAVE file.
    static func pcm16BufferFromWAV(_ data: Data) -> AVAudioPCMBuffer? {
        guard data.count > 44 else { return nil }

        func u32(_ o: Int) -> UInt32 {
            UInt32(data[o]) | UInt32(data[o + 1]) << 8 | UInt32(data[o + 2]) << 16 | UInt32(data[o + 3]) << 24
        }
        func u16(_ o: Int) -> UInt16 { UInt16(data[o]) | UInt16(data[o + 1]) << 8 }
        func tag(_ o: Int) -> String { String(bytes: data[o..<o + 4], encoding: .ascii) ?? "" }

        guard tag(0) == "RIFF", tag(8) == "WAVE" else { return nil }

        var offset = 12
        var channels = 1
        var sampleRate: Double = 16_000
        var bits = 16
        var audioFormat: UInt16 = 1
        var pcm: Data?

        while offset + 8 <= data.count {
            let id = tag(offset)
            let size = Int(u32(offset + 4))
            let body = offset + 8
            if id == "fmt " {
                audioFormat = u16(body)
                channels = Int(u16(body + 2))
                sampleRate = Double(u32(body + 4))
                bits = Int(u16(body + 14))
            } else if id == "data" {
                let end = min(body + size, data.count)
                if body <= end { pcm = data.subdata(in: body..<end) }
            }
            offset = body + size + (size & 1) // chunks are word-aligned
        }

        guard audioFormat == 1, bits == 16, let pcm else { return nil }
        return int16Buffer(from: pcm, sampleRate: sampleRate, channels: channels)
    }

    /// Convert an arbitrary PCM buffer to a 16 kHz mono Float32 sample array,
    /// the format WhisperKit expects.
    static func floatArray16kMono(from buffer: AVAudioPCMBuffer,
                                  converter: inout AVAudioConverter?) -> [Float] {
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16_000,
                                   channels: 1,
                                   interleaved: false)!
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let conv = converter,
              let out = convert(buffer, using: conv, to: target),
              let ch = out.floatChannelData
        else { return [] }
        let n = Int(out.frameLength)
        return Array(UnsafeBufferPointer(start: ch[0], count: n))
    }
}
