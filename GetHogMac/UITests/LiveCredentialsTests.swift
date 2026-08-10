import XCTest

final class LiveCredentialsTests: XCTestCase {

    func testSweepSkipsWithoutARegularControlFile() throws {
        let controlFile = try makeControlFileURL()

        XCTAssertThrowsError(
            try LiveCredentials.requireSweep(
                controlFileURL: controlFile,
                values: ["GETHOG_API_KEY": "nonempty-test-value"]
            )
        ) { error in
            XCTAssertTrue(error is XCTSkip)
        }

        try FileManager.default.createDirectory(
            at: controlFile,
            withIntermediateDirectories: false
        )
        XCTAssertThrowsError(
            try LiveCredentials.requireSweep(
                controlFileURL: controlFile,
                values: ["GETHOG_API_KEY": "nonempty-test-value"]
            )
        ) { error in
            XCTAssertTrue(error is XCTSkip)
        }
    }

    func testSweepFailsClosedWhenControlFileExistsWithoutAKey() throws {
        let controlFile = try makeControlFileURL()
        XCTAssertTrue(FileManager.default.createFile(atPath: controlFile.path, contents: Data()))

        for values in [[:], ["GETHOG_API_KEY": ""]] {
            XCTAssertThrowsError(
                try LiveCredentials.requireSweep(
                    controlFileURL: controlFile,
                    values: values
                )
            ) { error in
                XCTAssertFalse(error is XCTSkip)
                XCTAssertEqual(
                    error.localizedDescription,
                    "Live sweep opted in, but .env.local has no nonempty GETHOG_API_KEY."
                )
            }
        }
    }

    func testSweepProceedsWithControlFileAndNonemptyKey() throws {
        let controlFile = try makeControlFileURL()
        XCTAssertTrue(FileManager.default.createFile(atPath: controlFile.path, contents: Data()))

        XCTAssertNoThrow(
            try LiveCredentials.requireSweep(
                controlFileURL: controlFile,
                values: ["GETHOG_API_KEY": "nonempty-test-value"]
            )
        )
    }

    private func makeControlFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let controlFile = directory.appendingPathComponent(".live-pat-sweep")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return controlFile
    }

    func testParserAcceptsBareAndExportedAssignments() {
        let parsed = LiveCredentials.parse(
            """
            GETHOG_API_KEY=bare-value
            export GETHOG_REGION='eu'
            """
        )

        XCTAssertEqual(parsed["GETHOG_API_KEY"], "bare-value")
        XCTAssertEqual(parsed["GETHOG_REGION"], "eu")
    }

    func testLaunchEnvironmentIncludesOnlyAllowlistedKeys() {
        let environment = LiveCredentials.launchEnvironment(
            from: [
                "GETHOG_API_KEY": "nonempty-test-value",
                "GETHOG_REGION": "us",
                "GETHOG_DEMO": "1",
                "GETHOG_SCENARIO": "mutation",
                "GETHOG_ENABLE_MUTATIONS": "1",
                "UNRELATED_SECRET": "must-not-cross-boundary",
            ]
        )

        XCTAssertEqual(
            environment,
            [
                "GETHOG_API_KEY": "nonempty-test-value",
                "GETHOG_REGION": "us",
            ]
        )
    }
}
