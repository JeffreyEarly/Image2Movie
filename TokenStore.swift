import Foundation
import Security

/// The MCP bearer token belongs to this app installation, not a client session.
enum TokenStore {
    private static let service = "com.jeffreyearly.Image2Movie.mcp"
    private static let account = "local-bearer-token"

    static func current() throws -> String {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query(returnData: true) as CFDictionary, &result)
        if status == errSecItemNotFound { return try rotate() }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw TokenStoreError.keychain(status)
        }
        return token
    }

    @discardableResult
    static func rotate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw TokenStoreError.random
        }
        let token = Data(bytes).base64EncodedString()
        let data = Data(token.utf8)
        let updateStatus = SecItemUpdate(query(returnData: false) as CFDictionary,
                                         [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var attributes = query(returnData: false)
            attributes[kSecValueData as String] = data
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw TokenStoreError.keychain(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw TokenStoreError.keychain(updateStatus)
        }
        return token
    }

    private static func query(returnData: Bool) -> [String: Any] {
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if returnData {
            attributes[kSecReturnData as String] = true
            attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return attributes
    }
}

enum TokenStoreError: LocalizedError {
    case keychain(OSStatus)
    case random

    var errorDescription: String? {
        switch self {
        case .keychain(let status): "Could not access the MCP token in Keychain (\(status))."
        case .random: "Could not generate a secure MCP token."
        }
    }
}
