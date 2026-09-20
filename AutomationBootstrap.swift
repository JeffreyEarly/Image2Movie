import AppKit

@MainActor
@objc(AutomationBootstrap)
final class AutomationBootstrap: NSObject {
    @objc static func finishLaunching() {
        Task { await MCPServerController.shared.restoreEnabledState() }
    }
}
