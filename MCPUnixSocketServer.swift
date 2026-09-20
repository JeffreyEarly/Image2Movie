import Darwin
import Foundation
import MCP

actor MCPUnixSocketServer {
    static let maximumConnections = 16
    private let connectionChanged: @Sendable (Int) -> Void
    private let admission = MCPConnectionAdmission(
        maximum: MCPUnixSocketServer.maximumConnections)
    private var listener: MCPUnixSocketHandle?
    private var lockDescriptor: Int32 = -1
    private var socketURL: URL?
    private var socketDevice: dev_t = 0
    private var socketInode: ino_t = 0
    private var pending: [UUID: MCPUnixSocketHandle] = [:]
    private var sessions: [UUID: Session] = [:]
    private var stopping = false
    private var generation = 0

    private struct Session {
        let server: Server
        let transport: MCPUnixSocketTransport
    }

    init(connectionChanged: @escaping @Sendable (Int) -> Void) {
        self.connectionChanged = connectionChanged
    }

    func start() async throws {
        guard listener == nil else { return }
        guard !stopping else { throw MCPUnixSocket.SocketError.io(EBUSY) }
        let appURL = try MCPPeerIdentity.canonical(Bundle.main.bundleURL)
        let url = try MCPPeerIdentity.socketURL(for: appURL)
        let lockURL = URL(fileURLWithPath: url.path + ".lock")
        let lock = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw MCPUnixSocket.SocketError.io(errno) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            _ = Darwin.close(lock)
            throw MCPUnixSocket.SocketError.io(code)
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            let code = errno
            _ = Darwin.close(lock)
            throw MCPUnixSocket.SocketError.io(code)
        }
        var boundDevice: dev_t = 0
        var boundInode: ino_t = 0
        do {
            try Self.removeStaleSocket(at: url.path)
            let bound = try MCPUnixSocket.withAddress(url.path) {
                bind(descriptor, $0, $1)
            }
            guard bound == 0 else { throw MCPUnixSocket.SocketError.io(errno) }
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                throw MCPUnixSocket.SocketError.io(errno)
            }
            boundDevice = info.st_dev
            boundInode = info.st_ino
            guard chmod(url.path, 0o600) == 0 else {
                throw MCPUnixSocket.SocketError.io(errno)
            }
            guard listen(descriptor, 16) == 0 else {
                throw MCPUnixSocket.SocketError.io(errno)
            }
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw MCPUnixSocket.SocketError.io(errno)
            }
            socketDevice = boundDevice
            socketInode = boundInode
            socketURL = url
            lockDescriptor = lock
            let handle = MCPUnixSocketHandle(descriptor: descriptor)
            listener = handle
            generation &+= 1
            let acceptedGeneration = generation
            let admission = self.admission
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                while !handle.isStopped {
                    var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                    let polled = Darwin.poll(&event, 1, 250)
                    if polled == 0 || (polled < 0 && errno == EINTR) { continue }
                    if polled < 0 || handle.isStopped { break }
                    let peer = Darwin.accept(descriptor, nil, nil)
                    if peer < 0 {
                        if errno == EINTR || errno == EAGAIN { continue }
                        break
                    }
                    // Darwin accept inherits the listener's nonblocking flag.
                    // The handshake and transport use blocking I/O on workers.
                    let peerFlags = fcntl(peer, F_GETFL)
                    guard peerFlags >= 0,
                          fcntl(peer, F_SETFL, peerFlags & ~O_NONBLOCK) == 0 else {
                        MCPUnixSocket.close(peer)
                        continue
                    }
                    guard let self, admission.reserve() else {
                        MCPUnixSocket.close(peer)
                        continue
                    }
                    let peerHandle = MCPUnixSocketHandle(descriptor: peer) {
                        admission.release()
                    }
                    Task { await self.accept(peerHandle, appURL: appURL,
                                             generation: acceptedGeneration) }
                }
            }
        } catch {
            MCPUnixSocket.close(descriptor)
            _ = Darwin.close(lock)
            if boundInode != 0 {
                Self.unlinkIfOwned(url.path, device: boundDevice, inode: boundInode)
            }
            throw error
        }
    }

    func stop() async {
        guard listener != nil || !pending.isEmpty || !sessions.isEmpty else { return }
        stopping = true
        generation &+= 1
        let oldListener = listener
        listener = nil
        oldListener?.shutdown()
        for handle in pending.values { handle.shutdown() }
        pending.removeAll()
        let oldSessions = sessions
        sessions.removeAll()
        connectionChanged(0)
        for (_, session) in oldSessions {
            await session.transport.disconnect()
            await session.server.stop()
        }
        if let socketURL {
            Self.unlinkIfOwned(socketURL.path, device: socketDevice, inode: socketInode)
        }
        socketURL = nil
        socketDevice = 0
        socketInode = 0
        if lockDescriptor >= 0 {
            _ = flock(lockDescriptor, LOCK_UN)
            _ = Darwin.close(lockDescriptor)
            lockDescriptor = -1
        }
        stopping = false
    }

    private func accept(_ handle: MCPUnixSocketHandle, appURL: URL,
                        generation: Int) {
        guard !stopping, self.generation == generation,
              pending.count + sessions.count < Self.maximumConnections else {
            handle.shutdown()
            return
        }
        pending[handle.id] = handle
        connectionChanged(pending.count + sessions.count)
        MCPUnixSocket.configure(handle.descriptor)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let authenticated: Bool
            do {
                try MCPPeerIdentity.validatePeer(on: handle.descriptor,
                    identifier: MCPPeerIdentity.bridgeIdentifier,
                    expectedCodeURL: MCPPeerIdentity.bridgeExecutableURL(in: appURL))
                try MCPUnixSocket.writeAll(MCPUnixSocket.hello, to: handle.descriptor)
                authenticated = try MCPUnixSocket.readLine(from: handle.descriptor, limit: 32) ==
                    MCPUnixSocket.hello.dropLast()
            } catch {
                authenticated = false
            }
            guard let self else { handle.shutdown(); return }
            Task { await self.finishAccept(handle, authenticated: authenticated,
                                           generation: generation) }
        }
    }

    private func finishAccept(_ handle: MCPUnixSocketHandle, authenticated: Bool,
                              generation: Int) async {
        guard pending[handle.id] != nil else { return }
        guard authenticated, !stopping, self.generation == generation else {
            pending.removeValue(forKey: handle.id)
            handle.shutdown()
            connectionChanged(pending.count + sessions.count)
            return
        }
        MCPUnixSocket.configure(handle.descriptor, handshakeTimeout: false)
        let transport = MCPUnixSocketTransport(handle: handle) { [weak self] in
            guard let self else { return }
            Task { await self.sessionClosed(handle.id) }
        }
        let server = Server(name: "Image2Movie", version: "1.0.0",
                            capabilities: .init(tools: .init()))
        await MovieMCPTools.register(on: server, isActive: { transport.isActive })
        guard pending[handle.id] != nil, !stopping,
              self.generation == generation, transport.isActive else {
            pending.removeValue(forKey: handle.id)
            await transport.disconnect()
            connectionChanged(pending.count + sessions.count)
            return
        }
        do {
            try await server.start(transport: transport)
            guard pending[handle.id] != nil, !stopping,
                  self.generation == generation, transport.isActive else {
                await server.stop()
                return
            }
            pending.removeValue(forKey: handle.id)
            sessions[handle.id] = Session(server: server, transport: transport)
        } catch {
            pending.removeValue(forKey: handle.id)
            await transport.disconnect()
            await server.stop()
            connectionChanged(pending.count + sessions.count)
        }
    }

    private func sessionClosed(_ id: UUID) async {
        if pending.removeValue(forKey: id) != nil {
            connectionChanged(pending.count + sessions.count)
        }
        if let session = sessions.removeValue(forKey: id) {
            connectionChanged(pending.count + sessions.count)
            await session.server.stop()
        }
    }

    private static func removeStaleSocket(at path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return }
            throw MCPUnixSocket.SocketError.io(errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else {
            throw MCPUnixSocket.SocketError.io(EEXIST)
        }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw MCPUnixSocket.SocketError.io(errno) }
        let connected = try MCPUnixSocket.withAddress(path) { connect(probe, $0, $1) }
        let result = errno
        MCPUnixSocket.close(probe)
        guard connected < 0, result == ECONNREFUSED else {
            throw MCPUnixSocket.SocketError.io(connected == 0 ? EADDRINUSE : result)
        }
        unlinkIfOwned(path, device: info.st_dev, inode: info.st_ino)
    }

    private static func unlinkIfOwned(_ path: String, device: dev_t, inode: ino_t) {
        var current = stat()
        if lstat(path, &current) == 0,
           current.st_dev == device, current.st_ino == inode,
           (current.st_mode & S_IFMT) == S_IFSOCK {
            _ = unlink(path)
        }
    }
}

/// Reserved on the accept worker before any asynchronous authentication task.
private final class MCPConnectionAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private let maximum: Int
    private var count = 0

    init(maximum: Int) { self.maximum = maximum }

    func reserve() -> Bool {
        lock.withLock {
            guard count < maximum else { return false }
            count += 1
            return true
        }
    }

    func release() {
        lock.withLock { count -= 1 }
    }
}
