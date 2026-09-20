import AppKit
import Combine
import Foundation

@MainActor @objc(MCPServerController)
final class MCPServerController: NSObject, ObservableObject {
    static let shared = MCPServerController()
    private static let enabledKey = "Image2Movie.MCPEnabled"
    private static let port = 8765

    @Published private(set) var isEnabled = false
    @Published private(set) var isTransitioning = false
    @Published private(set) var status = "Disabled"
    @Published private(set) var activeConnections = 0
    let endpoint = "http://127.0.0.1:8765/mcp"

    private var server: MCPHTTPServer?
    private var lifecycleTail: Task<Void, Never>?
    private var pendingOperations = 0

    var codexConfiguration: String {
        """
        [mcp_servers.image2movie]
        url = "\(endpoint)"
        bearer_token_env_var = "IMAGE2MOVIE_MCP_TOKEN"
        """
    }

    /// Called by the application at launch. A fresh installation remains disabled.
    func restoreEnabledState() async {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        do { try await start() }
        catch { status = "MCP could not start: \(error.localizedDescription)" }
    }

    func start() async throws {
        try await serialize { try await self.startUnlocked() }
    }

    func stop() async {
        try? await serialize { await self.stopUnlocked() }
    }

    /// Rotation closes every prior MCP session and invalidates its token.
    func rotateToken() async throws {
        try await serialize {
            let wasEnabled = self.isEnabled
            if wasEnabled { await self.stopUnlocked() }
            do {
                _ = try TokenStore.rotate()
                if wasEnabled { try await self.startUnlocked() }
                else { self.status = "Token rotated" }
            } catch {
                self.status = "Token rotation failed: \(error.localizedDescription)"
                throw error
            }
        }
    }

    private func startUnlocked() async throws {
        guard server == nil else { return }
        let token = try TokenStore.current()
        let server = MCPHTTPServer(port: Self.port, token: token) { [weak self] count in
            Task { @MainActor in self?.activeConnections = count }
        }
        do {
            try await server.start()
        } catch {
            status = "Could not listen on port \(Self.port): \(error.localizedDescription)"
            throw error
        }
        self.server = server
        isEnabled = true
        status = "Listening on 127.0.0.1:\(Self.port)"
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
    }

    private func stopUnlocked() async {
        let server = self.server
        self.server = nil
        await server?.stop()
        isEnabled = false
        activeConnections = 0
        status = "Disabled"
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
    }

    private func serialize(_ operation: @escaping @MainActor @Sendable () async throws -> Void) async throws {
        pendingOperations += 1
        isTransitioning = true
        let predecessor = lifecycleTail
        let work = Task<Void, Error> { @MainActor in
            await predecessor?.value
            defer {
                self.pendingOperations -= 1
                self.isTransitioning = self.pendingOperations > 0
            }
            try await operation()
        }
        lifecycleTail = Task { _ = try? await work.value }
        try await work.value
    }

    func copyToken() throws {
        let token = try TokenStore.current()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
    }
}
