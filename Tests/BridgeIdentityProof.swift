import Darwin
import Foundation

// Standalone, signed proof fixture. See run-signed-bridge-proof.sh.
@main
struct BridgeIdentityProof {
    static func main() {
        do { try run() }
        catch {
            fputs("proof error: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        let role = CommandLine.arguments[1]
        let appURL = try MCPPeerIdentity.canonical(Bundle.main.bundleURL)
        let socketPath = CommandLine.arguments.count > 2
            ? CommandLine.arguments[2]
            : try MCPPeerIdentity.socketURL(for: appURL).path
        if role == "server" || role == "rogue-server" {
            let listener = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0 else { throw MCPUnixSocket.SocketError.io(errno) }
            defer { MCPUnixSocket.close(listener); _ = unlink(socketPath) }
            let bound = try MCPUnixSocket.withAddress(socketPath) { bind(listener, $0, $1) }
            guard bound == 0, listen(listener, 3) == 0 else {
                throw MCPUnixSocket.SocketError.io(errno)
            }
            _ = chmod(socketPath, 0o600)
            fputs("socket=\(socketPath)\n", stderr)
            if role == "rogue-server" {
                let peer = accept(listener, nil, nil)
                guard peer >= 0 else { throw MCPUnixSocket.SocketError.io(errno) }
                defer { MCPUnixSocket.close(peer) }
                var byte: UInt8 = 0
                guard read(peer, &byte, 1) == 0 else {
                    throw MCPUnixSocket.SocketError.protocolMismatch
                }
                fputs("rogue-server=rejected\n", stderr)
                return
            }
            for index in 0..<3 {
                let peer = accept(listener, nil, nil)
                guard peer >= 0 else { throw MCPUnixSocket.SocketError.io(errno) }
                defer { MCPUnixSocket.close(peer) }
                let authenticated = (try? MCPPeerIdentity.validatePeer(
                    on: peer, identifier: MCPPeerIdentity.bridgeIdentifier,
                    expectedCodeURL: MCPPeerIdentity.bridgeExecutableURL(in: appURL))) != nil
                fputs("attempt\(index)=\(authenticated ? "accepted" : "rejected")\n", stderr)
                if authenticated {
                    try MCPUnixSocket.writeAll(MCPUnixSocket.hello, to: peer)
                    guard try MCPUnixSocket.readLine(from: peer, limit: 32) ==
                          MCPUnixSocket.hello.dropLast() else {
                        throw MCPUnixSocket.SocketError.protocolMismatch
                    }
                }
            }
        } else {
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw MCPUnixSocket.SocketError.io(errno) }
            defer { MCPUnixSocket.close(descriptor) }
            let connected = try MCPUnixSocket.withAddress(socketPath) {
                connect(descriptor, $0, $1)
            }
            guard connected == 0 else { throw MCPUnixSocket.SocketError.io(errno) }
            if role == "client" {
                let executable = try MCPPeerIdentity.ownExecutableURL()
                let parent = try MCPPeerIdentity.canonical(
                    MCPPeerIdentity.containingAppURL(forBridgeExecutable: executable))
                try MCPPeerIdentity.validatePeer(on: descriptor,
                    identifier: MCPPeerIdentity.appIdentifier,
                    expectedCodeURL: parent)
                guard try MCPUnixSocket.readLine(from: descriptor, limit: 32) ==
                      MCPUnixSocket.hello.dropLast() else {
                    throw MCPUnixSocket.SocketError.protocolMismatch
                }
                try MCPUnixSocket.writeAll(MCPUnixSocket.hello, to: descriptor)
                fputs("client=verified\n", stderr)
            } else if role == "rogue" {
                // Wait for the server to reject this unsigned or different-copy process.
                var byte: UInt8 = 0
                let count = read(descriptor, &byte, 1)
                guard count == 0 else { throw MCPUnixSocket.SocketError.protocolMismatch }
                fputs("rogue=rejected\n", stderr)
            } else {
                throw MCPUnixSocket.SocketError.protocolMismatch
            }
        }
    }
}
