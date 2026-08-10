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

    private struct MissingSweepCredential: LocalizedError {
        var errorDescription: String? {
            "Live sweep opted in, but .env.local has no nonempty GETHOG_API_KEY."
        }
    }

    private static let allowlistedKeys = ["GETHOG_API_KEY", "GETHOG_REGION"]

    private static var controlFile: URL {
        ExclusiveRun.repositoryRoot
            .appendingPathComponent("build")
            .appendingPathComponent(".live-pat-sweep")
    }

    /// Allowlisted assignments from `.env.local` at the repository root.
    ///
    /// Parsed rather than sourced: this is read by a process inside the simulator,
    /// which has no shell to source it with. Parsing and launch environment
    /// construction both enforce the two-key allowlist, so demo, scenario,
    /// mutation, and unrelated secret values cannot cross into the app.
    static let values: [String: String] = {
        let url = ExclusiveRun.repositoryRoot.appendingPathComponent(".env.local")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }

        return parse(text)
    }()

    static func parse(_ text: String) -> [String: String] {
        var parsed: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            var statement = line.trimmingCharacters(in: .whitespaces)
            if statement.hasPrefix("export") {
                let suffix = statement.dropFirst("export".count)
                guard suffix.first?.isWhitespace == true else { continue }
                statement = suffix.trimmingCharacters(in: .whitespaces)
            }
            guard !statement.hasPrefix("#"), let separator = statement.firstIndex(of: "=") else {
                continue
            }
            let key = String(statement[..<separator]).trimmingCharacters(in: .whitespaces)
            guard allowlistedKeys.contains(key) else { continue }

            var value = String(statement[statement.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            // `export FOO="bar"` and `FOO='bar'` are both common in a file people
            // also source from a shell, and a quoted value would be sent to PostHog
            // with its quotes attached and fail as a malformed credential.
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\""))
                   || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            parsed[key] = value
        }
        return parsed
    }

    static func launchEnvironment(from values: [String: String]) -> [String: String] {
        allowlistedKeys.reduce(into: [:]) { environment, key in
            if let value = values[key] {
                environment[key] = value
            }
        }
    }

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

    /// Requires the host wrapper's explicit per-run opt-in as well as a key.
    static func requireSweep() throws {
        try requireSweep(controlFileURL: controlFile, values: values)
    }

    static func requireSweep(
        controlFileURL: URL,
        values: [String: String]
    ) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: controlFileURL.path)
        try XCTSkipUnless(
            attributes?[.type] as? FileAttributeType == .typeRegular,
            "Live sweep requires the wrapper opt-in."
        )
        guard !(values["GETHOG_API_KEY"] ?? "").isEmpty else {
            throw MissingSweepCredential()
        }
    }

    /// The launch environment for a normal live run.
    static var environment: [String: String] { launchEnvironment(from: values) }

    /// The same, with the region replaced.
    ///
    /// `GetHogApp` reads any `GETHOG_REGION` beginning `http` as
    /// `PostHogRegion.selfHosted`, so an unroutable address here produces a real
    /// connection failure on every request — which is how offline behaviour is
    /// exercised without touching the simulator's network settings, something no
    /// XCUITest can do.
    static func environment(region: String) -> [String: String] {
        var launchEnvironment = environment
        launchEnvironment["GETHOG_REGION"] = region
        return launchEnvironment
    }

    /// The same, with the key replaced — for the rejected-credential paths.
    static func environment(key: String) -> [String: String] {
        var launchEnvironment = environment
        launchEnvironment["GETHOG_API_KEY"] = key
        return launchEnvironment
    }
}
