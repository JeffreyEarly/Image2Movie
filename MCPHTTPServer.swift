import Foundation
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1

/// NIO is only an HTTP adapter. The official MCP SDK owns Streamable HTTP and JSON-RPC.
actor MCPHTTPServer {
    static let maximumBodyBytes = 1_048_576
    static let maximumConnections = 16
    static let maximumSessions = 16
    static let maximumRequestsPerSession = 100

    private var port: Int
    private let token: String
    private let connectionChanged: @Sendable (Int) -> Void
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private var sessions: [String: Session] = [:]
    private var busySessions: Set<String> = []
    private var pendingInitializations = 0
    private var connections = 0
    private var cleanupTask: Task<Void, Never>?
    private var isStopping = false
    private var generation = 0

    private struct Session {
        let server: Server
        let transport: StatefulHTTPServerTransport
        let createdAt: Date
        var lastUsed: Date
        var requests: Int
    }

    init(port: Int, token: String, connectionChanged: @escaping @Sendable (Int) -> Void) {
        self.port = port
        self.token = token
        self.connectionChanged = connectionChanged
    }

    func start() async throws {
        guard channel == nil else { return }
        guard !isStopping else { throw MCPError.internalError("MCP listener is stopping") }
        let startGeneration = generation
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        do {
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(MCPNIOHandler(server: self))
                    }
                }
            // A numeric IPv4 address prevents wildcard or IPv6 listener exposure.
            let channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
            guard !isStopping, generation == startGeneration else {
                try? await channel.close()
                throw MCPError.internalError("MCP listener was stopped during startup")
            }
            self.port = channel.localAddress?.port ?? port
            self.group = group
            self.channel = channel
            cleanupTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled else { break }
                    await self?.expireIdleSessions()
                }
            }
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func boundPort() -> Int { port }
    func sessionCount() -> Int { sessions.count }

    func stop() async {
        isStopping = true
        generation &+= 1
        cleanupTask?.cancel()
        cleanupTask = nil
        for (_, session) in sessions { await session.transport.disconnect() }
        sessions.removeAll()
        busySessions.removeAll()
        if let channel { try? await channel.close() }
        channel = nil
        if let group { try? await group.shutdownGracefully() }
        self.group = nil
        isStopping = false
    }

    func registerConnection() -> Bool {
        guard connections < Self.maximumConnections else { return false }
        connections += 1
        connectionChanged(connections)
        return true
    }

    func unregisterConnection() {
        connections = max(0, connections - 1)
        connectionChanged(connections)
    }

    /// The adapter calls finish after the response stream ends, so overlapping POSTs
    /// cannot reuse a JSON-RPC ID inside one SDK transport.
    func handle(_ request: HTTPRequest) async -> (HTTPResponse, String?) {
        guard !isStopping, channel != nil else {
            return (.error(statusCode: 503, .internalError("MCP listener is stopping")), nil)
        }
        guard request.path == "/mcp" else { return (.error(statusCode: 404, .invalidRequest("Not Found")), nil) }
        guard let host = request.header(HTTPHeaderName.host),
              host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else {
            return (.error(statusCode: 421, .invalidRequest("Host header not allowed")), nil)
        }
        if let origin = request.header(HTTPHeaderName.origin),
           origin != "http://127.0.0.1:\(port)" && origin != "http://localhost:\(port)" {
            return (.error(statusCode: 403, .invalidRequest("Origin not allowed")), nil)
        }
        guard let authorization = request.header(HTTPHeaderName.authorization),
              authorization.hasPrefix("Bearer "),
              Self.constantTimeEqual(String(authorization.dropFirst(7)), token) else {
            return (.error(statusCode: 401, .invalidRequest("Bearer authentication required"),
                           extraHeaders: [HTTPHeaderName.wwwAuthenticate: "Bearer"]), nil)
        }

        let sessionID = request.header(HTTPHeaderName.sessionID)
        if let sessionID, var session = sessions[sessionID] {
            if request.method.uppercased() == "GET" {
                return (.error(statusCode: 405, .invalidRequest("Standalone SSE is not available"),
                               extraHeaders: [HTTPHeaderName.allow: "POST, DELETE"]), nil)
            }
            let isPOST = request.method.uppercased() == "POST"
            if isPOST && busySessions.contains(sessionID) {
                return (.error(statusCode: 429, .invalidRequest("One request at a time per MCP session")), nil)
            }
            if session.requests >= Self.maximumRequestsPerSession ||
                Date().timeIntervalSince(session.createdAt) > 3600 {
                sessions.removeValue(forKey: sessionID)
                busySessions.remove(sessionID)
                await session.transport.disconnect()
                return (.error(statusCode: 404, .invalidRequest("MCP session expired; initialize again")), nil)
            }
            if isPOST { busySessions.insert(sessionID) }
            session.lastUsed = Date()
            session.requests += 1
            sessions[sessionID] = session
            let response = await session.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE" && response.statusCode == 200 {
                sessions.removeValue(forKey: sessionID)
                await session.transport.disconnect()
            }
            return (response, isPOST ? sessionID : nil)
        }
        if sessionID != nil {
            return (.error(statusCode: 404, .invalidRequest("MCP session not found")), nil)
        }
        guard request.method.uppercased() == "POST" else {
            return (.error(statusCode: 400, .invalidRequest("Initialize an MCP session first")), nil)
        }
        guard sessions.count + pendingInitializations < Self.maximumSessions else {
            return (.error(statusCode: 429, .invalidRequest("Too many MCP sessions")), nil)
        }
        pendingInitializations += 1
        defer { pendingInitializations -= 1 }
        let initializationGeneration = generation

        // A fresh transport/server pair ensures complete protocol state isolation.
        let transport = StatefulHTTPServerTransport(validationPipeline: validationPipeline)
        let server = Server(name: "Image2Movie", version: "1.0.0",
                            capabilities: .init(tools: .init()))
        await MovieMCPTools.register(on: server)
        do {
            try await server.start(transport: transport)
            guard !isStopping, generation == initializationGeneration else {
                await transport.disconnect()
                return (.error(statusCode: 503, .internalError("MCP listener stopped during initialization")), nil)
            }
            let response = await transport.handleRequest(request)
            guard !isStopping, generation == initializationGeneration else {
                await transport.disconnect()
                return (.error(statusCode: 503, .internalError("MCP listener stopped during initialization")), nil)
            }
            if response.statusCode != 200 || response.headers[HTTPHeaderName.sessionID] == nil {
                await transport.disconnect()
                return (response, nil)
            }
            let newID = response.headers[HTTPHeaderName.sessionID]!
            sessions[newID] = Session(server: server, transport: transport,
                                      createdAt: Date(), lastUsed: Date(), requests: 1)
            busySessions.insert(newID)
            return (response, newID)
        } catch {
            await transport.disconnect()
            return (.error(statusCode: 500, .internalError("Could not start MCP session")), nil)
        }
    }

    func finish(sessionID: String?) {
        if let sessionID { busySessions.remove(sessionID) }
    }

    func abandon(sessionID: String?) async {
        guard let sessionID else { return }
        busySessions.remove(sessionID)
        if let session = sessions.removeValue(forKey: sessionID) {
            await session.transport.disconnect()
        }
    }

    private var validationPipeline: StandardValidationPipeline {
        StandardValidationPipeline(validators: [
            OriginValidator(allowedHosts: ["127.0.0.1:\(port)", "localhost:\(port)"],
                            allowedOrigins: ["http://127.0.0.1:\(port)", "http://localhost:\(port)"]),
            AcceptHeaderValidator(mode: .sseRequired),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
            SessionValidator()
        ])
    }

    private func expireIdleSessions() async {
        let now = Date()
        for (id, session) in sessions
            where now.timeIntervalSince(session.lastUsed) > 600 ||
                  now.timeIntervalSince(session.createdAt) > 3600 {
            sessions.removeValue(forKey: id)
            busySessions.remove(id)
            await session.transport.disconnect()
        }
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        var difference = a.count ^ b.count
        for index in 0..<max(a.count, b.count) {
            difference |= Int((index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0))
        }
        return difference == 0
    }
}

/// NIO invokes this handler on its channel event loop; request work runs in tasks.
private final class MCPNIOHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private struct RequestState {
        var head: HTTPRequestHead
        var body: ByteBuffer
    }
    private let server: MCPHTTPServer
    private var state: RequestState?
    private var activeRequest = false
    private var registered = false
    private var requestTask: Task<Void, Never>?
    private var activeSessionID: String?
    private var responseCompleted = false
    private var deadline: Scheduled<Void>?

    init(server: MCPHTTPServer) { self.server = server }

    func channelActive(context: ChannelHandlerContext) {
        scheduleDeadline(context: context, seconds: 15)
        nonisolated(unsafe) let ctx = context
        Task {
            let admitted = await server.registerConnection()
            ctx.eventLoop.execute {
                if admitted && ctx.channel.isActive { self.registered = true }
                else {
                    if admitted { Task { await self.server.unregisterConnection() } }
                    ctx.close(promise: nil)
                }
            }
        }
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        deadline?.cancel()
        deadline = nil
        if !responseCompleted {
            requestTask?.cancel()
            if let activeSessionID { Task { await server.abandon(sessionID: activeSessionID) } }
        }
        requestTask = nil
        activeSessionID = nil
        if registered { Task { await server.unregisterConnection() } }
        context.fireChannelInactive()
    }

    private func scheduleDeadline(context: ChannelHandlerContext, seconds: Int64) {
        deadline?.cancel()
        nonisolated(unsafe) let ctx = context
        deadline = context.eventLoop.scheduleTask(in: .seconds(seconds)) {
            if self.state != nil || !self.activeRequest { ctx.close(promise: nil) }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            guard !activeRequest else { context.close(promise: nil); return }
            activeRequest = true
            responseCompleted = false
            state = RequestState(head: head, body: context.channel.allocator.buffer(capacity: 0))
            scheduleDeadline(context: context, seconds: 15)
            if let length = head.headers.first(name: "Content-Length"),
               let count = Int(length), count > MCPHTTPServer.maximumBodyBytes {
                context.close(promise: nil)
            }
        case .body(var bytes):
            guard var request = state else { return }
            guard request.body.readableBytes + bytes.readableBytes <= MCPHTTPServer.maximumBodyBytes else {
                state = nil
                context.close(promise: nil)
                return
            }
            request.body.writeBuffer(&bytes)
            state = request
        case .end:
            deadline?.cancel()
            deadline = nil
            guard let request = state else { return }
            state = nil
            for name in ["Host", "Authorization", "Origin", "MCP-Session-Id", "Content-Length"]
                where request.head.headers[name].count > 1 {
                context.close(promise: nil)
                return
            }
            let headers = Dictionary(request.head.headers.map { ($0.name, $0.value) }, uniquingKeysWith: { a, b in a + ", " + b })
            let body = request.body.getBytes(at: request.body.readerIndex,
                                             length: request.body.readableBytes).map(Data.init)
            let path = String(request.head.uri.split(separator: "?", maxSplits: 1).first ?? "")
            let httpRequest = HTTPRequest(method: request.head.method.rawValue, headers: headers,
                                          body: body, path: path)
            nonisolated(unsafe) let ctx = context
            requestTask = Task {
                let (response, sessionID) = await server.handle(httpRequest)
                ctx.eventLoop.execute { self.activeSessionID = sessionID }
                if Task.isCancelled {
                    await server.abandon(sessionID: sessionID)
                    return
                }
                let drained = await writeBody(response, version: request.head.version, context: ctx)
                guard drained, !Task.isCancelled else {
                    await server.abandon(sessionID: sessionID)
                    ctx.eventLoop.execute { ctx.close(promise: nil) }
                    return
                }
                let handedOff = try? await ctx.eventLoop.submit {
                    guard ctx.channel.isActive else { return false }
                    self.responseCompleted = true
                    self.activeSessionID = nil
                    return true
                }.get()
                guard handedOff == true, !Task.isCancelled else {
                    await server.abandon(sessionID: sessionID)
                    ctx.eventLoop.execute { ctx.close(promise: nil) }
                    return
                }
                // The SDK response stream is drained. Release its ID guard before
                // making HTTP EOF visible; reset and EOF share one event-loop turn.
                await server.finish(sessionID: sessionID)
                let endPromise = ctx.eventLoop.makePromise(of: Void.self)
                ctx.eventLoop.execute {
                    self.activeRequest = false
                    self.requestTask = nil
                    if ctx.channel.isActive {
                        self.scheduleDeadline(context: ctx, seconds: 30)
                        ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: endPromise)
                    } else {
                        endPromise.succeed(())
                    }
                }
                _ = try? await endPromise.futureResult.get()
            }
        }
    }

    private func writeBody(_ response: HTTPResponse, version: HTTPVersion,
                           context: ChannelHandlerContext) async -> Bool {
        nonisolated(unsafe) let ctx = context
        let responseHead = HTTPResponseHead(version: version,
                                            status: HTTPResponseStatus(statusCode: response.statusCode),
                                            headers: HTTPHeaders(response.headers.map { ($0.key, $0.value) }))
        ctx.eventLoop.execute {
            ctx.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
            ctx.flush()
        }
        if case .stream(let stream, _) = response {
            do {
                for try await chunk in stream {
                    ctx.eventLoop.execute {
                        var buffer = ctx.channel.allocator.buffer(capacity: chunk.count)
                        buffer.writeBytes(chunk)
                        ctx.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    }
                }
            } catch { return false /* An accepted export remains in the coordinator. */ }
        } else if let body = response.bodyData {
            ctx.eventLoop.execute {
                var buffer = ctx.channel.allocator.buffer(capacity: body.count)
                buffer.writeBytes(body)
                ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            }
        }
        return !Task.isCancelled
    }
}
