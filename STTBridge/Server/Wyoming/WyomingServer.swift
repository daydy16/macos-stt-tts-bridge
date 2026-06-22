import Foundation
import NIOCore
import NIOPosix

/// Wyoming protocol TCP server (default port 10700). A second transport adapter
/// over the same ``STTService`` / ``TTSEngine`` so Home Assistant's built-in
/// Wyoming integration can use the bridge natively (auto-discovered via Bonjour).
nonisolated final class WyomingServer {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    private let cfg: Config
    private let stt: STTService
    private let tts: TTSEngine
    private var bonjour: BonjourAdvertiser?

    init(config: Config, stt: STTService, tts: TTSEngine) {
        self.cfg = config
        self.stt = stt
        self.tts = tts
    }

    func start() throws {
        let stt = self.stt
        let tts = self.tts
        let cfg = self.cfg

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandlers([
                    ByteToMessageHandler(WyomingFrameDecoder()),
                    WyomingConnectionHandler(service: stt, tts: tts, cfg: cfg)
                ])
            }
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        let ch = try bootstrap.bind(host: cfg.wyomingBindHost, port: cfg.wyomingPort).wait()
        print("🏠 Wyoming TCP server läuft auf \(cfg.wyomingBindHost):\(cfg.wyomingPort)")

        if cfg.wyomingAdvertiseBonjour {
            let advertiser = BonjourAdvertiser(name: cfg.serviceName, port: cfg.wyomingPort)
            advertiser.start()
            bonjour = advertiser
        }

        try ch.closeFuture.wait()
    }
}

/// One Wyoming client connection. Translates Wyoming STT/TTS event flows onto
/// the shared engines. No recognition/synthesis logic lives here.
nonisolated final class WyomingConnectionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WyomingEvent
    typealias OutboundOut = ByteBuffer

    private let service: STTService
    private let tts: TTSEngine
    private let cfg: Config
    private weak var channel: Channel?

    private let lock = NSLock()
    private var language: String
    private var session: STTSession?
    private var pending: [Data] = []
    private var ready = false
    private var inputSampleRate: Double = 16_000
    private var inputChannels: Int = 1

    init(service: STTService, tts: TTSEngine, cfg: Config) {
        self.service = service
        self.tts = tts
        self.cfg = cfg
        self.language = cfg.defaultLang
    }

    func handlerAdded(context: ChannelHandlerContext) {
        channel = context.channel
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let event = unwrapInboundIn(data)
        switch event.type {
        case "describe":
            handleDescribe()
        case "transcribe":
            if let lang = event.data["language"] as? String, !lang.isEmpty {
                lock.lock(); language = normalizeLang(lang); lock.unlock()
            }
        case "audio-start":
            handleAudioStart(event.data)
        case "audio-chunk":
            if let payload = event.payload { handleAudioChunk(payload) }
        case "audio-stop":
            handleAudioStop()
        case "synthesize":
            handleSynthesize(event.data)
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        lock.lock(); let s = session; session = nil; lock.unlock()
        s?.cancel()
    }

    // MARK: - Discovery

    private func handleDescribe() {
        let service = self.service
        let tts = self.tts
        let cfg = self.cfg
        Task { [weak self] in
            let langs = await service.languages()
            let engineId = service.engineId
            let voices = await MainActor.run { tts.listVoices() }
            let info = WyomingInfo.event(serviceName: cfg.serviceName,
                                         sttLanguages: langs,
                                         sttEngineId: engineId,
                                         voices: voices)
            self?.send(info)
        }
    }

    // MARK: - STT flow

    private func handleAudioStart(_ data: [String: Any]) {
        lock.lock()
        pending.removeAll()
        ready = false
        session?.cancel()
        session = nil
        if let rate = data["rate"] as? Int { inputSampleRate = Double(rate) }
        else if let rate = data["rate"] as? Double { inputSampleRate = rate }
        if let ch = data["channels"] as? Int { inputChannels = max(1, ch) }
        let lang = language
        lock.unlock()

        let service = self.service
        Task { [weak self] in
            do {
                // Wyoming serves the local Home Assistant pipeline: force on-device.
                let s = try await service.startSession(lang: lang, requireOnDevice: true)
                self?.attachSession(s)
            } catch {
                NSLog("Wyoming STT start error: \(error)")
            }
        }
    }

    private func attachSession(_ s: STTSession) {
        // Flip ready + replay buffered audio atomically so a concurrent live
        // audio-chunk can't be appended before the buffered chunks.
        lock.lock()
        session = s
        let buffered = pending
        pending.removeAll()
        for d in buffered { feedLocked(d, to: s) }
        ready = true
        lock.unlock()
    }

    private func handleAudioChunk(_ payload: Data) {
        lock.lock()
        if ready, let s = session {
            feedLocked(payload, to: s)
        } else {
            pending.append(payload)
        }
        lock.unlock()
    }

    /// Caller must hold `lock`. Conversion and `session.append` are both
    /// non-blocking, so holding the lock keeps chunk ordering correct.
    private func feedLocked(_ data: Data, to s: STTSession) {
        guard let buffer = AudioBufferUtil.int16Buffer(from: data, sampleRate: inputSampleRate, channels: inputChannels) else { return }
        s.append(buffer)
    }

    private func handleAudioStop() {
        lock.lock()
        let s = session
        lock.unlock()
        guard let s else {
            send(WyomingEvent(type: "transcript", data: ["text": ""]))
            return
        }
        Task { [weak self] in
            await s.finishAudio()
            var text = ""
            for await result in s.results where result.isFinal { text = result.text }
            guard let self else { return }
            self.send(WyomingEvent(type: "transcript", data: ["text": text]))
            self.lock.lock()
            // Only clear if a newer utterance hasn't already replaced the session.
            if self.session === s { self.session = nil; self.ready = false }
            self.lock.unlock()
        }
    }

    // MARK: - TTS flow

    private func handleSynthesize(_ data: [String: Any]) {
        guard let text = data["text"] as? String, !text.isEmpty else { return }
        var voiceId: String?
        var lang: String?
        if let voice = data["voice"] as? [String: Any] {
            voiceId = voice["name"] as? String
            lang = (voice["language"] as? String).map { normalizeLang($0) }
        }
        let sr = cfg.ttsSampleRate
        let tts = self.tts

        send(WyomingEvent(type: "audio-start", data: ["rate": sr, "width": 2, "channels": 1, "timestamp": 0]))
        Task { [weak self] in
            let stream = tts.synthesizeStream(text: text, voiceId: voiceId, rate: nil, pitch: nil, language: lang, sampleRate: sr)
            for await pcm in stream {
                self?.send(WyomingEvent(type: "audio-chunk",
                                        data: ["rate": sr, "width": 2, "channels": 1],
                                        payload: pcm))
            }
            self?.send(WyomingEvent(type: "audio-stop", data: [:]))
        }
    }

    // MARK: - Helpers

    /// Map a possibly-bare language code to a BCP-47 locale. Never fabricates a
    /// bogus region (e.g. "en" must not become "en-EN").
    private func normalizeLang(_ raw: String) -> String {
        if raw.contains("-") { return raw }
        let lower = raw.lowercased()
        if cfg.defaultLang.lowercased().hasPrefix(lower) { return cfg.defaultLang }
        let common = [
            "de": "de-DE", "en": "en-US", "fr": "fr-FR", "es": "es-ES",
            "it": "it-IT", "nl": "nl-NL", "pt": "pt-PT", "ja": "ja-JP",
            "zh": "zh-CN", "ko": "ko-KR", "ru": "ru-RU"
        ]
        return common[lower] ?? raw
    }

    private func send(_ event: WyomingEvent) {
        guard let ch = channel else { return }
        let buf = WyomingFrame.encode(event, allocator: ch.allocator)
        ch.writeAndFlush(buf, promise: nil)
    }
}

/// Advertises the Wyoming service over Bonjour/mDNS (`_wyoming._tcp.`) so Home
/// Assistant auto-discovers it. No TXT records are needed — HA connects and
/// sends `describe` to learn capabilities.
nonisolated final class BonjourAdvertiser: NSObject, NetServiceDelegate {
    private let name: String
    private let port: Int
    private var service: NetService?

    init(name: String, port: Int) {
        self.name = name
        self.port = port
    }

    func start() {
        DispatchQueue.main.async {
            let service = NetService(domain: "local.", type: "_wyoming._tcp.", name: self.name, port: Int32(self.port))
            service.delegate = self
            service.publish()
            self.service = service
            print("📡 Bonjour: \(self.name) als _wyoming._tcp. auf Port \(self.port) angekündigt")
        }
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        NSLog("Bonjour publish failed: \(errorDict)")
    }
}
