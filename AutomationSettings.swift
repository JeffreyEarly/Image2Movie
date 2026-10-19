import AppKit
import SwiftUI

@MainActor
@objc(AutomationSettingsController)
final class AutomationSettingsController: NSObject {
    @objc static let shared = AutomationSettingsController()
    private var settingsWindow: NSWindow?

    @objc(showWindow:)
    func showWindow(_ sender: Any?) {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 590),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Automation Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: AutomationSettingsView())
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct AutomationSettingsView: View {
    @ObservedObject private var access = FileAccessManager.shared
    @ObservedObject private var server = MCPServerController.shared
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Automation").font(.title2).bold()
            Text("Choose folders that unattended exports may use. Input folders can be read; output folders can be read and written.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            folderSection(title: "Input folders", writable: false)
            folderSection(title: "Output folders", writable: true)

            Divider()
            HStack {
                Toggle("Allow AI tools to use Image2Movie", isOn: Binding(
                    get: { server.isEnabled },
                    set: { enabled in
                        Task {
                            await performServerAction {
                                if enabled { try await server.start() } else { await server.stop() }
                            }
                        }
                    }
                ))
                .disabled(server.isTransitioning)
                Spacer()
                Text(server.status).foregroundStyle(.secondary)
            }
            Text("Active connections: \(server.activeConnections)")
                .font(.caption).foregroundStyle(.secondary)
            Button("Copy Codex Configuration") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(server.codexConfiguration, forType: .string)
            }
            Text("This allows local tools using the bundled bridge to use your authorized folders. It does not authenticate Codex specifically.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Codex can start Image2Movie in the background when it loads its tools. Image2Movie stays running in the Dock until you quit it, including after clients disconnect, and a fresh connection can open it again after Quit. AI access and folder authorization are still required. If you move the app, copy the configuration again.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 560)
        .alert("Automation Settings", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func folderSection(title: String, writable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Authorize Folder…") { chooseFolder(replacing: nil, writable: writable) }
            }
            let entries = access.folders.filter { $0.writable == writable }
            if entries.isEmpty {
                Text("No folders authorized")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(entries) { folder in
                            HStack(spacing: 10) {
                                Image(systemName: folder.writable ? "folder.badge.plus" : "folder")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(folder.name).lineLimit(1)
                                    Text(access.pathHint(folderID: folder.id) ?? "")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(access.status(folderID: folder.id))
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Reauthorize…") { chooseFolder(replacing: folder, writable: writable) }
                                Button("Remove") { access.removeFolder(id: folder.id) }
                            }
                            .padding(.vertical, 7)
                            Divider()
                        }
                    }
                }
                .frame(height: 112)
            }
        }
    }

    private func chooseFolder(replacing folder: AuthorizedFolder?, writable: Bool) {
        let panel = NSOpenPanel()
        panel.message = writable ? "Authorize an output folder" : "Authorize an input folder"
        panel.prompt = folder == nil ? "Authorize" : "Reauthorize"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if let folder, let hint = access.pathHint(folderID: folder.id) {
            panel.directoryURL = URL(fileURLWithPath: hint, isDirectory: true)
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                if let folder {
                    try access.reauthorizeFolder(id: folder.id, with: url)
                } else {
                    try access.authorizeFolder(url, writable: writable)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performServerAction(_ action: () async throws -> Void) async {
        do { try await action() }
        catch { errorMessage = error.localizedDescription }
    }
}
