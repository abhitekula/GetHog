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
