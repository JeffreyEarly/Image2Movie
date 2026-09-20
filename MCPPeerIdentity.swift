import CryptoKit
import Darwin
import Foundation
import Security

enum MCPPeerIdentity {
    static let appIdentifier = "com.EarlyInnovations.Image2Movie"
    static let bridgeIdentifier = "com.EarlyInnovations.Image2Movie.MCPBridge"
    static let teamIdentifier = "BWNJC57N56"
    static let groupIdentifier = "BWNJC57N56.i2m"
    static let bridgeName = "image2movie-mcp"

    static func bridgeExecutableURL(in appBundleURL: URL) -> URL {
        appBundleURL.appendingPathComponent("Contents/MacOS/\(bridgeName)")
    }

    static func containingAppURL(forBridgeExecutable executableURL: URL) -> URL {
        executableURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func ownExecutableURL() throws -> URL {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            throw IdentityError.peerCode
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { throw IdentityError.peerCode }
        var path: CFURL?
        guard SecCodeCopyPath(staticCode, [], &path) == errSecSuccess,
              let path else { throw IdentityError.peerCode }
        return try canonical(path as URL)
    }

    static func canonical(_ url: URL) throws -> URL {
        guard let path = realpath(url.path, nil) else {
            throw IdentityError.invalidPath(url.path)
        }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }

    static func socketURL(for appBundleURL: URL) throws -> URL {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier) else {
            throw IdentityError.appGroupUnavailable
        }
        let appPath = try canonical(appBundleURL).path
        let digest = SHA256.hash(data: Data(appPath.utf8))
        let suffix = digest.prefix(10).map { String(format: "%02x", $0) }.joined()
        let socketURL = groupURL.appendingPathComponent("i2m-\(suffix).sock")
        guard socketURL.path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw IdentityError.socketPathTooLong
        }
        return socketURL
    }

    /// The kernel supplies this token for the connected Unix-domain peer.
    /// Neither PID strings nor handshake claims are used as authority.
    static func validatePeer(on descriptor: Int32, identifier: String,
                             expectedCodeURL: URL) throws {
        var token = audit_token_t()
        var tokenLength = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenLength) == 0,
              tokenLength == MemoryLayout<audit_token_t>.size,
              audit_token_to_euid(token) == geteuid() else {
            throw IdentityError.peerCredentials
        }

        let tokenBytes = withUnsafeBytes(of: token) { Data($0) }
        var peerCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil,
              [kSecGuestAttributeAudit: tokenBytes] as CFDictionary,
              [], &peerCode) == errSecSuccess, let peerCode else {
            throw IdentityError.peerCode
        }
        let requirementText = "anchor apple generic and identifier \"\(identifier)\" " +
            "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [],
                                             &requirement) == errSecSuccess,
              let requirement,
              SecCodeCheckValidity(peerCode, [], requirement) == errSecSuccess else {
            throw IdentityError.peerSignature
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(peerCode, [], &staticCode) == errSecSuccess,
              let staticCode else { throw IdentityError.peerCode }
        var codeURL: CFURL?
        guard SecCodeCopyPath(staticCode, [], &codeURL) == errSecSuccess,
              let codeURL,
              try canonical(codeURL as URL) == canonical(expectedCodeURL) else {
            throw IdentityError.peerInstallation
        }
    }

    enum IdentityError: LocalizedError {
        case appGroupUnavailable, socketPathTooLong, peerCredentials, peerCode
        case peerSignature, peerInstallation, invalidPath(String)

        var errorDescription: String? {
            switch self {
            case .appGroupUnavailable: "App Group container is unavailable"
            case .socketPathTooLong: "App Group socket path exceeds the system limit"
            case .peerCredentials: "The connected peer has invalid credentials"
            case .peerCode: "The connected peer's signed code could not be read"
            case .peerSignature: "The connected peer has an invalid code signature"
            case .peerInstallation: "The connected peer belongs to another app installation"
            case .invalidPath(let path): "Could not resolve path: \(path)"
            }
        }
    }
}
