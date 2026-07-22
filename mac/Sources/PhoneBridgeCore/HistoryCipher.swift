import Foundation
import CryptoKit
import Security

// Encrypts the notification history blob at rest. Injected into
// NotificationHistory so the on-disk logic stays unit-testable: tests use a
// plaintext cipher, the app uses the Keychain-backed one.
public protocol HistoryCipher {
    func seal(_ plaintext: Data) throws -> Data
    func open(_ ciphertext: Data) throws -> Data
}

// Identity cipher for tests and explicitly memory-only history instances.
public struct PlaintextHistoryCipher: HistoryCipher {
    public init() {}
    public func seal(_ plaintext: Data) throws -> Data { plaintext }
    public func open(_ ciphertext: Data) throws -> Data { ciphertext }
}

// AES-GCM with a 256-bit key held in the login Keychain, so a copy of
// history.json alone is useless to same-user malware that cannot reach the
// Keychain item.
public struct KeychainHistoryCipher: HistoryCipher {
    // Security/CSCommon.h: kSecCodeSignatureAdhoc. Swift's Security overlay
    // does not currently expose that C enum case.
    private static let adHocSignatureFlag: UInt32 = 0x0002
    private let key: SymmetricKey

    // Ad-hoc signatures have a CDHash-only designated requirement that changes
    // on every local rebuild. Existing Keychain ACLs then prompt again, and a
    // synchronous prompt here blocks the entire menu-bar app before its server
    // can bind. Persisted history is optional, so ad-hoc/unknown signatures use
    // memory-only history; a stable developer-signed build keeps encryption.
    public static var shouldAttemptPersistenceForCurrentProcess: Bool {
        var dynamicCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &dynamicCode) == errSecSuccess,
              let dynamicCode else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamicCode, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let signingFlags = dictionary[kSecCodeInfoFlags as String] as? NSNumber else {
            return false
        }
        return permitsPersistence(signingFlags: signingFlags.uint32Value)
    }

    internal static func permitsPersistence(signingFlags: UInt32?) -> Bool {
        guard let signingFlags else { return false }
        return signingFlags & adHocSignatureFlag == 0
    }

    public init(account: String = "history-encryption-key",
                service: String = "com.piyush.phonebridge") throws {
        self.key = try KeychainHistoryCipher.loadOrCreateKey(account: account, service: service)
    }

    public func seal(_ plaintext: Data) throws -> Data {
        try AES.GCM.seal(plaintext, using: key).combined ?? Data()
    }

    public func open(_ ciphertext: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
    }

    private static func loadOrCreateKey(account: String, service: String) throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            // History persistence is optional. An ad-hoc development rebuild
            // can invalidate a Keychain item's code-signing ACL; never let an
            // authorization dialog block AppState.init() and prevent the
            // notification server from starting. The caller falls back to
            // memory-only history on any read error.
            // Raw value of kSecUseAuthenticationUIFail. The replacement
            // LAContext.interactionNotAllowed does not suppress authorization
            // for legacy login-Keychain ACLs, which this app may already have.
            kSecUseAuthenticationUI as String: "u_AuthUIF",
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess {
            guard let data = item as? Data, data.count == 32 else {
                throw KeychainError.invalidStoredKey
            }
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else { throw KeychainError.readFailed(status) }

        var raw = Data(count: 32)
        let generated = raw.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard generated == errSecSuccess else { throw KeychainError.randomFailed }

        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: raw,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return SymmetricKey(data: raw)
        }
        if addStatus == errSecDuplicateItem {
            // Another process won the creation race. Use the key that actually
            // reached Keychain, never this process's unpersisted bytes.
            var storedItem: CFTypeRef?
            let rereadStatus = SecItemCopyMatching(query as CFDictionary, &storedItem)
            guard rereadStatus == errSecSuccess else {
                throw KeychainError.readFailed(rereadStatus)
            }
            guard let stored = storedItem as? Data, stored.count == 32 else {
                throw KeychainError.invalidStoredKey
            }
            return SymmetricKey(data: stored)
        }
        throw KeychainError.storeFailed(addStatus)
    }

    enum KeychainError: Error {
        case randomFailed
        case invalidStoredKey
        case readFailed(OSStatus)
        case storeFailed(OSStatus)
    }
}
