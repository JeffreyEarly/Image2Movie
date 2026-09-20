import Foundation
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1

private enum MCPRegressionError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

private struct SequentialHTTPReply: Sendable {
    let status: Int
    let sessionID: String?
}

/// Uses NIO's HTTP codec so every request below runs on exactly one TCP channel.
private final class SequentialHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private var context: ChannelHandlerContext?
    private var pending: CheckedContinuation<SequentialHTTPReply, Error>?
    private var responseHead: HTTPResponseHead?

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }

    func send(_ body: Data, port: Int, token: String, sessionID: String?,
              continuation: CheckedContinuation<SequentialHTTPReply, Error>) {
        guard let context, pending == nil else {
            continuation.resume(throwing: MCPRegressionError.failed("Sequential HTTP channel was unavailable"))
            return
        }
        pending = continuation
        var headers = HTTPHeaders([
            ("Host", "127.0.0.1:\(port)"),
            ("Authorization", "Bearer \(token)"),
            ("Accept", "application/json, text/event-stream"),
            ("Content-Type", "application/json"),
            ("Content-Length", String(body.count)),
            ("Connection", "keep-alive")
        ])
        if let sessionID { headers.add(name: "MCP-Session-Id", value: sessionID) }
        context.write(wrapOutboundOut(.head(.init(version: .http1_1, method: .POST,
                                                  uri: "/mcp", headers: headers))), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): responseHead = head
        case .body: break
        case .end:
            if let pending, let head = responseHead {
                pending.resume(returning: .init(status: Int(head.status.code),
                                                sessionID: head.headers.first(name: "MCP-Session-Id")))
            }
            pending = nil
            responseHead = nil
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        pending?.resume(throwing: MCPRegressionError.failed("Sequential HTTP channel closed early"))
        pending = nil
        context.fireChannelInactive()
    }
}

private func runSameSocketSequential(port: Int, token: String) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let handler = SequentialHTTPHandler()
    let channel = try await ClientBootstrap(group: group)
        .channelInitializer { channel in
            channel.pipeline.addHTTPClientHandlers().flatMap {
                channel.pipeline.addHandler(handler)
            }
        }
        .connect(host: "127.0.0.1", port: port).get()
    func send(_ body: Data, sessionID: String? = nil) async throws -> SequentialHTTPReply {
        try await withCheckedThrowingContinuation { continuation in
            channel.eventLoop.execute {
                handler.send(body, port: port, token: token, sessionID: sessionID,
                             continuation: continuation)
            }
        }
    }
    do {
        let initialized = try await send(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"SequentialRegression","version":"1.0"}}}"#.utf8))
        guard initialized.status == 200, let sessionID = initialized.sessionID else {
            throw MCPRegressionError.failed("Same-socket MCP initialization failed")
        }
        let notification = try await send(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8), sessionID: sessionID)
        guard notification.status == 202 else {
            throw MCPRegressionError.failed("Same-socket MCP initialized notification failed")
        }
        for id in 2...31 {
            let body = Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"tools/list\",\"params\":{}}".utf8)
            let reply = try await send(body, sessionID: sessionID)
            guard reply.status == 200 else {
                throw MCPRegressionError.failed("Same-socket sequential POST \(id) returned HTTP \(reply.status)")
            }
        }
    } catch {
        try? await channel.close()
        try? await group.shutdownGracefully()
        throw error
    }
    try? await channel.close()
    try? await group.shutdownGracefully()
}

/// Exercises the real NIO listener and the official MCP client transport. It uses
/// an ephemeral loopback port and a fixture token, leaving Keychain and app settings alone.
@MainActor
func runMCPRegression(inDirectory directory: URL) async throws {
    guard FileManager.default.fileExists(atPath: directory.path) else {
        throw MCPRegressionError.failed("MCP fixture directory is missing")
    }
    let token = UUID().uuidString + UUID().uuidString
    let server = MCPHTTPServer(port: 0, token: token) { _ in }
    try await server.start()
    defer { Task { await server.stop() } }
    let port = await server.boundPort()
    guard port > 0 else { throw MCPRegressionError.failed("MCP listener did not receive a port") }
    let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!
    let conflicting = MCPHTTPServer(port: port, token: "other-fixture-token") { _ in }
    do {
        try await conflicting.start()
        await conflicting.stop()
        throw MCPRegressionError.failed("A second MCP listener used an occupied port")
    } catch let error as MCPRegressionError {
        throw error
    } catch { /* A visible bind failure is the expected port-conflict result. */ }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 10
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let initialize = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"MCPRegression","version":"1.0"}}}"#.utf8)
    func request(body: Data = initialize, authorization: String? = nil,
                 host: String? = nil, origin: String? = nil) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        if let host { request.setValue(host, forHTTPHeaderField: "Host") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        return request
    }
    func status(_ request: URLRequest) async throws -> Int {
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw MCPRegressionError.failed("Non-HTTP response from MCP listener")
        }
        return response.statusCode
    }
    func freshStatus(_ request: URLRequest) async throws -> Int {
        let connection = URLSession(configuration: configuration)
        let (_, response) = try await connection.data(for: request)
        connection.finishTasksAndInvalidate()
        guard let response = response as? HTTPURLResponse else {
            throw MCPRegressionError.failed("Non-HTTP response from a fresh MCP connection")
        }
        return response.statusCode
    }

    guard try await status(request()) == 401 else {
        throw MCPRegressionError.failed("MCP accepted a missing token")
    }
    guard try await status(request(authorization: "Bearer wrong-token")) == 401 else {
        throw MCPRegressionError.failed("MCP accepted an invalid token")
    }
    guard try await status(request(authorization: "Bearer \(token)", origin: "https://untrusted.invalid")) == 403 else {
        throw MCPRegressionError.failed("MCP accepted an invalid Origin")
    }
    guard try await status(request(authorization: "Bearer \(token)", host: "untrusted.invalid")) == 421 else {
        throw MCPRegressionError.failed("MCP accepted an invalid Host")
    }

    func client() -> (Client, HTTPClientTransport) {
        let modifier: @Sendable (URLRequest) -> URLRequest = { request in
            var request = request
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
        let transport = HTTPClientTransport(endpoint: endpoint, configuration: configuration,
                                            requestModifier: modifier)
        return (Client(name: "MCPRegression", version: "1.0"), transport)
    }
    let (first, firstTransport) = client()
    let (second, secondTransport) = client()
    try await first.connect(transport: firstTransport)
    try await second.connect(transport: secondTransport)
    guard let firstSession = await firstTransport.sessionID,
          let secondSession = await secondTransport.sessionID,
          firstSession != secondSession else {
        throw MCPRegressionError.failed("MCP sessions were not isolated")
    }
    var getRequest = URLRequest(url: endpoint)
    getRequest.httpMethod = "GET"
    getRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    getRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    getRequest.setValue(firstSession, forHTTPHeaderField: "MCP-Session-Id")
    let (_, getResponse) = try await session.data(for: getRequest)
    guard let getHTTP = getResponse as? HTTPURLResponse,
          getHTTP.statusCode == 405,
          getHTTP.value(forHTTPHeaderField: "Allow") == "POST, DELETE" else {
        throw MCPRegressionError.failed("Authenticated GET did not return 405 with Allow")
    }

    let expectedNames: Set<String> = ["get_capabilities", "list_authorized_folders", "inspect_sequence",
                                      "export_movie", "get_export_status", "cancel_export"]
    let firstTools = try await first.listTools().tools
    let secondTools = try await second.listTools().tools
    guard Set(firstTools.map(\.name)) == expectedNames,
          Set(secondTools.map(\.name)) == expectedNames else {
        throw MCPRegressionError.failed("MCP did not advertise all six tools")
    }
    // Both clients have used the same sequence of JSON-RPC IDs. Their next IDs
    // overlap while different tool calls run concurrently on separate sessions.
    async let capabilities = first.callTool(name: "get_capabilities", arguments: [:])
    async let folders = second.callTool(name: "list_authorized_folders", arguments: [:])
    let (capabilityResult, folderResult) = try await (capabilities, folders)
    guard capabilityResult.isError != true, folderResult.isError != true,
          capabilityResult.content.contains(where: { content in
              if case .text(let text, _, _) = content { return text.contains("defaults") && text.contains("codecs") }
              return false
          }),
          folderResult.content.contains(where: { content in
              if case .text(let text, _, _) = content { return text.contains("folders") }
              return false
          }) else {
        throw MCPRegressionError.failed("Concurrent MCP sessions mixed or lost tool responses")
    }

    let unauthorized = try await first.callTool(name: "inspect_sequence", arguments: [
        "folder_id": .string(UUID().uuidString)
    ])
    guard unauthorized.isError == true else {
        throw MCPRegressionError.failed("MCP accepted an unauthorized folder ID")
    }

    let invalidReference: Value = .object(["folder_id": .string(UUID().uuidString),
                                           "relative_path": .string("frame.png")])
    let baseExport: [String: Value] = ["inputs": .array([invalidReference]),
                                       "output": invalidReference,
                                       "width": .int(640), "height": .int(480)]
    func rejects(_ changes: [String: Value], removing: Set<String> = [], code: String) async throws {
        var arguments = baseExport.filter { !removing.contains($0.key) }
        arguments.merge(changes) { _, new in new }
        let response = try await first.callTool(name: "export_movie", arguments: arguments)
        guard response.isError == true,
              response.content.contains(where: { content in
                  if case .text(let text, _, _) = content { return text.contains("\"code\":\"\(code)\"") }
                  return false
              }) else {
            throw MCPRegressionError.failed("MCP did not reject invalid export arguments as \(code)")
        }
    }
    try await rejects([:], removing: ["width"], code: "missing_argument")
    try await rejects([:], removing: ["height"], code: "missing_argument")
    try await rejects(["codec": .int(42)], code: "invalid_argument")
    try await rejects(["quality": .bool(false)], code: "invalid_argument")
    try await rejects(["overwrite": .string("yes")], code: "invalid_argument")
    try await rejects(["custom_bitrate_mbps": .string("5")], code: "invalid_argument")
    try await runSameSocketSequential(port: port, token: token)

    // The completed initialize POST closes its socket; the next tool call uses
    // a fresh client connection and must retain the same protocol session.
    var closedConnection = request(authorization: "Bearer \(token)")
    closedConnection.setValue("close", forHTTPHeaderField: "Connection")
    let (_, initializedResponse) = try await session.data(for: closedConnection)
    guard let initializedHTTP = initializedResponse as? HTTPURLResponse,
          initializedHTTP.statusCode == 200,
          let reusableID = initializedHTTP.value(forHTTPHeaderField: "MCP-Session-Id") else {
        throw MCPRegressionError.failed("Could not initialize a reconnectable MCP session")
    }
    for callID in 2...6 {
        let body = Data("{\"jsonrpc\":\"2.0\",\"id\":\(callID),\"method\":\"tools/list\",\"params\":{}}".utf8)
        var listRequest = request(body: body, authorization: "Bearer \(token)")
        listRequest.setValue(reusableID, forHTTPHeaderField: "MCP-Session-Id")
        listRequest.setValue("close", forHTTPHeaderField: "Connection")
        let reconnectSession = URLSession(configuration: configuration)
        let (resumedBody, resumedResponse) = try await reconnectSession.data(for: listRequest)
        reconnectSession.finishTasksAndInvalidate()
        let resumedStatus = (resumedResponse as? HTTPURLResponse)?.statusCode ?? 0
        guard resumedStatus == 200 else {
            throw MCPRegressionError.failed("A completed POST lost its session after connection close (HTTP \(resumedStatus), headers \((resumedResponse as? HTTPURLResponse)?.allHeaderFields ?? [:]), body \(String(decoding: resumedBody, as: UTF8.self)))")
        }
    }

    // A session owns its SDK transport and bounded replay buffer. Once the cap
    // is reached, another initialization must be rejected without allocation.
    let existingSessions = await server.sessionCount()
    guard existingSessions < MCPHTTPServer.maximumSessions else {
        throw MCPRegressionError.failed("Reconnect test unexpectedly filled the session table")
    }
    for _ in 0..<(MCPHTTPServer.maximumSessions - existingSessions - 1) {
        let fillStatus = try await freshStatus(request(authorization: "Bearer \(token)"))
        guard fillStatus == 200 else {
            throw MCPRegressionError.failed("MCP could not fill the bounded session table (HTTP \(fillStatus), existing \(existingSessions))")
        }
    }
    let parallelA = request(authorization: "Bearer \(token)")
    let parallelB = request(authorization: "Bearer \(token)")
    async let firstInitialization = freshStatus(parallelA)
    async let secondInitialization = freshStatus(parallelB)
    let parallelStatuses = try await [firstInitialization, secondInitialization].sorted()
    guard parallelStatuses == [200, 429] else {
        throw MCPRegressionError.failed("Parallel initializations exceeded the session limit: \(parallelStatuses)")
    }

    let oversized = request(body: Data(repeating: 0x20, count: MCPHTTPServer.maximumBodyBytes + 1),
                            authorization: "Bearer \(token)")
    if let oversizedStatus = try? await status(oversized), (200..<300).contains(oversizedStatus) {
        throw MCPRegressionError.failed("MCP accepted an oversized request body")
    }

    await first.disconnect()
    await second.disconnect()
    await server.stop()
    if let stoppedStatus = try? await status(request()), (200..<300).contains(stoppedStatus) {
        throw MCPRegressionError.failed("MCP listener remained active after stop")
    }
}
