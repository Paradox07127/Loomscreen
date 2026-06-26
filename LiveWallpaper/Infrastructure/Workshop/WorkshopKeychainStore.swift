#if !LITE_BUILD && DIRECT_DISTRIBUTION
import Foundation
import Security

/// Keychain slot for the Steam Web API key is `WhenUnlockedThisDeviceOnly` +
/// `Synchronizable=false` — explicitly **no iCloud sync**.
actor WorkshopKeychainStore {

    private static let service = "com.loomscreen.livewallpaper.workshop.webapikey"
    private static let account = "default"
    private static let keyPattern = #"^[A-Fa-f0-9]{32}$"#

    enum WorkshopKeychainError: Error, Equatable, Sendable {
        case osStatus(OSStatus)
        case malformedData
        case keyNotFound
        case duplicate
    }

    func setWebAPIKey(_ key: String) async throws {
        guard Self.isValidAPIKeyShape(key),
              let data = key.data(using: .utf8) else {
            throw WorkshopKeychainError.malformedData
        }

        var addQuery = Self.baseQuery()
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        addQuery[kSecValueData as String] = data

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                kSecAttrSynchronizable as String: kCFBooleanFalse as Any
            ]
            let updateStatus = SecItemUpdate(Self.baseQuery() as CFDictionary, updateAttributes as CFDictionary)
            switch updateStatus {
            case errSecSuccess: return
            case errSecItemNotFound: throw WorkshopKeychainError.keyNotFound
            case errSecDuplicateItem: throw WorkshopKeychainError.duplicate
            default: throw WorkshopKeychainError.osStatus(updateStatus)
            }
        default:
            throw WorkshopKeychainError.osStatus(status)
        }
    }

    func loadWebAPIKey() async throws -> String? {
        var query = Self.baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let key = String(data: data, encoding: .utf8),
                  Self.isValidAPIKeyShape(key) else {
                throw WorkshopKeychainError.malformedData
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw WorkshopKeychainError.osStatus(status)
        }
    }

    func deleteWebAPIKey() async throws {
        let status = SecItemDelete(Self.baseQuery() as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw WorkshopKeychainError.osStatus(status)
        }
    }

    func hasWebAPIKey() async -> Bool {
        var query = Self.baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }

    private static func isValidAPIKeyShape(_ key: String) -> Bool {
        key.range(of: keyPattern, options: [.regularExpression, .anchored]) != nil
    }
}
#endif
