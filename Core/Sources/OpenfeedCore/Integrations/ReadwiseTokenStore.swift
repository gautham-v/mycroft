import Foundation
import Security
import Synchronization

/// Where the Readwise token lives. The live store is the Keychain; tests use `InMemoryReadwiseTokenStore`.
public protocol ReadwiseTokenStore: Sendable {
    func readToken() throws -> String?
    /// nil deletes.
    func writeToken(_ token: String?) throws
}

/// Generic-password Keychain item (service "com.gauthamv.openfeed", account "readwise_token").
/// Uses the data-protection keychain where the build is entitled to it and falls back to the
/// file-based keychain on macOS when it is not (ad-hoc signed builds get errSecMissingEntitlement).
public struct KeychainReadwiseTokenStore: ReadwiseTokenStore {
    public let service: String
    public let account: String

    public init(service: String = "com.gauthamv.openfeed", account: String = "readwise_token") {
        self.service = service
        self.account = account
    }

    public func readToken() throws -> String? {
        try withFallback { dataProtection in
            var q = baseQuery(dataProtection: dataProtection)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &out)
            guard status == errSecSuccess else { return (status, nil) }
            guard let data = out as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty else {
                return (errSecSuccess, nil)
            }
            return (errSecSuccess, s)
        }
    }

    public func writeToken(_ token: String?) throws {
        guard let token, !token.isEmpty else {
            _ = try withFallback { dataProtection -> (OSStatus, String?) in
                (SecItemDelete(baseQuery(dataProtection: dataProtection) as CFDictionary), nil)
            }
            return
        }
        let data = Data(token.utf8)
        _ = try withFallback { dataProtection -> (OSStatus, String?) in
            let q = baseQuery(dataProtection: dataProtection)
            let update: [String: Any] = [kSecValueData as String: data]
            var status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                var add = q
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                status = SecItemAdd(add as CFDictionary, nil)
            }
            return (status, nil)
        }
    }

    private func baseQuery(dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    /// Runs `op` against the data-protection keychain, retrying against the legacy keychain on macOS
    /// when the process lacks the entitlement (writes fail with errSecMissingEntitlement; reads just
    /// report errSecItemNotFound). Item-not-found is not an error (returns nil).
    private func withFallback(_ op: (Bool) -> (OSStatus, String?)) throws -> String? {
        var (status, value) = op(true)
        #if os(macOS)
        if status == errSecMissingEntitlement || status == errSecItemNotFound {
            (status, value) = op(false)
        }
        #endif
        if status == errSecSuccess || status == errSecItemNotFound { return value }
        throw IntegrationError.keychain(status)
    }
}

/// Process-local token store (tests and previews).
public final class InMemoryReadwiseTokenStore: ReadwiseTokenStore {
    private let token: Mutex<String?>

    public init(_ token: String? = nil) {
        self.token = Mutex(token)
    }

    public func readToken() throws -> String? { token.withLock { $0 } }

    public func writeToken(_ token: String?) throws {
        self.token.withLock { $0 = (token?.isEmpty ?? true) ? nil : token }
    }
}
