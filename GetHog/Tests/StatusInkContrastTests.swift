import SwiftUI
import Testing
import UIKit

@testable import GetHog

/// Contrast of the word inside a `StatusPill`, measured rather than eyeballed.
///
/// The pill drew its word in the tint over a 15% wash of that same tint, which
/// put `Theme.Status.critical` at 3.25:1 in light and 4.21:1 in dark against a
/// 4.5:1 AA floor — a status word that is hard to read defeating the very
/// mechanism it exists to be. `Theme.Status.ink(for:)` is the fix, and this
/// suite is here because the fix is a lookup: if it ever stops recognising a
/// tint it degrades quietly to a legible neutral rather than crashing, so
/// nothing on screen would announce the regression.
@Suite("Status ink contrast")
struct StatusInkContrastTests {

    /// Every tint the app hands to a pill, with the alpha it carries.
    /// `.secondary` is the system's, at 0.6, which is why its wash is 9% and
    /// not 15%.
    private static let pillTints: [(name: String, tint: Color)] = [
        ("critical", Theme.Status.critical),
        ("good", Theme.Status.good),
        ("warning", Theme.accentWarm),
        ("accent", Theme.accent),
        ("neutral", .secondary),
    ]

    private static let surfaces: [(name: String, color: Color)] = [
        ("card", Theme.cardBackground),
        ("page", Theme.pageBackground),
    ]

    private static let appearances: [UIUserInterfaceStyle] = [.light, .dark]

    /// The floor this whole change exists to clear: AA for text below 18pt.
    @Test("A pill's word clears 4.5:1 on both grounds, in both appearances")
    func wordClearsAA() {
        for (name, tint) in Self.pillTints {
            for (surfaceName, surface) in Self.surfaces {
                for style in Self.appearances {
                    let chip = Pixel(tint, style)
                        .over(Pixel(surface, style), alpha: 0.15)
                    let word = Pixel(Theme.Status.ink(for: tint), style).over(chip)
                    #expect(
                        word.contrast(with: chip) >= 4.5,
                        "\(name) on \(surfaceName) in \(style == .light ? "light" : "dark")"
                    )
                }
            }
        }
    }

    /// The lookup falls back to a legible neutral, so a tint it fails to
    /// recognise still passes the test above. This is what would actually catch
    /// that: each named tint has to come back with an ink of its own.
    @Test("Each named tint resolves to its own ink, not the neutral fallback")
    func namedTintsKeepTheirHue() {
        let pairs: [(Color, Color)] = [
            (Theme.Status.critical, Theme.Status.criticalInk),
            (Theme.Status.good, Theme.Status.goodInk),
            (Theme.accentWarm, Theme.Status.warningInk),
            (Theme.accent, Theme.Status.accentInk),
        ]
        for (tint, expected) in pairs {
            for style in Self.appearances {
                #expect(Pixel(Theme.Status.ink(for: tint), style) == Pixel(expected, style))
            }
        }
    }

    /// A tint nobody measured — a series colour, say — must not silently take
    /// the failing path. `Theme.Ink.secondary` clears 5.64:1 against the darkest
    /// chip in the set, so the fallback is legible by construction.
    @Test("An unrecognised tint falls back to the measured neutral ink")
    func unknownTintFallsBack() {
        let stray = SeriesPalette.color(at: 3)
        for style in Self.appearances {
            #expect(Pixel(Theme.Status.ink(for: stray), style) == Pixel(Theme.Ink.secondary, style))

            let chip = Pixel(stray, style).over(Pixel(Theme.pageBackground, style), alpha: 0.15)
            #expect(Pixel(Theme.Ink.secondary, style).over(chip).contrast(with: chip) >= 4.5)
        }
    }

    /// The marks were deliberately left alone, and this is the floor that lets
    /// them stay: WCAG asks 3:1 of a glyph, a bar or a chart rule, not 4.5:1.
    /// Darkening them to text weight would have cost the separation between
    /// states that a chart mark has instead of a word.
    @Test("Mark tints still clear the 3:1 non-text floor")
    func marksClearNonTextFloor() {
        for (name, tint) in Self.pillTints {
            for (surfaceName, surface) in Self.surfaces {
                for style in Self.appearances {
                    let ground = Pixel(surface, style)
                    let mark = Pixel(tint, style).over(ground)
                    #expect(
                        mark.contrast(with: ground) >= 3.0,
                        "\(name) on \(surfaceName) in \(style == .light ? "light" : "dark")"
                    )
                }
            }
        }
    }
}

/// One resolved sRGB sample, so a colour's contrast can be measured in the
/// appearance it will actually be drawn in rather than assumed from its light
/// value.
private struct Pixel: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(_ color: Color, _ style: UIUserInterfaceStyle) {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        (red, green, blue, alpha) = (Double(r), Double(g), Double(b), Double(a))
    }

    private init(red: Double, green: Double, blue: Double) {
        (self.red, self.green, self.blue, self.alpha) = (red, green, blue, 1)
    }

    /// Composites in gamma space, which is what the renderer does — compositing
    /// in linear light would report ratios the screen never shows.
    func over(_ background: Pixel, alpha overrideAlpha: Double? = nil) -> Pixel {
        let a = (overrideAlpha ?? 1) * alpha
        return Pixel(
            red: red * a + background.red * (1 - a),
            green: green * a + background.green * (1 - a),
            blue: blue * a + background.blue * (1 - a)
        )
    }

    private var luminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    func contrast(with other: Pixel) -> Double {
        let (high, low) = (max(luminance, other.luminance), min(luminance, other.luminance))
        return (high + 0.05) / (low + 0.05)
    }
}
