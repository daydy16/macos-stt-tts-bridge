import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import AVFoundation
import Speech

extension ByteBuffer {
    nonisolated mutating func readData(length: Int) -> Data? {
        guard let bytes = self.readBytes(length: length) else { return nil }
        return Data(bytes)
    }
}

nonisolated final class HTTPServer {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    private let cfg: Config
    let stt: STTService
    let tts: TTSEngine

    init(config: Config, stt: STTService, tts: TTSEngine) {
        self.cfg = config
        self.stt = stt
        self.tts = tts
    }

    func start() throws {
        let upgrader = NIOWebSocketServerUpgrader(maxFrameSize: 1 << 20,
            shouldUpgrade: { channel, head in channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { channel, req in self.installWebSocket(channel: channel, request: req)
            }
        )

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let handler = HTTPHandler(server: self, upgrader: upgrader)
                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }),
                    withErrorHandling: true
                ).flatMap { channel.pipeline.addHandler(handler) }
            }
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        let ch = try bootstrap.bind(host: cfg.bindHost, port: cfg.port).wait()
        print("🔊 STTBridge HTTP/WS läuft auf http://\(cfg.bindHost):\(cfg.port)")
        try ch.closeFuture.wait()
    }

    private func installWebSocket(channel: Channel, request: HTTPRequestHead) -> EventLoopFuture<Void> {
        let path = URL(string: request.uri)?.path ?? request.uri
        guard path == "/stt/stream" else {
            var buf = channel.allocator.buffer(capacity: 0)
            buf.writeString("{\"type\":\"error\",\"error\":\"invalid_path\"}")
            let frame = WebSocketFrame(fin: true, opcode: .text, data: buf)
            channel.writeAndFlush(frame, promise: nil)
            return channel.close()
        }

        var lang = cfg.defaultLang
        var offline = false
        var partials = true
        var token: String? = nil
        if let url = URL(string: request.uri), let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            for q in comps.queryItems ?? [] {
                switch q.name {
                case "lang": lang = q.value ?? lang
                case "offline": offline = (q.value ?? "false").lowercased() == "true" || cfg.offlineOnly
                case "partials": partials = (q.value ?? "true").lowercased() == "true"
                case "token": token = q.value
                default: break
                }
            }
        }
        if let required = cfg.authToken {
            let provided = token ?? request.headers.first(name: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
            if provided != required {
                var buf = channel.allocator.buffer(capacity: 0)
                buf.writeString("{\"type\":\"error\",\"error\":\"unauthorized\"}")
                let frame = WebSocketFrame(fin: true, opcode: .text, data: buf)
                channel.writeAndFlush(frame, promise: nil)
                return channel.close()
            }
        }

        let wsHandler = WebSocketStreamHandler(service: stt, lang: lang, requireOnDevice: offline, sendPartials: partials)
        return channel.pipeline.addHandler(wsHandler, name: "ws-handler", position: .last)
    }

    // MARK: HTTP Handler
    nonisolated final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let server: HTTPServer
        private let upgrader: NIOWebSocketServerUpgrader
        private var head: HTTPRequestHead?
        private var bodyBuf: ByteBuffer?

        init(server: HTTPServer, upgrader: NIOWebSocketServerUpgrader) {
            self.server = server
            self.upgrader = upgrader
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let part = self.unwrapInboundIn(data)
            switch part {
            case .head(let h): head = h; bodyBuf = context.channel.allocator.buffer(capacity: 0)
            case .body(var b): bodyBuf?.writeBuffer(&b)
            case .end:
                if let h = head, let body = bodyBuf { route(context: context, head: h, body: body) }
                head = nil; bodyBuf = nil
            }
        }

        private func corsHeaders(for origin: String?) -> HTTPHeaders {
            var h = HTTPHeaders()
            let allow = (origin?.hasPrefix("http://localhost") ?? false) ? origin! : "http://localhost"
            h.add(name: "Access-Control-Allow-Origin", value: allow)
            h.add(name: "Access-Control-Allow-Methods", value: "GET,POST,OPTIONS")
            h.add(name: "Access-Control-Allow-Headers", value: "Content-Type,Authorization,X-Sample-Rate,X-Channel-Count")
            h.add(name: "Access-Control-Max-Age", value: "86400")
            return h
        }

        private func verifyAuth(_ head: HTTPRequestHead) -> APIError? {
            guard let required = server.cfg.authToken else { return nil }
            let provided = head.headers.first(name: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
            if provided != required { return .unauthorized("Fehlender oder ungültiger Token.") }
            return nil
        }

        private func writeHeadBodyEnd(_ context: ChannelHandlerContext, status: HTTPResponseStatus, headers: HTTPHeaders, body: ByteBuffer?) {
            let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
            context.write(self.wrapOutboundOut(.head(head)), promise: nil)
            if let body = body {
                context.write(self.wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
            }
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }

        private func writeJSON<T: Encodable>(_ context: ChannelHandlerContext, value: T, status: HTTPResponseStatus = .ok, extra: HTTPHeaders? = nil) {
            var headers = HTTPHeaders(); headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
            if let e = extra { for (n,v) in e { headers.add(name:n, value:v) } }
            let data = try! JSONEncoder().encode(value)
            var buf = context.channel.allocator.buffer(capacity: data.count); buf.writeBytes(data)
            writeHeadBodyEnd(context, status: status, headers: headers, body: buf)
        }

        private func writeBytes(_ context: ChannelHandlerContext, data: Data, contentType: String, status: HTTPResponseStatus = .ok, extra: HTTPHeaders? = nil) {
            var headers = HTTPHeaders(); headers.add(name: "Content-Type", value: contentType)
            if let e = extra { for (n,v) in e { headers.add(name:n, value:v) } }
            var buf = context.channel.allocator.buffer(capacity: data.count); buf.writeBytes(data)
            writeHeadBodyEnd(context, status: status, headers: headers, body: buf)
        }

        private func writeError(_ context: ChannelHandlerContext, _ error: APIError, extra: HTTPHeaders? = nil) {
            writeJSON(context, value: ["error": error.message], status: .init(statusCode: error.statusCode), extra: extra)
        }

        private func query(_ uri: String, _ name: String) -> String? {
            URLComponents(string: uri)?.queryItems?.first(where: { $0.name == name })?.value
        }

        private func route(context: ChannelHandlerContext, head: HTTPRequestHead, body: ByteBuffer) {
            let origin = head.headers.first(name: "Origin")
            let extra = corsHeaders(for: origin)

            if head.method == .OPTIONS {
                writeHeadBodyEnd(context, status: .ok, headers: extra, body: nil); return
            }

            let path = URL(string: head.uri)?.path ?? head.uri
            switch (head.method, path) {
            case (.GET, "/healthz"):
                let lang = server.cfg.defaultLang
                let engineId = server.stt.engineId
                Task {
                    let supported = await server.stt.onDeviceSupported(lang: lang)
                    context.eventLoop.execute {
                        self.writeJSON(context, value: Healthz(status: "ok", lang: lang, engine: engineId, onDeviceSTT: supported), extra: extra)
                    }
                }

            case (.GET, "/languages"):
                Task {
                    let langs = await server.stt.languages()
                    context.eventLoop.execute { self.writeJSON(context, value: langs, extra: extra) }
                }

            case (.GET, "/voices"):
                Task { @MainActor in
                    let voices = server.tts.listVoices()
                    context.eventLoop.execute { self.writeJSON(context, value: voices, extra: extra) }
                }

            case (.GET, "/"):
                if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "WebRoot"),
                   let data = try? Data(contentsOf: url) {
                    writeBytes(context, data: data, contentType: "text/html; charset=utf-8", extra: extra)
                } else { writeError(context, .internalError("index.html fehlt"), extra: extra) }

            case (.GET, "/app.js"):
                if let url = Bundle.main.url(forResource: "app", withExtension: "js", subdirectory: "WebRoot"),
                   let data = try? Data(contentsOf: url) {
                    writeBytes(context, data: data, contentType: "application/javascript", extra: extra)
                } else { writeError(context, .internalError("app.js fehlt"), extra: extra) }

            case (.GET, "/styles.css"):
                if let url = Bundle.main.url(forResource: "styles", withExtension: "css", subdirectory: "WebRoot"),
                   let data = try? Data(contentsOf: url) {
                    writeBytes(context, data: data, contentType: "text/css", extra: extra)
                } else { writeError(context, .internalError("styles.css fehlt"), extra: extra) }

            case (.POST, "/stt"):
                if let err = verifyAuth(head) { writeError(context, err, extra: extra); return }
                let lang = query(head.uri, "lang")
                    ?? head.headers.first(name: "X-Language")
                    ?? server.cfg.defaultLang
                let requireOnDevice = server.cfg.offlineOnly || (query(head.uri, "offline")?.lowercased() == "true")
                let ct = head.headers.first(name: "Content-Type")?.lowercased() ?? "application/octet-stream"
                var copy = body
                let payload = copy.readData(length: body.readableBytes) ?? Data()
                let sampleRateHeader = head.headers.first(name: "X-Sample-Rate")
                let channelCountHeader = head.headers.first(name: "X-Channel-Count")

                Task {
                    do {
                        let resp: STTResponse
                        if ct.contains("audio/l16") {
                            let sr = Double(sampleRateHeader ?? "16000") ?? 16000
                            let ch = Int(channelCountHeader ?? "1") ?? 1
                            resp = try await self.server.stt.transcribeRaw(data: payload, sampleRate: sr, channels: ch, lang: lang, requireOnDevice: requireOnDevice)
                        } else if let srStr = sampleRateHeader, let chStr = channelCountHeader {
                            let sr = Double(srStr) ?? 16000
                            let ch = Int(chStr) ?? 1
                            resp = try await self.server.stt.transcribeRaw(data: payload, sampleRate: sr, channels: ch, lang: lang, requireOnDevice: requireOnDevice)
                        } else {
                            resp = try await self.server.stt.transcribeRaw(data: payload, sampleRate: nil, channels: nil, lang: lang, requireOnDevice: requireOnDevice)
                        }
                        context.eventLoop.execute { self.writeJSON(context, value: resp, extra: extra) }
                    } catch let e as APIError {
                        context.eventLoop.execute { self.writeError(context, e, extra: extra) }
                    } catch {
                        context.eventLoop.execute { self.writeError(context, .internalError("Interner Fehler"), extra: extra) }
                    }
                }

            case (.GET, "/tts"):
                if let err = verifyAuth(head) { writeError(context, err, extra: extra); return }
                guard let text = query(head.uri, "text"), !text.isEmpty else {
                    writeError(context, .badRequest("Parameter 'text' fehlt"), extra: extra); return
                }
                let lang = query(head.uri, "lang")
                let voiceId = query(head.uri, "voiceId")
                let rate = query(head.uri, "rate").flatMap { Double($0) }
                let pitch = query(head.uri, "pitch").flatMap { Double($0) }
                Task {
                    do {
                        let wav = try await self.server.tts.synthesizeToWAV(text: text, voiceId: voiceId, rate: rate, pitch: pitch, language: lang)
                        context.eventLoop.execute { self.writeBytes(context, data: wav, contentType: "audio/wav", extra: extra) }
                    } catch {
                        context.eventLoop.execute { self.writeError(context, .internalError("TTS-Fehler: \(error)"), extra: extra) }
                    }
                }

            case (.GET, "/tts/stream"):
                if let err = verifyAuth(head) { writeError(context, err, extra: extra); return }
                guard let text = query(head.uri, "text"), !text.isEmpty else {
                    writeError(context, .badRequest("Parameter 'text' fehlt"), extra: extra); return
                }
                let lang = query(head.uri, "lang")
                let voiceId = query(head.uri, "voiceId")
                let rate = query(head.uri, "rate").flatMap { Double($0) }
                let pitch = query(head.uri, "pitch").flatMap { Double($0) }
                streamTTS(context: context, text: text, lang: lang, voiceId: voiceId, rate: rate, pitch: pitch, extra: extra)

            case (.POST, "/tts"):
                if let err = verifyAuth(head) { writeError(context, err, extra: extra); return }
                var copy = body
                guard let data = copy.readData(length: body.readableBytes),
                      let payload = try? JSONDecoder().decode(TTSPayload.self, from: data) else {
                    writeError(context, .badRequest("Ungültiger JSON-Body"), extra: extra); return
                }
                if payload.speakLocal ?? false {
                    Task { @MainActor in
                        self.server.tts.speakLocal(payload.text, voiceId: payload.voiceId, rate: payload.rate, pitch: payload.pitch)
                        self.writeJSON(context, value: ["ok": true], extra: extra)
                    }
                } else {
                    Task {
                        do {
                            let wav = try await self.server.tts.synthesizeToWAV(text: payload.text, voiceId: payload.voiceId, rate: payload.rate, pitch: payload.pitch)
                            context.eventLoop.execute { self.writeBytes(context, data: wav, contentType: "audio/wav", extra: extra) }
                        } catch {
                            context.eventLoop.execute { self.writeError(context, .internalError("TTS-Fehler: \(error)"), extra: extra) }
                        }
                    }
                }

            default:
                let headResp = HTTPResponseHead(version: .http1_1, status: .notFound, headers: extra)
                context.write(self.wrapOutboundOut(.head(headResp)), promise: nil)
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }

        /// Sentence-streamed TTS as chunked raw PCM16 (`audio/l16`). The first
        /// chunk is flushed the moment the first sentence is synthesized, so the
        /// browser can measure (and start playing on) first-audio latency.
        private func streamTTS(context: ChannelHandlerContext, text: String, lang: String?, voiceId: String?, rate: Double?, pitch: Double?, extra: HTTPHeaders) {
            let sr = server.cfg.ttsSampleRate
            var headers = extra
            headers.add(name: "Content-Type", value: "audio/l16")
            headers.add(name: "X-Sample-Rate", value: "\(sr)")
            headers.add(name: "X-Channel-Count", value: "1")
            headers.add(name: "Cache-Control", value: "no-store")
            headers.add(name: "Transfer-Encoding", value: "chunked") // stream chunks as synthesized
            // Close after the stream so a streamed body can't interleave with a
            // pipelined request's response on a keep-alive connection.
            headers.add(name: "Connection", value: "close")
            let respHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
            context.write(self.wrapOutboundOut(.head(respHead)), promise: nil)
            context.flush()

            let channel = context.channel
            let tts = server.tts
            Task { @MainActor in
                let stream = tts.synthesizeStream(text: text, voiceId: voiceId, rate: rate, pitch: pitch, language: lang, sampleRate: sr)
                for await pcm in stream {
                    guard channel.isActive else { return } // client disconnected mid-stream
                    var buf = channel.allocator.buffer(capacity: pcm.count)
                    buf.writeBytes(pcm)
                    channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buf)), promise: nil)
                }
                guard channel.isActive else { return }
                channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
                    channel.close(promise: nil)
                }
            }
        }
    }
}

// MARK: WebSocket stream handler

/// Bridges the browser test-UI WebSocket protocol to a transport-agnostic
/// ``STTSession``. Audio frames arriving before the (async) session is ready are
/// buffered and replayed once it attaches.
nonisolated final class WebSocketStreamHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame

    private let service: STTService
    private let lang: String
    private let requireOnDevice: Bool
    private let sendPartials: Bool
    private weak var channel: Channel?

    private let lock = NSLock()
    private var session: STTSession?
    private var pending: [Data] = []
    private var ready = false
    private var ended = false
    private var graceful = false
    private var consumeTask: Task<Void, Never>?

    init(service: STTService, lang: String, requireOnDevice: Bool, sendPartials: Bool) {
        self.service = service
        self.lang = lang
        self.requireOnDevice = requireOnDevice
        self.sendPartials = sendPartials
    }

    func handlerAdded(context: ChannelHandlerContext) {
        channel = context.channel
        let service = self.service
        let lang = self.lang
        let rod = self.requireOnDevice
        Task { [weak self] in
            do {
                let session = try await service.startSession(lang: lang, requireOnDevice: rod)
                self?.attach(session)
            } catch {
                self?.send(json: ["type": "error", "error": "\(error)"])
                self?.channel?.close(promise: nil)
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        switch frame.opcode {
        case .binary:
            var d = frame.data
            guard let payload = d.readData(length: d.readableBytes) else { return }
            lock.lock()
            if ready, let s = session { feedLocked(payload, to: s) }
            else { pending.append(payload) }
            lock.unlock()
        case .text:
            var d = frame.data
            if let payload = d.readData(length: d.readableBytes),
               let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
               (obj["type"] as? String) == "end" {
                endStream(graceful: true)
            }
        case .connectionClose:
            endStream(graceful: false)
            context.close(promise: nil)
        default:
            break
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        endStream(graceful: false)
    }

    // MARK: - Session wiring

    private func attach(_ session: STTSession) {
        lock.lock()
        self.session = session
        let buffered = pending
        pending.removeAll()
        for data in buffered { feedLocked(data, to: session) } // replay before going live
        ready = true
        let alreadyEnded = ended
        let wasGraceful = graceful
        lock.unlock()

        let task = Task { [weak self] in
            for await result in session.results {
                guard let self else { return }
                if let err = result.error {
                    self.send(json: ["type": "error", "error": err])
                } else if result.isFinal {
                    var obj: [String: Any] = ["type": "final", "text": result.text]
                    if let c = result.confidence { obj["confidence"] = c }
                    self.send(json: obj)
                } else if self.sendPartials {
                    self.send(json: ["type": "partial", "text": result.text])
                }
            }
        }
        lock.lock(); consumeTask = task; lock.unlock()

        // The client may have ended before the session became ready.
        if alreadyEnded {
            if wasGraceful { Task { await session.finishAudio() } }
            else { session.cancel(); task.cancel() }
        }
    }

    /// Caller must hold `lock`. Conversion and `session.append` are non-blocking,
    /// so holding the lock keeps chunk ordering correct (buffered replay can't
    /// interleave with a live frame).
    private func feedLocked(_ data: Data, to s: STTSession) {
        guard let buffer = AudioBufferUtil.int16Buffer(from: data, sampleRate: 16_000, channels: 1) else { return }
        s.append(buffer)
    }

    private func endStream(graceful: Bool) {
        lock.lock()
        if ended { lock.unlock(); return }
        ended = true
        self.graceful = graceful
        let s = session
        let task = consumeTask
        lock.unlock()
        guard let s else { return } // not ready yet; attach() will honor `ended`/`graceful`
        if graceful {
            Task { await s.finishAudio() }
        } else {
            s.cancel()
            task?.cancel()
        }
    }

    func send(json: [String: Any]) {
        guard let ch = channel else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        var buf = ch.allocator.buffer(capacity: data.count); buf.writeBytes(data)
        ch.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: buf), promise: nil)
    }
}
