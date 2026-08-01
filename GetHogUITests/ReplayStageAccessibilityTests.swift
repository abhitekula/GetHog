import XCTest

/// The replayed page must not be part of this app's accessibility tree.
///
/// A session recording is a picture of somebody else's website that has already
/// happened. Its links lead nowhere and its buttons do nothing, so every element
/// WebKit publishes from it is a VoiceOver stop that cannot be acted on — and the
/// leak is unbounded, because a bigger recorded page contributes arbitrarily more
/// of another company's navigation.
///
/// Measured on this screen before the fix: **3 web views, 15 activatable links
/// and 61 elements** belonging to the replayed site. Adding
/// `.accessibilityElement(children: .ignore)` left it at **3 / 15 / 62** — WebKit
/// serves the page's elements from its own content process, where SwiftUI's
/// ignore never reaches. Only `.accessibilityRepresentation`, which *replaces*
/// the subtree, brings it to **0 / 0 / one element**.
///
/// That is why this test asserts descendant counts rather than "the stage has a
/// label": a plausible-looking fix passes a label assertion and changes nothing.
final class ReplayStageAccessibilityTests: XCTestCase {

    func testReplayStageIsOneElementAndPublishesNoWebContent() {
        let app = DemoLaunch.launch(openURL: "gethog://replay/\(DemoLaunch.replaySessionID)")

        let stage = DemoLaunch.elements(labelled: "Session replay", in: app)
        // The player has to boot rrweb in a web view and be fed snapshots before
        // the stage exists at all, so this waits far longer than a screen would.
        XCTAssertTrue(
            DemoLaunch.wait(for: stage.firstMatch, timeout: 120),
            "The replay never reached its playing state, so there was no stage to measure."
        )

        XCTAssertEqual(
            stage.count, 1,
            "The replay stage must be exactly one element carrying its own label."
        )

        // Was 3. A web view in the tree means the page's own elements are in it.
        XCTAssertEqual(
            app.webViews.count, 0,
            "The replayed page is publishing web views into this app's accessibility tree."
        )

        // Was 15, every one of them another company's navigation announced as
        // something a VoiceOver user could follow.
        XCTAssertEqual(
            app.links.count, 0,
            "The replayed page is publishing followable links into this app's accessibility tree."
        )

        // Belt and braces on the same fact from the other direction: whatever the
        // stage element's type turns out to be, nothing may be *inside* it.
        let stageElement = stage.firstMatch
        XCTAssertEqual(stageElement.descendants(matching: .webView).count, 0)
        XCTAssertEqual(stageElement.descendants(matching: .link).count, 0)
        XCTAssertEqual(stageElement.descendants(matching: .staticText).count, 0)
    }
}
