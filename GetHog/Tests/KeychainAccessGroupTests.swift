import Foundation
import GetHogKit
import Security
import Testing

@testable import GetHog

/// Where the PostHog credential actually lives.
///
/// This exists because the answer was written down wrongly once and the wrong
/// version was plausible. `IntentDependencies.keychainAccessGroup` is `nil`, and
/// nil is easy to read as "the app's own private group" — which would mean an
/// extension, whose `application-identifier` is a *different* string, could never
/// find the item the app wrote, and an intent that silently cannot authenticate
/// is indistinguishable from one whose data is missing.
///
/// It is not what nil means here. The default access group is the **first entry
/// of the `keychain-access-groups` entitlement**, and only falls back to
/// `application-identifier` when that entitlement is absent. Both this app and
/// `GetHogWidgets` declare exactly one, and the same one.
///
/// Asserted rather than asserted-in-a-comment because the failure it guards is
/// invisible and destructive: adding a second group *ahead* of the shared one in
/// the entitlement would move where new credentials are written, and every
/// existing user would be silently signed out with a keychain item still sitting
/// in the old group. This suite is what turns that into a red build.
///
/// These tests run in the app's process — a unit-test bundle is injected into
/// `GetHog.app`, so the entitlements in force are the app's own.
@Suite("Keychain access group", .serialized)
struct KeychainAccessGroupTests {

    /// The group every keychain item in this app is expected to land in, minus
    /// the team prefix.
    ///
    /// Compared by suffix on purpose. The literal in `GetHog.entitlements` is
    /// `$(AppIdentifierPrefix)app.gethog.shared`, and Xcode substitutes a
    /// prefix that belongs to whoever is signing — `<TeamID>.` on the machine
    /// this was measured on. Pinning the whole string would fail for every other
    /// developer while telling them nothing.
    private let sharedSuffix = ".app.gethog.shared"

    private func probeQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.gethog.tests.accessgroup",
            kSecAttrAccount as String: account,
        ]
    }

    /// Reads back the group an item was filed under, having named none.
    private func groupOfItemWrittenWithoutOne(account: String) throws -> String? {
        let base = probeQuery(account: account)
        SecItemDelete(base as CFDictionary)
        defer { SecItemDelete(base as CFDictionary) }

        var insert = base
        insert[kSecValueData as String] = Data("probe".utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(insert as CFDictionary, nil)
        #expect(added == errSecSuccess, "SecItemAdd failed: \(added)")

        var query = base
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let read = SecItemCopyMatching(query as CFDictionary, &item)
        #expect(read == errSecSuccess, "SecItemCopyMatching failed: \(read)")

        return (item as? [String: Any])?[kSecAttrAccessGroup as String] as? String
    }

    /// **The measurement the rest of this rests on.** An item written with no
    /// `kSecAttrAccessGroup` at all is filed under the shared group, not under
    /// the app identifier — measured as `<TeamID>.app.gethog.shared`, where
    /// `<TeamID>.app.gethog.GetHog` is what the app-identifier answer
    /// would have looked like.
    @Test("an item written with no access group lands in the shared group")
    func defaultIsTheSharedGroup() throws {
        let group = try groupOfItemWrittenWithoutOne(account: "default-group")
        #expect(group?.hasSuffix(sharedSuffix) == true, "unexpected default access group: \(group ?? "<nil>")")
    }

    /// Which is why the intents' access group is nil, and why nil is a decision
    /// rather than a gap. Naming the group explicitly would select the group the
    /// empty query already selects; it would also have to be spelled with a team
    /// prefix Swift has no way to know.
    @Test("the intents read the same group the app writes")
    func intentsUseTheDefault() throws {
        #expect(IntentDependencies.keychainAccessGroup == nil)

        let group = try groupOfItemWrittenWithoutOne(account: "intents-group")
        #expect(group?.hasSuffix(sharedSuffix) == true)
    }

    /// End to end through the type that actually stores the credential, because
    /// the two halves above are about `SecItem` and this is about
    /// `KeychainTokenStore` — including the accessibility class, which is the
    /// other half of "where does this live". `WhenUnlockedThisDeviceOnly` and no
    /// iCloud sync: a personal API key is a bearer credential for the user's
    /// whole PostHog account.
    @Test("the credential store round-trips into the shared group")
    func storeWritesToTheSharedGroup() throws {
        let store = KeychainTokenStore(
            service: "app.gethog.tests.credential",
            accessGroup: IntentDependencies.keychainAccessGroup
        )
        defer { try? store.clear() }

        try store.clear()
        #expect(try store.load() == nil)

        let credential = StoredCredential(key: "phx_test", region: .usCloud, projectID: 1)
        try store.save(credential)
        #expect(try store.load() == credential)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.gethog.tests.credential",
            kSecAttrAccount as String: "posthog-credential",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        query[kSecReturnData as String] = false
        var item: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess)
        let attributes = item as? [String: Any]

        let group = attributes?[kSecAttrAccessGroup as String] as? String
        #expect(group?.hasSuffix(sharedSuffix) == true, "credential filed under \(group ?? "<nil>")")

        let accessible = attributes?[kSecAttrAccessible as String] as? String
        #expect(accessible == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String))
        // Absent, not false: the item was never marked synchronisable, so the
        // attribute simply isn't there.
        #expect(attributes?[kSecAttrSynchronizable as String] as? Bool != true)
    }

    /// The app and the widget extension must declare the *same* first group, or
    /// the paragraph above stops being true for one of them. Read out of the
    /// source entitlements because the built `.xcent` differs per signing
    /// identity, and this is the file a change would land in.
    @Test("both targets declare the same single keychain access group")
    func entitlementsAgree() throws {
        func groups(_ path: String) throws -> [String] {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()  // GetHog
                .appending(path: "Support/\(path)")
            let data = try Data(contentsOf: url)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            return (plist as? [String: Any])?["keychain-access-groups"] as? [String] ?? []
        }

        let app = try groups("GetHog.entitlements")
        let widgets = try groups("GetHogWidgets.entitlements")

        #expect(app == ["$(AppIdentifierPrefix)app.gethog.shared"])
        #expect(app == widgets)
    }
}
