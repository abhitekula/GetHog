import SwiftUI

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

    static let cardBackground = Color(.secondarySystemGroupedBackground)
    static let pageBackground = Color(.systemGroupedBackground)

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
