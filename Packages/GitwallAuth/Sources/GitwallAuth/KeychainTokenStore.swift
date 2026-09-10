import Foundation
import Security

/// Stores one ``StoredToken`` per account as a generic-password item in the data-protection Keychain.
///
/// Items are keyed by `kSecAttrService` (``service``) and `kSecAttrAccount` (the account UUID string);
/// the item data is the JSON produced by ``StoredToken/encode(_:)``. Items use
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so they are never synced or migrated to another Mac.
///
/// By default items live in the classic macOS login keychain, which works for sandboxed apps without any
/// extra entitlement or provisioning profile (the item ACL is bound to the app's code signature).
/// Pass `useDataProtectionKeychain: true` to use the iOS-style keychain instead; that variant requires a
/// provisioning profile with an application-identifier and fails with `errSecMissingEntitlement` (-34018)
/// in development builds signed without one and in plain `swift test` runners.
///
/// The class is stateless apart from ``service``, so a single instance can be shared freely.
public final class KeychainTokenStore: TokenStore, Sendable {
    /// Service name used by the Gitwall app for account tokens.
    public static let defaultService = "cz.prokopsimek.gitwall.tokens"

    /// `kSecAttrService` of every item this store owns.
    public let service: String
    public let useDataProtectionKeychain: Bool

    public init(service: String = KeychainTokenStore.defaultService, useDataProtectionKeychain: Bool = false) {
        self.service = service
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    public func token(for accountID: UUID) throws -> StoredToken? {
        var query = baseQuery(accountID: accountID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.decoding }
            do {
                return try StoredToken.decode(from: data)
            } catch {
                throw KeychainError.decoding
            }
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandled(status)
        }
    }

    public func set(_ token: StoredToken, for accountID: UUID) throws {
        let data: Data
        do {
            data = try StoredToken.encode(token)
        } catch {
            throw KeychainError.encoding
        }

        var attributes = baseQuery(accountID: accountID)
        attributes[kSecValueData] = data
        attributes[kSecAttrLabel] = "Gitwall account token"
        if useDataProtectionKeychain {
            attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }

        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            var update: [CFString: Any] = [kSecValueData: data]
            if useDataProtectionKeychain {
                update[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
            let updateStatus = SecItemUpdate(baseQuery(accountID: accountID) as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeychainError.unhandled(updateStatus) }
        default:
            throw KeychainError.unhandled(status)
        }
    }

    public func removeToken(for accountID: UUID) throws {
        try delete(baseQuery(accountID: accountID))
    }

    /// Deletes every item whose `kSecAttrService` equals ``service``.
    public func removeAll() throws {
        try delete(baseQuery(accountID: nil))
    }

    // MARK: - Private

    private func baseQuery(accountID: UUID?) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain] = true
        }
        if let accountID {
            query[kSecAttrAccount] = accountID.uuidString
        }
        return query
    }

    private func delete(_ query: [CFString: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }
}
