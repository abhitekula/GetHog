import Foundation
import Testing

@testable import GetHogKit

/// Console and network diagnostics extracted from compact, fictional rrweb events.
@Suite("Replay console and network")
struct ReplayDiagnosticsTests {

    private func events(_ fixture: String) throws -> [SnapshotEvent] {
        try SnapshotParser.parse(jsonl: Fixture.data(fixture))
    }

    private func diagnostics(_ fixture: String = "replay_plugin_session.jsonl") throws
        -> ReplayDiagnostics
    {
        ReplayDiagnostics.extract(from: try events(fixture))
    }

    @Test("reads one fictional console entry and one fictional request")
    func readsSyntheticDiagnostics() throws {
        let diagnostics = try diagnostics()

        #expect(diagnostics.console.count == 1)
        #expect(diagnostics.network.count == 1)

        let console = try #require(diagnostics.console.first)
        #expect(console.level == .log)
        #expect(console.rawLevel == "info")
        #expect(console.parts == ["Dashboard widgets loaded", #"{"widgetCount":3}"#])
        #expect(console.trace == ["https://app.example.com/dashboard"])

        let request = try #require(diagnostics.network.first)
        #expect(request.url == "https://app.example.com/api/widgets")
        #expect(request.method == "GET")
        #expect(request.status == 200)
        #expect(request.pathLabel == "/api/widgets")
        #expect(request.host == "app.example.com")
        #expect(!request.isFailure)
    }

    @Test("the compact shape fixture carries the same supported plugin shapes")
    func readsShapes() throws {
        let diagnostics = try diagnostics("replay_plugin_shapes.jsonl")
        #expect(diagnostics.console.count == 1)
        #expect(diagnostics.network.count == 1)
    }

    @Test("maps rrweb console levels onto the three PostHog counts")
    func mapsLevels() {
        #expect(ReplayConsoleLevel(rrweb: "error") == .error)
        #expect(ReplayConsoleLevel(rrweb: "assert") == .error)
        #expect(ReplayConsoleLevel(rrweb: "warn") == .warn)
        #expect(ReplayConsoleLevel(rrweb: "info") == .log)
        #expect(ReplayConsoleLevel(rrweb: "something-new") == .log)
    }

    @Test("diagnostic entries carry offsets from the replay origin")
    func offsets() throws {
        let diagnostics = try diagnostics()
        let origin = Date(timeIntervalSince1970: 1_768_478_400)
        let console = try #require(diagnostics.console.first)
        let request = try #require(diagnostics.network.first)

        #expect(abs(console.offset(from: origin) - 1.0) < 0.001)
        #expect(abs(request.offset(from: origin) - 1.2) < 0.001)
    }

    @Test("merging repeated chunks preserves one request and unique console ids")
    func mergesChunks() throws {
        let chunk = try diagnostics()
        var merged = chunk
        merged.merge(chunk)

        #expect(merged.network.count == 1)
        #expect(merged.console.count == 2)
        #expect(Set(merged.console.map(\.id)).count == 2)
    }

    @Test("reads which plugins were active from the recorder startup event")
    func readsActivePlugins() throws {
        let raw = """
            ["w",{"type":5,"timestamp":1,"data":{"tag":"$session_options","payload":{\
            "activePlugins":["rrweb/console@1","rrweb/network@1"]}}}]
            """
        let capture = ReplayDiagnostics.extract(
            from: try SnapshotParser.parse(jsonl: Data(raw.utf8))
        ).capture

        #expect(capture.sawStartupEvent)
        #expect(capture.consoleEnabled == true)
        #expect(capture.networkEnabled == true)
        #expect(capture.activePlugins == ["rrweb/console@1", "rrweb/network@1"])
    }

    @Test("a live plugin with no entries is enabled rather than absent")
    func enabledButSilent() throws {
        var capture = ReplayCaptureConfig()
        capture.sawStartupEvent = true
        capture.activePlugins = ["rrweb/console@1"]
        #expect(capture.status(.console, hasEntries: false) == .enabledButNone)
        #expect(capture.status(.console, hasEntries: true) == .captured)
    }

    @Test("a recorder that did not load a plugin reports it as disabled")
    func disabledPlugin() {
        var capture = ReplayCaptureConfig()
        capture.sawStartupEvent = true
        capture.activePlugins = ["rrweb/network@1"]
        #expect(capture.consoleEnabled == false)
        #expect(capture.status(.console, hasEntries: false) == .disabled)
        #expect(capture.status(.network, hasEntries: false) == .enabledButNone)
    }

    @Test("no startup event and no entries is unknown rather than disabled")
    func unknownWithoutStartupEvent() {
        let capture = ReplayCaptureConfig()
        #expect(capture.consoleEnabled == nil)
        #expect(capture.status(.console, hasEntries: false) == .unknown)
        #expect(capture.status(.network, hasEntries: false) == .unknown)
        #expect(capture.status(.console, hasEntries: true) == .captured)
    }

    @Test("falls back to remote configuration when the startup event is absent")
    func fallsBackToRemoteConfig() throws {
        let raw = """
            ["w",{"type":5,"timestamp":1,"data":{"tag":"$remote_config_received","payload":{\
            "consoleLogRecordingEnabled":false,\
            "networkPayloadCapture":{"capturePerformance":{"network_timing":true}}}}}]
            """
        let capture = ReplayDiagnostics.extract(
            from: try SnapshotParser.parse(jsonl: Data(raw.utf8))
        ).capture

        #expect(!capture.sawStartupEvent)
        #expect(capture.consoleEnabled == false)
        #expect(capture.networkEnabled == true)
    }

    @Test("accepts capturePerformance as a boolean")
    func booleanCapturePerformance() throws {
        let raw = """
            ["w",{"type":5,"timestamp":1,"data":{"tag":"$remote_config_received","payload":{\
            "consoleLogRecordingEnabled":true,"networkPayloadCapture":{"capturePerformance":false}}}}]
            """
        let capture = ReplayDiagnostics.extract(
            from: try SnapshotParser.parse(jsonl: Data(raw.utf8))
        ).capture
        #expect(capture.networkEnabled == false)
    }

    @Test("malformed and unknown plugin events do not poison valid entries")
    func toleratesGarbage() throws {
        let raw = """
            ["w",{"type":6,"timestamp":1,"data":{"plugin":"rrweb/console@1","payload":"nope"}}]
            ["w",{"type":6,"timestamp":2,"data":{"plugin":"rrweb/network@1","payload":{"requests":"nope"}}}]
            ["w",{"type":6,"timestamp":3,"data":{"plugin":"rrweb/unknown@9","payload":{}}}]
            ["w",{"type":6,"timestamp":4,"data":{"plugin":"rrweb/console@1","payload":{"level":"error","payload":["\\"ok\\""]}}}]
            """
        let diagnostics = ReplayDiagnostics.extract(
            from: try SnapshotParser.parse(jsonl: Data(raw.utf8))
        )
        #expect(diagnostics.network.isEmpty)
        #expect(diagnostics.console.count == 1)
        #expect(diagnostics.console[0].summary == "ok")
    }

    @Test("a recording with no plugin events yields empty diagnostics")
    func emptyRecording() {
        let diagnostics = ReplayDiagnostics.extract(from: [])
        #expect(diagnostics.console.isEmpty)
        #expect(diagnostics.network.isEmpty)
        #expect(!diagnostics.capture.sawStartupEvent)
    }
}
