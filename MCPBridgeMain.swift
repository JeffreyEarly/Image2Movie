import AppKit
import Darwin
import Foundation

/// Codex launches this signed executable with `command` in its MCP config.
/// Only newline-delimited MCP JSON is written to stdout.
@main
struct MCPBridgeMain {
    @MainActor static func main() async {
        _ = signal(SIGPIPE, SIG_IGN)
        do { try await run() }
        catch {
            fputs("Image2Movie MCP bridge: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor private static func run() async throws {
        let deadline = DispatchTime.now() + .seconds(8)
        let startupGuard = StartupDeadlineGuard(deadline: deadline)
        // This also bounds synchronous Security/Launch Services calls, which
        // have no cancellation or per-call timeout.
        let watchdog = startWatchdog(deadline: deadline, guard: startupGuard)
        defer { watchdog.cancel() }

        let executableURL = try MCPPeerIdentity.ownExecutableURL()
        let appURL = try MCPPeerIdentity.canonical(
            MCPPeerIdentity.containingAppURL(forBridgeExecutable: executableURL))
        guard executableURL == MCPPeerIdentity.bridgeExecutableURL(in: appURL) else {
            throw MCPPeerIdentity.IdentityError.peerInstallation
        }
        let socketURL = try MCPPeerIdentity.socketURL(for: appURL)
        let descriptor = try await establishConnection(to: socketURL, appURL: appURL,
                                                       deadline: deadline)
        try startupGuard.complete()
        watchdog.cancel()
        defer { MCPUnixSocket.close(descriptor) }
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

    @MainActor private static func establishConnection(to socketURL: URL, appURL: URL,
                                                        deadline: DispatchTime) async throws -> Int32 {
        var inspectedApp = false
        while true {
            guard DispatchTime.now() < deadline else { throw BridgeError.startupDeadline }
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw MCPUnixSocket.SocketError.io(errno) }
            do {
                try connectBeforeDeadline(descriptor, to: socketURL.path, deadline: deadline)
                try MCPPeerIdentity.validatePeer(on: descriptor,
                    identifier: MCPPeerIdentity.appIdentifier, expectedCodeURL: appURL)
                try configureHandshakeTimeout(descriptor, deadline: deadline)
                guard try MCPUnixSocket.readLine(from: descriptor, limit: 32) ==
                      MCPUnixSocket.hello.dropLast() else {
                    throw MCPUnixSocket.SocketError.protocolMismatch
                }
                try configureHandshakeTimeout(descriptor, deadline: deadline)
                try MCPUnixSocket.writeAll(MCPUnixSocket.hello, to: descriptor)
                guard DispatchTime.now() < deadline else { throw BridgeError.startupDeadline }
                MCPUnixSocket.configure(descriptor, handshakeTimeout: false)
                return descriptor
            } catch {
                MCPUnixSocket.close(descriptor)
                if case MCPUnixSocket.SocketError.io(let number) = error,
                   number == EAGAIN || number == ETIMEDOUT {
                    throw BridgeError.startupDeadline
                }
                guard case MCPUnixSocket.SocketError.io(let number) = error,
                      number == ENOENT || number == ECONNREFUSED else { throw error }
            }

            if !inspectedApp {
                inspectedApp = true
                let running = NSWorkspace.shared.runningApplications.contains { app in
                    guard let bundleURL = app.bundleURL else { return false }
                    return (try? MCPPeerIdentity.canonical(bundleURL)) == appURL
                }
                if !running {
                    try MCPPeerIdentity.validateAppForLaunch(at: appURL)
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = false
                    configuration.allowsRunningApplicationSubstitution = false
                    configuration.createsNewApplicationInstance = false
                    configuration.promptsUserIfNeeded = false
                    configuration.appleEvent = MCPLaunchRequest.makeAppleEvent()
                    let application = try await NSWorkspace.shared.openApplication(
                        at: appURL, configuration: configuration)
                    guard let launchedURL = application.bundleURL,
                          try MCPPeerIdentity.canonical(launchedURL) == appURL else {
                        throw MCPPeerIdentity.IdentityError.peerInstallation
                    }
                }
            }
            guard DispatchTime.now() < deadline else { throw BridgeError.startupDeadline }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func connectBeforeDeadline(_ descriptor: Int32, to path: String,
                                              deadline: DispatchTime) throws {
        MCPUnixSocket.configure(descriptor)
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw MCPUnixSocket.SocketError.io(errno)
        }
        defer { _ = fcntl(descriptor, F_SETFL, flags) }
        let connected = try MCPUnixSocket.withAddress(path) { connect(descriptor, $0, $1) }
        if connected == 0 { return }
        let connectionError = errno
        guard connectionError == EINPROGRESS || connectionError == EINTR else {
            throw MCPUnixSocket.SocketError.io(connectionError)
        }
        while true {
            var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let count = poll(&event, 1, try remainingMilliseconds(until: deadline))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                if count == 0 { throw BridgeError.startupDeadline }
                throw MCPUnixSocket.SocketError.io(errno)
            }
            var result: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &result, &length) == 0 else {
                throw MCPUnixSocket.SocketError.io(errno)
            }
            if result != 0 { throw MCPUnixSocket.SocketError.io(result) }
            return
        }
    }

    private static func configureHandshakeTimeout(_ descriptor: Int32,
                                                   deadline: DispatchTime) throws {
        let nanos = try remainingNanoseconds(until: deadline)
        var timeout = timeval(tv_sec: Int(nanos / 1_000_000_000),
                              tv_usec: Int32(max(1, (nanos % 1_000_000_000) / 1_000)))
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            guard setsockopt(descriptor, SOL_SOCKET, option, &timeout,
                             socklen_t(MemoryLayout<timeval>.size)) == 0 else {
                throw MCPUnixSocket.SocketError.io(errno)
            }
        }
    }

    private static func remainingNanoseconds(until deadline: DispatchTime) throws -> UInt64 {
        let remaining = deadline.uptimeNanoseconds &- DispatchTime.now().uptimeNanoseconds
        guard remaining <= 8_000_000_000, remaining > 0 else {
            throw BridgeError.startupDeadline
        }
        return remaining
    }

    private static func remainingMilliseconds(until deadline: DispatchTime) throws -> Int32 {
        Int32((try remainingNanoseconds(until: deadline) + 999_999) / 1_000_000)
    }

    private nonisolated static func startWatchdog(deadline: DispatchTime,
                                                  guard startupGuard: StartupDeadlineGuard)
        -> any DispatchSourceTimer {
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: deadline)
        watchdog.setEventHandler(handler: { @Sendable in startupGuard.expire() })
        watchdog.resume()
        return watchdog
    }

    private enum BridgeError: LocalizedError {
        case startupDeadline
        var errorDescription: String? {
            "Startup exceeded eight seconds. Check Image2Movie’s Automation Settings and restart the bridge."
        }
    }

    /// The lock gives successful handshake completion and the timer one winner.
    private final class StartupDeadlineGuard: @unchecked Sendable {
        private let lock = NSLock()
        private let deadline: DispatchTime
        private var completed = false

        init(deadline: DispatchTime) { self.deadline = deadline }

        func complete() throws {
            try lock.withLock {
                guard DispatchTime.now() < deadline else { throw BridgeError.startupDeadline }
                completed = true
            }
        }

        func expire() {
            lock.withLock {
                guard !completed else { return }
                fputs("Image2Movie MCP bridge: Startup exceeded eight seconds. Check Image2Movie’s Automation Settings and restart the bridge.\n", stderr)
                _exit(1)
            }
        }
    }
}
