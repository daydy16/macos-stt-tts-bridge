import XCTest
import AVFoundation
@testable import STTBridge

final class STTBridgeTests: XCTestCase {

    // MARK: - Sentence splitting (Phase 2 streaming TTS chunking)

    func testSplitSentencesBasic() {
        let parts = TTSEngine.splitSentences("Hallo Welt. Wie geht es dir? Gut!")
        XCTAssertEqual(parts, ["Hallo Welt.", "Wie geht es dir?", "Gut!"])
    }

    func testSplitSentencesKeepsRemainder() {
        let parts = TTSEngine.splitSentences("Ohne Satzzeichen am Ende")
        XCTAssertEqual(parts, ["Ohne Satzzeichen am Ende"])
    }

    func testSplitSentencesEmptyFallsBackToWhole() {
        let parts = TTSEngine.splitSentences("")
        XCTAssertEqual(parts, [""])
    }

    func testSplitSentencesNewlinesAndSemicolons() {
        let parts = TTSEngine.splitSentences("Eins;\nZwei.")
        XCTAssertEqual(parts, ["Eins;", "Zwei."])
    }

    // MARK: - Engine selection

    func testEngineKindDefaultsToSpeechAnalyzer() {
        XCTAssertEqual(STTEngineKind(envValue: nil), .speechAnalyzer)
        XCTAssertEqual(STTEngineKind(envValue: "unknown"), .speechAnalyzer)
        XCTAssertEqual(STTEngineKind(envValue: "speechanalyzer"), .speechAnalyzer)
    }

    func testEngineKindAliases() {
        XCTAssertEqual(STTEngineKind(envValue: "legacy"), .legacy)
        XCTAssertEqual(STTEngineKind(envValue: "SF"), .legacy)
        XCTAssertEqual(STTEngineKind(envValue: "whisper"), .whisperKit)
        XCTAssertEqual(STTEngineKind(envValue: "whisperkit"), .whisperKit)
    }

    // MARK: - Config

    func testConfigDefaults() {
        let cfg = Config(env: [:])
        XCTAssertEqual(cfg.port, 8787)
        XCTAssertEqual(cfg.defaultLang, "de-DE")
        XCTAssertEqual(cfg.sttEngine, .speechAnalyzer)
        XCTAssertTrue(cfg.wyomingEnabled)
        XCTAssertEqual(cfg.wyomingPort, 10700)
    }

    func testConfigOverrides() {
        let cfg = Config(env: [
            "PORT": "9001",
            "STT_ENGINE": "legacy",
            "WYOMING_ENABLED": "false",
            "WYOMING_PORT": "12345",
            "DEFAULT_LANG": "en-US"
        ])
        XCTAssertEqual(cfg.port, 9001)
        XCTAssertEqual(cfg.sttEngine, .legacy)
        XCTAssertFalse(cfg.wyomingEnabled)
        XCTAssertEqual(cfg.wyomingPort, 12345)
        XCTAssertEqual(cfg.defaultLang, "en-US")
    }

    // MARK: - Audio buffers

    func testInt16BufferFrameCount() {
        // 100 frames, mono, 16-bit = 200 bytes
        let data = Data(count: 200)
        let buf = AudioBufferUtil.int16Buffer(from: data, sampleRate: 16_000, channels: 1)
        XCTAssertNotNil(buf)
        XCTAssertEqual(buf?.frameLength, 100)
        XCTAssertEqual(buf?.format.channelCount, 1)
        XCTAssertEqual(buf?.format.sampleRate, 16_000)
    }

    func testInt16BufferStereoFrameCount() {
        // 50 frames, stereo, 16-bit = 50 * 2ch * 2bytes = 200 bytes
        let data = Data(count: 200)
        let buf = AudioBufferUtil.int16Buffer(from: data, sampleRate: 44_100, channels: 2)
        XCTAssertEqual(buf?.frameLength, 50)
        XCTAssertEqual(buf?.format.channelCount, 2)
    }

    func testWavRoundTrip() {
        let frames = 320 // 20 ms @ 16k
        let wav = Self.makeWAV(frames: frames, sampleRate: 16_000, channels: 1)
        let buf = AudioBufferUtil.pcm16BufferFromWAV(wav)
        XCTAssertNotNil(buf)
        XCTAssertEqual(buf?.frameLength, AVAudioFrameCount(frames))
        XCTAssertEqual(buf?.format.sampleRate, 16_000)
    }

    func testWavRejectsNonWav() {
        XCTAssertNil(AudioBufferUtil.pcm16BufferFromWAV(Data("not a wav file at all......".utf8)))
    }

    // MARK: - Wyoming info event

    func testWyomingInfoStructure() {
        let voices = [VoiceInfo(name: "Anna", identifier: "com.apple.voice.de.Anna", language: "de-DE", quality: 2)]
        let event = WyomingInfo.event(serviceName: "Test Bridge",
                                      sttLanguages: ["de-DE", "en-US"],
                                      sttEngineId: "speechanalyzer",
                                      voices: voices)
        XCTAssertEqual(event.type, "info")

        let asr = event.data["asr"] as? [[String: Any]]
        XCTAssertEqual(asr?.count, 1)
        let models = asr?.first?["models"] as? [[String: Any]]
        XCTAssertEqual((models?.first?["languages"] as? [String])?.contains("de-DE"), true)

        let tts = event.data["tts"] as? [[String: Any]]
        let ttsVoices = tts?.first?["voices"] as? [[String: Any]]
        XCTAssertEqual(ttsVoices?.first?["name"] as? String, "com.apple.voice.de.Anna")

        // Required empty program lists must be present for HA's Info.from_dict.
        for key in ["handle", "intent", "wake", "mic", "snd"] {
            XCTAssertNotNil(event.data[key], "missing key \(key)")
        }
    }

    // MARK: - Helpers

    private static func makeWAV(frames: Int, sampleRate: Int, channels: Int) -> Data {
        let bytesPerSample = 2
        let dataBytes = frames * channels * bytesPerSample
        var out = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        out.append(Data("RIFF".utf8)); u32(UInt32(36 + dataBytes)); out.append(Data("WAVE".utf8))
        out.append(Data("fmt ".utf8)); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * channels * bytesPerSample))
        u16(UInt16(channels * bytesPerSample)); u16(16)
        out.append(Data("data".utf8)); u32(UInt32(dataBytes))
        out.append(Data(count: dataBytes))
        return out
    }
}
