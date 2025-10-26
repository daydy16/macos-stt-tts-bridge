import Foundation
import AVFoundation

enum AudioError: Error {
    case unsupportedFormat(String)
    case conversionFailed(String)
    case io(String)
}

final class AudioResampler {
    func fileToPCM16Mono16k(url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let src = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: frames) else {
            throw AudioError.conversionFailed("allocate src")
        }
        try file.read(into: buf)

        let dst = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        return try convert(buf, to: dst)
    }

    func rawL16ToBuffer(data: Data, sampleRate: Double, channels: AVAudioChannelCount) throws -> AVAudioPCMBuffer {
        let src = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: channels, interleaved: true)!
        let frames = AVAudioFrameCount(data.count / Int(channels) / 2)
        guard let buf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: frames) else {
            throw AudioError.conversionFailed("allocate raw")
        }
        buf.frameLength = frames
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(buf.int16ChannelData![0], base, data.count)
            }
        }
        if sampleRate == 16000 && channels == 1 { return buf }
        let dst = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        return try convert(buf, to: dst)
    }

    func convert(_ src: AVAudioPCMBuffer, to dst: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let conv = AVAudioConverter(from: src.format, to: dst) else {
            throw AudioError.conversionFailed("create converter")
        }
        let ratio = Double(dst.sampleRate) / src.format.sampleRate
        let dstFrames = AVAudioFrameCount(Double(src.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: dstFrames) else {
            throw AudioError.conversionFailed("allocate dst")
        }
        var err: NSError?
        let status = conv.convert(to: out, error: &err, withInputFrom: { _, outStatus in
            outStatus.pointee = .haveData
            return src
        })
        if status == .error || err != nil { throw AudioError.conversionFailed("convert fail: \(err?.localizedDescription ?? "unknown")") }
        out.frameLength = out.frameCapacity
        return out
    }

    func wavData(from int16buf: AVAudioPCMBuffer, sampleRate: Int = 16000) throws -> Data {
        guard int16buf.format.commonFormat == .pcmFormatInt16 else {
            throw AudioError.unsupportedFormat("expect Int16")
        }
        let ch = Int(int16buf.format.channelCount)
        let bits = 16
        let byteRate = sampleRate * ch * bits / 8
        let blockAlign = ch * bits / 8
        let frames = Int(int16buf.frameLength)
        let dataBytes = frames * blockAlign

        var out = Data()
        func u32(_ v: UInt32){ var x=v.littleEndian; withUnsafeBytes(of:&x){ out.append(contentsOf:$0) } }
        func u16(_ v: UInt16){ var x=v.littleEndian; withUnsafeBytes(of:&x){ out.append(contentsOf:$0) } }

        out.append("RIFF".data(using:.ascii)!); u32(UInt32(36+dataBytes)); out.append("WAVE".data(using:.ascii)!)
        out.append("fmt ".data(using:.ascii)!); u32(16); u16(1); u16(UInt16(ch)); u32(UInt32(sampleRate)); u32(UInt32(byteRate)); u16(UInt16(blockAlign)); u16(UInt16(bits))
        out.append("data".data(using:.ascii)!); u32(UInt32(dataBytes))

        var pcm = Data(count: dataBytes)
        let dest = pcm.withUnsafeMutableBytes { $0.bindMemory(to: Int16.self).baseAddress! }
        let src = int16buf.int16ChannelData![0]
        dest.update(from: src, count: frames * ch)
        out.append(pcm)
        return out
    }
}
