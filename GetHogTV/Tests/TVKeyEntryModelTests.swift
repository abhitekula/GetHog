import Foundation
import GetHogKit
import Testing
@testable import GetHog

/// Pins what key entry will and will not send.
///
/// Worth pinning on this platform specifically: a key typed with a remote is
/// entered a character at a time from a grid, which is exactly the input
/// method most likely to produce a leading space or an unfinished URL. The
/// Connect button's enablement is the only thing between that and a request
/// that fails with something reading like a network error.
@Suite("TV key entry")
@MainActor
struct TVKeyEntryModelTests {

    @Test("a key of nothing but whitespace cannot connect")
    func whitespaceOnlyKeyIsRefused() {
        let model = TVKeyEntryModel()
        model.key = "   \n\t "
        #expect(model.trimmedKey.isEmpty)
        #expect(!model.canConnect)
    }

    @Test("an empty form cannot connect")
    func emptyKeyIsRefused() {
        #expect(!TVKeyEntryModel().canConnect)
    }

    @Test("trimming matches what the auth provider itself does")
    func trimmingMatchesTheAuthProvider() {
        let model = TVKeyEntryModel()
        model.key = "  phx_example  \n"
        // `PersonalKeyAuthProvider.init` trims on `.whitespacesAndNewlines`
        // before the key ever reaches an `Authorization` header — and
        // `StoredCredential` deliberately does not, so it keeps what was
        // typed. This screen has to agree with the provider, not the store: if
        // it trimmed differently the two would disagree about what "empty"
        // means, and a key of three spaces would enable Connect and then
        // authenticate as the empty string.
        let provider = PersonalKeyAuthProvider(key: model.key, region: .usCloud)
        #expect(model.trimmedKey == provider.key)
        #expect(model.trimmedKey == "phx_example")
    }

    @Test("the EU choice resolves to EU Cloud, not the default")
    func euChoiceResolves() {
        let model = TVKeyEntryModel()
        model.region = .euCloud
        #expect(model.resolvedRegion() == .euCloud)
    }

    @Test("the US choice resolves to US Cloud")
    func usChoiceResolves() {
        #expect(TVKeyEntryModel().resolvedRegion() == .usCloud)
    }

    @Test("a self-hosted address with no host resolves to no region")
    func garbageSelfHostedURLResolvesNothing() {
        let model = TVKeyEntryModel()
        model.key = "phx_example"
        model.region = .selfHosted

        // `URL(string:)` accepts every one of these. A bare word yields a
        // relative URL with no host and no scheme, which would reach the client
        // as a base and fail at request time looking like the network's fault.
        for typo in ["", "   ", "posthog", "not a url at all"] {
            model.selfHostedHost = typo
            #expect(model.resolvedRegion() == nil, "‘\(typo)’ should not resolve")
            #expect(!model.canConnect, "‘\(typo)’ should not enable Connect")
        }
    }

    @Test("a complete self-hosted address resolves and enables Connect")
    func validSelfHostedURLResolves() {
        let model = TVKeyEntryModel()
        model.key = "phx_example"
        model.region = .selfHosted
        model.selfHostedHost = "  https://posthog.example.com  "
        #expect(model.resolvedRegion() == .selfHosted(URL(string: "https://posthog.example.com")!))
        #expect(model.canConnect)
    }

    @Test("a resolvable region is not enough without a key")
    func regionAloneCannotConnect() {
        let model = TVKeyEntryModel()
        model.region = .euCloud
        #expect(model.resolvedRegion() != nil)
        #expect(!model.canConnect)
    }

    @Test("the footnote names where the key rests and does not claim it syncs")
    func storageFootnoteIsHonest() {
        // The kit stores this platform's credential under an
        // after-first-unlock class, because an Apple TV has no lock screen to
        // unlock interactively. The wording has to match, and it must not
        // repeat the phone's "marked device-only… Face ID" promise.
        let text = TVKeyEntryView.storageFootnote
        #expect(text.contains("Keychain"))
        #expect(text.contains("after the first unlock"))
        #expect(text.contains("never synced"))
        #expect(!text.contains("Face ID"))
    }
}
