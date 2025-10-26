import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import AVFoundation
import Speech

extension ByteBuffer {
    mutating func readData(length: Int) -> Data? {
        guard let bytes = self.readBytes(length: length) else { return nil }
        return Data(bytes)
    }
}

final class HTTPServer {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    private let cfg: Config
    private let stt: STTEngine
    private let tts = TTSEngine()

    init(config: Config) {
        self.cfg = config
        self.stt = STTEngine(config: config)
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
        print("🔊 STTBridge läuft auf http://\(cfg.bindHost):\(cfg.port)")
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

        do {
            let session = try STTStreamSession(lang: lang, requiresOnDevice: offline || cfg.offlineOnly)
            let wsHandler = WebSocketStreamHandler(session: session, sendPartials: partials)
            session.onPartial = { [weak wsHandler] text in wsHandler?.send(json: ["type":"partial","text":text]) }
            session.onFinal   = { [weak wsHandler] text, conf in
                var obj: [String:Any] = ["type":"final","text":text]
                if let c = conf { obj["confidence"] = c }
                wsHandler?.send(json: obj)
            }
            session.onError   = { [weak wsHandler] err in wsHandler?.send(json: ["type":"error","error":"\(err)"])
            }
            return channel.pipeline.addHandler(wsHandler, name: "ws-handler", position: .last)
        } catch {
            var buf = channel.allocator.buffer(capacity: 0)
            buf.writeString("{\"type\":\"error\",\"error\":\"\(error)\"}")
            let frame = WebSocketFrame(fin: true, opcode: .text, data: buf)
            channel.writeAndFlush(frame, promise: nil)
            return channel.close()
        }
    }

    // MARK: HTTP Handler
    final class HTTPHandler: ChannelInboundHandler {
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

        private func route(context: ChannelHandlerContext, head: HTTPRequestHead, body: ByteBuffer) {
            let origin = head.headers.first(name: "Origin")
            let extra = corsHeaders(for: origin)

            if head.method == .OPTIONS {
                writeHeadBodyEnd(context, status: .ok, headers: extra, body: nil); return
            }

            let path = URL(string: head.uri)?.path ?? head.uri
            switch (head.method, path) {
            case (.GET, "/healthz"):
                let supported = server.stt.onDeviceSupported(lang: server.cfg.defaultLang)
                writeJSON(context, value: Healthz(status: "ok", lang: server.cfg.defaultLang, onDeviceSTT: supported), extra: extra)

            case (.GET, "/languages"):
                writeJSON(context, value: server.stt.languages(), extra: extra)

            case (.GET, "/voices"):
                writeJSON(context, value: server.tts.listVoices(), extra: extra)

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
                let comps = URLComponents(string: head.uri)
                let lang = comps?.queryItems?.first(where: { $0.name == "lang" })?.value ?? 
                           head.headers.first(name: "X-Language") ?? 
                           server.cfg.defaultLang
                let offline = (server.cfg.offlineOnly || ((comps?.queryItems?.first(where: { $0.name == "offline" })?.value ?? "false").lowercased() == "true"))
                let ct = head.headers.first(name: "Content-Type")?.lowercased() ?? "application/octet-stream"
                var copy = body
                let payload = copy.readData(length: body.readableBytes) ?? Data()
                
                // Extract sample rate and channel count from headers (for Home Assistant compatibility)
                let sampleRateHeader = head.headers.first(name: "X-Sample-Rate")
                let channelCountHeader = head.headers.first(name: "X-Channel-Count")
                
                Task.detached {
                    do {
                        let resp: STTResponse
                        if ct.contains("audio/l16") {
                            // Explicit raw PCM
                            let sr = Double(head.headers.first(name: "X-Sample-Rate") ?? "16000") ?? 16000
                            let ch = Int(head.headers.first(name: "X-Channel-Count") ?? "1") ?? 1
                            resp = try await self.server.stt.transcribeRaw(data: payload, sampleRate: sr, channels: ch, lang: lang, offline: offline)
                        } else if let srStr = sampleRateHeader, let chStr = channelCountHeader {
                            // WAV with metadata headers (Home Assistant sends this)
                            let sr = Double(srStr) ?? 16000
                            let ch = Int(chStr) ?? 1
                            resp = try await self.server.stt.transcribeRaw(data: payload, sampleRate: sr, channels: ch, lang: lang, offline: offline)
                        } else {
                            // Regular WAV file
                            resp = try await self.server.stt.transcribeRaw(data: payload, sampleRate: nil, channels: nil, lang: lang, offline: offline)
                        }
                        context.eventLoop.execute { self.writeJSON(context, value: resp, extra: extra) }
                    } catch let e as APIError {
                        context.eventLoop.execute { self.writeError(context, e, extra: extra) }
                    } catch {
                        context.eventLoop.execute { self.writeError(context, .internalError("Interner Fehler"), extra: extra) }
                    }
                }

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
    }
}

// MARK: WebSocket stream handler
final class WebSocketStreamHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    private let session: STTStreamSession
    private let sendPartials: Bool
    private weak var channel: Channel?

    init(session: STTStreamSession, sendPartials: Bool) {
        self.session = session; self.sendPartials = sendPartials
    }
    func handlerAdded(context: ChannelHandlerContext) { self.channel = context.channel }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        switch frame.opcode {
        case .binary:
            var d = frame.data; let n = d.readableBytes
            if let payload = d.readData(length: n) { try? session.append(payload) }
        case .connectionClose:
            session.stop(); context.close(promise: nil)
        default: break
        }
    }
    func handlerRemoved(context: ChannelHandlerContext) { session.stop() }

    func send(json: [String:Any]) {
        guard let ch = channel else { return }
        if !sendPartials, (json["type"] as? String) == "partial" { return }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        var buf = ch.allocator.buffer(capacity: data.count); buf.writeBytes(data)
        ch.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: buf), promise: nil)
    }
}
