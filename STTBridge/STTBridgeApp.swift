import SwiftUI
import Speech
import Combine

@main
struct STTBridgeApp: App {
    @StateObject private var serverMgr = ServerManager()
    
    // Check if running headless (backend-only)
    private var isHeadless: Bool {
        CommandLine.arguments.contains("--headless") || 
        CommandLine.arguments.contains("--no-ui")
    }

    var body: some Scene {
        WindowGroup {
            if isHeadless {
                // Minimal view for headless mode
                Text("STT/TTS Bridge Server")
                    .frame(width: 0, height: 0)
                    .hidden()
            } else {
                ContentView(status: serverMgr.status, stt: serverMgr.stt, tts: serverMgr.tts)
            }
        }
        .defaultSize(width: isHeadless ? 0 : 800, height: isHeadless ? 0 : 600)
        .windowStyle(.hiddenTitleBar)
    }
}

final class ServerManager: ObservableObject {
    @Published var status: String = "Startet…"
    let stt: STTService
    let tts: TTSEngine
    private var httpServer: HTTPServer?
    private var wyomingServer: WyomingServer?

    init() {
        // Legacy SFSpeechRecognizer still needs authorization; harmless for
        // SpeechAnalyzer (which runs on-device without it).
        SFSpeechRecognizer.requestAuthorization { st in
            print("Speech auth: \(st)")
        }

        let cfg = Config()
        let stt = STTService(config: cfg)
        let tts = TTSEngine()
        self.stt = stt
        self.tts = tts

        let headless = CommandLine.arguments.contains("--headless") ||
                       CommandLine.arguments.contains("--no-ui")

        // HTTP + WebSocket (browser test UI + existing HA custom integration).
        DispatchQueue.global(qos: .userInitiated).async {
            let server = HTTPServer(config: cfg, stt: stt, tts: tts)
            self.httpServer = server
            do {
                let msg = "Server läuft auf http://\(cfg.bindHost):\(cfg.port)  (Engine: \(cfg.sttEngine.rawValue))"
                DispatchQueue.main.async { self.status = msg }
                if headless {
                    print("✓ \(msg)")
                    print("✓ Drücke Ctrl+C zum Beenden")
                }
                try server.start()
            } catch {
                let errMsg = "Serverfehler (HTTP): \(error)"
                DispatchQueue.main.async { self.status = errMsg }
                print("✗ \(errMsg)")
            }
        }

        // Wyoming TCP transport (native Home Assistant integration).
        if cfg.wyomingEnabled {
            DispatchQueue.global(qos: .userInitiated).async {
                let server = WyomingServer(config: cfg, stt: stt, tts: tts)
                self.wyomingServer = server
                do {
                    if headless { print("✓ Wyoming TCP auf \(cfg.wyomingBindHost):\(cfg.wyomingPort)") }
                    try server.start()
                } catch {
                    print("✗ Serverfehler (Wyoming): \(error)")
                }
            }
        }
    }
}
