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

    private let ttsEngine: TTSEngine
    private let stt: STTService
    private var sttSession: STTSession?
    private var resultsTask: Task<Void, Never>?
    private var audioEngine: AVAudioEngine?

    init(stt: STTService, tts: TTSEngine) {
        self.stt = stt
        self.ttsEngine = tts
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
        Task { @MainActor in
            do {
                let session = try await stt.startSession(lang: "de-DE", requireOnDevice: true)
                self.sttSession = session

                // Forward partial + final results to the UI.
                self.resultsTask = Task { @MainActor [weak self] in
                    for await result in session.results {
                        if let err = result.error { self?.sttText = "Fehler: \(err)" }
                        else { self?.sttText = result.text }
                    }
                }

                // Feed mic audio; the session converts to the engine's format.
                let audioEngine = AVAudioEngine()
                self.audioEngine = audioEngine
                let inputNode = audioEngine.inputNode
                let recordingFormat = inputNode.outputFormat(forBus: 0)
                inputNode.installTap(onBus: 0, bufferSize: 2048, format: recordingFormat) { buffer, _ in
                    session.append(buffer)
                }
                audioEngine.prepare()
                try audioEngine.start()
            } catch {
                self.sttText = "Fehler beim Starten von STT: \(error.localizedDescription)"
                self.isRecording = false
            }
        }
    }

    private func stopSTT() {
        isRecording = false
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        let session = sttSession
        sttSession = nil
        resultsTask = nil
        Task { await session?.finishAudio() }
    }
}

// MARK: - ContentView
struct ContentView: View {
    let status: String // From ServerManager
    @StateObject private var viewModel: AppViewModel

    init(status: String, stt: STTService, tts: TTSEngine) {
        self.status = status
        _viewModel = StateObject(wrappedValue: AppViewModel(stt: stt, tts: tts))
    }

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