import Foundation
import Security

public struct StoredCredential: Sendable, Codable, Equatable {
    public let key: String
    public let region: PostHogRegion
    public var projectID: Int?

    public init(key: String, region: PostHogRegion, projectID: Int? = nil) {
        self.key = key
        self.region = region
        self.projectID = projectID
    }
}

public protocol CredentialStoring: Sendable {
    func load() throws -> StoredCredential?
    func save(_ credential: StoredCredential) throws
    func clear() throws
}

/// Keychain-backed credential storage.
///
/// Stored in an App Group so the widget and App Intents extensions can read it,
/// and pinned to `ThisDeviceOnly` with no iCloud sync — a personal API key is a
/// bearer credential for the user's whole PostHog account and should never leave
/// the device it was entered on.
public struct KeychainTokenStore: CredentialStoring {
    private let service: String
    private let account = "posthog-credential"
    private let accessGroup: String?

    public init(service: String = "app.gethog.credential", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    /// The dictionary every `SecItem*` call starts from — load, save and clear
    /// all derive their queries from it, so this is the one place the shape of
    /// a keychain request is decided. Internal rather than private so tests can
    /// assert that shape without talking to a real keychain.
    var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // On iOS every keychain is already the data-protection keychain and
            // this key changes nothing. On macOS it is the difference between
            // that keychain and the legacy login keychain, which prompts the
            // user for its password and cannot honor access groups — so a Mac
            // build without it would show a password sheet on first launch and
            // then file the credential where no extension could read it.
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    public func load() throws -> StoredCredential? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return try JSONDecoder().decode(StoredCredential.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    public func save(_ credential: StoredCredential) throws {
        let data = try JSONEncoder().encode(credential)

        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = baseQuery
            insert.merge(update) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    public enum KeychainError: Error, LocalizedError {
        case status(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .status(let s):
                "Keychain error \(s): \(SecCopyErrorMessageString(s, nil) as String? ?? "unknown")"
            }
        }
    }
}

/// In-memory store for tests and previews.
public final class InMemoryTokenStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: StoredCredential?

    public init(credential: StoredCredential? = nil) {
        self.credential = credential
    }

    public func load() throws -> StoredCredential? {
        lock.withLock { credential }
    }

    public func save(_ credential: StoredCredential) throws {
        lock.withLock { self.credential = credential }
    }

    public func clear() throws {
        lock.withLock { credential = nil }
    }
}
