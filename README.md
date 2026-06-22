# macOS STT/TTS Bridge 🎤🔊

> ⚠️ **Experimental & AI-Generated** - This project was developed with AI assistance and is in active development. Expect bugs!

Native macOS server application that makes Apple's high-quality Speech Recognition and Text-to-Speech engines accessible via a **Wyoming** TCP transport (native Home Assistant) and an HTTP/WebSocket API (browser test UI + the existing custom HA integration). Built for **low-latency, fully-local** voice on an Apple Silicon home server.

> **Architecture direction (June 2026):** this bridge's primary value is
> **local, on-device STT** (Apple `SpeechAnalyzer`). For **TTS**, the recommended
> path is a **cloud engine** in Home Assistant — a deep investigation found no
> local German neural TTS that is simultaneously natural, low-latency, and cleanly
> Mac-runnable. The built-in `AVSpeechSynthesizer` TTS is kept as a
> convenience/fallback only. See
> [`docs/decisions/0001-cloud-tts-keep-local-stt.md`](docs/decisions/0001-cloud-tts-keep-local-stt.md)
> and the research in [`docs/research/`](docs/research/).

## ✨ Features

- 🚀 **Modern streaming STT** — built on Apple's `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26+, Apple Neural Engine), with live volatile (partial) results and **instant finalization** on end-of-speech.
- 🔌 **Pluggable engines** — `SpeechAnalyzer` (default), legacy `SFSpeechRecognizer` (A/B flag), and optional **WhisperKit** — selectable via `STT_ENGINE`.
- 🏠 **Wyoming protocol** — native TCP transport (port 10700) auto-discovered by Home Assistant's built-in Wyoming integration. No custom component required.
- 🗣️ **Streaming TTS** — sentence-by-sentence synthesis so playback starts before the full answer is rendered (`AVSpeechSynthesizer`, system/enhanced voices).
- ⚡ **Low latency by design** — in-memory audio (no disk I/O), warm models, small frames, streamed both ways. The browser UI shows live first-partial / final / first-TTS-byte readouts.
- 🔒 **100% local & private** — no cloud, no network egress (the app ships sandboxed with outgoing connections disabled).
- 🎨 **UI & headless modes** — run with or without a window; ships as a launchd service.
- 🌍 **Multi-language, German-first** — `de-DE` by default.

## 🚀 Quick Start

### Run from source (current path — no prebuilt release yet)

```bash
git clone https://github.com/daydy16/macos-stt-tts-bridge.git
cd macos-stt-tts-bridge
open STTBridge.xcodeproj
# In Xcode: select the STTBridge scheme → Run (Cmd+R)
```

On first launch:
- Allow **microphone** and **speech recognition** when prompted (the GUI mic test needs them; the network transports do not).
- macOS downloads the `de-DE` SpeechAnalyzer assets once in the background. If recognition returns an error about a missing locale, install German dictation assets via **System Settings → Keyboard → Dictation** (or Accessibility → Spoken Content) and retry.

Then open the test UI at **http://localhost:8787** (live partials, final, and TTS latency readouts). Home Assistant connects to the Wyoming transport on port **10700** (see below).

Engine/ports are configured via environment variables (see **Configuration**); e.g. run headless with a chosen engine:

```bash
STT_ENGINE=speechanalyzer ./build/STTBridge.app/Contents/MacOS/STTBridge --headless
```

### Install as a packaged app

1. In Xcode: **Product → Archive → Distribute App → Copy App**, then move `STTBridge.app` to `/Applications`.
2. **Start with UI:** double-click `STTBridge.app` and allow microphone access.
3. **Start headless (no window):**

   ```bash
   /Applications/STTBridge.app/Contents/MacOS/STTBridge --headless
   ```

### Install as Service

Automatic startup on login:

```bash
# Change to project directory
cd /path/to/STTBridge

# Install service
./install-service.sh
```

**Service commands:**

```bash
# Check status
launchctl list | grep sttbridge

# Stop
launchctl unload ~/Library/LaunchAgents/io.github.daydy16.sttbridge.plist

# Start
launchctl load ~/Library/LaunchAgents/io.github.daydy16.sttbridge.plist

# View logs
tail -f /tmp/sttbridge.log
```

## 📡 Transports & API

The bridge exposes **two transports over one shared engine core**:

| Transport | Port | Consumer |
|-----------|------|----------|
| **Wyoming TCP** | `10700` | Home Assistant (built-in Wyoming integration, auto-discovered) |
| **HTTP / WebSocket** | `8787` | Browser test UI + the existing custom HA integration |

### HTTP Endpoints

**Health / engine info:**

```bash
curl http://localhost:8787/healthz      # {status, lang, engine, onDeviceSTT}
curl http://localhost:8787/languages    # supported BCP-47 locales for the active engine
curl http://localhost:8787/voices       # available TTS voices
```

**Speech-to-Text (HTTP POST, one-shot):**

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
# One-shot WAV (back-compat)
curl "http://localhost:8787/tts?text=Hallo%20Welt&lang=de-DE" -o output.wav

# Streaming: chunked raw PCM16 (audio/l16), first bytes arrive per sentence
curl "http://localhost:8787/tts/stream?text=Hallo.%20Wie%20geht%20es%20dir?&lang=de-DE" -o stream.l16
```

### WebSocket Streaming STT

For real-time speech recognition:

```javascript
const ws = new WebSocket('ws://localhost:8787/stt/stream?lang=en-US');

ws.onopen = () => {
  // Start message
  ws.send(JSON.stringify({
    type: 'start',
    sampleRate: 16000,
    channels: 1,
    language: 'en-US'
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

### Option A — Wyoming (recommended, native)

The bridge speaks the Wyoming protocol on TCP **10700** and advertises itself over Bonjour (`_wyoming._tcp.`), so Home Assistant auto-discovers it.

1. HA shows a discovered **Wyoming Protocol** device → click **Configure** (or add the *Wyoming Protocol* integration manually and enter the Mac's IP + port `10700`).
2. **Settings → Voice Assistants → Assist**: pick the bridge for Speech-to-Text and Text-to-Speech.

No custom component, nothing to maintain against HA releases. The bridge must be reachable from HA — Wyoming binds `0.0.0.0` by default.

### Option B — Custom HTTP/WS integration (legacy)

Still fully supported via the `/stt`, `/voices`, `/tts`, and `/stt/stream` endpoints:

1. HACS → add `https://github.com/daydy16/ha-local-macos-tts-stt` as a custom repository, install "STT/TTS Bridge", restart HA.
2. **Settings → Devices & Services → + Add Integration → STT/TTS Bridge**, enter host:port (default `localhost:8787`). For a remote HA set `BIND_HOST=0.0.0.0`.

### Latency tuning (read this)

End-to-end latency through HA is dominated by the **Assist silence-detection (VAD) timeout**, not raw recognition. In your Assist pipeline lower the end-of-speech silence window if responses feel slow — the bridge finalizes the transcript the instant audio stops, so the perceived delay is almost entirely the VAD window.

## ⚙️ Configuration (environment variables)

All configuration is via environment variables (set them in the launchd plist). No recompile needed.

| Variable | Default | Description |
|----------|---------|-------------|
| `STT_ENGINE` | `speechanalyzer` | `speechanalyzer` \| `legacy` \| `whisperkit` |
| `DEFAULT_LANG` | `de-DE` | Default recognition/synthesis locale |
| `PORT` | `8787` | HTTP/WebSocket port |
| `BIND_HOST` | `127.0.0.1` | HTTP/WS bind host (`0.0.0.0` for remote HA) |
| `OFFLINE_ONLY` | `false` | Force on-device recognition everywhere |
| `WYOMING_ENABLED` | `true` | Enable the Wyoming TCP transport |
| `WYOMING_PORT` | `10700` | Wyoming TCP port |
| `WYOMING_BONJOUR` | `true` | Advertise via Bonjour for HA auto-discovery |
| `SERVICE_NAME` | `macOS STT/TTS Bridge` | Name shown in HA / Bonjour |
| `TTS_SAMPLE_RATE` | `22050` | Output sample rate for streaming TTS |
| `WHISPER_MODEL` | `large-v3-v20240930_626MB` | WhisperKit model (multilingual; avoid `.en`) |
| `AUTH_TOKEN` | _(none)_ | If set, required on HTTP/WS requests |

### A/B comparison

`SpeechAnalyzer` is the default. To compare against the legacy recognizer set `STT_ENGINE=legacy` and restart; `/healthz` reports the active engine.

## 🔧 Development

### Requirements

- **macOS 26.0+** (required for `SpeechAnalyzer` / `SpeechTranscriber`)
- Xcode 26+
- Apple Silicon recommended (Apple Neural Engine)

> First run downloads the `de-DE` SpeechAnalyzer language assets (system-managed, one-time). If the sandbox blocks the download, install the German dictation/voice assets once via **System Settings → Accessibility → Spoken Content / Keyboard → Dictation**.

### Build from Source

```bash
# Clone repository
git clone https://github.com/daydy16/macos-stt-tts-bridge.git
cd macos-stt-tts-bridge

# Open in Xcode
open STTBridge.xcodeproj

# Build & Run in Xcode (Cmd+R)
```

### Project Structure

```
STTBridge/
├── STTBridgeApp.swift          # App entry; boots HTTP + Wyoming servers
├── ContentView.swift           # SwiftUI status window
├── Server/
│   ├── HTTPServer.swift        # HTTP + WebSocket transport (8787)
│   ├── TTSEngine.swift         # AVSpeechSynthesizer + sentence streaming
│   ├── AudioResampler.swift    # WAV/format helpers
│   ├── Config.swift            # Env-var configuration
│   ├── Models.swift            # DTOs
│   ├── STT/
│   │   ├── STTEngineProtocol.swift   # STTEngine / STTSession protocols
│   │   ├── STTService.swift          # Engine selection + one-shot driver
│   │   ├── SpeechAnalyzerEngine.swift# Default (macOS 26)
│   │   ├── LegacySFEngine.swift      # SFSpeechRecognizer (A/B flag)
│   │   ├── WhisperKitEngine.swift    # Optional (#if canImport(WhisperKit))
│   │   └── AudioBufferUtil.swift     # In-memory PCM/WAV helpers
│   └── Wyoming/
│       ├── WyomingProtocol.swift     # Wire framing + info event
│       └── WyomingServer.swift       # TCP server + Bonjour
└── WebRoot/                    # Browser test UI (with latency readouts)
STTBridgeTests/                 # Unit tests (Cmd+U)
```

The two transports are thin adapters over the shared `STTService` / `TTSEngine` — no recognition logic lives in the transport layer.

### Enabling the WhisperKit engine (optional)

WhisperKit is gated behind `#if canImport(WhisperKit)`, so the project builds without it. To enable:

1. In Xcode: **File → Add Package Dependencies…** → `https://github.com/argmaxinc/argmax-oss-swift.git` → add the **WhisperKit** product to the `STTBridge` target.
2. Set `STT_ENGINE=whisperkit` (optionally `WHISPER_MODEL`).
3. WhisperKit downloads its CoreML model on first use, which needs **outbound network**. The app ships sandboxed with outgoing connections **disabled** — temporarily set `ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES` in the target's build settings (or pre-place the model) for the initial download, then you can disable it again.

### Tests

Run the unit tests with **Cmd+U** (or `xcodebuild test -scheme STTBridge -destination 'platform=macOS'`). They cover sentence chunking, engine selection, config parsing, in-memory WAV/PCM decoding, and the Wyoming `info` structure.

## 🎯 STT accuracy & context enrichment

The default engine (`SpeechAnalyzer` + `SpeechTranscriber`) is Apple's most
accurate on-device transcriber and benchmarks very well on **clean German
commands**; accuracy drops on hesitant/noisy speech. A key constraint when trying
to bias recognition toward Home-Assistant entity/room/device names:

> **`SpeechTranscriber` (our default) cannot be biased with contextual strings**
> (confirmed by Apple). Vocabulary enrichment therefore requires a trade-off —
> either drop to `DictationTranscriber` (`AnalysisContext.contextualStrings`, new
> API, lower base accuracy) or to the legacy `SFSpeechRecognizer` engine with
> `contextualStrings` / a `SFCustomLanguageModelData` custom LM (most powerful:
> weighted phrases, intent templates, custom pronunciations).

Cheap reliability wins that **keep** the high-accuracy engine: gate on
`transcriptionConfidence`, act only on finalized (not volatile) results, and
pre-reserve the `de-DE` asset for a warm start. Full analysis, API references and
a recommended rollout order are in
[`docs/research/2026-06-stt-context-enrichment.md`](docs/research/2026-06-stt-context-enrichment.md).

## 🗣️ TTS voices (local fallback)

TTS output is best served by a **cloud engine** in Home Assistant (see the
architecture note at the top). The built-in `AVSpeechSynthesizer` path is a local
fallback only and **cannot use Siri's voices** — Apple does not expose the Siri /
AFM-3 "expressive" voices to third-party apps. If you do use the local fallback,
a **Premium** system voice sounds far better than the default "Anna":

1. **System Settings → Accessibility → Spoken Content → System Voice → Manage Voices…**
2. Pick your language (e.g. German) and download a **Premium** variant.
3. Restart the bridge. It auto-selects the highest-quality voice
   (Premium > Enhanced > Default); pick a specific one in the browser UI, via
   `?voiceId=…`, or in Home Assistant's TTS voice dropdown.

Why not a *local neural* German TTS? A deep investigation
([`docs/research/2026-06-local-german-tts.md`](docs/research/2026-06-local-german-tts.md))
found none that is natural + low-latency + cleanly Mac-runnable today — hence the
cloud-TTS decision.

## 🔒 Privacy / no egress

The app is sandboxed with `ENABLE_OUTGOING_NETWORK_CONNECTIONS = NO` and only incoming connections enabled, structurally guaranteeing no cloud calls. SpeechAnalyzer and WhisperKit run entirely on-device. (See the WhisperKit note above for the one-time model download exception.)

## 🐛 Known Issues / Notes

- `SpeechAnalyzer` uses Apple-managed models (no version pinning; may change across OS updates) — acceptable for a home assistant; WhisperKit/Parakeet exist as alternatives if German accuracy/latency disappoints.
- The legacy engine restarts long (>~50 s) utterances; command-length utterances are unaffected.
- AFM-3 / Siri "expressive" voices are **not** available to third-party apps; TTS uses system/enhanced voices.

## 🤝 Contributing

This project is experimental and was mostly AI-generated. Contributions are welcome!

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 📝 License

MIT License - see [LICENSE](LICENSE) file

## 🙏 Credits

- Developed with ❤️ and AI assistance
- Uses Apple's Speech Framework and AVFoundation
- Inspired by Wyoming Protocol and Rhasspy

## ⚠️ Disclaimer

This is an experimental project developed with AI assistance.
It is provided "as-is" without warranties. Use at your own risk!

---

**Like this project? Star it! ⭐**
