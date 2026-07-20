import Foundation
import Security

// Stores small secrets (the pairing token and the TLS private key) so they
// live in the login Keychain rather than as plaintext files that same-user
// malware could read straight off disk.
public protocol SecretStore {
    func data(for account: String) -> Data?
    func set(_ data: Data, for account: String) throws
}

public enum SecretStoreError: Error {
    case storeFailed(OSStatus)
}

public struct KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String = "com.piyush.phonebridge") {
        self.service = service
    }

    public func data(for account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    public func set(_ data: Data, for account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            let add = base.merging(update) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SecretStoreError.storeFailed(addStatus) }
        } else if status != errSecSuccess {
            throw SecretStoreError.storeFailed(status)
        }
    }
}

// In-memory store for tests, so the suite never touches the real Keychain.
public final class InMemorySecretStore: SecretStore {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func data(for account: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storage[account]
    }

    public func set(_ data: Data, for account: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[account] = data
    }
}
