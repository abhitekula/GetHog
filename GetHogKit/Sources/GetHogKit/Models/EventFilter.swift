import Foundation

/// One chip in the events search field.
///
/// A token is a *narrowing* the user can see and remove, rather than a string
/// the app guesses the meaning of. The three kinds map onto the only three
/// things the events query can filter on: which event, which person, and which
/// property value.
public struct EventFilterToken: Sendable, Hashable, Codable, Identifiable {

    public enum Kind: String, Sendable, Codable, CaseIterable {
        case event
        case person
        case property
    }

    public let kind: Kind
    /// Property name for `.property`, empty for the other kinds.
    public let key: String
    public let value: String

    public init(kind: Kind, key: String = "", value: String) {
        self.kind = kind
        self.key = key
        self.value = value
    }

    public static func event(_ name: String) -> Self { Self(kind: .event, value: name) }
    public static func person(_ term: String) -> Self { Self(kind: .person, value: term) }
    public static func property(_ key: String, _ value: String) -> Self {
        Self(kind: .property, key: key, value: value)
    }

    /// Kind participates in identity: filtering on an event named `alice` and on
    /// a person called `alice` are different chips and must both be removable.
    public var id: String { "\(kind.rawValue)\u{1F}\(key)\u{1F}\(value)" }

    public var displayText: String {
        kind == .property ? "\(key): \(value)" : value
    }

    public var systemImage: String {
        switch kind {
        case .event: "bolt"
        case .person: "person"
        case .property: "tag"
        }
    }

    /// Readings of the typed text to offer as chips.
    ///
    /// `key:value` is unambiguous enough to offer alone; anything else could be
    /// either an event name or a person, so both are offered and the user picks.
    public static func suggestions(for text: String) -> [EventFilterToken] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let separator = trimmed.firstIndex(of: ":") {
            let key = String(trimmed[trimmed.startIndex..<separator])
                .trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            if isValidPropertyKey(key), !value.isEmpty {
                return [.property(key, value)]
            }
        }

        return [.event(trimmed), .person(trimmed)]
    }

    /// A property key is interpolated into HogQL as a bare path, so it has to be
    /// an identifier. Anything else falls back to an event or person reading
    /// rather than being escaped into a query that would not mean what it says.
    static func isValidPropertyKey(_ key: String) -> Bool {
        guard let first = key.first else { return false }
        let leading = CharacterSet.letters.union(CharacterSet(charactersIn: "_$"))
        let rest = leading.union(.decimalDigits)
        guard first.unicodeScalars.allSatisfy({ leading.contains($0) }) else { return false }
        return key.unicodeScalars.allSatisfy { rest.contains($0) }
    }
}

/// A named set of tokens the user chose to keep.
public struct SavedEventFilter: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var name: String
    public var tokens: [EventFilterToken]
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        tokens: [EventFilterToken],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.tokens = tokens
        self.createdAt = createdAt
    }
}

/// The key/value slot saved filters are written to.
///
/// Abstracted so the store can be exercised without touching the real user
/// defaults, and so previews can run against throwaway state.
public protocol SavedFilterStorage: Sendable {
    func filterData(forKey key: String) -> Data?
    func setFilterData(_ value: Data?, forKey key: String)
}

/// Backed by `UserDefaults`. There is no PostHog API for saved filters, so this
/// is deliberately device-local and does not sync.
public struct UserDefaultsFilterStorage: SavedFilterStorage {
    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    // Resolved per call so the type itself stores only a `String?` and stays a
    // plain `Sendable` value.
    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public func filterData(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    public func setFilterData(_ value: Data?, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}

public final class InMemoryFilterStorage: SavedFilterStorage {
    private let lock = NSLock()
    nonisolated(unsafe) private var storage: [String: Data] = [:]

    public init() {}

    public func filterData(forKey key: String) -> Data? {
        lock.withLock { storage[key] }
    }

    public func setFilterData(_ value: Data?, forKey key: String) {
        lock.withLock { storage[key] = value }
    }
}

/// Reads and writes the user's saved filter sets.
///
/// Every entry point takes a project id because the sets are scoped to one: a
/// filter naming `checkout_completed` is meaningless in a project that has no
/// such event, and showing it there would be noise rather than a shortcut.
public struct SavedEventFilterStore: Sendable {
    private let storage: any SavedFilterStorage

    public init(storage: any SavedFilterStorage = UserDefaultsFilterStorage()) {
        self.storage = storage
    }

    public static func storageKey(projectID: Int) -> String {
        "com.gethog.savedEventFilters.project.\(projectID)"
    }

    public func filters(projectID: Int) -> [SavedEventFilter] {
        guard let data = storage.filterData(forKey: Self.storageKey(projectID: projectID)),
              let decoded = try? JSONDecoder().decode([SavedEventFilter].self, from: data)
        else {
            // Unreadable data means an older or corrupt encoding. Reporting "no
            // saved sets" keeps the screen usable; throwing would take the whole
            // events list down over a convenience feature.
            return []
        }
        return decoded.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    @discardableResult
    public func add(
        name: String,
        tokens: [EventFilterToken],
        projectID: Int
    ) -> SavedEventFilter? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !tokens.isEmpty else { return nil }

        let filter = SavedEventFilter(name: trimmed, tokens: tokens)
        var all = filters(projectID: projectID)
        all.append(filter)
        write(all, projectID: projectID)
        return filter
    }

    public func rename(id: UUID, to name: String, projectID: Int) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var all = filters(projectID: projectID)
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].name = trimmed
        write(all, projectID: projectID)
    }

    public func delete(id: UUID, projectID: Int) {
        let remaining = filters(projectID: projectID).filter { $0.id != id }
        write(remaining, projectID: projectID)
    }

    private func write(_ filters: [SavedEventFilter], projectID: Int) {
        let key = Self.storageKey(projectID: projectID)
        guard !filters.isEmpty else {
            storage.setFilterData(nil, forKey: key)
            return
        }
        storage.setFilterData(try? JSONEncoder().encode(filters), forKey: key)
    }
}
