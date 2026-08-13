import Foundation
import Testing

@Suite("Mac Sessions navigation composition")
struct SessionsNavigationCompositionTests {

    /// The regular Sessions screen draws list and detail as sibling panes, but
    /// Playlists is a drill-in flow. Its stack must own the whole custom split
    /// so both the toolbar link and a playlist row can push and pop. Recording
    /// rows remain selection-driven: giving this branch their destination would
    /// turn the two-pane selection into a push.
    @Test("regular split drives playlist navigation without pushing recordings")
    func regularSplitDrivesOnlyPlaylistDrillIn() throws {
        let source = try sessionsSource()
        let regularBranch = String(
            try slice(
                source,
                after: "#if os(macOS)\n",
                before: "                #else\n                NavigationSplitView {",
                startingAfter: "            } else {"
            )
        )
        let branchLines = regularBranch
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        #expect(
            regularBranch.components(separatedBy: "NavigationStack {").count == 2,
            "The regular Sessions branch must have exactly one navigation owner."
        )
        #expect(
            branchLines.first == "NavigationStack {",
            "The playlist stack must own the whole regular split, not only one pane."
        )
        #expect(
            Array(branchLines.suffix(2)) == ["}", "}"],
            "The custom split and its owning playlist stack must close independently."
        )
        try expectOrder(
            in: regularBranch,
            [
                "NavigationStack {",
                "MacRegularListDetailSplit(",
                "listChrome",
                "detailPane",
                ".navigationDestination(isPresented: $showsPlaylists)",
                "PlaylistsView { filter in",
                "store.replaceFilter(filter)",
                "showsPlaylists = false",
            ]
        )
        #expect(
            !regularBranch.contains("navigationDestination(item: selectedID)"),
            "Regular recording rows must update the sibling detail pane, not push onto the playlist stack."
        )
        #expect(
            source.contains("List(selection: selectedID)"),
            "The regular recording list lost its selection-driven detail binding."
        )
        #expect(
            source.contains("NavigationLink(value: recording.id)"),
            "Recording rows no longer write their id through the selected list row."
        )

        let macToolbar = try slice(
            source,
            after: "#if os(macOS)\n",
            before: "#else\n                .toolbar {",
            startingAfter: "private var listChrome: some View"
        )
        #expect(macToolbar.contains("ToolbarItem(id: \"playlists\""))
        #expect(macToolbar.contains("{ playlistsButton }"))
        #expect(
            !macToolbar.contains("{ playlistsLink }"),
            "The live Mac toolbar must not rely on an inert NavigationLink."
        )

        let button = try slice(
            source,
            after: "private var playlistsButton: some View {",
            before: "    #endif",
            startingAfter: "struct SessionsRoot: View"
        )
        #expect(button.contains("Button"))
        #expect(button.contains("showsPlaylists = true"))
        #expect(button.contains(".accessibilityLabel(\"Playlists\")"))
        #expect(
            source.contains("@State private var showsPlaylists = false"),
            "The Mac playlist push lost its explicit route state."
        )
        #expect(
            source.contains(".onChange(of: model.projectID)")
                && source.contains("showsPlaylists = false"),
            "A project switch must discard the old project's playlist route."
        )
    }

    /// Compact Mac Sessions gets its stack from `MacAdaptiveNavigationHost`,
    /// while regular Sessions owns the stack around its custom split. The same
    /// toolbar button must register its route in both topologies, and resizing
    /// must clear an in-flight route before SwiftUI rebuilds the owner.
    @Test("playlist route follows compact topology without replaying after resize")
    func playlistRouteCoversCompactTopologyTransition() throws {
        let source = try sessionsSource()
        let compactBranch = try slice(
            source,
            after: "if usesHostNavigation {",
            before: "            } else {",
            startingAfter: "var body: some View"
        )

        try expectOrder(
            in: compactBranch,
            [
                "navigationDestination(item: selectedID)",
                ".navigationDestination(isPresented: $showsPlaylists)",
                "PlaylistsView { filter in",
                "store.replaceFilter(filter)",
                "showsPlaylists = false",
            ]
        )
        #expect(
            source.components(
                separatedBy: ".navigationDestination(isPresented: $showsPlaylists)"
            ).count == 3,
            "Compact and regular Mac topology must each register the explicit playlist route."
        )
        #expect(
            source.contains(".onChange(of: usesHostNavigation)")
                && source.contains("showsPlaylists = false"),
            "Resizing across the Mac topology boundary must discard the old route owner."
        )
    }

    private func sessionsSource() throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // GetHogMac
            .deletingLastPathComponent()  // repository
        return try String(
            contentsOf: repository.appending(
                path: "GetHog/Sources/Sessions/SessionsRoot.swift"
            ),
            encoding: .utf8
        )
    }

    private func slice(
        _ text: String,
        after start: String,
        before end: String,
        startingAfter anchor: String
    ) throws -> Substring {
        let anchorRange = try #require(text.range(of: anchor))
        let anchored = text[anchorRange.upperBound...]
        let startRange = try #require(anchored.range(of: start))
        let remainder = anchored[startRange.upperBound...]
        let endRange = try #require(remainder.range(of: end))
        return remainder[..<endRange.lowerBound]
    }

    private func expectOrder(in text: some StringProtocol, _ tokens: [String]) throws {
        let text = String(text)
        var lowerBound = text.startIndex
        for token in tokens {
            let range = try #require(
                text.range(of: token, range: lowerBound..<text.endIndex)
            )
            lowerBound = range.upperBound
        }
    }
}
