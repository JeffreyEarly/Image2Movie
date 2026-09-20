import Foundation

private struct FileAccessRegressionFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func fileAccessCheck(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw FileAccessRegressionFailure(message: message) }
}

@MainActor
func runFileAccessRegression(inDirectory directory: URL) throws {
    let fileManager = FileManager.default
    let suffix = UUID().uuidString
    let root = directory.appendingPathComponent("file-access-root-\(suffix)", isDirectory: true)
    let outside = directory.appendingPathComponent("file-access-outside-\(suffix)", isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
    defer {
        try? fileManager.removeItem(at: root)
        try? fileManager.removeItem(at: outside)
    }
    let insideFile = root.appendingPathComponent("inside.txt")
    try Data("inside".utf8).write(to: insideFile)
    try Data("outside".utf8).write(to: outside.appendingPathComponent("secret.txt"))
    try fileManager.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)

    let valid = try FileAccessManager.validatedDescendant(root: root, relativePath: "inside.txt")
    try fileAccessCheck(valid == insideFile.resolvingSymlinksInPath(), "A file under the selected folder did not resolve")
    for invalid in ["../secret.txt", "/tmp/secret.txt", "./inside.txt", "", "a//b", "escape/secret.txt"] {
        let accepted = try? FileAccessManager.validatedDescendant(root: root, relativePath: invalid)
        try fileAccessCheck(accepted == nil, "Accepted an unsafe folder path: \(invalid)")
    }
    let alias = root.appendingPathComponent("alias.txt")
    try fileManager.createSymbolicLink(at: alias, withDestinationURL: insideFile)
    let pinnedPath = try FileAccessManager.validatedDescendant(root: root, relativePath: "alias.txt")
    try fileManager.removeItem(at: alias)
    try fileManager.createSymbolicLink(at: alias, withDestinationURL: outside.appendingPathComponent("secret.txt"))
    try fileAccessCheck(pinnedPath == insideFile.resolvingSymlinksInPath() && (try? String(contentsOf: pinnedPath, encoding: .utf8)) == "inside",
                        "An already resolved input followed a retargeted symlink")

    let access = FileAccessManager.shared
    var directLease: FileAccessLease? = try access.acquire(
        reading: [insideFile, outside.appendingPathComponent("secret.txt")], writing: [])
    weak var weakDirectLease: FileAccessLease?
    weakDirectLease = directLease
    try fileAccessCheck(weakDirectLease != nil, "A multi-file acquisition returned no lease")
    directLease = nil
    try fileAccessCheck(weakDirectLease == nil, "A completed file acquisition retained its lease")

    // Security-scoped bookmark creation needs the signed app's bookmark service.
    // The path checks above still run in unsigned test hosts.
    let existing = Set(access.folders.map(\.id))
    do {
        try access.authorizeFolder(root, writable: false)
    } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == 256 {
        print("SKIP: bookmark lifecycle requires a signed sandboxed app host")
        return
    }
    guard let grant = access.folders.first(where: { !existing.contains($0.id) }) else {
        throw FileAccessRegressionFailure(message: "New folder authorization was not listed")
    }
    defer { access.removeFolder(id: grant.id) }

    try fileAccessCheck(!grant.writable && grant.name == root.lastPathComponent,
                        "Input authorization has incorrect permissions or name")
    try fileAccessCheck(UserDefaults.standard.data(forKey: "authorizedAutomationFoldersV1")?.isEmpty == false,
                        "Folder bookmark was not persisted")
    let resolvedFile = try access.resolve(folderID: grant.id, relativePath: "inside.txt", forWriting: false)
    try fileAccessCheck(resolvedFile == insideFile.resolvingSymlinksInPath(),
                        "Persisted folder failed to resolve its child")
    try fileAccessCheck((try? access.resolve(folderID: grant.id, relativePath: "inside.txt", forWriting: true)) == nil,
                        "Input-only grant allowed output writing")
    try fileAccessCheck((try? access.resolve(folderID: grant.id, relativePath: "escape/secret.txt", forWriting: false)) == nil,
                        "Authorized folder followed a symlink outside its root")

    var lease: FileAccessLease? = try access.acquire(reading: [insideFile], writing: [])
    weak var weakLease: FileAccessLease?
    weakLease = lease
    try fileAccessCheck(weakLease != nil, "Acquisition did not retain a lease")
    access.removeFolder(id: grant.id)
    try fileAccessCheck(weakLease != nil && fileManager.isReadableFile(atPath: insideFile.path),
                        "Removing a grant invalidated a live read")
    try fileAccessCheck((try? access.resolve(folderID: grant.id, relativePath: "inside.txt", forWriting: false)) == nil,
                        "Removed grant still resolved new work")
    lease = nil
    try fileAccessCheck(weakLease == nil, "Lease remained alive after its last owner released it")
}
