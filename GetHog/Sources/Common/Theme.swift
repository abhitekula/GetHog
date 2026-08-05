import SwiftUI
import UIKit

/// Visual system.
///
/// Deliberately restrained: chrome stays monochrome and semantic so light and
/// dark come free, and colour is reserved almost entirely for chart series and
/// status. Dense dashboards need calm surroundings.
enum Theme {

    /// App tint. Chosen deliberately away from PostHog's blue/orange, both for
    /// trademark distance and so the app never reads as first-party.
    static let accent = Color(
        light: Color(red: 0.043, green: 0.431, blue: 0.459),   // #0B6E75 deep teal
        dark: Color(red: 0.243, green: 0.773, blue: 0.808)     // #3EC5CE
    )

    /// Warm off-white rather than the system's cool grey.
    ///
    /// Borrowed from PostHog's console, which grounds everything on a cream
    /// paper tone. It is the single change that stops the app reading as a
    /// default-styled iOS shell, and it makes a plain white card look like a
    /// deliberate surface instead of the absence of one.
    static let pageBackground = Color(
        light: Color(hex: 0xF2EFE9),
        dark: Color(hex: 0x151413)
    )

    /// Cards stay near-white so data sits on the highest-contrast surface
    /// available; the page tone is what does the work of separating them.
    static let cardBackground = Color(
        light: Color(hex: 0xFFFFFF),
        dark: Color(hex: 0x1F1E1C)
    )

    /// Neutral letterbox behind locally rendered session replays.
    static let replayStageBackground = Color.black

    /// Warm border, a shade darker than the page.
    ///
    /// Load-bearing rather than decorative: a white card on a pale ground has no
    /// edge of its own, and the hard-offset shadow below hangs off this line.
    static let hairline = Color(
        light: Color(hex: 0xDDD6C9),
        dark: Color(hex: 0x38342F)
    )

    /// Supporting text, in two steps that both clear WCAG AA.
    ///
    /// This exists because the system's semantic label colours do not clear it on
    /// this app's own surfaces, which was measured rather than assumed. They are
    /// alpha composites — `secondaryLabel` is `rgba(60,60,67,0.6)`, `tertiaryLabel`
    /// the same ink at `0.3` — so their contrast is a function of whatever they sit
    /// on, and on a near-white card that lands at:
    ///
    /// | | light card `#FFFFFF` | light page `#F2EFE9` | dark card `#1F1E1C` |
    /// |---|---|---|---|
    /// | `.secondary` | **3.44:1** | **3.26:1** | 5.88:1 |
    /// | `.tertiary`  | **1.73:1** | **1.70:1** | **2.48:1** |
    ///
    /// AA wants 4.5:1 for text this size, so three of those six fail and the worst
    /// is less than half the floor. The failure was found on screen first — an
    /// earlier pass moved `DataRow`'s footnote off `.tertiary` (measured 1.84:1)
    /// onto `.secondary` and predicted that `.secondary` would fail the same
    /// audit; it did, on two devices.
    ///
    /// So supporting text gets colours of its own rather than borrowing the
    /// system's. Opaque, not alpha, so a call site's ratio does not depend on what
    /// it happens to be layered over. Warm rather than neutral grey, because a
    /// neutral goes visibly cold against the cream ground.
    ///
    /// The ramp is still three steps — `.primary` at 21:1, these two beneath it —
    /// so hierarchy survives the fix. What changes is that the bottom step now
    /// recedes by being *lighter than the text above it* rather than by being
    /// too faint to read.
    enum Ink {
        /// 7.98:1 on `cardBackground`, 6.95:1 on `pageBackground`;
        /// 9.14:1 and 10.09:1 in dark. Replaces `.secondary` on text.
        static let secondary = Color(
            light: Color(hex: 0x55504A),
            dark: Color(hex: 0xC6BFB5)
        )

        /// 5.97:1 on `cardBackground`, 5.20:1 on `pageBackground`;
        /// 5.57:1 and 6.15:1 in dark. Replaces `.tertiary` on text.
        ///
        /// Deliberately not parked on the 4.5:1 line: the ratios above are
        /// computed on the flat colours, and rendered glyphs are antialiased
        /// against the surface, so a value that clears exactly can measure under.
        static let tertiary = Color(
            light: Color(hex: 0x6B6259),
            dark: Color(hex: 0x9C948A)
        )
    }

    /// The label on top of a slab painted `Theme.accent`.
    ///
    /// **The accent is an ink colour, not a fill colour, and this is the bill
    /// for using it as one.** `accent` was chosen so it reads *on* the ground;
    /// in dark that makes it a light cyan, and SwiftUI's `.borderedProminent`
    /// and `.glassProminent` both draw a **white** label on it by default.
    /// Sampled off the rendered screen — `render-detail.png`, iPhone 17 Pro,
    /// the "Play" button — that is `#FFFFFF` on `#3CC5CE` for **2.09:1**, less
    /// than half the 4.5:1 AA floor for text this size. Light is fine at
    /// **6.00:1** (`#FFFFFF` on `#0B6E75`), which is why it survived a
    /// light-only reading of eleven separate buttons.
    ///
    /// **Why the token and not eleven local fixes.** Eleven is what there are,
    /// and four of them had already been corrected in place — three in
    /// onboarding, one in Tracing — each with its own literal and its own copy
    /// of the comment. That is the shape a rule takes when it lives at call
    /// sites: it drifts, and the next prominent button starts white again
    /// because nothing in `Theme` says otherwise. One named token is the thing a
    /// new call site can be pointed at.
    ///
    /// **Two constraints, not one.** The first correction reached for
    /// `pageBackground`, which fixes dark (`#151413` on `#3EC5CE`, **8.83:1**,
    /// sampled on the rendered "Run" and "Get started" buttons) and costs light:
    /// `#F2EFE9` on `#0B6E75` is **5.23:1**, still AA but a move *down* from
    /// white's 6.00:1 on the one appearance that was never broken. That 5.23 is
    /// the one figure here computed rather than sampled — it is the ratio
    /// between two independently sampled colours, the ground off this screen and
    /// `pageBackground` off the session filter sheet — because the intermediate
    /// state it describes is not what any current build renders. So the value is
    /// picked per appearance:
    ///
    /// | | ink | on accent | ratio |
    /// |---|---|---|---|
    /// | light | `#FFFFFF` | `#0B6E75` | **6.00:1** — unchanged |
    /// | dark  | `#151413` | `#3EC5CE` | **8.83:1** — was 2.08:1 |
    ///
    /// In light, white is not merely acceptable, it is *optimal*: `#0B6E75` has
    /// a relative luminance of 0.128, so the best a dark ink can reach on it is
    /// 3.55:1 against pure black — below the floor. Light must stay light and
    /// dark must go dark, which is exactly what a `Color(light:dark:)` is for.
    ///
    /// **Written as literals rather than as `cardBackground` / `pageBackground`,
    /// which they currently equal.** Those two are surface tokens; re-tuning the
    /// cream ground half a step is a legitimate change to make to them and must
    /// not silently move a button label's contrast. This token has one job and
    /// one measurement, so it owns its own values.
    ///
    /// `Theme.swift` compiles into `GetHogWidgets` as well, so this is
    /// reachable there — but nothing in that target has the defect: there is no
    /// `.borderedProminent`/`.glassProminent` and no label drawn over an accent
    /// fill anywhere in `GetHogWidgets/`. See the note on
    /// `WidgetPalette.accent`.
    static let inkOnAccent = Color(
        light: Color(hex: 0xFFFFFF),
        dark: Color(hex: 0x151413)
    )

    /// A second accent for chrome that needs warmth without competing with the
    /// data — badges, small-caps section headers, selected pills.
    static let accentWarm = Color(
        light: Color(hex: 0xC2410C),
        dark: Color(hex: 0xEA8C4F)
    )

    enum SignalChrome {
        static let teal = Theme.accent
        static let coral = Theme.accentWarm
        static let clay = Color(
            light: Color(hex: 0x865A3B),
            dark: Color(hex: 0xD6A178)
        )
        static let ink = Theme.Ink.tertiary

        static let all = [teal, coral, clay, ink]
    }

    /// Glass tint for a control in its **selected** state.
    ///
    /// The only tint the app applies to glass, and it carries meaning: this
    /// control is on. Apple's guidance is explicit that tint is for primary
    /// actions with semantic weight, not decoration — an earlier version of
    /// this file tinted *every* glass surface warm to match the cream ground,
    /// which is precisely the decorative use that rule prohibits and is a large
    /// part of why the chrome read as almost-but-not-quite native.
    ///
    /// Warmth now lives entirely in the content layer — ground, cards,
    /// hairlines — and the navigation layer is left as system glass.
    static let glassActiveTint = Color(
        light: Color(red: 0.043, green: 0.431, blue: 0.459).opacity(0.16),
        dark: Color(red: 0.243, green: 0.773, blue: 0.808).opacity(0.20)
    )

    /// Type scale. Four sizes and two weights, deliberately — every extra size
    /// buys a little emphasis and costs a lot of coherence, and a dense
    /// analytics screen is exactly where that trade goes bad.
    ///
    /// All of them are semantic, so Dynamic Type works without per-screen care.
    enum Typography {
        /// Big numbers. Rounded because it reads as a figure rather than prose,
        /// and monospaced digits so a value updating in place doesn't reflow.
        static let metric = Font.system(.largeTitle, design: .rounded, weight: .semibold)
            .monospacedDigit()
        /// A smaller metric, for tiles that sit several to a row.
        static let metricSmall = Font.system(.title2, design: .rounded, weight: .semibold)
            .monospacedDigit()
        static let title = Font.headline
        static let body = Font.subheadline
        static let caption = Font.caption
    }

    /// One spacing scale, so rhythm is consistent rather than per-screen taste.
    /// Multiples of 4, which is what the system's own metrics are built on.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// Corner radii, always drawn `.continuous`. The system's own shapes use
    /// continuous curvature; a circular radius next to them reads as subtly
    /// wrong even when nobody can say why.
    enum Radius {
        static let small: CGFloat = 10
        static let medium: CGFloat = 16
        static let large: CGFloat = 22
    }

    /// Depth as a hard offset rather than a blur.
    ///
    /// Also from PostHog's console: its surfaces drop a tight, barely-blurred
    /// shadow straight down, so a card reads as a physical card sitting on
    /// paper. A soft radial blur reads as a slide-deck drop shadow instead, and
    /// at these small sizes it just muddies the edge. The tint is warm because a
    /// neutral black shadow on a cream ground goes visibly grey.
    struct Elevation {
        let ambient: (color: Color, radius: CGFloat, y: CGFloat)
        let key: (color: Color, radius: CGFloat, y: CGFloat)

        static let card = Elevation(
            ambient: (Color(light: Color(hex: 0x4A3F2F).opacity(0.10), dark: .black.opacity(0.5)), 0, 1.5),
            key: (Color(light: Color(hex: 0x4A3F2F).opacity(0.06), dark: .black.opacity(0.35)), 6, 3)
        )
        static let raised = Elevation(
            ambient: (Color(light: Color(hex: 0x4A3F2F).opacity(0.14), dark: .black.opacity(0.6)), 0, 2),
            key: (Color(light: Color(hex: 0x4A3F2F).opacity(0.10), dark: .black.opacity(0.45)), 14, 7)
        )
    }

    /// Status colour, in two weights: a **mark** and an **ink**.
    ///
    /// The marks below are for things that are not words — the glyph tile that
    /// leads a row, a usage bar, a chart rule, a card's accent stripe. WCAG's
    /// floor for those is 3:1 and they clear it; `critical` is the tightest at
    /// 3.95:1 on `cardBackground`, 3.44:1 on `pageBackground`.
    ///
    /// They are not text colours, and that is not academic. A `StatusPill` drew
    /// its word in the tint over a 15% wash of the same tint, which measured:
    ///
    /// | | light card | light page | dark card | dark page |
    /// |---|---|---|---|---|
    /// | `critical`   | **3.25:1** | **2.87:1** | **4.21:1** | 4.71:1 |
    /// | `good`       | **4.00:1** | **3.52:1** | 5.18:1 | 5.82:1 |
    /// | `accentWarm` | **4.16:1** | **3.67:1** | 5.15:1 | 5.79:1 |
    /// | `accent`     | 4.82:1 | **4.24:1** | 6.02:1 | 6.78:1 |
    /// | `.secondary` | **3.24:1** | **3.07:1** | 5.06:1 | 5.49:1 |
    ///
    /// Ten of those twenty are under the 4.5:1 AA floor for text this size — on
    /// the one word in the app whose whole job is to state a state without
    /// relying on colour. A status word that is hard to read defeats the
    /// mechanism it is.
    ///
    /// The wash cannot fix it. The word *is* the tint, so the palest chip
    /// possible is a white one, and even there `critical` tops out at 3.95:1;
    /// a heavier wash moves the wrong way (2.53:1 at 25%).
    ///
    /// Nor can darkening the marks. Solving each tint so that it clears 4.5:1
    /// against a wash of *itself* lands all four on one luminance, and the
    /// separation between states — 1.05:1 to 1.74:1 today — collapses to
    /// 1.00:1. That separation is the only thing a chart mark has when red and
    /// green arrive at the same hue, and unlike a pill it has no word beside it.
    /// It would also drag a 3pt bar to 6.46:1 against a card to settle an
    /// argument about a 9pt word.
    ///
    /// So the marks keep their values and words take `ink(for:)`.
    enum Status {
        static let good = Color(
            light: Color(red: 0.0, green: 0.514, blue: 0.0),
            dark: Color(red: 0.212, green: 0.729, blue: 0.404)
        )
        static let critical = Color(
            light: Color(red: 0.890, green: 0.286, blue: 0.282),
            dark: Color(red: 0.902, green: 0.404, blue: 0.404)
        )

        // Text-weight partners: each mark's own hue and saturation, moved to the
        // value that clears 5.0:1 on the darker of the two grounds a pill sits
        // on. Deliberately not parked on 4.5:1, for the reason `Theme.Ink`
        // gives — the ratios are computed on flat colour and a rendered glyph is
        // antialiased into the chip beneath it.
        //
        // Light is where the work was needed. In dark the mark is already
        // text-weight, so `good`, `warning` and `accent` resolve to the mark
        // itself and only `critical`, at 4.21:1, needs a lighter partner.

        /// 5.70:1 / 5.02:1 on its chip, card and page.
        static let goodInk = Color(light: Color(hex: 0x006800), dark: good)

        /// 5.66:1 / 4.99:1 light; 5.14:1 / 5.75:1 dark, up from 4.21:1 / 4.71:1.
        static let criticalInk = Color(
            light: Color(hex: 0xA13433),
            dark: Color(hex: 0xF37B7B)
        )

        /// Partner to `Theme.accentWarm`, the warning tint. 5.68:1 / 5.01:1.
        static let warningInk = Color(light: Color(hex: 0x9E350A), dark: Theme.accentWarm)

        /// Partner to `Theme.accent`, which pills use for in-flight states.
        /// 5.70:1 / 5.02:1 — it was the one tint that cleared AA on a card, and
        /// it still failed on the page at 4.24:1.
        static let accentInk = Color(light: Color(hex: 0x0A6268), dark: Theme.accent)

        /// The ink that belongs with a pill's tint.
        ///
        /// Keyed on the resolved colour rather than on token identity, so a call
        /// site that spells the same tint a different way is not silently left
        /// with the failing one. Anything unrecognised — including `.secondary`,
        /// which is what the app's neutral pills carry — takes
        /// `Theme.Ink.secondary`: it measures 5.64:1 or better against every
        /// chip in the table above, so the fallback is legible by construction
        /// rather than by luck. It gives up the word's hue, which is why the
        /// four tints that carry severity are named here instead.
        static func ink(for tint: Color) -> Color {
            inkByTint[swatchKey(tint)] ?? Theme.Ink.secondary
        }

        private static let inkByTint: [UInt32: Color] = [
            swatchKey(good): goodInk,
            swatchKey(critical): criticalInk,
            swatchKey(Theme.accentWarm): warningInk,
            swatchKey(Theme.accent): accentInk,
        ]

        /// Packs a colour's light-appearance sRGB into a comparable key. Light
        /// specifically, because that is the appearance in which the tints are
        /// furthest apart, and it makes the lookup independent of the appearance
        /// the pill happens to be drawn in.
        private static func swatchKey(_ color: Color) -> UInt32 {
            let resolved = UIColor(color)
                .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 0 }
            func byte(_ channel: CGFloat) -> UInt32 {
                UInt32(min(max((channel * 255).rounded(), 0), 255))
            }
            return byte(red) << 24 | byte(green) << 16 | byte(blue) << 8 | byte(alpha)
        }
    }
}

/// Categorical series palette.
///
/// This is the validated reference palette from the `dataviz` skill: eight hues
/// selected per mode (the dark column is the same hues re-stepped for a dark
/// surface, not an automatic flip). Verified with the skill's validator —
/// lightness band, chroma floor, CVD separation and normal-vision floor all pass
/// in both modes.
///
/// Three light-mode hues sit below 3:1 against the light surface, so the
/// **relief rule** applies: charts using them always ship a legend and direct
/// labels, never colour alone.
enum SeriesPalette {
    /// Slot order is a brand decision, not alphabetical: slot 0 is what every
    /// single-series tile in the app is painted, which makes it the app's most
    /// visible colour after the accent itself. It used to be the blue — so the
    /// home tab opened on two large stock-blue charts inside teal chrome, the
    /// single loudest generic-by-default tell in two independent design
    /// sweeps. The aqua leads now: it is the palette's teal-family hue, so a
    /// chart reads as this app's before a single label is read. The hues
    /// themselves are unchanged — same validated set, same relief rule — and
    /// the yellow keeps slot 3, which `StatusInkContrastTests` samples.
    private static let light: [Color] = [
        Color(hex: 0x1BAF7A),  // aqua
        Color(hex: 0xEB6834),  // orange
        Color(hex: 0x2A78D6),  // blue
        Color(hex: 0xEDA100),  // yellow
        Color(hex: 0xE87BA4),  // magenta
        Color(hex: 0x008300),  // green
        Color(hex: 0x4A3AA7),  // violet
        Color(hex: 0xE34948),  // red
    ]

    private static let dark: [Color] = [
        Color(hex: 0x199E70),
        Color(hex: 0xD95926),
        Color(hex: 0x3987E5),
        Color(hex: 0xC98500),
        Color(hex: 0xD55181),
        Color(hex: 0x008300),
        Color(hex: 0x9085E9),
        Color(hex: 0xE66767),
    ]

    static let slotCount = 8

    /// Colour follows the entity's fixed slot, never its rank — filtering a
    /// series list must not repaint the survivors.
    static func color(at index: Int) -> Color {
        let slot = index % slotCount
        return Color(light: light[slot], dark: dark[slot])
    }

    /// Secondary encoding so identity never rests on hue alone.
    static func symbol(at index: Int) -> String {
        let symbols = ["circle.fill", "square.fill", "triangle.fill", "diamond.fill",
                       "hexagon.fill", "pentagon.fill", "rhombus.fill", "seal.fill"]
        return symbols[index % symbols.count]
    }
}

extension Color {
    /// Builds a colour that resolves per appearance, so dark mode is a selected
    /// value rather than an automatic inversion.
    init(light: Color, dark: Color) {
        self = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }

    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
