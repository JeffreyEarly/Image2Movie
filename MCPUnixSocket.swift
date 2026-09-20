import Darwin
import Foundation

enum MCPUnixSocket {
    static let hello = Data("I2M-MCP/1\n".utf8)

    static func address(for path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8CString)
        var address = sockaddr_un()
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw SocketError.pathTooLong
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            for (offset, byte) in bytes.enumerated() { target[offset] = UInt8(bitPattern: byte) }
        }
        return address
    }

    static func withAddress<T>(_ path: String,
                               _ operation: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var address = try address(for: path)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                operation($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func configure(_ descriptor: Int32, handshakeTimeout: Bool = true) {
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                       socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: handshakeTimeout ? 5 : 0, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                       socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                       socklen_t(MemoryLayout<timeval>.size))
    }

    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset),
                                           buffer.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0 && errno == EINTR { continue }
                throw SocketError.io(errno)
            }
        }
    }

    static func readExact(_ count: Int, from descriptor: Int32) throws -> Data {
        guard count >= 0 && count <= 1_048_576 else { throw SocketError.messageTooLarge }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < count {
                let received = Darwin.read(descriptor, base.advanced(by: offset), count - offset)
                if received > 0 { offset += received; continue }
                if received < 0 && errno == EINTR { continue }
                throw SocketError.io(received == 0 ? 0 : errno)
            }
        }
        return data
    }

    static func readLine(from descriptor: Int32, limit: Int) throws -> Data {
        var result = Data()
        while result.count <= limit {
            var byte: UInt8 = 0
            let received = Darwin.read(descriptor, &byte, 1)
            if received == 1 {
                if byte == 10 { return result }
                result.append(byte)
                continue
            }
            if received < 0 && errno == EINTR { continue }
            throw SocketError.io(received == 0 ? 0 : errno)
        }
        throw SocketError.messageTooLarge
    }

    static func close(_ descriptor: Int32) {
        _ = shutdown(descriptor, SHUT_RDWR)
        _ = Darwin.close(descriptor)
    }

    enum SocketError: LocalizedError {
        case pathTooLong, messageTooLarge, protocolMismatch, io(Int32)
        var errorDescription: String? {
            switch self {
            case .pathTooLong: "Unix socket path exceeds the system limit"
            case .messageTooLarge: "MCP message exceeds the size limit"
            case .protocolMismatch: "Image2Movie bridge protocol version mismatch"
            case .io(let number): "Unix socket error \(number)"
            }
        }
    }
}

/// Retaining workers keep the descriptor allocated until their I/O has stopped.
/// Shutdown is immediate; the final close happens exactly once in deinit.
final class MCPUnixSocketHandle: @unchecked Sendable {
    let id = UUID()
    let descriptor: Int32
    private let lock = NSLock()
    private var stopped = false
    private let onDeinit: (@Sendable () -> Void)?

    init(descriptor: Int32, onDeinit: (@Sendable () -> Void)? = nil) {
        self.descriptor = descriptor
        self.onDeinit = onDeinit
    }

    var isStopped: Bool { lock.withLock { stopped } }

    func shutdown() {
        let first = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            return true
        }
        if first { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
    }

    deinit {
        shutdown()
        _ = Darwin.close(descriptor)
        onDeinit?()
    }
}

/// Reads complete newline frames while keeping at most one syscall-sized
/// lookahead. A separate instance is used for each descriptor's read side.
final class MCPUnixSocketLineReader: @unchecked Sendable {
    private let descriptor: Int32
    private var pending = Data()

    init(descriptor: Int32) { self.descriptor = descriptor }

    func readLine(limit: Int) throws -> Data {
        while true {
            if let newline = pending.firstIndex(of: 10) {
                let size = pending.distance(from: pending.startIndex, to: newline)
                guard size <= limit else { throw MCPUnixSocket.SocketError.messageTooLarge }
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                return line
            }
            guard pending.count <= limit else {
                throw MCPUnixSocket.SocketError.messageTooLarge
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = chunk.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count > 0 { pending.append(contentsOf: chunk.prefix(count)); continue }
            if count < 0 && errno == EINTR { continue }
            throw MCPUnixSocket.SocketError.io(count == 0 ? 0 : errno)
        }
    }
}
