import AppKit
import Darwin

/// A signed fixture app exercised by the production bridge. No user defaults,
/// folder grants, export data, or Codex settings are read or changed.
@MainActor
private final class LaunchProofDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let appURL = Bundle.main.bundleURL
        let scenario = Bundle.main.object(forInfoDictionaryKey: "LaunchProofScenario") as? String ?? "normal"
        let event = NSAppleEventManager.shared().currentAppleEvent
        let report: [String: Any] = [
            "pid": getpid(),
            "quiet": MCPLaunchRequest.isAutomationLaunch(arguments: CommandLine.arguments, event: event),

            "restorationDisabled": event?.paramDescriptor(forKeyword: AEKeyword(keyAERestoreAppState))?.enumCodeValue == DescType(kAENo)
        ]
        let initialReport = try! JSONSerialization.data(withJSONObject: report)
        guard scenario != "disabled" else { return }
        DispatchQueue.global().async {
            do {
                if scenario == "slow-start" { Thread.sleep(forTimeInterval: 12) }
                let path = try MCPPeerIdentity.socketURL(for: appURL).path
                let listener = socket(AF_UNIX, SOCK_STREAM, 0)
                guard listener >= 0 else { throw MCPUnixSocket.SocketError.io(errno) }
                defer { MCPUnixSocket.close(listener); unlink(path) }
                unlink(path)
                guard try MCPUnixSocket.withAddress(path, { Darwin.bind(listener, $0, $1) }) == 0,
                      listen(listener, 16) == 0 else { throw MCPUnixSocket.SocketError.io(errno) }
                while true {
                    let peer = accept(listener, nil, nil)
                    guard peer >= 0 else { throw MCPUnixSocket.SocketError.io(errno) }
                    DispatchQueue.global().async {
                        defer { MCPUnixSocket.close(peer) }
                        do {
                            try MCPPeerIdentity.validatePeer(on: peer,
                                identifier: MCPPeerIdentity.bridgeIdentifier,
                                expectedCodeURL: MCPPeerIdentity.bridgeExecutableURL(in: appURL))
                            if scenario == "slow-handshake" { Thread.sleep(forTimeInterval: 12) }
                            let hello = scenario == "wrong-version" ? Data("I2M-MCP/999\n".utf8) : MCPUnixSocket.hello
                            try MCPUnixSocket.writeAll(hello, to: peer)
                            guard try MCPUnixSocket.readLine(from: peer, limit: 32) == MCPUnixSocket.hello.dropLast() else { return }
                            while true {
                                _ = try MCPUnixSocket.readLine(from: peer, limit: 256)
                                let response = DispatchQueue.main.sync {
                                    var live = try! JSONSerialization.jsonObject(with: initialReport) as! [String: Any]
                                    live["active"] = NSApp.isActive
                                    return try! JSONSerialization.data(withJSONObject: live) + Data([10])
                                }
                                try MCPUnixSocket.writeAll(response, to: peer)
                            }
                        } catch { /* Rejected/terminated clients are part of the fixture checks. */ }
                    }
                }
            } catch { fputs("launch fixture: \(error)\n", stderr); exit(2) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        false
    }
}

@main
private struct BridgeLaunchProof {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = LaunchProofDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
