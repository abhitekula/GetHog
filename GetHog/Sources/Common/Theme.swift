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

    /// A second accent for chrome that needs warmth without competing with the
    /// data — badges, small-caps section headers, selected pills.
    static let accentWarm = Color(
        light: Color(hex: 0xC2410C),
        dark: Color(hex: 0xEA8C4F)
    )

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

    enum Status {
        static let good = Color(
            light: Color(red: 0.0, green: 0.514, blue: 0.0),
            dark: Color(red: 0.212, green: 0.729, blue: 0.404)
        )
        static let critical = Color(
            light: Color(red: 0.890, green: 0.286, blue: 0.282),
            dark: Color(red: 0.902, green: 0.404, blue: 0.404)
        )
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
    private static let light: [Color] = [
        Color(hex: 0x2A78D6),  // blue
        Color(hex: 0xEB6834),  // orange
        Color(hex: 0x1BAF7A),  // aqua
        Color(hex: 0xEDA100),  // yellow
        Color(hex: 0xE87BA4),  // magenta
        Color(hex: 0x008300),  // green
        Color(hex: 0x4A3AA7),  // violet
        Color(hex: 0xE34948),  // red
    ]

    private static let dark: [Color] = [
        Color(hex: 0x3987E5),
        Color(hex: 0xD95926),
        Color(hex: 0x199E70),
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
