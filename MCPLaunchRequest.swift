import AppKit

/// The sandboxed bridge's NSWorkspace launch arguments are discarded by macOS.
/// Its standard open-application event carries the private startup marker instead.
enum MCPLaunchRequest {
    static let argument = "--image2movie-automation-launch"
    private static let openApplication: AEEventID = 0x6f617070 // oapp
    private static let appleEventClass: AEEventClass = 0x61657674 // aevt
    private static let automationKeyword: AEKeyword = 0x49324d41 // I2MA

    @MainActor
    static func makeAppleEvent() -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: appleEventClass,
                                           eventID: openApplication,
                                           targetDescriptor: nil,
                                           returnID: -1, transactionID: 0)
        event.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: automationKeyword)
        event.setParam(NSAppleEventDescriptor(enumCode: 0x6e6f2020),
                       forKeyword: keyAERestoreAppState) // kAENo
        return event
    }

    static func isAutomationLaunch(arguments: [String],
                                   event: NSAppleEventDescriptor?) -> Bool {
        if arguments.contains(argument) { return true }
        guard let event,
              event.eventClass == appleEventClass,
              event.eventID == openApplication,
              let marker = event.paramDescriptor(forKeyword: automationKeyword) else {
            return false
        }
        return marker.booleanValue
    }
}
