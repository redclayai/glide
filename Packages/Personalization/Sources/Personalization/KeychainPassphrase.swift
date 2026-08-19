import Foundation
import Security

/// Manages the random passphrase used to encrypt the writing-history database (SQLCipher).
///
/// The passphrase never ships with the app and is never written to disk in the clear: it is a
/// 256-bit random value generated once and kept in the macOS Keychain (generic password,
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so it stays on this device and survives
/// reboots without iCloud sync). Deleting it makes the encrypted database permanently unreadable —
/// which is exactly what the "Clear all personal data" action relies on as a backstop. See ADR-023.
public enum KeychainPassphrase {
    /// Service identifier namespacing KeyType's keychain items.
    public static let service = "com.pattonium.KeyType.history"
    /// Account key for the database passphrase item.
    public static let account = "db-passphrase"

    public enum KeychainError: Error, CustomStringConvertible {
        case randomGenerationFailed
        case unexpectedStatus(OSStatus)
        case malformedItem

        public var description: String {
            switch self {
            case .randomGenerationFailed: return "Could not generate a random passphrase"
            case let .unexpectedStatus(status): return "Keychain error (OSStatus \(status))"
            case .malformedItem: return "Keychain item was not in the expected format"
            }
        }
    }

    /// Returns the existing passphrase, generating and persisting a fresh random one on first use.
    /// Idempotent: subsequent calls return the same value so the database opens consistently.
    public static func loadOrCreate(
        service: String = service,
        account: String = account
    ) throws -> String {
        if let existing = try load(service: service, account: account) {
            return existing
        }
        let passphrase = try generate()
        try store(passphrase, service: service, account: account)
        return passphrase
    }

    /// Reads the stored passphrase, or `nil` when none has been created yet.
    public static func load(
        service: String = service,
        account: String = account
    ) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let passphrase = String(data: data, encoding: .utf8) else {
                throw KeychainError.malformedItem
            }
            return passphrase
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Removes the passphrase from the keychain. Safe to call when nothing is stored.
    public static func delete(
        service: String = service,
        account: String = account
    ) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Helpers

    private static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard result == errSecSuccess else { throw KeychainError.randomGenerationFailed }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func store(
        _ passphrase: String,
        service: String,
        account: String
    ) throws {
        guard let data = passphrase.data(using: .utf8) else {
            throw KeychainError.malformedItem
        }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
