import GetHogKit
import SwiftUI
import Testing
import UIKit

@testable import GetHog

/// What colour a screen is actually painted, sampled from a render.
///
/// A screenshot sweep of the running app found twelve of thirty-five roots —
/// `actions`, `annotations`, `clickmap`, `earlyAccess`, `experiments`, `health`,
/// `inbox`, `max`, `notebooks`, `pipelines`, `signals`, `warehouse` — sampling
/// `#FFFFFF` in light and `#000000` in dark where the other twenty-three sampled
/// the app's `#F2EFE9` / `#151413`. The same twelve on iPhone and on iPad, in
/// both appearances, which is what said it was one defect and not twelve: every
/// one of them was showing an empty state, and `pageSurface()` was applied to the
/// `List` branch that was not on screen.
///
/// The nature of that bug is that nothing announces it. Every screen compiles,
/// every screen lays out, and the wrong ground is only wrong next to a right one
/// — so it survived a review of all thirty-five screens and was found by a
/// camera. These tests are that camera, at the one resolution a unit test can
/// afford: render the shared pieces and read the pixels back.
@Suite("Page ground")
@MainActor
struct PageGroundTests {

    private static let appearances: [(name: String, scheme: ColorScheme, style: UIUserInterfaceStyle)] = [
        ("light", .light, .light),
        ("dark", .dark, .dark),
    ]

    // MARK: - The whole-screen states

    /// The defect itself. `EmptyStateView` is what all twelve were rendering.
    @Test("an empty state is painted on the app ground, not the system background")
    func emptyStateIsOnTheGround() throws {
        for (name, scheme, style) in Self.appearances {
            let corners = try corners(
                of: EmptyStateView(
                    title: "Nothing to triage",
                    systemImage: "tray",
                    message: "Tasks appear here when a scout or a signal report files one."
                ),
                scheme
            )
            expectGround(corners, style, "empty state in \(name)")
        }
    }

    /// The other view that replaces a whole screen. Not in the sampled twelve
    /// only because the demo key is not missing any scope.
    @Test("a locked capability state is painted on the app ground")
    func lockedStateIsOnTheGround() throws {
        for (name, scheme, style) in Self.appearances {
            let corners = try corners(
                of: LockedCapabilityView(capability: .sessions, scope: "session_recording:read"),
                scheme
            )
            expectGround(corners, style, "locked state in \(name)")
        }
    }

    /// This one stacks the authored fault *below* the empty state, so the ground
    /// has to be claimed by the stack rather than by the state view inside it.
    @Test("a load failure state is painted on the app ground under its detail too")
    func failureStateIsOnTheGround() throws {
        for (name, scheme, style) in Self.appearances {
            let corners = try corners(
                of: LoadFailureState(
                    title: "Couldn't load insights",
                    failure: LoadFailure(summary: "The request timed out.", detail: "code: timeout")
                ),
                scheme
            )
            expectGround(corners, style, "failure state in \(name)")
        }
    }

    // MARK: - The structural guarantee

    /// The part that stops a thirteenth screen doing it.
    ///
    /// Every root applies `projectSubtitle()` — it is how the screen names the
    /// project whose numbers it is showing, which this app treats as a
    /// correctness requirement rather than a decoration — and that modifier now
    /// lays the ground under the *whole body*, before any branching. The view
    /// under test here paints nothing at all: if the ground came from the branch
    /// rather than from the chrome, this render would come back transparent, and
    /// transparent is exactly what the twelve screens were showing through.
    @Test("a screen whose content paints nothing is still on the app ground")
    func chromeCarriesTheGround() throws {
        let model = AppModel(store: InMemoryTokenStore(), transport: DemoTransport())
        for (name, scheme, style) in Self.appearances {
            let corners = try corners(
                of: Color.clear.projectSubtitle().environment(model),
                scheme
            )
            expectGround(corners, style, "bare screen chrome in \(name)")
        }
    }

    // MARK: - Harness

    private static let size = CGSize(width: 320, height: 400)

    /// The four corner pixels of a render, which is where a state view's own
    /// content never reaches — `ContentUnavailableView` centres everything it
    /// draws, so a corner is the ground or it is nothing.
    private func corners(of view: some View, _ scheme: ColorScheme) throws -> [Pixel] {
        let renderer = ImageRenderer(
            content: view
                .frame(width: Self.size.width, height: Self.size.height)
                .environment(\.colorScheme, scheme)
        )
        renderer.scale = 1
        let cg = try #require(renderer.uiImage?.cgImage, "the view produced no image at all")

        let width = cg.width
        let height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(
            CGContext(
                data: &bytes,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Two pixels in from each edge: the outermost row can carry an
        // antialiased edge from the frame itself.
        let inset = 2
        return [(inset, inset), (width - 1 - inset, inset),
                (inset, height - 1 - inset), (width - 1 - inset, height - 1 - inset)]
            .map { x, y in
                let offset = (y * width + x) * 4
                return Pixel(
                    red: Int(bytes[offset]),
                    green: Int(bytes[offset + 1]),
                    blue: Int(bytes[offset + 2]),
                    alpha: Int(bytes[offset + 3])
                )
            }
    }

    /// Asserts the render matches `Theme.pageBackground`, and — separately —
    /// that it is not the system background it was measured as. Both, because
    /// they fail for different reasons: the first catches a wrong token, the
    /// second catches no token at all, which is the bug that happened.
    private func expectGround(
        _ corners: [Pixel],
        _ style: UIUserInterfaceStyle,
        _ what: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let ground = Pixel(Theme.pageBackground, style)
        let system = Pixel(Color(uiColor: .systemBackground), style)
        for corner in corners {
            #expect(
                corner.matches(ground),
                "\(what): sampled \(corner), expected the app ground \(ground)",
                sourceLocation: sourceLocation
            )
            #expect(
                !corner.matches(system),
                "\(what): sampled the system background \(system)",
                sourceLocation: sourceLocation
            )
        }
    }
}

/// One 8-bit sRGB sample.
private struct Pixel: CustomStringConvertible {
    var red: Int
    var green: Int
    var blue: Int
    var alpha: Int

    init(red: Int, green: Int, blue: Int, alpha: Int) {
        (self.red, self.green, self.blue, self.alpha) = (red, green, blue, alpha)
    }

    /// The value a token resolves to in a given appearance, for comparison with
    /// what came out of the renderer.
    init(_ color: Color, _ style: UIUserInterfaceStyle) {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ channel: CGFloat) -> Int { Int((channel * 255).rounded()) }
        (red, green, blue, alpha) = (byte(r), byte(g), byte(b), byte(a))
    }

    /// Within one step per channel. The render round-trips through a device RGB
    /// context, so an exact match would be asserting something about colour
    /// management rather than about the design system — while the failure this
    /// guards against is ~13 steps away in light and ~21 in dark.
    func matches(_ other: Pixel) -> Bool {
        abs(red - other.red) <= 1
            && abs(green - other.green) <= 1
            && abs(blue - other.blue) <= 1
            && abs(alpha - other.alpha) <= 1
    }

    var description: String {
        alpha == 255
            ? String(format: "#%02X%02X%02X", red, green, blue)
            : String(format: "#%02X%02X%02X at alpha %d", red, green, blue, alpha)
    }
}
