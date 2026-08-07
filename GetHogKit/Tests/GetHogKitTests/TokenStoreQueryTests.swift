import Foundation
import Security
import Testing

@testable import GetHogKit

/// What `KeychainTokenStore` asks `SecItem*` for, asserted without a keychain.
///
/// Load, save and clear all build their queries from `baseQuery`, so the one
/// dictionary is the whole contract this suite has to hold.
@Suite("Keychain token store query")
struct TokenStoreQueryTests {

    @Test("every query opts into the data-protection keychain")
    func dataProtectionKeychain() {
        let query = KeychainTokenStore().baseQuery
        // A no-op on iOS; on macOS the difference between the modern keychain
        // and the legacy login keychain, which prompts for a password and
        // cannot honor access groups.
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
    }

    @Test("opting in disturbs nothing else in the query")
    func queryShape() {
        let query = KeychainTokenStore(service: "app.gethog.tests.query").baseQuery
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "app.gethog.tests.query")
        #expect(query[kSecAttrAccount as String] as? String == "posthog-credential")
        // Absent, not empty: an access group nobody named must stay unnamed so
        // the entitlement's first entry keeps deciding where items land.
        #expect(query[kSecAttrAccessGroup as String] == nil)
    }

    @Test("an injected access group still reaches the query")
    func accessGroup() {
        let query = KeychainTokenStore(accessGroup: "app.gethog.tests.shared").baseQuery
        #expect(query[kSecAttrAccessGroup as String] as? String == "app.gethog.tests.shared")
    }

    @Test("the stored credential never leaves the device it was entered on")
    func accessibilityIsDeviceOnly() {
        // **This executes the running platform's branch and no other.** The
        // package's test hosts are macOS and iOS; there is none for tvOS, so
        // that branch is a compile-time rule and an assertion naming its value
        // here would be asserting the branch it was itself compiled into.
        //
        // What every branch has to agree on is the `ThisDeviceOnly` half: a
        // personal API key is not a thing to hand another device through an
        // iCloud Keychain restore, and `SettingsRoot`'s footer promises on
        // every platform that the key is "never synced or uploaded".
        //
        // Asserted against the constants rather than against the string: these
        // are opaque short codes ("aku", "cku"), so no spelling of them reads
        // as its own meaning and a suffix check would be checking nothing.
        let accessible = KeychainTokenStore.accessibility as String
        let deviceOnly = [
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
        ]
        let syncable = [
            kSecAttrAccessibleWhenUnlocked as String,
            kSecAttrAccessibleAfterFirstUnlock as String,
        ]
        #expect(deviceOnly.contains(accessible))
        #expect(!syncable.contains(accessible))

        #if os(tvOS)
        #expect(accessible == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #else
        #expect(accessible == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #endif
    }
}
