import SwiftUI
import AVFoundation
import Speech
import Combine

// MARK: - ViewModel
@MainActor
class AppViewModel: ObservableObject {
    // TTS Properties
    @Published var ttsText: String = "Hallo Stuttgart! Dies ist eine lokale TTS-Demo."
    @Published var voices: [VoiceInfo] = []
    @Published var selectedVoiceIdentifier: String? = nil

    // STT Properties
    @Published var sttText: String = ""
    @Published var isRecording: Bool = false

    private let ttsEngine = TTSEngine()
    private var sttSession: STTStreamSession?
    private var audioEngine: AVAudioEngine?

    init() {
        loadVoices()
    }

    // MARK: - TTS Methods
    func loadVoices() {
        self.voices = ttsEngine.listVoices().sorted(by: { $0.name < $1.name })
        
        var annaVoice: VoiceInfo? = nil
        for voice in self.voices {
            if voice.name == "Anna" && voice.quality > 1 {
                annaVoice = voice
                break
            }
        }

        if let anna = annaVoice {
            self.selectedVoiceIdentifier = anna.identifier
            return
        }

        var germanVoice: VoiceInfo? = nil
        for voice in self.voices {
            if voice.language == "de-DE" {
                germanVoice = voice
                break
            }
        }

        if let defaultGerman = germanVoice {
            self.selectedVoiceIdentifier = defaultGerman.identifier
        }
    }

    func speak() {
        ttsEngine.speakLocal(ttsText, voiceId: selectedVoiceIdentifier, rate: nil, pitch: nil)
    }

    // MARK: - STT Methods
    func toggleRecording() {
        if isRecording {
            stopSTT()
        } else {
            startSTT()
        }
    }

    private func startSTT() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                guard authStatus == .authorized else {
                    self.sttText = "Fehler: Spracherkennungs-Berechtigung fehlt."
                    return
                }
                // Mic permission is handled by the system automatically on first access on macOS
                self.isRecording = true
                self.sttText = "Höre zu..."
                self.setupAndStartSTT()
            }
        }
    }

    private func setupAndStartSTT() {
        do {
            sttSession = try STTStreamSession(lang: "de-DE", requiresOnDevice: true)
            sttSession?.onPartial = { [weak self] text in self?.sttText = text }
            sttSession?.onFinal = { [weak self] text, _ in self?.sttText = text }
            sttSession?.onError = { [weak self] error in
                self?.sttText = "STT Fehler: \(error.localizedDescription)"
                self?.stopSTT()
            }

            audioEngine = AVAudioEngine()
            let inputNode = audioEngine!.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
            let converter = AVAudioConverter(from: recordingFormat, to: targetFormat)!

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] (buffer, _) in
                let pcmBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096)!
                var error: NSError? = nil
                let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                converter.convert(to: pcmBuffer, error: &error, withInputFrom: inputBlock)

                if error != nil { return }
                
                let channelData = pcmBuffer.int16ChannelData![0]
                let channelDataSize = Int(pcmBuffer.frameLength) * Int(pcmBuffer.format.streamDescription.pointee.mBytesPerFrame)
                let data = Data(bytes: channelData, count: channelDataSize)
                try? self?.sttSession?.append(data)
            }

            audioEngine?.prepare()
            try audioEngine?.start()

        } catch {
            sttText = "Fehler beim Starten von STT: \(error.localizedDescription)"
            isRecording = false
        }
    }

    private func stopSTT() {
        isRecording = false
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        sttSession?.stop()
        sttSession = nil
    }
}

// MARK: - ContentView
struct ContentView: View {
    let status: String // From ServerManager
    @StateObject private var viewModel = AppViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading) {
                Text("STTBridge Server").font(.title).bold()
                Text(status).font(.body).textSelection(.enabled)
            }

            Divider()

            Text("Speech-to-Text (STT)").font(.title2)
            Text(viewModel.sttText)
                .frame(minHeight: 70, alignment: .topLeading)
                .padding(5)
                .border(Color.gray.opacity(0.5), width: 1)
            Button(viewModel.isRecording ? "Aufnahme stoppen" : "Aufnahme starten", action: viewModel.toggleRecording)
                .tint(viewModel.isRecording ? .red : .accentColor)

            Divider()

            Text("Text-to-Speech (TTS)").font(.title2)
            TextEditor(text: $viewModel.ttsText)
                .frame(height: 80)
                .border(Color.gray.opacity(0.5), width: 1)
            
            HStack {
                Picker("Stimme:", selection: $viewModel.selectedVoiceIdentifier) {
                    ForEach(viewModel.voices, id: \.identifier) { voice in
                        Text("\(voice.name) (\(voice.language))").tag(voice.identifier as String?)
                    }
                }
                .pickerStyle(.menu)
                
                Button("Sprechen", action: viewModel.speak)
            }

        }
        .padding(20)
        .frame(minWidth: 520, alignment: .leading)
    }
}