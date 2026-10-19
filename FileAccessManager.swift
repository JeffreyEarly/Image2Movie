import Foundation
import Combine

struct AuthorizedFolder: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let name: String
    let writable: Bool
}

private struct FolderRecord: Codable {
    var folder: AuthorizedFolder
    var bookmark: Data
    var pathHint: String
}

private enum FileAccessError: LocalizedError {
    case invalidURL
    case unavailable(String)
    case unauthorized(String)
    case invalidRelativePath
    case escapedFolder
    case readOnlyFolder
    case missingFolder

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Choose a local file or folder."
        case .unavailable(let name): "“\(name)” is unavailable. Choose it again in Automation Settings."
        case .unauthorized(let name): "Access to “\(name)” has expired. Choose it again in Automation Settings."
        case .invalidRelativePath: "Use a relative path without . or .. components."
        case .escapedFolder: "The path leaves its authorized folder."
        case .readOnlyFolder: "This folder is authorized for input only. Authorize an output folder in Automation Settings."
        case .missingFolder: "This folder authorization was removed. Authorize it again in Automation Settings."
        }
    }
}

// A lease can be retained by an image row, Undo snapshot, background load, or export.
// It has no actor-isolated teardown: the last owner may release it on a worker queue.
@objc(FileAccessLease)
final class FileAccessLease: NSObject, @unchecked Sendable {
    private let startedURLs: [URL]

    init(startedURLs: [URL]) {
        self.startedURLs = startedURLs
        super.init()
    }

    deinit {
        for url in startedURLs.reversed() {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

@MainActor
@objc(FileAccessManager)
final class FileAccessManager: NSObject, ObservableObject {
    @objc static let shared = FileAccessManager()
    @Published private(set) var folders: [AuthorizedFolder] = []

    private static let defaultsKey = "authorizedAutomationFoldersV1"
    private var records: [FolderRecord]

    private override init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? PropertyListDecoder().decode([FolderRecord].self, from: data) {
            records = saved
        } else {
            records = []
        }
        super.init()
        folders = records.map(\.folder)
    }

    // Only AutomationSettings' NSOpenPanel completion calls these grant mutations.
    func authorizeFolder(_ url: URL, writable: Bool) throws {
        guard url.isFileURL else { throw FileAccessError.invalidURL }
        let options: URL.BookmarkCreationOptions = writable
            ? [.withSecurityScope] : [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        let bookmark = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
        let folder = AuthorizedFolder(id: UUID(), name: url.lastPathComponent, writable: writable)
        records.append(FolderRecord(folder: folder, bookmark: bookmark, pathHint: url.path))
        persist()
    }

    func reauthorizeFolder(id: UUID, with url: URL) throws {
        guard let index = records.firstIndex(where: { $0.folder.id == id }) else { throw FileAccessError.missingFolder }
        guard url.isFileURL else { throw FileAccessError.invalidURL }
        let options: URL.BookmarkCreationOptions = records[index].folder.writable
            ? [.withSecurityScope] : [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        let bookmark = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
        records[index].bookmark = bookmark
        records[index].pathHint = url.path
        records[index].folder = AuthorizedFolder(id: id, name: url.lastPathComponent, writable: records[index].folder.writable)
        persist()
    }

    func removeFolder(id: UUID) {
        records.removeAll { $0.folder.id == id }
        persist()
    }

    func pathHint(folderID: UUID) -> String? {
        records.first { $0.folder.id == folderID }?.pathHint
    }

    func status(folderID: UUID) -> String {
        guard let record = records.first(where: { $0.folder.id == folderID }) else { return "Removed" }
        do {
            let root = try resolvedRoot(for: record)
            guard root.startAccessingSecurityScopedResource() else { return "Reauthorization needed" }
            defer { root.stopAccessingSecurityScopedResource() }
            return FileManager.default.fileExists(atPath: root.path) ? "Available" : "Folder unavailable"
        } catch {
            return "Reauthorization needed"
        }
    }

    func resolve(folderID: UUID, relativePath: String, forWriting: Bool) throws -> URL {
        guard let record = records.first(where: { $0.folder.id == folderID }) else { throw FileAccessError.missingFolder }
        if forWriting && !record.folder.writable { throw FileAccessError.readOnlyFolder }
        let root = try resolvedRoot(for: record)
        guard root.startAccessingSecurityScopedResource() else { throw FileAccessError.unauthorized(record.folder.name) }
        defer { root.stopAccessingSecurityScopedResource() }
        guard FileManager.default.fileExists(atPath: root.path) else { throw FileAccessError.unavailable(record.folder.name) }
        return try Self.validatedDescendant(root: root, relativePath: relativePath)
    }

    func rootURL(folderID: UUID) throws -> URL {
        guard let record = records.first(where: { $0.folder.id == folderID }) else { throw FileAccessError.missingFolder }
        let root = try resolvedRoot(for: record)
        guard root.startAccessingSecurityScopedResource() else { throw FileAccessError.unauthorized(record.folder.name) }
        defer { root.stopAccessingSecurityScopedResource() }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FileAccessError.unavailable(record.folder.name)
        }
        return root
    }

    // Pure path validation also makes it possible to test traversal without a bookmark agent.
    static func validatedDescendant(root: URL, relativePath: String) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard root.isFileURL, !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") }) else {
            throw FileAccessError.invalidRelativePath
        }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let target = components.reduce(root) { $0.appendingPathComponent(String($1)) }
        let canonicalTarget = target.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalTarget.path.hasPrefix(canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/") else {
            throw FileAccessError.escapedFolder
        }
        return canonicalTarget
    }

    func acquire(reading: [URL], writing: [URL]) throws -> FileAccessLease {
        var started: [URL] = []
        do {
            for url in reading { try activate(url, writing: false, into: &started) }
            for url in writing { try activate(url, writing: true, into: &started) }
            return FileAccessLease(startedURLs: started)
        } catch {
            for url in started.reversed() { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    @objc(leaseForReadingURLs:error:)
    func leaseForReadingURLs(_ urls: [URL]) throws -> FileAccessLease {
        try acquire(reading: urls, writing: [])
    }

    @objc(leaseForWritingURLs:error:)
    func leaseForWritingURLs(_ urls: [URL]) throws -> FileAccessLease {
        try acquire(reading: [], writing: urls)
    }

    private func activate(_ url: URL, writing: Bool, into started: inout [URL]) throws {
        guard url.isFileURL else { throw FileAccessError.invalidURL }
        if url.startAccessingSecurityScopedResource() {
            started.append(url)
            return
        }
        var candidateError: Error?
        for record in records where !writing || record.folder.writable {
            // A broken unrelated bookmark cannot deny an explicit GUI selection.
            guard let root = try? resolvedRoot(for: record) else { continue }
            guard url.standardizedFileURL == root.standardizedFileURL ||
                    isDescendant(url.standardizedFileURL, of: root.standardizedFileURL) else { continue }
            guard root.startAccessingSecurityScopedResource() else {
                candidateError = FileAccessError.unauthorized(record.folder.name)
                continue
            }
            let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
            let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
            guard canonicalURL == canonicalRoot || isDescendant(canonicalURL, of: canonicalRoot) else {
                root.stopAccessingSecurityScopedResource()
                candidateError = FileAccessError.escapedFolder
                continue
            }
            started.append(root)
            return
        }
        if let candidateError { throw candidateError }
        // Container files and non-sandboxed regression fixtures need no scope token.
        let path = url.path
        let accessible = writing
            ? FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
            : FileManager.default.isReadableFile(atPath: path)
        guard accessible else { throw FileAccessError.unauthorized(url.lastPathComponent) }
    }

    private func resolvedRoot(for record: FolderRecord) throws -> URL {
        var stale = false
        let root: URL
        do {
            root = try URL(resolvingBookmarkData: record.bookmark,
                           options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            throw FileAccessError.unauthorized(record.folder.name)
        }
        if stale, root.startAccessingSecurityScopedResource() {
            defer { root.stopAccessingSecurityScopedResource() }
            let options: URL.BookmarkCreationOptions = record.folder.writable
                ? [.withSecurityScope] : [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
            if let refreshed = try? root.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil),
               let index = records.firstIndex(where: { $0.folder.id == record.folder.id }) {
                records[index].bookmark = refreshed
                records[index].pathHint = root.path
                persist()
            }
        }
        return root
    }

    private func isDescendant(_ target: URL, of root: URL) -> Bool {
        target.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
    }

    private func persist() {
        if let data = try? PropertyListEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        let updated = records.map(\.folder)
        if folders != updated { folders = updated }
    }
}
