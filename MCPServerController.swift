import AppKit
import Combine
import Foundation

@MainActor @objc(MCPServerController)
final class MCPServerController: NSObject, ObservableObject {
    static let shared = MCPServerController()
    private static let enabledKey = "Image2Movie.LocalAutomationEnabled"
    private static let legacyEnabledKey = "Image2Movie.MCPEnabled"

    @Published private(set) var isEnabled = false
    @Published private(set) var isTransitioning = false
    @Published private(set) var status = "Disabled"
    @Published private(set) var activeConnections = 0

    private var server: MCPUnixSocketServer?
    private var lifecycleTail: Task<Void, Never>?
    private var pendingOperations = 0
    private var migrationError: Error?
    private var connectionGeneration = UUID()

    override init() {
        Self.migrateLegacyDefaults(UserDefaults.standard)
        do { try TokenStore.removeLegacyCredentials() }
        catch { migrationError = error }
        super.init()
    }

    static func migrateLegacyDefaults(_ defaults: UserDefaults) {
        defaults.removeObject(forKey: legacyEnabledKey)
    }

    static func localAutomationEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    /// The helper is embedded beside the application executable in the app bundle.
    static func bundledHelperPath(bundleURL: URL = Bundle.main.bundleURL) -> String {
        MCPPeerIdentity.bridgeExecutableURL(in: bundleURL).path
    }

    static func tomlEscape(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x08: return "\\b"
            case 0x09: return "\\t"
            case 0x0A: return "\\n"
            case 0x0C: return "\\f"
            case 0x0D: return "\\r"
            case 0x22: return "\\\""
            case 0x5C: return "\\\\"
            case 0x00...0x1F, 0x7F: return String(format: "\\u%04X", scalar.value)
            default: return String(scalar)
            }
        }.joined()
    }

    static func codexConfiguration(helperPath: String) -> String {
        """
        [mcp_servers.image2movie]
        command = "\(tomlEscape(helperPath))"
        """
    }

    var codexConfiguration: String {
        Self.codexConfiguration(helperPath: Self.bundledHelperPath())
    }

    /// Called by the application at launch. A fresh installation remains disabled.
    func restoreEnabledState() async {
        guard Self.localAutomationEnabled(in: UserDefaults.standard) else {
            if let migrationError { status = "Legacy MCP cleanup failed: \(migrationError.localizedDescription)" }
            return
        }
        do { try await start() }
        catch { status = "Local automation could not start: \(error.localizedDescription)" }
    }

    func start() async throws { try await serialize { try await self.startUnlocked() } }
    func stop() async { try? await serialize { await self.stopUnlocked() } }

    private func startUnlocked() async throws {
        guard server == nil else { return }
        let generation = UUID()
        connectionGeneration = generation
        let server = MCPUnixSocketServer { [weak self] count in
            Task { @MainActor in
                guard let self, self.connectionGeneration == generation else { return }
                self.activeConnections = count
                if self.isEnabled { self.status = count == 0 ? "Running" : "Connected (\(count))" }
            }
        }
        do { try await server.start() }
        catch {
            status = "Local automation could not start: \(error.localizedDescription)"
            throw error
        }
        self.server = server
        isEnabled = true
        status = "Running"
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
    }

    private func stopUnlocked() async {
        connectionGeneration = UUID()
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
}
