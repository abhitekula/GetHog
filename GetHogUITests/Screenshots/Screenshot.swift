import UIKit
import XCTest

/// A screenshot harness for looking at the app, rather than reasoning about it.
///
/// **Why this exists.** Large amounts of shipped UI in this project have never
/// been seen running. The iOS Simulator MCP's `launch` action accepts no launch
/// arguments and no environment, so `-GetHogDemo` cannot be set through it,
/// and `xcrun simctl` is off-limits here — which left four separate agents
/// rendering views through `ImageRenderer` in throwaway tests. That found real
/// defects every time, but it cannot render materials, real `.sheet`
/// presentations with detents, `Menu`, or `ScrollView`-clipped content, and it
/// does not exercise layout in a real window.
///
/// A UI test *can* pass launch arguments — that is exactly how
/// `AccessibilityAuditTests` drives 25 screens. So this target launches the demo
/// build once per screen and writes a PNG of what actually came up.
///
/// **Where the images go, and why not an attachment.** `XCTAttachment` puts the
/// PNGs inside the `.xcresult` in DerivedData, behind an `xcresulttool export`
/// step — which is the "hard to reach" failure the harness exists to avoid.
/// Measured instead: the UI-test *runner* process, though it lives in the
/// simulator, can write to the host filesystem. `#filePath` gives this file's
/// host path at compile time, so the repository root is derivable with no
/// environment variable and no `-derivedDataPath`. Images land in
/// `build/Screenshots/<device>/<configuration>/<screen>.png` — inside the
/// project, one Finder window away, and already covered by `.gitignore`'s
/// `build/` rule so 150 PNGs never appear in `git status`.
///
/// **Why a target of its own.** A full sweep is minutes, not seconds, and the
/// project's verification command is
/// `xcodebuild test -only-testing:GetHogUITests`. Adding ~50 launching tests
/// to that target would make the normal run slow and move its count off 33.
/// `TEST_RUNNER_`-prefixed variables were measured **not** reaching the runner's
/// environment under this Xcode, so skipping by environment flag was not
/// available either. A separate `GetHogScreenshots` target with a scheme of
/// its own leaves `GetHogUITests` untouched at 33 tests.
enum Screenshot {

    // MARK: - Output

    /// The repository root, found by walking up until `project.yml` appears.
    ///
    /// Derived rather than configured, for the reasons recorded on
    /// `ExclusiveRun.repositoryRoot` — which is where the walk now lives, because
    /// the run lock writes to `build/` too and two derivations of the same path
    /// would be free to disagree.
    static var repositoryRoot: URL { ExclusiveRun.repositoryRoot }

    /// CoreSimulator injects this into every process it starts, including the
    /// test runner — verified, `SIMULATOR_DEVICE_NAME=iPhone 17`. It is what
    /// keeps an iPhone sweep and an iPad sweep from overwriting each other, so a
    /// run needs no argument beyond `-destination`.
    static let deviceName: String = {
        let raw = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "Unknown device"
        return raw.replacingOccurrences(of: "/", with: "-")
    }()

    /// True on iPad, which is what scopes the matrix — see `Configuration`.
    static let isPad: Bool = deviceName.lowercased().contains("ipad")

    static var outputRoot: URL {
        repositoryRoot
            .appendingPathComponent("build")
            .appendingPathComponent("Screenshots")
            .appendingPathComponent(deviceName)
    }

    // MARK: - Configurations

    /// One point in the matrix.
    ///
    /// **The matrix is deliberately not a cross-product.** Thirty-five roots plus
    /// a dozen interaction states, across two devices, two appearances and two
    /// type sizes, is ~400 images, most of which differ from a neighbour in
    /// nothing a reader would notice. What is kept is one axis at a time against
    /// a common baseline:
    ///
    /// * **light** — the baseline. Every screen, every device.
    /// * **dark** — every screen, every device. Free: `XCUIDevice.appearance` is
    ///   a live trait change, so this is a second screenshot of an app that is
    ///   already up rather than a second launch. Dark is where an invisible
    ///   element hides — a bar tint that matched the background was one of the
    ///   defects `ImageRenderer` found — so paying nothing for it is worth more
    ///   than the disk.
    /// * **ax5** — accessibility XXXL, iPhone matrix plus explicit iPad overview
    ///   cases, light only. This is the one configuration that needs its own launch, because
    ///   `-UIPreferredContentSizeCategoryName` is read once at start-up.
    ///
    /// **Why the general ax5 matrix is iPhone-only.** The defect class it exists to find is text
    /// that clips or overflows when it grows, and that is strictly harder in the
    /// narrower container: an iPad running the same screen at the same type size
    /// has 390pt more width to absorb it. iPad's own risk is the sidebar and the
    /// two-column split. The Core Four overview scenes are the exception: they
    /// only render in that split detail pane, so their dedicated iPad AX5 tests
    /// call `captureRootAX5OnIPad` without broadening every screenshot case.
    ///
    /// **Why ax5 rather than a middle accessibility size.** Worst case finds
    /// most. AX5 is the largest the system offers, and a layout that survives it
    /// survives AX1–AX4.
    enum Configuration: String, CaseIterable {
        case light
        case dark
        case ax5

        /// Whether this configuration is captured on the device now running.
        var appliesToThisDevice: Bool {
            switch self {
            case .light, .dark: true
            case .ax5: !Screenshot.isPad
            }
        }

        var appearance: XCUIDevice.Appearance {
            switch self {
            case .light, .ax5: .light
            case .dark: .dark
            }
        }

        /// `nil` means "whatever the device is set to", which is `.large`.
        ///
        /// Set as a **launch argument**, not through any XCTest API: there is no
        /// XCUITest call for the preferred content size category, and
        /// `-UIPreferredContentSizeCategoryName` is the `UserDefaults` key UIKit
        /// reads at start-up. Verified visually on Settings, which came up with
        /// two-line wrapped values and a truncated third row — i.e. it applied.
        var contentSizeCategory: String? {
            switch self {
            case .light, .dark: nil
            case .ax5: "UICTContentSizeCategoryAccessibilityXXXL"
            }
        }

        /// Whether reaching this configuration requires a fresh process.
        ///
        /// Always for `ax5`, because `-UIPreferredContentSizeCategoryName` is
        /// read once at start-up.
        ///
        /// **And for `dark` on both devices, which was measured rather than
        /// assumed — twice, and the second measurement overturned the first.**
        ///
        /// On iPad Pro 11" a live `XCUIDevice.appearance = .dark` does nothing
        /// at all: the first full sweep produced a `dark/` directory whose 36
        /// images were pixel-identical to `light/`, checked by sampling rather
        /// than by eye. That is loud, and the duplicate check in
        /// `Screenshot.capture` catches it.
        ///
        /// On iPhone the same flip was believed to work, because the app's
        /// *content* answers it inside the beat this harness waits and the
        /// resulting frame is unmistakably dark. It is the **navigation layer
        /// that does not follow**. Measured on iPhone 17 Pro across two
        /// independent full sweeps: `dark/actions`, `dark/clickmap`,
        /// `dark/earlyAccess`, `dark/max` and `dark/notebooks` came back with a
        /// pure-black large title on the #151413 ground, an invisible project
        /// subtitle, light-mode glass on the two toolbar circles, a light search
        /// field, and a **black status-bar clock** — i.e. UIKit's window still in
        /// light while SwiftUI's content had redrawn dark. The same five screens
        /// in the iPad `dark/` directory, which takes its own launch, are
        /// correct. So the failure is the live flip, not the app, and it is
        /// quiet: it produces a plausible dark screenshot with one wrong region,
        /// which a reviewer files as five defects in the app.
        ///
        /// Dark therefore starts its own process everywhere. It costs one extra
        /// launch per screen — about four minutes on a full iPhone sweep — and
        /// buys images whose chrome is answerable.
        var needsOwnLaunch: Bool {
            contentSizeCategory != nil || self == .dark
        }
    }

    // MARK: - Launching

    /// Launches the demo build in a given configuration, and returns immediately.
    ///
    /// Deliberately **not** `DemoLaunch.launch`: that helper is shared with the
    /// audit target and takes no configuration, and adding a parameter to it
    /// would put screenshot concerns inside the file three passing test classes
    /// depend on. It also *waits* for a navigation bar, which onboarding — the
    /// one screen here that launches without demo mode — does not have to
    /// produce on the same schedule. Waiting is the caller's job, because only
    /// the caller knows what "arrived" means for its screen.
    ///
    /// `terminate()` before every launch, because `launch()` on an
    /// already-running instance attaches to it and silently serves the
    /// *previous* process's arguments — which for this harness would mean an
    /// "ax5" image at default type, indistinguishable from a screen that simply
    /// does not scale.
    static func launch(
        _ configuration: Configuration,
        tab: String? = nil,
        openURL: String? = nil,
        environment: [String: String] = [:],
        demo: Bool = true,
        extraArguments: [String] = []
    ) -> XCUIApplication {
        precondition(tab == nil || openURL == nil, "GETHOG_TAB overrules GETHOG_OPEN_URL.")

        // Before the appearance is changed and before anything is terminated:
        // both of those are visible to a run that already owns this device.
        guard ExclusiveRun.claim() else { return XCUIApplication() }

        XCUIDevice.shared.appearance = configuration.appearance

        let app = XCUIApplication()
        app.launchArguments = demo ? ["-GetHogDemo"] : []
        if let category = configuration.contentSizeCategory {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", category]
        }
        // Belt and braces with `XCUIDevice.appearance` above, because that API
        // was measured doing **nothing at all** on iPad Pro 11" — see
        // `Configuration.needsOwnLaunch`. `UIUserInterfaceStyle` is the
        // `UserDefaults` key UIKit reads at start-up, the same mechanism
        // `-UIPreferredContentSizeCategoryName` uses, and it is honoured on both
        // devices.
        if configuration.appearance == .dark {
            app.launchArguments += ["-UIUserInterfaceStyle", "Dark"]
        }
        app.launchArguments += extraArguments
        if let tab { app.launchEnvironment["GETHOG_TAB"] = tab }
        if let openURL { app.launchEnvironment["GETHOG_OPEN_URL"] = openURL }
        for (key, value) in environment { app.launchEnvironment[key] = value }

        app.terminate()
        app.launch()

        // **iPad dark: still not capturable for a root screen, with one measured
        // exception, and it is not a timing problem.**
        //
        // Both mechanisms remain no-ops on iPad Pro 11" (M5) / iOS 26.0 for the
        // root hierarchy. Three separate sweeps on 30–31 Jul each had the
        // duplicate check delete effectively the whole `dark/` directory — 65 of
        // 66, then 64 of 66, then 3 of 3 on a targeted re-run.
        //
        // The exception is `sql-schema-browser` and `sql-schema-columns`, which
        // came out **genuinely dark** in the same runs that deleted everything
        // else: 0.078 and 0.074 against their light twins' 0.819 and 0.819. What
        // is different about those two is that they are a *presented sheet*
        // rather than the root — a view controller created after launch.
        //
        // The obvious next theory was that the trait simply arrives late and an
        // early capture misses it. **Measured and false**: a five-second pause
        // here, after `launch()` and before anything is waited on, left
        // `actions`, `events` and `settings` all still deleted as
        // indistinguishable from light. The pause is therefore gone rather than
        // kept "just in case" — it would have cost five minutes a sweep to buy a
        // theory that does not hold.
        //
        // One sweep at 22:01–22:40 on 30 Jul did produce 66 honest iPad dark
        // images with this same code, luminances 0.09 against 0.93. That set was
        // preserved and checked; it is not a misreading. Nothing found here
        // explains the difference, and this comment says so rather than guessing.
        return app
    }

    // MARK: - Capturing

    /// Writes one PNG, and never fails the test for it.
    ///
    /// A capture run's job is to produce images; a write error on image 90 must
    /// not throw away the 89 before it or stop the 60 after. Failures are printed
    /// and counted rather than asserted — the only assertions in this target are
    /// the waits that say a screen actually came up, because a photograph of the
    /// wrong screen is worse than a missing one.
    /// Writes one PNG and returns the name of the configuration it turned out to
    /// be a byte-for-byte copy of, if any — see the caller for why that matters.
    @discardableResult
    static func capture(_ name: String, configuration: Configuration) -> String? {
        // The whole screen rather than `app.screenshot()`: a `Menu`'s popover,
        // an alert and a confirmation dialog are presented in windows of their
        // own, and an app-scoped screenshot can miss exactly the transient
        // chrome this harness exists to photograph.
        let data = XCUIScreen.main.screenshot().pngRepresentation
        let directory = outputRoot.appendingPathComponent(configuration.rawValue)
        let file = directory.appendingPathComponent("\(name).png")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try data.write(to: file)
            captured += 1
        } catch {
            print("SCREENSHOT-FAILED \(name) [\(configuration.rawValue)]")
            failures.append(name)
            return nil
        }

        // Keyed by screen *and* configuration so the comparison survives the two
        // separate launches an iPad's dark pass takes, which is exactly the case
        // that needs it.
        //
        // **Mean luminance, not the bytes.** Comparing `Data` was the first
        // attempt and it does not work: the status bar carries a clock, so two
        // screenshots of the identically-rendered screen a minute apart differ in
        // a few hundred pixels and compare unequal. Averaging the whole frame to
        // one number ignores the clock and cannot ignore an inverted app —
        // measured on this app, light pages sit near 0.93 and dark ones near
        // 0.10.
        // **Only against a configuration whose *appearance* differs.** Mean
        // luminance answers "is this dark mode or not"; it answers nothing about
        // type size, and comparing ax5 with light on that axis is a false
        // positive waiting to happen — measured immediately, on the session
        // filter sheet, whose light and ax5 frames are a pale sheet over a dimmed
        // list either way and land within 0.02 of each other while differing in
        // every line of layout.
        // **Two measures, and either one matching is enough**, because the whole
        // frame on its own has a measured blind spot: `iPad/dark/session-detail`
        // survived a sweep in which all 65 of its neighbours were correctly
        // deleted. That screen is a replay player showing a recorded white web
        // page, so it reads 0.96 in light — *brighter* than a normal light page
        // at 0.93 — and the dishonest dark copy landed 0.03 away from its light
        // twin instead of the usual 0.83. One light-mode screenshot in a
        // directory called `dark/` is exactly the output this check exists to
        // prevent, and it shipped.
        //
        // The status-bar strip is the fix and it is the right measure for the
        // question: the clock and the battery are system chrome, they are drawn
        // in the *window's* appearance rather than the app's, and no amount of
        // app content can brighten or darken them. Measured on this app: black
        // glyphs over cream sit near 0.9, white glyphs over near-black near 0.1,
        // on every screen including the replay.
        let brightness = Sample(
            whole: meanLuminance(of: data, topFraction: 1),
            chrome: meanLuminance(of: data, topFraction: 0.035)
        )
        let match = previous.first {
            $0.key.screen == name
                && $0.key.configuration.appearance != configuration.appearance
                && (abs($0.value.whole - brightness.whole) < 0.02
                    || abs($0.value.chrome - brightness.chrome) < 0.02)
        }?.key
        previous[Key(screen: name, configuration: configuration)] = brightness

        // Deleted, not just reported. A directory called `dark/` holding a
        // light-mode screenshot is the one output worse than an absent one: the
        // failure is in a log a reviewer may not read, and the image is right
        // there in the folder looking like an answer.
        if match != nil {
            try? FileManager.default.removeItem(at: file)
            captured -= 1
        }
        return match.map(\.configuration.rawValue)
    }

    /// The average brightness of a PNG's top `topFraction`, 0…1.
    ///
    /// Drawn into a 1×1 context, which is CoreGraphics averaging every pixel for
    /// us — cheaper and shorter than walking a buffer, and precise enough for a
    /// question whose two answers are 0.93 and 0.10. The band is selected by
    /// drawing the image into a 1-pixel-tall context scaled so that only the
    /// wanted fraction lands inside it: the destination rect is
    /// `1 / topFraction` tall and anchored so the image's top edge is at the
    /// context's top, and everything below the band falls outside the context
    /// and is clipped rather than averaged.
    ///
    /// 0.035 of an iPhone 17 Pro's 2622px is 92px, which is the status bar and
    /// nothing else — the navigation bar's own content starts below it. On the
    /// iPad landscape captures the frame arrives rotated into a portrait canvas,
    /// so the band is a strip of page rather than the status bar; that is still a
    /// legitimate second sample of the same frame, just a less pointed one, and
    /// the whole-frame measure carries those.
    private static func meanLuminance(of png: Data, topFraction: Double) -> Double {
        guard let image = UIImage(data: png)?.cgImage else { return .nan }
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .nan }
        let height = 1 / max(topFraction, .leastNormalMagnitude)
        // CoreGraphics' origin is bottom-left, so anchoring the image's *top* to
        // the context's top means placing the rect's origin at `1 - height`.
        context.draw(image, in: CGRect(x: 0, y: 1 - height, width: 1, height: height))
        return (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2]))
            / 255
    }

    private struct Key: Hashable {
        let screen: String
        let configuration: Configuration
    }

    /// The whole frame and its top strip. See `capture` for why one is not
    /// enough.
    private struct Sample {
        let whole: Double
        let chrome: Double
    }

    nonisolated(unsafe) private static var previous: [Key: Sample] = [:]

    /// Lets the frame after the data land.
    ///
    /// `DemoTransport` sleeps 120ms per response on purpose so every screen
    /// passes through its loading state; `DemoLaunch.settle` waits that out. The
    /// extra beat is for the chart and list animations that start once the data
    /// is in — a screenshot inside those catches a bar at 40% height, which reads
    /// as a data defect and is not one.
    static func settle(_ app: XCUIApplication) {
        DemoLaunch.settle(app)
        DemoLaunch.pause(0.9)
    }

    nonisolated(unsafe) static var captured = 0
    nonisolated(unsafe) static var failures: [String] = []
}


/// One image in a sequence: a name for the file, and what has to happen to the
/// running app before it can be taken.
///
/// A sequence rather than a single state, because reaching some of these screens
/// is the expensive part and the states are on the way to each other. The replay
/// is the case that forced it: the player has to boot rrweb in a web view and be
/// fed snapshots before anything is on screen — measured at up to two minutes —
/// and the console and network panes are then simply *further down the same
/// scroll view*. Three launches for three images there would be six minutes for
/// content one launch already has.
struct ScreenshotStep {
    let name: String
    /// Returns false when the state could not be reached, which stops the
    /// sequence rather than photographing whatever was underneath. A picture of
    /// the wrong screen filed under the right name is the one output worse than
    /// no output at all.
    let reach: (XCUIApplication) -> Bool

    init(_ name: String, reach: @escaping (XCUIApplication) -> Bool = { _ in true }) {
        self.name = name
        self.reach = reach
    }
}

/// Shared plumbing for both capture classes.
///
/// **One test method per screen**, inherited from `AccessibilityAuditTests` and
/// for the measured reason recorded there: a single method that launched the app
/// 21 times took the runner down with "Restarting after unexpected exit, crash,
/// or test timeout", repeatably and on a different screen each time. Six
/// consecutive launches inside one method were measured fine, so a method here
/// spends at most four — one launch per configuration group, doubled only if the
/// first attempt could not reach the state.
class ScreenshotCase: XCTestCase {

    override func setUp() {
        super.setUp()
        // A capture run is not a pass/fail run: one screen that will not come up
        // must not abandon the other 46.
        continueAfterFailure = true
    }

    override func tearDown() {
        // Never leave the device dark for whatever runs next — including the
        // audit target, if the two are run in one invocation.
        XCUIDevice.shared.appearance = .light
        super.tearDown()
    }

    // MARK: - Capturing

    /// Runs one sequence in every configuration this device is in.
    ///
    /// **Light and dark share a launch; ax5 cannot.** `XCUIDevice.appearance` is
    /// a live trait change the running app answers itself, so dark is a second
    /// screenshot of an app that is already up and already navigated — which
    /// matters most for a multi-step sequence, where re-launching for dark would
    /// mean walking the taps again. `-UIPreferredContentSizeCategoryName` is read
    /// once at start-up and cannot be changed on a running process, so ax5 walks
    /// the sequence itself.
    ///
    /// The appearance is toggled *per step*, not once per run, for the same
    /// reason: after step two the app is somewhere step one's screenshot cannot
    /// be taken from any more.
    func capture(
        launching open: (Screenshot.Configuration) -> XCUIApplication,
        steps: [ScreenshotStep],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // This target sets `continueAfterFailure = true` so one unreachable
        // screen does not abandon the other 46, which means a blocked run would
        // otherwise spend every remaining test waiting out timeouts against an
        // app it never launched. One failure, named, and nothing else attempted.
        guard ExclusiveRun.claim(file: file, line: line) else { return }

        let configurations = Screenshot.Configuration.allCases.filter(\.appliesToThisDevice)
        let riders = configurations.filter { !$0.needsOwnLaunch }

        if !riders.isEmpty {
            run(steps, launching: open, capturing: riders, file: file, line: line)
        }
        for configuration in configurations where configuration.needsOwnLaunch {
            run(steps, launching: open, capturing: [configuration], file: file, line: line)
        }
    }

    /// The common case: a tab root, reached by `GETHOG_TAB` and confirmed by
    /// its **own** navigation title.
    ///
    /// The title wait is load-bearing, and is the constraint this target inherits
    /// wholesale: `GETHOG_TAB` is applied in `RootView.onAppear`, so the app
    /// draws the restored tab first and switches a beat later. A screenshot
    /// inside that beat photographs the previous tab — which, in a directory of
    /// a hundred images, is a defect report written against a screen that was
    /// never on screen.
    func captureRoot(
        _ tab: String,
        titled title: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        capture(
            launching: { Screenshot.launch($0, tab: tab) },
            steps: [ScreenshotStep(tab) { DemoLaunch.wait(for: $0.navigationBars[title]) }],
            file: file,
            line: line
        )
    }

    /// Captures the regular-width detail pane at AX5 without turning the whole
    /// iPad screenshot matrix into a third pass. These overview scenes do not
    /// exist on compact roots, so phone AX5 cannot exercise their composition.
    func captureRootAX5OnIPad(
        _ tab: String,
        titled title: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try XCTSkipUnless(
            Screenshot.isPad,
            "This capture exists for the regular-width iPad detail pane."
        )
        guard ExclusiveRun.claim(file: file, line: line) else { return }
        run(
            [ScreenshotStep(tab) { DemoLaunch.wait(for: $0.navigationBars[title]) }],
            launching: { configuration in
                Screenshot.launch(configuration, tab: tab)
            },
            capturing: [.ax5],
            file: file,
            line: line
        )
    }

    // MARK: Internals

    private func run(
        _ steps: [ScreenshotStep],
        launching open: (Screenshot.Configuration) -> XCUIApplication,
        capturing configurations: [Screenshot.Configuration],
        file: StaticString,
        line: UInt
    ) {
        guard let base = configurations.first else { return }

        // Two attempts, because the failure a retry recovers is the simulator's
        // rather than the app's: `DemoLaunch` records the SQL console rendering
        // nothing at all as the seventeenth launch of a run and passing on its
        // own 4.8 seconds later. A capture is a photograph, not an assertion, so
        // retrying weakens nothing — a screen that never renders is photographed
        // as blank either way.
        for attempt in 1...2 {
            let app = open(base)
            var failed: String?

            for step in steps {
                guard step.reach(app) else { failed = step.name; break }
                Screenshot.settle(app)
                for configuration in configurations {
                    if configuration != base {
                        XCUIDevice.shared.appearance = configuration.appearance
                        // The trait change is delivered asynchronously, and every
                        // material, chart, separator and bar tint in the tree
                        // redraws for it.
                        //
                        // **Currently unreachable, and kept deliberately.** Every
                        // configuration except `light` now sets
                        // `needsOwnLaunch`, so each `run` is handed exactly one
                        // configuration and this branch never fires — see
                        // `needsOwnLaunch` for the measurement that put dark on
                        // its own process. It is the mechanism a *future*
                        // configuration that genuinely is a live trait change
                        // would ride on, and deleting it would mean rediscovering
                        // that a multi-step sequence cannot simply be re-walked.
                        DemoLaunch.pause(2.5)
                    }
                    // **A configuration that did not apply must not look like a
                    // result.** Measured on iPad Pro 11": both mechanisms for
                    // dark — `XCUIDevice.appearance` and the
                    // `-UIUserInterfaceStyle` launch argument — are no-ops there,
                    // and the first sweep produced a `dark/` directory of 36
                    // images byte-identical to `light/`. Nothing failed, nothing
                    // warned, and a reviewer would have concluded the app's dark
                    // mode was fine on iPad having never seen it. Comparing the
                    // bytes is the cheapest possible check, it holds across
                    // separate launches as well as within one, and it turns a
                    // silent wrong answer into a named failure.
                    if let duplicate = Screenshot.capture(
                        step.name, configuration: configuration
                    ) {
                        XCTFail(
                            "'\(step.name)' in \(configuration.rawValue) is indistinguishable "
                                + "from \(duplicate) on this simulator — the "
                                + "configuration did not apply, and the image is not what its "
                                + "directory says it is.",
                            file: file,
                            line: line
                        )
                    }
                }
                if configurations.count > 1 {
                    XCUIDevice.shared.appearance = base.appearance
                    DemoLaunch.pause(1.0)
                }
            }

            guard let failed else { return }
            if attempt == 2 {
                XCTFail(
                    "Could not reach '\(failed)' in \(base.rawValue), twice. "
                        + "Nothing was captured for it, or for anything after it.",
                    file: file,
                    line: line
                )
            }
        }
    }

    // MARK: - Reaching states

    /// Polls a condition instead of building an `XCTNSPredicateExpectation`.
    ///
    /// The same measured reason `DemoLaunch.wait` polls, generalised: a failing
    /// XCTest wait captures a full element debug description on every retry, and
    /// enough of those in a row ends the run rather than failing it. Several
    /// states here are recognised by a *pair* of possible elements — an insight
    /// detail is a sheet with a "Done" button on iPhone and a side panel with a
    /// "Close insight" button on iPad — and no single-element wait can express
    /// that.
    @discardableResult
    func waitUntil(timeout: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            DemoLaunch.pause(0.5)
        }
        return false
    }

    /// Every element whose label begins with a prefix, of any type.
    ///
    /// Prefix rather than equality because almost nothing in this app publishes a
    /// bare title: a tile's label is title + chart summary + freshness, a session
    /// row is person + duration + clicks, a funnel step is
    /// `"Step 2, <name>: <n> people"`. Typed queries are avoided for the reason
    /// `DemoLaunch.elements(labelled:in:)` avoids them — the element type a
    /// SwiftUI control resolves to is an implementation detail, and a capture
    /// must not fail because a row became a `Button` instead of a `Cell`.
    func elements(startingWith prefix: String, in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
    }

    /// Taps an element, scrolling to find it if it is not on screen yet.
    ///
    /// **The wait is short and the scroll is unconditional, and that ordering is
    /// the whole fix.** The first version waited 30 seconds for `exists` and only
    /// scrolled if the element existed but was not hittable — which is precisely
    /// backwards for a `ScrollView`: SwiftUI has not built the rows below the
    /// fold, so they do not *exist* to be waited for, and the wait expired
    /// without a single swipe. Measured against five screens at once — Settings'
    /// "About GetHog", Taxonomy's, Summaries' and Renders' first rows at an
    /// accessibility type size, and Clickmap's saved render — all of which are
    /// simply further down a screen that is working.
    @discardableResult
    func tap(_ element: XCUIElement, timeout: TimeInterval = 12) -> Bool {
        if !DemoLaunch.wait(for: element, timeout: timeout) || !element.isHittable {
            guard scrollIntoView(element) else { return false }
        }
        guard element.isHittable else { return false }
        element.tap()
        // Presentations animate, and the next step's wait would otherwise race
        // the sheet on its way up.
        DemoLaunch.pause(0.8)
        return true
    }

    /// Taps the first element whose label starts with `prefix`.
    @discardableResult
    func tapFirst(startingWith prefix: String, in app: XCUIApplication) -> Bool {
        tap(elements(startingWith: prefix, in: app).firstMatch)
    }

    /// Scrolls until an element is on screen, or gives up.
    ///
    /// Bounded, because an element that is genuinely absent would otherwise
    /// scroll forever, and a capture run that hangs is worse than one that
    /// records a missing image. Swipes the app rather than a located scroll view:
    /// several of these screens nest one inside another, and `swipeUp` on the
    /// window hits whichever is under the finger — which is the one being read.
    @discardableResult
    func scrollIntoView(_ element: XCUIElement, maximumSwipes: Int = 10) -> Bool {
        let app = XCUIApplication()
        for _ in 0..<maximumSwipes {
            // `exists` is re-read every pass rather than captured: the element
            // this is looking for usually does not exist when the loop starts,
            // because SwiftUI builds a `ScrollView`'s rows as they approach the
            // viewport.
            if element.exists && element.isHittable { return true }
            app.swipeUp()
            DemoLaunch.pause(0.5)
        }
        return element.exists && element.isHittable
    }

    /// Scrolls until an element is near the **top** of the window, not merely
    /// present in it.
    ///
    /// `scrollIntoView` answers "can this be tapped", which is the wrong
    /// question for a screenshot. Measured: `replay-network` was
    /// **byte-identical** to `replay-console` in three of the five
    /// device/configuration directories, because the replay page draws Console
    /// and Network as sibling cards and by the time Console is on screen the
    /// Network header is already just inside the bottom edge — so
    /// `scrollIntoView` found it `exists && isHittable` on its first pass, swiped
    /// nothing, and the second capture photographed the first one's frame. Three
    /// directories held a file called `replay-network` that was a picture of the
    /// console, which is the exact failure `Screenshot.capture`'s duplicate check
    /// exists to prevent and could not see, because it only compares across
    /// *configurations* of one screen and never across two screens.
    ///
    /// The threshold is a fraction of the window rather than a fixed inset
    /// because the caller is aiming at a section header whose own height is a
    /// function of the type size — at AX5 a `SectionLabel` is several times its
    /// default height, and an absolute 100pt would be satisfied by a header still
    /// mostly off-screen.
    @discardableResult
    func scrollToHeadOfPage(
        _ element: XCUIElement,
        within fraction: CGFloat = 0.4,
        maximumSwipes: Int = 12
    ) -> Bool {
        let app = XCUIApplication()
        guard scrollIntoView(element, maximumSwipes: maximumSwipes) else { return false }
        let ceiling = app.frame.height * fraction
        for _ in 0..<maximumSwipes {
            // Re-read every pass: the frame is what the swipe is changing, and a
            // captured value would loop forever or stop immediately.
            let before = element.frame.minY
            if before <= ceiling { return true }
            app.swipeUp()
            DemoLaunch.pause(0.5)
            guard element.exists else { return false }
            // A swipe at the end of a scroll view moves nothing. The element may
            // legitimately have nowhere further to go — the last card on a page
            // cannot reach the top of the window — and swiping eleven more times
            // to discover that costs six seconds per configuration. The caller
            // still gets a frame showing it, just not at the top.
            if abs(element.frame.minY - before) < 1 { return true }
        }
        return element.exists
    }

    /// Goes back to a named root, by whichever route this device has.
    ///
    /// **The interactive pop gesture is not one of them, and that is the
    /// measurement.** `app.swipeRight()` was what the two multi-step sequences
    /// here used, on the recorded grounds that this app's back control "is a
    /// floating chevron that is not a child of the bar element". The second half
    /// of that is true — `navigationBars.buttons` does come back empty — but the
    /// conclusion drawn from it was not: `session-playlist-saved-filter` was
    /// missing from **every** directory on both devices in two full sweeps, and
    /// the runner's log shows the swipe firing and the wait for the root's bar
    /// then spending its full timeout. `XCUIElement.swipeRight` starts near the
    /// element's centre, and the system back gesture is an *edge* pan, so a
    /// centre swipe scrolls whatever is under it and pops nothing.
    ///
    /// The chevron does have an identifier — `BackButton`, read out of an
    /// element dump of the dashboard detail, at (16, 62) 44×44 — so it can be
    /// tapped like any other control. The swipe is kept as a fallback rather
    /// than deleted, because a screen that does not use the standard control
    /// would otherwise have no route at all.
    ///
    /// Returns true when the root is on screen, **including when it never left**
    /// — on iPad a list/detail root is a column that a push does not replace, so
    /// "already there" is the correct answer and not a failure to navigate.
    @discardableResult
    func popToRoot(_ app: XCUIApplication, titled title: String, attempts: Int = 3) -> Bool {
        for _ in 0..<attempts {
            if app.navigationBars[title].exists { return true }
            let back = app.buttons["BackButton"]
            if back.exists && back.isHittable {
                back.tap()
            } else {
                app.swipeRight()
            }
            DemoLaunch.pause(1.0)
        }
        return app.navigationBars[title].exists
    }

    /// Scrolls back to the top of whatever is under the finger.
    ///
    /// `scrollIntoView` only ever swipes **up**, so it can reach something below
    /// the fold and never something above it. A sequence that photographs the
    /// bottom of a screen and then needs a control near the top — the error
    /// issue's triage buttons, after its stack-trace section — has to come back
    /// first, and at an accessibility type size "back" can be several screens.
    func scrollToTop(swipes: Int = 12) {
        let app = XCUIApplication()
        for _ in 0..<swipes {
            app.swipeDown()
            DemoLaunch.pause(0.3)
        }
    }
}
