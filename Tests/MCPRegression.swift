import Darwin
import Foundation
import MCP
#if canImport(System)
import System
#else
import SystemPackage
#endif

private enum MCPRegressionError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
}

private struct SocketSession {
    let client: Client
    let clientTransport: StdioTransport
    let clientDescriptor: Int32
    let server: Server
    let serverTransport: MCPUnixSocketTransport
}

private func socketPair() throws -> (Int32, Int32) {
    var descriptors: [Int32] = [0, 0]
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
        throw MCPRegressionError.failed("Could not create a Unix socket pair")
    }
    return (descriptors[0], descriptors[1])
}

private func makeSession() async throws -> SocketSession {
    let (serverDescriptor, clientDescriptor) = try socketPair()
    let serverTransport = MCPUnixSocketTransport(descriptor: serverDescriptor) {}
    let clientFD = FileDescriptor(rawValue: clientDescriptor)
    let clientTransport = StdioTransport(input: clientFD, output: clientFD, logger: nil)
    let server = Server(name: "Image2Movie", version: "1.0.0",
                        capabilities: .init(tools: .init()))
    await MovieMCPTools.register(on: server, isActive: { serverTransport.isActive })
    try await server.start(transport: serverTransport)
    let client = Client(name: "MCPRegression", version: "1.0")
    try await client.connect(transport: clientTransport)
    return SocketSession(client: client, clientTransport: clientTransport,
                         clientDescriptor: clientDescriptor,
                         server: server, serverTransport: serverTransport)
}

private func stop(_ session: SocketSession) async {
    await session.client.disconnect()
    MCPUnixSocket.close(session.clientDescriptor)
    await session.server.stop()
    await session.serverTransport.disconnect()
    await session.clientTransport.disconnect()
}

private func runFramingRegression() async throws {
    let (transportDescriptor, peerDescriptor) = try socketPair()
    let transport = MCPUnixSocketTransport(descriptor: transportDescriptor) {}
    try await transport.connect()
    let oversized = Data(repeating: 0x20, count: 262_145)
    do {
        try await transport.send(oversized)
        throw MCPRegressionError.failed("Socket transport accepted an oversized response")
    } catch MCPUnixSocket.SocketError.messageTooLarge { }
    guard !transport.isActive else {
        throw MCPRegressionError.failed("Oversized response left socket transport active")
    }

    let (malformedDescriptor, malformedPeer) = try socketPair()
    let malformed = MCPUnixSocketTransport(descriptor: malformedDescriptor) {}
    try await malformed.connect()
    try MCPUnixSocket.writeAll(Data("[]\n".utf8), to: malformedPeer)
    for _ in 0..<20 where malformed.isActive {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard !malformed.isActive else {
        throw MCPRegressionError.failed("Malformed JSON batch was accepted")
    }
    await malformed.disconnect()
    MCPUnixSocket.close(malformedPeer)
    MCPUnixSocket.close(peerDescriptor)

    let (boundaryDescriptor, boundaryPeer) = try socketPair()
    let boundary = MCPUnixSocketTransport(descriptor: boundaryDescriptor) {}
    try await boundary.connect()
    let limit = 1_048_576
    let prefix = Data(#"{"jsonrpc":"2.0","method":"notifications/padding","params":{"p":""# .utf8)
    let suffix = Data(#""}}"#.utf8)
    var line = prefix
    line.append(Data(repeating: 0x61, count: limit - prefix.count - suffix.count))
    line.append(suffix)
    line.append(10)
    try MCPUnixSocket.writeAll(line, to: boundaryPeer)
    try await Task.sleep(for: .milliseconds(20))
    guard boundary.isActive else {
        throw MCPRegressionError.failed("Exactly 1 MiB inbound message was rejected")
    }
    var tooLarge = Data(repeating: 0x61, count: limit + 1)
    tooLarge.append(10)
    try MCPUnixSocket.writeAll(tooLarge, to: boundaryPeer)
    for _ in 0..<20 where boundary.isActive {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard !boundary.isActive else {
        throw MCPRegressionError.failed("Oversized inbound message was accepted")
    }
    await boundary.disconnect()
    MCPUnixSocket.close(boundaryPeer)

    let (fractionalDescriptor, fractionalPeer) = try socketPair()
    let fractional = MCPUnixSocketTransport(descriptor: fractionalDescriptor) {}
    try await fractional.connect()
    try MCPUnixSocket.writeAll(Data(#"{"jsonrpc":"2.0","id":1.5,"method":"tools/list"}"# .utf8) + Data([10]), to: fractionalPeer)
    for _ in 0..<20 where fractional.isActive {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard !fractional.isActive else {
        throw MCPRegressionError.failed("Fractional JSON-RPC ID was accepted")
    }
    await fractional.disconnect()
    MCPUnixSocket.close(fractionalPeer)

    let (stoppedDescriptor, stoppedPeer) = try socketPair()
    let stoppedHandle = MCPUnixSocketHandle(descriptor: stoppedDescriptor)
    let stopped = MCPUnixSocketTransport(handle: stoppedHandle) {}
    stoppedHandle.shutdown()
    do {
        try await stopped.connect()
        throw MCPRegressionError.failed("A stopped socket started a transport")
    } catch MCPUnixSocket.SocketError.io(ENOTCONN) { }
    guard !stopped.isActive else {
        throw MCPRegressionError.failed("A pre-stopped transport became active")
    }
    MCPUnixSocket.close(stoppedPeer)
}

/// Exercises the official MCP SDK over the newline-delimited socket transport.
/// Production peer-signature admission is tested separately because socket
/// pairs have no code identity.
private func exerciseSessions(_ first: SocketSession, _ second: SocketSession) async throws {

    let expectedNames: Set<String> = ["get_capabilities", "list_authorized_folders", "inspect_sequence",
                                      "export_movie", "get_export_status", "cancel_export"]
    let firstTools = try await first.client.listTools().tools
    let secondTools = try await second.client.listTools().tools
    guard Set(firstTools.map(\.name)) == expectedNames,
          Set(secondTools.map(\.name)) == expectedNames else {
        throw MCPRegressionError.failed("MCP did not advertise all six tools")
    }

    async let capabilities = first.client.callTool(name: "get_capabilities", arguments: [:])
    async let folders = second.client.callTool(name: "list_authorized_folders", arguments: [:])
    let (capabilityResult, folderResult) = try await (capabilities, folders)
    guard capabilityResult.isError != true, folderResult.isError != true,
          capabilityResult.content.contains(where: { if case .text(let text, _, _) = $0 { return text.contains("defaults") && text.contains("codecs") }; return false }),
          folderResult.content.contains(where: { if case .text(let text, _, _) = $0 { return text.contains("folders") }; return false }) else {
        throw MCPRegressionError.failed("Concurrent socket sessions mixed or lost responses")
    }

    for _ in 0..<8 {
        try await first.clientTransport.send(Data(#"{"jsonrpc":"2.0","method":"notifications/probe"}"#.utf8))
    }
    for _ in 0..<8 {
        _ = try await first.client.listTools()
    }

    let unauthorized = try await first.client.callTool(name: "inspect_sequence", arguments: [
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
        let response = try await first.client.callTool(name: "export_movie", arguments: arguments)
        guard response.isError == true,
              response.content.contains(where: { if case .text(let text, _, _) = $0 { return text.contains("\"code\":\"\(code)\"") }; return false }) else {
            throw MCPRegressionError.failed("MCP did not reject invalid export arguments as \(code)")
        }
    }
    try await rejects([:], removing: ["width"], code: "missing_argument")
    try await rejects([:], removing: ["height"], code: "missing_argument")
    try await rejects(["codec": .int(42)], code: "invalid_argument")
    try await rejects(["quality": .bool(false)], code: "invalid_argument")
    try await rejects(["overwrite": .string("yes")], code: "invalid_argument")
    try await rejects(["custom_bitrate_mbps": .string("5")], code: "invalid_argument")
}

@MainActor
func runMCPRegression(inDirectory directory: URL) async throws {
    guard FileManager.default.fileExists(atPath: directory.path) else {
        throw MCPRegressionError.failed("MCP fixture directory is missing")
    }
    try await runFramingRegression()
    var sessions: [SocketSession] = []
    do {
        sessions.append(try await makeSession())
        sessions.append(try await makeSession())
        try await exerciseSessions(sessions[0], sessions[1])
    } catch {
        for session in sessions { await stop(session) }
        throw error
    }
    for session in sessions { await stop(session) }
}
