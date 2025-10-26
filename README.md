# macOS STT/TTS Bridge 🎤🔊

> ⚠️ **Experimentell & AI-generiert** - Dieses Projekt wurde mit AI-Unterstützung entwickelt und befindet sich in aktiver Entwicklung. Bugs sind zu erwarten!

Native macOS Server-Anwendung, die Apples hochwertige Speech Recognition und Text-to-Speech Engines über eine HTTP/WebSocket API zugänglich macht. Perfekt für **Home Assistant** und andere lokale Automatisierungssysteme.

## ✨ Features

- 🎯 **Native macOS Speech Recognition** - Nutzt Apples eingebaute Speech Framework
- 🗣️ **High-Quality TTS** - Natürlich klingende Sprachausgabe in vielen Sprachen
- ⚡ **Streaming STT** - WebSocket-basiertes Echtzeit-Streaming für minimale Latenz
- 🔒 **100% Lokal & Privat** - Keine Cloud, alle Daten bleiben auf deinem Mac
- 🏠 **Home Assistant Integration** - Fertige Custom Component verfügbar
- 🎨 **UI & Headless Modi** - Mit oder ohne grafische Oberfläche nutzbar
- 🌍 **Multi-Language** - Unterstützt alle von macOS unterstützten Sprachen

## 🚀 Quick Start

### Installation

1. **App herunterladen:**
   ```bash
   # Lade die neueste Version von Releases
   # Entpacke und verschiebe nach /Applications
   ```

2. **Mit UI starten:**
   - Doppelklick auf `STTBridge.app`
   - Erlaube Mikrofon-Zugriff wenn gefragt

3. **Headless starten (ohne UI):**
   ```bash
   /Applications/STTBridge.app/Contents/MacOS/STTBridge --headless
   ```

### Als Service installieren

Automatischer Start beim Login:

```bash
# In das Projektverzeichnis wechseln
cd /pfad/zu/STTBridge

# Service installieren
./install-service.sh
```

**Service-Befehle:**
```bash
# Status prüfen
launchctl list | grep sttbridge

# Stoppen
launchctl unload ~/Library/LaunchAgents/io.github.daydy16.sttbridge.plist

# Starten
launchctl load ~/Library/LaunchAgents/io.github.daydy16.sttbridge.plist

# Logs ansehen
tail -f /tmp/sttbridge.log
```

## 📡 API Endpoints

### HTTP Endpoints

**Speech-to-Text (HTTP POST):**
```bash
curl -X POST http://localhost:8787/stt \
  -H "Content-Type: audio/wav" \
  -H "X-Language: de-DE" \
  -H "X-Sample-Rate: 16000" \
  -H "X-Channel-Count: 1" \
  --data-binary @audio.wav
```

**Text-to-Speech:**
```bash
curl "http://localhost:8787/tts?text=Hallo%20Welt&lang=de-DE" -o output.wav
```

**Verfügbare Stimmen:**
```bash
curl http://localhost:8787/voices
```

### WebSocket Streaming STT

Für Echtzeit-Spracherkennung:

```javascript
const ws = new WebSocket('ws://localhost:8787/stt/stream?lang=de-DE');

ws.onopen = () => {
  // Start message
  ws.send(JSON.stringify({
    type: 'start',
    sampleRate: 16000,
    channels: 1,
    language: 'de-DE'
  }));
  
  // Stream audio chunks
  audioChunks.forEach(chunk => ws.send(chunk));
  
  // End stream
  ws.send(JSON.stringify({ type: 'end' }));
};

ws.onmessage = (event) => {
  const data = JSON.parse(event.data);
  if (data.type === 'partial') {
    console.log('Partial:', data.text);
  } else if (data.type === 'final') {
    console.log('Final:', data.text);
  }
};
```

## 🏠 Home Assistant Integration

### Installation

1. **HACS Installation (empfohlen):**
   - Füge `https://github.com/daydy16/ha-local-macos-tts-stt` als Custom Repository hinzu
   - Installiere "STT/TTS Bridge"
   - Starte Home Assistant neu

2. **Manuelle Installation:**
   ```bash
   cd config/custom_components
   git clone https://github.com/daydy16/ha-local-macos-tts-stt sttbridge
   ```

### Konfiguration

1. Gehe zu **Einstellungen → Geräte & Dienste**
2. Klicke **+ Integration hinzufügen**
3. Suche nach "STT/TTS Bridge"
4. Gib Host und Port ein (Standard: `localhost:8787`)

### Nutzung in Assist Pipeline

1. **Einstellungen → Voice Assistants → Assist**
2. Wähle bei Speech-to-Text: `STT/TTS Bridge STT`
3. Wähle bei Text-to-Speech: `STT/TTS Bridge TTS`
4. Sprache: `de-DE` oder gewünschte Sprache

## ⚙️ Konfiguration

Die App nutzt Standard-Einstellungen, die für die meisten Anwendungen funktionieren:

- **Host:** `127.0.0.1` (localhost)
- **Port:** `8787`
- **Auth Token:** Optional (kann in Config.swift gesetzt werden)
- **Default Language:** `de-DE`

Zum Anpassen editiere `STTBridge/Server/Config.swift` und kompiliere neu.

## 🔧 Entwicklung

### Voraussetzungen

- macOS 13.0+
- Xcode 15.0+
- Swift 5.9+

### Build von Source

```bash
# Repository klonen
git clone https://github.com/daydy16/macos-stt-tts-bridge.git
cd macos-stt-tts-bridge

# In Xcode öffnen
open STTBridge.xcodeproj

# Build & Run in Xcode (Cmd+R)
```

### Projektstruktur

```
STTBridge/
├── STTBridgeApp.swift      # Main App & UI Toggle
├── ContentView.swift        # SwiftUI Interface
├── Server/
│   ├── HTTPServer.swift     # HTTP/WebSocket Server
│   ├── STTEngine.swift      # Speech Recognition
│   ├── TTSEngine.swift      # Text-to-Speech
│   ├── Config.swift         # Configuration
│   └── Models.swift         # Data Models
└── Webroot/                 # Test Web UI
    ├── index.html
    ├── app.js
    └── styles.css
```

## 🐛 Bekannte Probleme

- [ ] Performance bei sehr langen Audio-Streams könnte optimiert werden
- [ ] Keine Unterstützung für Batch-Verarbeitung
- [ ] Auth-Token Implementierung ist basic

## 🤝 Contributing

Dieses Projekt ist experimentell und wurde größtenteils AI-generiert. Contributions sind willkommen!

1. Fork das Repository
2. Erstelle einen Feature Branch (`git checkout -b feature/amazing-feature`)
3. Commit deine Änderungen (`git commit -m 'Add amazing feature'`)
4. Push zum Branch (`git push origin feature/amazing-feature`)
5. Öffne einen Pull Request

## 📝 Lizenz

MIT License - siehe [LICENSE](LICENSE) Datei

## 🙏 Credits

- Entwickelt mit ❤️ und AI-Unterstützung
- Nutzt Apples Speech Framework und AVFoundation
- Inspiriert von Wyoming Protocol und Rhasspy

## ⚠️ Disclaimer

Dies ist ein experimentelles Projekt, das mit AI-Unterstützung entwickelt wurde. 
Es wird "as-is" bereitgestellt ohne Garantien. Nutze es auf eigenes Risiko!

---

**Gefällt dir das Projekt? Star it! ⭐**
