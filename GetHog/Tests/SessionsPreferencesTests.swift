import Foundation
import GetHogKit
import Testing

@testable import GetHog

@MainActor
@Suite("Sessions preferences")
struct SessionsPreferencesTests {
    private func storage(_ name: String = #function) -> UserDefaults {
        let suite = "SessionsPreferencesTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("an empty store returns the authored defaults and a new store restores a write")
    func defaultsAndRoundTrip() {
        let defaults = storage()
        let scope = ProjectPreferenceScope(projectID: 1_001, region: .usCloud)
        let value = SessionsPreferences.Value(
            filterTestAccounts: true,
            playableOnly: true,
            order: .consoleErrorCount
        )

        #expect(SessionsPreferences(defaults: defaults).value(for: scope) == .init())
        SessionsPreferences(defaults: defaults).set(value, for: scope)
        #expect(SessionsPreferences(defaults: defaults).value(for: scope) == value)
    }

    @Test("two project ids on one host do not share a value")
    func separatesProjects() {
        let preferences = SessionsPreferences(defaults: storage())
        let first = ProjectPreferenceScope(projectID: 41, region: .usCloud)
        let second = ProjectPreferenceScope(projectID: 42, region: .usCloud)

        preferences.set(.init(filterTestAccounts: true), for: first)
        #expect(preferences.value(for: first).filterTestAccounts)
        #expect(!preferences.value(for: second).filterTestAccounts)
    }

    @Test("the same project id on two hosts does not share a value")
    func separatesHosts() {
        let preferences = SessionsPreferences(defaults: storage())
        let us = ProjectPreferenceScope(projectID: 7, region: .usCloud)
        let eu = ProjectPreferenceScope(projectID: 7, region: .euCloud)

        preferences.set(.init(playableOnly: true), for: us)
        #expect(preferences.value(for: us).playableOnly)
        #expect(!preferences.value(for: eu).playableOnly)
        #expect(us.storageKeyComponent != eu.storageKeyComponent)
    }

    @Test("equivalent self-hosted endpoint spellings reuse one project value")
    func normalizesEquivalentSelfHostedEndpoints() {
        let preferences = SessionsPreferences(defaults: storage())
        let withoutTrailingSlash = ProjectPreferenceScope(
            projectID: 71,
            region: .selfHosted(URL(string: "https://posthog.example.test")!)
        )
        let withTrailingSlash = ProjectPreferenceScope(
            projectID: 71,
            region: .selfHosted(URL(string: "https://posthog.example.test/")!)
        )

        preferences.set(.init(playableOnly: true), for: withoutTrailingSlash)

        #expect(withoutTrailingSlash.storageKeyComponent == withTrailingSlash.storageKeyComponent)
        #expect(preferences.value(for: withTrailingSlash).playableOnly)
    }

    @Test("self-hosted host spelling and default ports share one project value")
    func normalizesSelfHostedHostSpellingAndDefaultPorts() {
        let preferences = SessionsPreferences(defaults: storage())
        let canonical = ProjectPreferenceScope(
            projectID: 72,
            region: .selfHosted(URL(string: "https://posthog.example.test")!)
        )
        let mixedCase = ProjectPreferenceScope(
            projectID: 72,
            region: .selfHosted(URL(string: "HTTPS://POSTHOG.example.test")!)
        )
        let explicitDefaultPort = ProjectPreferenceScope(
            projectID: 72,
            region: .selfHosted(URL(string: "https://posthog.example.test:443")!)
        )

        preferences.set(.init(filterTestAccounts: true), for: canonical)

        #expect(canonical.storageKeyComponent == mixedCase.storageKeyComponent)
        #expect(canonical.storageKeyComponent == explicitDefaultPort.storageKeyComponent)
        #expect(preferences.value(for: mixedCase).filterTestAccounts)
        #expect(preferences.value(for: explicitDefaultPort).filterTestAccounts)
    }

    @Test("equivalent self-hosted endpoints are one equality and hash identity")
    func equivalentSelfHostedScopesShareIdentity() {
        let scopes = [
            "https://posthog.example.test",
            "https://posthog.example.test/",
            "HTTPS://POSTHOG.example.test",
            "https://posthog.example.test:443",
        ].map {
            ProjectPreferenceScope(
                projectID: 81,
                region: .selfHosted(URL(string: $0)!)
            )
        }

        #expect(scopes.allSatisfy { $0 == scopes[0] })
        #expect(Set(scopes).count == 1)
    }

    @Test("a cloud endpoint and its exact self-hosted URL are one scope identity")
    func cloudAndEquivalentSelfHostedScopesShareIdentity() {
        let cloud = ProjectPreferenceScope(projectID: 82, region: .usCloud)
        let equivalent = ProjectPreferenceScope(
            projectID: 82,
            region: .selfHosted(PostHogRegion.usCloud.host)
        )

        #expect(cloud == equivalent)
        #expect(Set([cloud, equivalent]).count == 1)
    }

    @Test("canonical identity retains project path and non-default-port boundaries")
    func canonicalIdentityRetainsBoundaries() {
        let scopes = [
            ProjectPreferenceScope(
                projectID: 83,
                region: .selfHosted(URL(string: "https://posthog.example.test")!)
            ),
            ProjectPreferenceScope(
                projectID: 84,
                region: .selfHosted(URL(string: "https://posthog.example.test")!)
            ),
            ProjectPreferenceScope(
                projectID: 83,
                region: .selfHosted(URL(string: "https://posthog.example.test/analytics")!)
            ),
            ProjectPreferenceScope(
                projectID: 83,
                region: .selfHosted(URL(string: "https://posthog.example.test:8443")!)
            ),
        ]

        #expect(Set(scopes).count == 4)
    }

    @Test("self-hosted path prefixes and non-default ports remain isolated")
    func separatesSelfHostedPathPrefixesAndNonDefaultPorts() {
        let base = ProjectPreferenceScope(
            projectID: 73,
            region: .selfHosted(URL(string: "https://posthog.example.test/posthog")!)
        )
        let otherPath = ProjectPreferenceScope(
            projectID: 73,
            region: .selfHosted(URL(string: "https://posthog.example.test/analytics")!)
        )
        let nonDefaultPort = ProjectPreferenceScope(
            projectID: 73,
            region: .selfHosted(URL(string: "https://posthog.example.test:8443/posthog")!)
        )

        #expect(base.storageKeyComponent != otherPath.storageKeyComponent)
        #expect(base.storageKeyComponent != nonDefaultPort.storageKeyComponent)
    }

    @Test("missing fields default independently and an unknown order does not erase booleans")
    func toleratesVersionSkew() throws {
        let defaults = storage()
        let scope = ProjectPreferenceScope(
            projectID: 9,
            region: .selfHosted(URL(string: "https://posthog.example.test")!)
        )
        let data = try JSONSerialization.data(withJSONObject: [
            "filterTestAccounts": true,
            "order": "removed_in_a_future_build",
        ])
        defaults.set(data, forKey: SessionsPreferences.defaultsKey(for: scope))

        let value = SessionsPreferences(defaults: defaults).value(for: scope)
        #expect(value.filterTestAccounts)
        #expect(!value.playableOnly)
        #expect(value.order == .startTime)
    }

    @Test("an unreadable record safely returns all defaults")
    func corruptRecordDefaults() {
        let defaults = storage()
        let scope = ProjectPreferenceScope(projectID: 11, region: .euCloud)
        defaults.set(Data([0xFF, 0x00]), forKey: SessionsPreferences.defaultsKey(for: scope))

        #expect(SessionsPreferences(defaults: defaults).value(for: scope) == .init())
    }
}
