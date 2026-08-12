import Foundation
import GetHogKit

@MainActor
struct SessionsPreferences {
    struct Value: Equatable, Sendable {
        var filterTestAccounts: Bool
        var playableOnly: Bool
        var order: SessionRecordingFilter.Order

        init(
            filterTestAccounts: Bool = false,
            playableOnly: Bool = false,
            order: SessionRecordingFilter.Order = .startTime
        ) {
            self.filterTestAccounts = filterTestAccounts
            self.playableOnly = playableOnly
            self.order = order
        }

        init(filter: SessionRecordingFilter) {
            self.init(
                filterTestAccounts: filter.filterTestAccounts,
                playableOnly: filter.source == .web,
                order: filter.order
            )
        }

        func apply(to filter: inout SessionRecordingFilter) {
            filter.filterTestAccounts = filterTestAccounts
            filter.source = playableOnly ? .web : nil
            filter.order = order
        }
    }

    private struct StoredValue: Codable {
        var filterTestAccounts: Bool?
        var playableOnly: Bool?
        var order: String?
    }

    private static let keyPrefix = "sessions.preferences.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func defaultsKey(for scope: ProjectPreferenceScope) -> String {
        "\(keyPrefix).\(scope.storageKeyComponent)"
    }

    func value(for scope: ProjectPreferenceScope) -> Value {
        guard let data = defaults.data(forKey: Self.defaultsKey(for: scope)),
              let stored = try? JSONDecoder().decode(StoredValue.self, from: data)
        else { return Value() }

        return Value(
            filterTestAccounts: stored.filterTestAccounts ?? false,
            playableOnly: stored.playableOnly ?? false,
            order: stored.order.flatMap(SessionRecordingFilter.Order.init(rawValue:))
                ?? .startTime
        )
    }

    func set(_ value: Value, for scope: ProjectPreferenceScope) {
        let stored = StoredValue(
            filterTestAccounts: value.filterTestAccounts,
            playableOnly: value.playableOnly,
            order: value.order.rawValue
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.defaultsKey(for: scope))
    }
}
