import Foundation
import Testing

/// The Simulator can execute app and bundle contracts, but it must not follow
/// a compile-time host path back into the repository. Such access crosses the
/// simulator/host file-coordination boundary and can block indefinitely.
@Suite("Simulator test source isolation")
struct SimulatorTestSourceIsolationTests {
    @Test("iOS tests do not derive repository paths from filePath")
    func noHostRepositoryPathDerivation() throws {
        let tests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "GetHog/Tests")

        let enumerator = try #require(
            FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil),
            "couldn't read \(tests.path)"
        )
        let offenders = try enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .filter { url in
                try String(contentsOf: url, encoding: .utf8).contains("#filePath")
            }
            .map(\.lastPathComponent)
            .sorted()

        #expect(
            offenders.isEmpty,
            "iOS Simulator tests must use bundle resources or temporary files; move source contracts to a host suite: \(offenders)"
        )
    }
}
