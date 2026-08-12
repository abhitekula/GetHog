import Foundation
import Testing

@Suite("Mac toolbar default layout")
struct MacToolbarDefaultLayoutTests {

    /// Product actions share one native window toolbar with the shell's project
    /// context and search field. Without an explicit flexible space, AppKit is
    /// free to distribute those actions over the outer source list or through
    /// the middle of a full-screen title bar. Pin the default declaration here;
    /// users can still customize the two identified toolbars afterwards.
    @Test("product actions follow a flexible space on Mac")
    func productActionsFollowFlexibleSpace() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // GetHogMac
            .deletingLastPathComponent()  // repository

        let events = try source(
            "GetHog/Sources/Events/EventsRoot.swift",
            repository: repository
        )
        let eventsToolbar = try slice(
            events,
            after: ".toolbar {\n                    ProjectSwitcher()",
            before: "                // The same table the share menu above offers"
        )
        try expectOrder(
            in: eventsToolbar,
            ["ProjectSwitcher()", "ToolbarSpacer(.flexible)", "SavedFiltersMenu("]
        )
        #expect(
            eventsToolbar.contains(
                "#if os(macOS)\n                    ToolbarSpacer(.flexible)\n                    #endif"
            ),
            "Events must not add the Mac window-toolbar spacer on other platforms"
        )

        let sessions = try source(
            "GetHog/Sources/Sessions/SessionsRoot.swift",
            repository: repository
        )
        let sessionsToolbar = try slice(
            sessions,
            after: ".toolbar(id: \"sessions\") {",
            before: "#else\n                .toolbar {"
        )
        try expectOrder(
            in: sessionsToolbar,
            ["PinnedProjectSwitcher()", "ToolbarSpacer(.flexible)", "ToolbarItem(id: \"filter\""]
        )

        let annotations = try source(
            "GetHog/Sources/DataManagement/AnnotationsRoot.swift",
            repository: repository
        )
        let annotationsToolbar = try slice(
            annotations,
            after: ".toolbar {",
            before: "            .projectSubtitle()"
        )
        try expectOrder(
            in: annotationsToolbar,
            ["ProjectSwitcher()", "ToolbarSpacer(.flexible)", "composeButton"]
        )
        #expect(
            annotationsToolbar.contains(
                "#if os(macOS)\n                ToolbarSpacer(.flexible)\n                #endif"
            ),
            "Annotations must not add the Mac window-toolbar spacer on other platforms"
        )

        let dashboards = try source(
            "GetHog/Sources/Dashboards/DashboardsRoot.swift",
            repository: repository
        )
        let dashboardToolbars = dashboards.components(separatedBy: ".toolbar(id: \"dashboards\") {")
        #expect(dashboardToolbars.count == 3, "Expected both Dashboard toolbar declarations")
        for toolbarRemainder in dashboardToolbars.dropFirst() {
            let toolbar = try slice(
                toolbarRemainder,
                after: "PinnedProjectSwitcher()",
                before: "ToolbarItem(id: \"refresh\""
            )
            #expect(
                toolbar.contains("ToolbarSpacer(.flexible)"),
                "A Dashboard default toolbar left Refresh detached from the trailing action cluster"
            )
        }
    }

    private func source(_ path: String, repository: URL) throws -> String {
        try String(contentsOf: repository.appending(path: path), encoding: .utf8)
    }

    private func slice(_ text: String, after start: String, before end: String) throws -> String {
        let startRange = try #require(text.range(of: start))
        let suffix = text[startRange.lowerBound...]
        let endRange = try #require(suffix.range(of: end))
        return String(suffix[..<endRange.lowerBound])
    }

    private func expectOrder(in text: String, _ tokens: [String]) throws {
        var lowerBound = text.startIndex
        for token in tokens {
            let range = try #require(text.range(of: token, range: lowerBound..<text.endIndex))
            lowerBound = range.upperBound
        }
    }
}
