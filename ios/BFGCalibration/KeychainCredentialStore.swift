import Foundation
import Security
import BFGCore

/// Persistent pairing credentials, backed by the iOS Keychain.
///
/// This is where the iOS design deliberately diverges from Android, and it is
/// an improvement rather than a workaround.
///
/// Android kept keys in process memory only (`PairingCredentialStore`), because
/// it could not write them anywhere durable without inventing its own storage.
/// To get "pair once, reconnect without a button press" it instead read the
/// pre-existing key out of the official Ninebot app's database — via root, or
/// via a virtualised container running the Ninebot APK.
///
/// iOS has neither of those. It does have the Keychain. Since the app
/// negotiates and owns the password it writes to the vehicle during pairing,
/// it can simply store its own key. No other app is involved, no root, no
/// virtualisation, and the key survives app restarts.
///
/// Keys are stored `WhenUnlockedThisDeviceOnly` so they are never copied into
/// an iCloud or iTunes backup.
public final class KeychainCredentialStore: CredentialStore {
    public static let shared = KeychainCredentialStore()

    private let service = "com.bfgtools.calibration.pairing"
    private let account = "vehicle-password-v1"

    private init() { }

    /// Stores the 32-byte pairing password against the vehicle's serial.
    ///
    /// Keyed by serial rather than MAC: iOS never exposes a MAC address, and
    /// the 14-character serial is what the vehicle advertises over BLE.
    @discardableResult
    public func save(serial: String, password32: [UInt8]) -> Bool {
        guard password32.count == 32 else { return false }
        let key = compositeKey(serial)
        let data = Data(password32)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        _ = SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// Returns the stored 32-byte password, or nil when the vehicle has never
    /// been paired by this app.
    public func load(serial: String) -> [UInt8]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: compositeKey(serial),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              data.count == 32
        else { return nil }
        return [UInt8](data)
    }

    public func delete(serial: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: compositeKey(serial)
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    public func deleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    private func compositeKey(_ serial: String) -> String {
        "\(account).\(serial.uppercased())"
    }
}
