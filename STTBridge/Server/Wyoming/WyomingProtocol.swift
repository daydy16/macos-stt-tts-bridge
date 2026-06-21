import Foundation
import NIOCore

/// Wyoming protocol version advertised in event headers. Matches the `wyoming`
/// library bundled by Home Assistant; the value is informational for readers.
let wyomingVersion = "1.9.0"

/// A decoded Wyoming event: a JSON header line, an optional JSON `data` region,
/// and an optional raw binary `payload` region (e.g. PCM).
nonisolated struct WyomingEvent {
    let type: String
    let data: [String: Any]
    let payload: Data?

    init(type: String, data: [String: Any] = [:], payload: Data? = nil) {
        self.type = type
        self.data = data
        self.payload = payload
    }
}

nonisolated enum WyomingFrame {
    /// Encode an event into a single ByteBuffer following the 3-region wire
    /// format: `<header JSON>\n<data JSON><payload>`. `data_length` /
    /// `payload_length` are byte counts of the UTF-8 / raw regions.
    static func encode(_ event: WyomingEvent, allocator: ByteBufferAllocator) -> ByteBuffer {
        var header: [String: Any] = ["type": event.type, "version": wyomingVersion]

        var dataBytes: Data?
        if !event.data.isEmpty,
           let encoded = try? JSONSerialization.data(withJSONObject: event.data) {
            dataBytes = encoded
            header["data_length"] = encoded.count
        }
        if let payload = event.payload, !payload.isEmpty {
            header["payload_length"] = payload.count
        }

        let headerLine = (try? JSONSerialization.data(withJSONObject: header)) ?? Data("{\"type\":\"\(event.type)\"}".utf8)

        var buf = allocator.buffer(capacity: headerLine.count + 1 + (dataBytes?.count ?? 0) + (event.payload?.count ?? 0))
        buf.writeBytes(headerLine)
        buf.writeInteger(UInt8(0x0A)) // '\n'
        if let dataBytes { buf.writeBytes(dataBytes) }
        if let payload = event.payload, !payload.isEmpty { buf.writeBytes(payload) }
        return buf
    }
}

/// Streaming decoder for the Wyoming wire format. Frames strictly by byte
/// counts (PCM payloads contain `0x0A`, so we never scan the payload for
/// newlines).
nonisolated struct WyomingFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = WyomingEvent

    private struct PendingHeader {
        let type: String
        let dataLength: Int
        let payloadLength: Int
        let inlineData: [String: Any]
    }

    private var pending: PendingHeader?

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        if let header = pending {
            let need = header.dataLength + header.payloadLength
            guard buffer.readableBytes >= need else { return .needMoreData }

            var data = header.inlineData
            if header.dataLength > 0, let bytes = buffer.readBytes(length: header.dataLength) {
                if let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] {
                    for (k, v) in obj { data[k] = v }
                }
            }
            var payload: Data?
            if header.payloadLength > 0, let bytes = buffer.readBytes(length: header.payloadLength) {
                payload = Data(bytes)
            }
            pending = nil
            context.fireChannelRead(wrapInboundOut(WyomingEvent(type: header.type, data: data, payload: payload)))
            return .continue
        }

        // Read one header line terminated by '\n'.
        let view = buffer.readableBytesView
        guard let newlineIndex = view.firstIndex(of: 0x0A) else {
            return .needMoreData
        }
        let lineLength = view.distance(from: view.startIndex, to: newlineIndex)
        guard let lineBytes = buffer.readBytes(length: lineLength) else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: 1) // consume '\n'

        guard let header = try? JSONSerialization.jsonObject(with: Data(lineBytes)) as? [String: Any],
              let type = header["type"] as? String else {
            // Malformed header line; skip it.
            return .continue
        }

        let dataLength = (header["data_length"] as? Int) ?? 0
        let payloadLength = (header["payload_length"] as? Int) ?? 0
        let inlineData = (header["data"] as? [String: Any]) ?? [:]

        if dataLength == 0 && payloadLength == 0 {
            context.fireChannelRead(wrapInboundOut(WyomingEvent(type: type, data: inlineData, payload: nil)))
            return .continue
        }

        pending = PendingHeader(type: type, dataLength: dataLength, payloadLength: payloadLength, inlineData: inlineData)
        return .continue
    }

    mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        // Try to flush any fully-buffered trailing frame, otherwise stop.
        if pending != nil || buffer.readableBytesView.firstIndex(of: 0x0A) != nil {
            return try decode(context: context, buffer: &buffer)
        }
        return .needMoreData
    }
}

/// Builds the `info` event Home Assistant reads (via `describe`) to discover the
/// service and its STT/TTS capabilities.
nonisolated enum WyomingInfo {
    static func event(serviceName: String,
                      sttLanguages: [String],
                      sttEngineId: String,
                      voices: [VoiceInfo]) -> WyomingEvent {
        let attribution: [String: Any] = ["name": "macos-stt-tts-bridge", "url": "https://github.com/daydy16/macos-stt-tts-bridge"]
        let appleAttribution: [String: Any] = ["name": "Apple", "url": "https://www.apple.com"]

        let asrModel: [String: Any] = [
            "name": sttEngineId,
            "languages": sttLanguages,
            "attribution": appleAttribution,
            "installed": true,
            "description": "On-device speech-to-text (\(sttEngineId))",
            "version": "1.0.0"
        ]
        let asrProgram: [String: Any] = [
            "name": serviceName,
            "description": "Local macOS speech-to-text bridge",
            "attribution": attribution,
            "installed": true,
            "version": "1.0.0",
            "models": [asrModel],
            "supports_transcript_streaming": false,
            "requires_external_vad": true,
            "prefers_auto_gain_enabled": true,
            "prefers_noise_reduction_enabled": true
        ]

        let ttsVoices: [[String: Any]] = voices.map { v in
            [
                "name": v.identifier,
                "description": "\(v.name) (\(v.language))" + (v.quality == 2 ? " – Enhanced" : ""),
                "languages": [v.language],
                "attribution": appleAttribution,
                "installed": true,
                "version": "1.0.0"
            ]
        }
        let ttsProgram: [String: Any] = [
            "name": serviceName,
            "description": "Local macOS text-to-speech bridge (AVSpeechSynthesizer)",
            "attribution": attribution,
            "installed": true,
            "version": "1.0.0",
            "voices": ttsVoices,
            "supports_synthesize_streaming": false
        ]

        let data: [String: Any] = [
            "asr": [asrProgram],
            "tts": [ttsProgram],
            "handle": [],
            "intent": [],
            "wake": [],
            "mic": [],
            "snd": []
        ]
        return WyomingEvent(type: "info", data: data)
    }
}
