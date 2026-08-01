import XCTest

/// The first thing VoiceOver says on first launch.
///
/// The welcome step's hero was a bare `Image(systemName: "chart.xyaxis.line")`
/// with no label and no `.accessibilityHidden(true)`, so the app opened by
/// speaking an SF Symbol's name. `AboutView` draws the identical glyph for the
/// identical reason and has always hidden it, so that one really was a plain
/// omission with a known-correct sibling, and hiding it really did fix it —
/// measured, the element is gone.
///
/// **The three highlight rows under it were a different defect, and the
/// measurement is the only reason that is known.** They already carried
/// `.accessibilityElement(children: .combine)`, and it folded their two `Text`s
/// into one label while leaving all three children in the tree: two rows
/// published stops labelled `rectangle.stack` and `lock.shield`, and the third
/// read "Grid View" only because SF Symbols happens to ship a description for
/// that glyph. Adding `.accessibilityHidden(true)` to those images changed
/// nothing — measured before and after, both symbol names still there. Combining
/// makes the row a container, and a container does not consult a child's
/// suppression. Only `.accessibilityRepresentation` removed them, which is the
/// same finding as the dashboard tile next door and the replay stage beside
/// that.
///
/// So: one screen, two mechanisms, and the audit caught neither.
///
/// It survived because of the shape of the test target around it: every other
/// screen is reached with `-GetHogDemo`, and demo mode hands `AppModel` an
/// `InMemoryTokenStore` that already holds a credential, so `bootstrap()` puts
/// the app straight to `.ready`. Nothing in this target had ever rendered
/// onboarding at all.
///
/// So this launches plain — no demo argument, no `GETHOG_API_KEY` — against a
/// real, empty `KeychainTokenStore`. The welcome step issues no request, so it
/// still costs the organisation's rate-limit budget nothing.
final class OnboardingAccessibilityTests: XCTestCase {

    /// The hero's glyph, and the three highlight rows'. Asserted individually so
    /// a failure names which one, because the two groups fail for different
    /// reasons and take different fixes.
    private static let symbols = [
        "chart.xyaxis.line",
        "square.grid.2x2",
        "rectangle.stack",
        "lock.shield",
    ]

    func testWelcomeStepSpeaksNoSymbolNames() {
        let app = XCUIApplication()
        app.launch()

        // Doubles as the guard on *which* screen this is. A simulator holding a
        // stored credential launches past onboarding onto Dashboards, and this
        // fails loudly rather than auditing the wrong screen.
        XCTAssertTrue(
            DemoLaunch.wait(for: app.buttons["Get started"]),
            "Onboarding's welcome step never appeared. If this simulator holds a "
                + "stored credential, the app launched past it."
        )

        for symbol in Self.symbols {
            XCTAssertEqual(
                DemoLaunch.elements(labelled: symbol, in: app).count, 0,
                "The welcome step speaks '\(symbol)' — an SF Symbol name — aloud."
            )
        }

        // A label *containing* a symbol name rather than being one. Measured,
        // `.combine` did not splice the glyph into the row's sentence — but a
        // future header that labels its image would, and that reads worse than a
        // separate stop because it cannot be skipped.
        for symbol in Self.symbols {
            let containing = app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", symbol)
            )
            XCTAssertEqual(
                containing.count, 0,
                "'\(symbol)' is spliced into a spoken label: '\(containing.firstMatch.label)'."
            )
        }

        // The screen still says what it is. A hero removed by deleting the
        // wordmark beside it would pass every assertion above.
        XCTAssertTrue(
            app.staticTexts["GetHog"].exists,
            "The welcome step no longer names the app."
        )
    }
}
