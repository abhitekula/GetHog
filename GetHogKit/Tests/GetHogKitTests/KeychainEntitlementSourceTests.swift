import Foundation
import Testing

/// Source-plist validation runs in this host package suite intentionally.
///
/// App unit tests execute inside the iOS Simulator. Reaching from that process
/// through `#filePath` to the host checkout can block indefinitely instead of
/// throwing when the host path is unavailable. The runtime keychain contracts
/// remain in `KeychainAccessGroupTests`; only the repository configuration
/// contract belongs here, where both entitlement files are ordinary host files.
@Suite("Keychain entitlement source")
struct KeychainEntitlementSourceTests {
    @Test("the app and widget declare the same single keychain access group")
    func appAndWidgetAgree() throws {
        let expected = ["$(AppIdentifierPrefix)app.gethog.shared"]
        let app = try groups(in: "GetHog.entitlements")
        let widgets = try groups(in: "GetHogWidgets.entitlements")

        #expect(app == expected)
        #expect(widgets == expected)
    }

    private func groups(in fileName: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // GetHogKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // GetHogKit
            .deletingLastPathComponent()  // repository root
            .appending(path: "GetHog/Support/\(fileName)")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return (plist as? [String: Any])?["keychain-access-groups"] as? [String] ?? []
    }
}
