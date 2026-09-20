import Foundation

private enum MCPSettingsRegressionError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        if case .failed(let message) = self { return "MCP settings regression: \(message)" }
        return nil
    }
}

/// Pure settings/configuration checks. This intentionally never constructs the
/// controller, so it cannot touch a user's real Keychain.
@MainActor
func runMCPSettingsRegression() throws {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw MCPSettingsRegressionError.failed(message) }
    }

    let source = "/tmp/quo\"te\\line\nsnow☃" + String(UnicodeScalar(1)!)
    let escaped = MCPServerController.tomlEscape(source)
    try check(escaped == "/tmp/quo\\\"te\\\\line\\nsnow☃\\u0001", "TOML escaping changed")

    let bundleURL = URL(fileURLWithPath: "/tmp/Image 2 ☃.app", isDirectory: true)
    let expectedHelper = bundleURL.appendingPathComponent("Contents/MacOS/image2movie-mcp").path
    try check(MCPServerController.bundledHelperPath(bundleURL: bundleURL) == expectedHelper,
              "bundled helper path changed")
    try check(MCPServerController.codexConfiguration(helperPath: #"/tmp/a"b\c"#) ==
              "[mcp_servers.image2movie]\ncommand = \"/tmp/a\\\"b\\\\c\"",
              "Codex TOML configuration changed")

    let suiteName = "Image2Movie.MCPSettingsRegression.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        throw MCPSettingsRegressionError.failed("could not create isolated defaults")
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try check(!MCPServerController.localAutomationEnabled(in: defaults), "fresh setting was enabled")
    defaults.set(true, forKey: "Image2Movie.MCPEnabled")
    MCPServerController.migrateLegacyDefaults(defaults)
    try check(!MCPServerController.localAutomationEnabled(in: defaults),
              "legacy HTTP setting enabled local automation")
    defaults.set(true, forKey: "Image2Movie.LocalAutomationEnabled")
    try check(MCPServerController.localAutomationEnabled(in: defaults),
              "explicit local automation opt-in was not persisted")
}
