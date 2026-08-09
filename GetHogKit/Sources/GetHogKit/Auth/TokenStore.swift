import Foundation
import Security

public struct StoredCredential: Sendable, Codable, Equatable {
    public let key: String
    public let region: PostHogRegion
    public var projectID: Int?
    /// A non-secret epoch binding snapshot-backed actions to this exact saved
    /// credential. Optional for payloads written by older app versions; the app
    /// migrates those only after the key has authenticated successfully.
    public let authSessionID: UUID?

    public init(
        key: String,
        region: PostHogRegion,
        projectID: Int? = nil,
        authSessionID: UUID? = nil
    ) {
        self.key = key
        self.region = region
        self.projectID = projectID
        self.authSessionID = authSessionID
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

    /// How readable the stored credential is, and when.
    ///
    /// `…WhenUnlockedThisDeviceOnly` is the right answer on a device somebody
    /// unlocks: the key is readable only while the screen is, and it never
    /// leaves this hardware. An Apple TV has neither half of that premise —
    /// there is no lock screen to unlock and no device-owner authentication to
    /// unlock it with — so a credential filed under that class would be
    /// unreadable to the app that wrote it. `…AfterFirstUnlockThisDeviceOnly`
    /// is the platform's equivalent: still device-only, still never synced,
    /// readable once the device has booted.
    ///
    /// **The executed test pins the running platform's value only.** The kit
    /// has no tvOS test host, so the tvOS branch is a compile-time rule and
    /// nothing here can execute it — a test asserting otherwise would be
    /// asserting the branch it was itself compiled into.
    static var accessibility: CFString {
        #if os(tvOS)
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #else
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #endif
    }

    public func save(_ credential: StoredCredential) throws {
        let data = try JSONEncoder().encode(credential)

        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: Self.accessibility,
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
