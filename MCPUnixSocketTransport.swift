import Darwin
import Foundation
import Logging
import MCP

/// One authenticated socket is one SDK transport and one independent MCP session.
actor MCPUnixSocketTransport: Transport {
    nonisolated let logger = Logger(label: "image2movie.mcp.unix")
    private let io: MCPConnectionIO
    nonisolated let messages: AsyncThrowingStream<Data, Error>

    init(descriptor: Int32, onClose: @escaping @Sendable () -> Void) {
        self.init(handle: MCPUnixSocketHandle(descriptor: descriptor), onClose: onClose)
    }

    init(handle: MCPUnixSocketHandle, onClose: @escaping @Sendable () -> Void) {
        let io = MCPConnectionIO(handle: handle, onClose: onClose)
        self.io = io
        messages = AsyncThrowingStream(unfolding: { [weak io] in
            await io?.nextMessage()
        })
    }

    nonisolated var isActive: Bool { io.isOpen }

    func connect() async throws {
        guard io.isOpen else { throw MCPUnixSocket.SocketError.io(ENOTCONN) }
        io.start()
    }
    func disconnect() async { io.close() }
    func send(_ data: Data) async throws { try await io.send(data) }
    nonisolated func receive() -> AsyncThrowingStream<Data, Error> { messages }
}

/// Blocking reads and writes live on dispatch workers, outside Swift's cooperative
/// executor. Only one JSON-RPC request is admitted until its matching response is
/// written. This bounds SDK handler tasks as well as stream buffering.
private final class MCPConnectionIO: @unchecked Sendable {
    static let maximumInbound = 1_048_576
    static let maximumOutbound = 262_144 // includes the SDK JSON-RPC envelope
    private let handle: MCPUnixSocketHandle
    private let lineReader: MCPUnixSocketLineReader
    private let onClose: @Sendable () -> Void
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private let delivery = NSCondition()
    private let requestFinished = DispatchSemaphore(value: 0)
    private var open = true
    private var started = false
    private var pendingID: String?
    private var pendingMessage: Data?
    private var waitingReader: CheckedContinuation<Data?, Never>?
    private var queuedWrites = 0

    init(handle: MCPUnixSocketHandle, onClose: @escaping @Sendable () -> Void) {
        self.handle = handle
        lineReader = MCPUnixSocketLineReader(descriptor: handle.descriptor)
        self.onClose = onClose
    }

    var isOpen: Bool { stateLock.withLock { open } && !handle.isStopped }

    func start() {
        let shouldStart = stateLock.withLock { () -> Bool in
            guard open, !started, !handle.isStopped else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in readLoop() }
    }

    func close() {
        let shouldClose = stateLock.withLock { () -> Bool in
            guard open else { return false }
            open = false
            pendingID = nil
            return true
        }
        guard shouldClose else { return }
        handle.shutdown()
        requestFinished.signal()
        delivery.lock()
        pendingMessage = nil
        let reader = waitingReader
        waitingReader = nil
        delivery.broadcast()
        delivery.unlock()
        reader?.resume(returning: nil)
        onClose()
    }

    func nextMessage() async -> Data? {
        await withCheckedContinuation { continuation in
            delivery.lock()
            if let pendingMessage {
                self.pendingMessage = nil
                delivery.broadcast()
                delivery.unlock()
                continuation.resume(returning: pendingMessage)
            } else if !isOpen {
                delivery.unlock()
                continuation.resume(returning: nil)
            } else {
                waitingReader = continuation
                delivery.unlock()
            }
        }
    }

    func send(_ data: Data) async throws {
        guard !data.isEmpty, data.count <= Self.maximumOutbound,
              !data.contains(10) else {
            close()
            throw MCPUnixSocket.SocketError.messageTooLarge
        }
        let admitted = stateLock.withLock { () -> Bool in
            guard open, !handle.isStopped, queuedWrites < 2 else { return false }
            queuedWrites += 1
            return true
        }
        guard admitted else {
            close()
            throw MCPUnixSocket.SocketError.io(ENOBUFS)
        }
        try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { stateLock.withLock { queuedWrites -= 1 } }
                writeLock.lock()
                defer { writeLock.unlock() }
                do {
                    guard isOpen else { throw MCPUnixSocket.SocketError.io(ENOTCONN) }
                    var framed = data
                    framed.append(10)
                    try MCPUnixSocket.writeAll(framed, to: handle.descriptor)
                    if let responseID = Self.messageID(in: data) {
                        let matched = stateLock.withLock { () -> Bool in
                            guard pendingID == responseID else { return false }
                            pendingID = nil
                            return true
                        }
                        if matched { requestFinished.signal() }
                    }
                    completion.resume()
                } catch {
                    close()
                    completion.resume(throwing: error)
                }
            }
        }
    }

    private func readLoop() {
        var consecutiveNotifications = 0
        while isOpen {
            do {
                let line = try lineReader.readLine(limit: Self.maximumInbound)
                guard !line.isEmpty,
                      let json = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let method = json["method"] as? String else {
                    throw MCPUnixSocket.SocketError.protocolMismatch
                }
                let sdkLine = try Self.sdkCompatibleInitialize(line, json: json)
                let requestID = Self.idKey(json["id"])
                if json["id"] != nil && requestID == nil {
                    throw MCPUnixSocket.SocketError.protocolMismatch
                }
                if requestID == nil {
                    guard method.hasPrefix("notifications/"),
                          consecutiveNotifications < 32 else {
                        throw MCPUnixSocket.SocketError.protocolMismatch
                    }
                    consecutiveNotifications += 1
                } else {
                    consecutiveNotifications = 0
                    stateLock.withLock { pendingID = requestID }
                }
                guard deliver(sdkLine) else {
                    throw MCPUnixSocket.SocketError.io(ENOBUFS)
                }
                if requestID != nil { requestFinished.wait() }
            } catch {
                break
            }
        }
        close()
    }

    private static func sdkCompatibleInitialize(_ line: Data,
                                                json: [String: Any]) throws -> Data {
        guard json["method"] as? String == "initialize",
              var params = json["params"] as? [String: Any],
              var capabilities = params["capabilities"] as? [String: Any],
              let experimental = capabilities["experimental"] as? [String: Any],
              !experimental.isEmpty,
              experimental.values.allSatisfy({ $0 is [String: Any] }) else {
            return line
        }
        // The 2025-11-25 protocol defines object-valued experimental capabilities,
        // but swift-sdk 0.12.1 decodes them as [String: String] (upstream #287).
        // This server does not use experimental client capabilities. Remove only a
        // valid object-valued map until the SDK fixes its decoder.
        // https://github.com/modelcontextprotocol/swift-sdk/issues/287
        capabilities.removeValue(forKey: "experimental")
        params["capabilities"] = capabilities
        var normalized = json
        normalized["params"] = params
        let result = try JSONSerialization.data(withJSONObject: normalized)
        guard result.count <= maximumInbound else {
            throw MCPUnixSocket.SocketError.messageTooLarge
        }
        return result
    }

    private func deliver(_ message: Data) -> Bool {
        delivery.lock()
        while pendingMessage != nil && isOpen { delivery.wait() }
        guard isOpen else { delivery.unlock(); return false }
        if let reader = waitingReader {
            waitingReader = nil
            delivery.unlock()
            reader.resume(returning: message)
        } else {
            pendingMessage = message
            delivery.unlock()
        }
        return true
    }

    private static func messageID(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["method"] == nil else { return nil }
        return idKey(json["id"])
    }

    private static func idKey(_ value: Any?) -> String? {
        if let string = value as? String, string.utf8.count <= 256 {
            return "s:\(string)"
        }
        if let number = value as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(),
           !["d", "f"].contains(String(cString: number.objCType)),
           let encoded = try? JSONSerialization.data(withJSONObject: number,
                                                      options: .fragmentsAllowed),
           let integer = try? JSONDecoder().decode(Int.self, from: encoded) {
            return "n:\(integer)"
        }
        return nil
    }
}
