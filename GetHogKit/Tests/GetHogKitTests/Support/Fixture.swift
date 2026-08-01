import Foundation

/// Loads deterministic, hand-authored PostHog response shapes containing only fictional data.
enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "Fixtures/\(name)",
            withExtension: nil
        ) else {
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }

    static func string(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }

    enum FixtureError: Error, CustomStringConvertible {
        case missing(String)
        var description: String {
            switch self {
            case .missing(let name): "Fixture not found: \(name)"
            }
        }
    }
}
