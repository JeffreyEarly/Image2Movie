import AppKit

@MainActor
@objc(AutomationBootstrap)
final class AutomationBootstrap: NSObject {
    @objc static func isAutomationLaunch() -> Bool {
        MCPLaunchRequest.isAutomationLaunch(
            arguments: ProcessInfo.processInfo.arguments,
            event: NSAppleEventManager.shared().currentAppleEvent
        )
    }

    @objc static func isAutomationReopen() -> Bool {
        MCPLaunchRequest.isAutomationLaunch(
            arguments: [],
            event: NSAppleEventManager.shared().currentAppleEvent
        )
    }

    @objc static func finishLaunching() {
        Task { await MCPServerController.shared.restoreEnabledState() }
    }
}
