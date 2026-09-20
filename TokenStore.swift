import Foundation
import Security

/// Removes credentials created by the retired HTTP MCP server.
enum TokenStore {
    private static let service = "com.jeffreyearly.Image2Movie.mcp"
    private static let account = "local-bearer-token"

    /// Deletes only the old credential, without reading it or touching other items.
    static func removeLegacyCredentials() throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.keychain(status)
        }
    }
}

enum TokenStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            "Could not remove the retired MCP credential from Keychain (\(status))."
        }
    }
}
