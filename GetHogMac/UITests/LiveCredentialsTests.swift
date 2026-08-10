import XCTest

final class LiveCredentialsTests: XCTestCase {

    func testSweepRequiresControlFileAndNonemptyKey() throws {
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

        XCTAssertFalse(
            LiveCredentials.sweepIsAvailable(
                controlFileURL: controlFile,
                values: ["GETHOG_API_KEY": "nonempty-test-value"]
            )
        )

        try FileManager.default.createDirectory(
            at: controlFile,
            withIntermediateDirectories: false
        )
        XCTAssertFalse(
            LiveCredentials.sweepIsAvailable(
                controlFileURL: controlFile,
                values: ["GETHOG_API_KEY": "nonempty-test-value"]
            )
        )
        try FileManager.default.removeItem(at: controlFile)

        XCTAssertTrue(FileManager.default.createFile(atPath: controlFile.path, contents: Data()))
        XCTAssertFalse(
            LiveCredentials.sweepIsAvailable(
                controlFileURL: controlFile,
                values: ["GETHOG_API_KEY": ""]
            )
        )
        XCTAssertTrue(
            LiveCredentials.sweepIsAvailable(
                controlFileURL: controlFile,
                values: ["GETHOG_API_KEY": "nonempty-test-value"]
            )
        )
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
