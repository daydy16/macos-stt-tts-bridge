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
                ContentView(status: serverMgr.status)
            }
        }
        .defaultSize(width: isHeadless ? 0 : 800, height: isHeadless ? 0 : 600)
        .windowStyle(isHeadless ? .hiddenTitleBar : .automatic)
    }
}

final class ServerManager: ObservableObject {
    @Published var status: String = "Startet…"
    private var server: HTTPServer?

    init() {
        SFSpeechRecognizer.requestAuthorization { st in
            print("Speech auth: \(st)")
        }
        let cfg = Config()
        DispatchQueue.global(qos: .userInitiated).async {
            let srv = HTTPServer(config: cfg)
            self.server = srv
            do {
                let msg = "Server läuft auf http://\(cfg.bindHost):\(cfg.port)"
                DispatchQueue.main.async { self.status = msg }
                
                // Print to console for headless mode
                if CommandLine.arguments.contains("--headless") || 
                   CommandLine.arguments.contains("--no-ui") {
                    print("✓ \(msg)")
                    print("✓ Drücke Ctrl+C zum Beenden")
                }
                
                try srv.start()
            } catch {
                let errMsg = "Serverfehler: \(error)"
                DispatchQueue.main.async { self.status = errMsg }
                print("✗ \(errMsg)")
            }
        }
    }
}
