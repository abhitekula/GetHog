import XCTest

/// The live credential, read from an untracked file rather than the environment.
///
/// **Why a file and not `TEST_RUNNER_GETHOG_API_KEY`.** That channel was measured
/// not to work here — `project.yml` records it: `TEST_RUNNER_`-prefixed variables
/// on the `xcodebuild` command line do **not** reach the UI-test runner's
/// `ProcessInfo.environment` under this toolchain. The runner *can* read the host
/// filesystem, which is how `Screenshot` writes PNGs into the repository at all,
/// so the same channel carries the credential inward.
///
/// **Why that is also the safer shape.** The key never appears on a command line,
/// so it cannot be read out of a process listing, and it never has to be pasted
/// anywhere it would be echoed. `.env*` is already in `.gitignore`, so the file it
/// lives in cannot be committed by accident.
///
/// Nothing here ever prints a value. The skip message names the *file*, never its
/// contents, because a skipped run's message is the one string from this type that
/// is certain to be read aloud in a log.
enum LiveCredentials {

    /// `GETHOG_`-prefixed assignments from `.env.local` at the repository root.
    ///
    /// Parsed rather than sourced: this is read by a process inside the simulator,
    /// which has no shell to source it with. Only `GETHOG_`-prefixed keys are kept,
    /// so an unrelated secret sharing the file cannot be forwarded into the app's
    /// launch environment by accident.
    static let values: [String: String] = {
        let url = ExclusiveRun.repositoryRoot.appendingPathComponent(".env.local")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }

        var parsed: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let statement = line.trimmingCharacters(in: .whitespaces)
            guard !statement.hasPrefix("#"), let separator = statement.firstIndex(of: "=") else {
                continue
            }
            let key = String(statement[..<separator]).trimmingCharacters(in: .whitespaces)
            guard key.hasPrefix("GETHOG_") else { continue }

            var value = String(statement[statement.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            // `export FOO="bar"` and `FOO='bar'` are both common in a file people
            // also source from a shell, and a quoted key would be sent to PostHog
            // with its quotes attached and fail as a malformed credential.
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\""))
                   || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            parsed[key] = value
        }
        return parsed
    }()

    static var isAvailable: Bool { !(values["GETHOG_API_KEY"] ?? "").isEmpty }

    /// Skips rather than fails when there is no credential.
    ///
    /// A missing `.env.local` is the normal state of this repository for everyone
    /// who is not running a live sweep, including CI. A failing target would make
    /// that the default experience of checking the project out.
    static func require() throws {
        try XCTSkipUnless(
            isAvailable,
            "No GETHOG_API_KEY in .env.local at the repository root — live sweep skipped."
        )
    }

    /// The launch environment for a normal live run.
    static var environment: [String: String] { values }

    /// The same, with the region replaced.
    ///
    /// `GetHogApp` reads any `GETHOG_REGION` beginning `http` as
    /// `PostHogRegion.selfHosted`, so an unroutable address here produces a real
    /// connection failure on every request — which is how offline behaviour is
    /// exercised without touching the simulator's network settings, something no
    /// XCUITest can do.
    static func environment(region: String) -> [String: String] {
        var environment = values
        environment["GETHOG_REGION"] = region
        return environment
    }

    /// The same, with the key replaced — for the rejected-credential paths.
    static func environment(key: String) -> [String: String] {
        var environment = values
        environment["GETHOG_API_KEY"] = key
        return environment
    }
}
