import Darwin
import Foundation

/// Codex launches this signed executable with `command` in its MCP config.
/// Only newline-delimited MCP JSON is written to stdout.
@main
struct MCPBridgeMain {
    static func main() {
        _ = signal(SIGPIPE, SIG_IGN)
        do { try run() }
        catch {
            fputs("Image2Movie MCP bridge: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        let executableURL = try MCPPeerIdentity.ownExecutableURL()
        let appURL = try MCPPeerIdentity.canonical(
            MCPPeerIdentity.containingAppURL(forBridgeExecutable: executableURL))
        guard executableURL == MCPPeerIdentity.bridgeExecutableURL(in: appURL) else {
            throw MCPPeerIdentity.IdentityError.peerInstallation
        }
        let socketURL = try MCPPeerIdentity.socketURL(for: appURL)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw MCPUnixSocket.SocketError.io(errno) }
        defer { MCPUnixSocket.close(descriptor) }
        MCPUnixSocket.configure(descriptor)
        let connected = try MCPUnixSocket.withAddress(socketURL.path) {
            connect(descriptor, $0, $1)
        }
        guard connected == 0 else {
            if errno == ENOENT || errno == ECONNREFUSED {
                throw BridgeError.appUnavailable
            }
            throw MCPUnixSocket.SocketError.io(errno)
        }
        try MCPPeerIdentity.validatePeer(on: descriptor,
            identifier: MCPPeerIdentity.appIdentifier, expectedCodeURL: appURL)
        guard try MCPUnixSocket.readLine(from: descriptor, limit: 32) ==
              MCPUnixSocket.hello.dropLast() else {
            throw MCPUnixSocket.SocketError.protocolMismatch
        }
        try MCPUnixSocket.writeAll(MCPUnixSocket.hello, to: descriptor)
        MCPUnixSocket.configure(descriptor, handshakeTimeout: false)
        let input = MCPUnixSocketLineReader(descriptor: STDIN_FILENO)
        let output = MCPUnixSocketLineReader(descriptor: descriptor)

        // Two dedicated blocking I/O paths preserve pipe and socket backpressure.
        // The app owns all MCP parsing and tool execution.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                while true {
                    let line = try input.readLine(limit: 1_048_576)
                    guard !line.isEmpty else { continue }
                    var framed = line
                    framed.append(10)
                    try MCPUnixSocket.writeAll(framed, to: descriptor)
                }
            } catch {
                if case MCPUnixSocket.SocketError.io(0) = error {
                    // An ordinary EOF from Codex ends this bridge session.
                } else {
                    fputs("Image2Movie MCP bridge input: \(error.localizedDescription)\n", stderr)
                }
                _ = shutdown(descriptor, SHUT_WR)
            }
        }
        while true {
            let line: Data
            do { line = try output.readLine(limit: 262_144) }
            catch {
                if case MCPUnixSocket.SocketError.io(0) = error {
                    break
                }
                fputs("Image2Movie MCP bridge output: \(error.localizedDescription)\n", stderr)
                break
            }
            guard !line.isEmpty else { continue }
            var framed = line
            framed.append(10)
            try MCPUnixSocket.writeAll(framed, to: STDOUT_FILENO)
        }
    }

    private enum BridgeError: LocalizedError {
        case appUnavailable
        var errorDescription: String? {
            "Open Image2Movie and turn on ‘Allow AI tools to use Image2Movie’ before launching this bridge."
        }
    }
}
