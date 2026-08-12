import AppKit
import Foundation
import GetHogUI
import SwiftUI
import Testing

@Suite("Mac supporting-ink source contract")
@MainActor
struct MacSupportingInkConformanceTests {

    /// A system semantic colour is not a portable supporting-text token: its
    /// contrast depends on the surface below it. The Mac app owns warm page and
    /// card surfaces, so its content must spell words through `Theme.Ink` and
    /// neutral glyphs/fills through `Theme.neutralMark` instead of making an
    /// anonymous `.secondary`/`.tertiary` choice at each call site.
    ///
    /// The exceptions are deliberately a multiset, not a broad path exemption:
    /// App Intent snippets and the menu-bar popover render on system-owned
    /// materials where SwiftUI's semantic styles are authoritative. Counting
    /// each normalized source line means a new exception in either file still
    /// fails, while unrelated edits above an approved site do not churn the
    /// ledger.
    @Test("raw supporting colours equal the system-surface allowlist")
    func rawSupportingColoursEqualSystemSurfaceAllowlist() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // GetHogMac
            .deletingLastPathComponent()  // repository
        let inventory = try RawSupportingColourInventory.scan(repository: repository)

        #expect(
            inventory.scannedFileCount >= 180,
            "The Mac production-source scan became unexpectedly narrow: \(inventory.scannedFileCount) files"
        )

        let expected: [RawSupportingColourSite: Int] = [
            // Siri, Shortcuts, Spotlight, and App Intent snippets choose their
            // own material. Theme.Ink was measured only on GetHog surfaces.
            .init(
                path: "GetHog/Sources/Intents/GetHogIntents.swift",
                line: ".foregroundStyle(.secondary)"
            ): 6,

            // A native MenuBarExtra popover also owns its material. These five
            // identical calls are its supporting labels, not app-card content.
            .init(
                path: "GetHogMac/Sources/MacMenuBarExtra.swift",
                line: ".foregroundStyle(.secondary)"
            ): 5,
            .init(
                path: "GetHogMac/Sources/MacMenuBarExtra.swift",
                line: "notice.kind == .failure ? Theme.Status.criticalInk : Color.secondary"
            ): 1,

            // The sole app-owned raw semantic is centralized as a named mark.
            // It is intentionally not word ink and preserves Increase Contrast.
            .init(
                path: "GetHogUI/Sources/GetHogUI/Theme.swift",
                line: "public static let neutralMark = Color.secondary"
            ): 1,
        ]

        let report = RawSupportingColourInventory.diff(
            actual: inventory.sites,
            expected: expected
        )
        #expect(inventory.sites == expected, Comment(rawValue: report))
    }

    @Test("supporting word inks clear AA on every app surface")
    func supportingWordInksClearAA() {
        let inks = [
            ("secondary", Theme.Ink.secondary),
            ("tertiary", Theme.Ink.tertiary),
        ]
        let surfaces = [
            ("card", Theme.cardBackground),
            ("page", Theme.pageBackground),
        ]

        for (inkName, ink) in inks {
            for (surfaceName, surface) in surfaces {
                for appearance in MacContrastSample.appearances {
                    let foreground = MacContrastSample(ink, appearance).over(
                        MacContrastSample(surface, appearance)
                    )
                    let background = MacContrastSample(surface, appearance)
                    #expect(
                        foreground.contrast(with: background) >= 4.5,
                        "\(inkName) ink on \(surfaceName) in \(appearance.name.rawValue)"
                    )
                }
            }
        }
    }

    @Test("the neutral mark clears the non-text floor and neutral words do not reuse it")
    func neutralMarkHasOnlyTheMarkRole() {
        for (surfaceName, surface) in [
            ("card", Theme.cardBackground),
            ("page", Theme.pageBackground),
        ] {
            for appearance in MacContrastSample.appearances {
                let background = MacContrastSample(surface, appearance)
                let mark = MacContrastSample(Theme.neutralMark, appearance).over(background)
                #expect(
                    mark.contrast(with: background) >= 3,
                    "neutral mark on \(surfaceName) in \(appearance.name.rawValue)"
                )

                let neutralWord = MacContrastSample(
                    Theme.Status.ink(for: Theme.neutralMark),
                    appearance
                )
                #expect(neutralWord == MacContrastSample(Theme.Ink.secondary, appearance))
                #expect(neutralWord != MacContrastSample(Theme.neutralMark, appearance))
            }
        }
    }

    /// The raw-token inventory cannot tell whether an already-named token is
    /// attached to words or to a symbol. These four controls are the concrete
    /// boundary: their glyph is either the entire control label or an accessory
    /// inside one, so `Theme.Ink` would be a word token in a mark role. Keep the
    /// contract on the primitive shape and symbol rather than a line number so
    /// harmless source movement cannot hide or invalidate it.
    @Test("glyph-only controls use the mark role")
    func glyphOnlyControlsUseTheMarkRole() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contracts = [
            GlyphMarkContract(
                path: "GetHog/Sources/Common/WriteOutcome.swift",
                name: "write outcome dismiss button",
                pattern: dismissButtonPattern
            ),
            GlyphMarkContract(
                path: "GetHog/Sources/Dashboards/InsightInspector.swift",
                name: "insight close button",
                pattern: #"Button\(action:\s*onClose\)\s*\{\s*Image\(systemName:\s*"xmark\.circle\.fill"\)\s*\.font\(\.title3\)\s*\.foregroundStyle\(Theme\.neutralMark\)"#
            ),
            GlyphMarkContract(
                path: "GetHog/Sources/ErrorTracking/ErrorIssueDetailView.swift",
                name: "triage message dismiss button",
                pattern: dismissButtonPattern
            ),
            GlyphMarkContract(
                path: "GetHog/Sources/Settings/TabBarSettingsView.swift",
                name: "tab-slot menu accessory",
                pattern: #"Image\(systemName:\s*"chevron\.up\.chevron\.down"\)\s*\.font\(\.footnote\)\s*\.foregroundStyle\(Theme\.neutralMark\)"#
            ),
        ]

        for contract in contracts {
            let source = try String(
                contentsOf: repository.appending(path: contract.path),
                encoding: .utf8
            )
            let regex = try NSRegularExpression(
                pattern: contract.pattern,
                options: [.dotMatchesLineSeparators]
            )
            let matches = regex.numberOfMatches(
                in: source,
                range: NSRange(source.startIndex..., in: source)
            )
            #expect(
                matches == 1,
                "\(contract.name) must use Theme.neutralMark exactly once; found \(matches)"
            )
        }
    }

    private var dismissButtonPattern: String {
        #"Button\(action:\s*onDismiss\)\s*\{\s*Image\(systemName:\s*"xmark\.circle\.fill"\)\s*\.minimumHitTarget\(\)\s*\}\s*\.buttonStyle\(\.plain\)\s*\.foregroundStyle\(Theme\.neutralMark\)"#
    }
}

private struct GlyphMarkContract {
    let path: String
    let name: String
    let pattern: String
}

/// One resolved sRGB sample, including the alpha carried by AppKit's semantic
/// colours, so the test measures the actual composite instead of comparing
/// token literals. Increased-contrast appearances are part of the matrix: the
/// app inks keep their light/dark values while the system-owned mark may adapt.
private struct MacContrastSample: Equatable {
    @MainActor static let appearances: [NSAppearance] = [
        NSAppearance(named: .aqua),
        NSAppearance(named: .darkAqua),
        NSAppearance(named: .accessibilityHighContrastAqua),
        NSAppearance(named: .accessibilityHighContrastDarkAqua),
    ].compactMap { $0 }

    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(_ color: Color, _ appearance: NSAppearance) {
        var resolved = NSColor.clear
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB) ?? .clear
        }
        red = Double(resolved.redComponent)
        green = Double(resolved.greenComponent)
        blue = Double(resolved.blueComponent)
        alpha = Double(resolved.alphaComponent)
    }

    private init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        alpha = 1
    }

    func over(_ background: MacContrastSample) -> MacContrastSample {
        MacContrastSample(
            red: red * alpha + background.red * (1 - alpha),
            green: green * alpha + background.green * (1 - alpha),
            blue: blue * alpha + background.blue * (1 - alpha)
        )
    }

    private var luminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    func contrast(with other: MacContrastSample) -> Double {
        let high = max(luminance, other.luminance)
        let low = min(luminance, other.luminance)
        return (high + 0.05) / (low + 0.05)
    }
}

private struct RawSupportingColourSite: Hashable {
    let path: String
    let line: String
}

private enum RawSupportingColourInventory {
    struct Result {
        let scannedFileCount: Int
        let sites: [RawSupportingColourSite: Int]
    }

    /// These are the four sources excluded by the GetHogMac target in
    /// project.yml. Keeping the same subtraction here makes the test describe
    /// the actual Mac build graph rather than a convenient superset.
    private static let excludedSharedAppSources: Set<String> = [
        "GetHog/Sources/App/GetHogApp.swift",
        "GetHog/Sources/App/QuickActions.swift",
        "GetHog/Sources/App/BackgroundRefresh.swift",
        "GetHog/Sources/App/RootView.swift",
    ]

    static func scan(repository: URL) throws -> Result {
        let rawSupportingColour = try NSRegularExpression(
            pattern: #"\bColor\.(?:secondary|tertiary)\b|(?<![A-Za-z0-9_.])\.(?:secondary|tertiary)\b"#
        )
        let roots = [
            repository.appending(path: "GetHog/Sources"),
            repository.appending(path: "GetHogUI/Sources/GetHogUI"),
            repository.appending(path: "GetHogMac/Sources"),
        ]
        var files: [URL] = []

        for root in roots {
            let enumerator = try #require(
                FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ),
                "Cannot enumerate Mac production source root \(root.path)"
            )
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                let path = relativePath(of: file, to: repository)
                if !excludedSharedAppSources.contains(path) {
                    files.append(file)
                }
            }
        }

        var sites: [RawSupportingColourSite: Int] = [:]
        for file in files.sorted(by: { $0.path < $1.path }) {
            let path = relativePath(of: file, to: repository)
            let source = try String(contentsOf: file, encoding: .utf8)
            let executableSource = removingCommentsAndStringLiterals(from: source)

            for rawLine in executableSource.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(rawLine)
                let matches = rawSupportingColour.matches(
                    in: line,
                    range: NSRange(line.startIndex..., in: line)
                )
                guard !matches.isEmpty else { continue }

                let site = RawSupportingColourSite(path: path, line: normalize(line))
                sites[site, default: 0] += matches.count
            }
        }

        return Result(scannedFileCount: files.count, sites: sites)
    }

    static func diff(
        actual: [RawSupportingColourSite: Int],
        expected: [RawSupportingColourSite: Int]
    ) -> String {
        let allSites = Set(actual.keys).union(expected.keys)
        let mismatches = allSites.compactMap { site -> String? in
            let actualCount = actual[site, default: 0]
            let expectedCount = expected[site, default: 0]
            guard actualCount != expectedCount else { return nil }
            let disposition = actualCount > expectedCount ? "unexpected" : "missing"
            return "\(disposition) \(site.path) ×\(actualCount)/\(expectedCount): \(site.line)"
        }
        .sorted()

        return ([
            "Raw supporting colours escaped their semantic roles.",
            "Counts are actual/allowed; use Theme.Ink for words and Theme.neutralMark for app-owned marks.",
        ] + mismatches).joined(separator: "\n")
    }

    private static func relativePath(of file: URL, to repository: URL) -> String {
        let root = repository.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        precondition(path.hasPrefix(root + "/"), "Source escaped repository: \(path)")
        return String(path.dropFirst(root.count + 1))
    }

    private static func normalize(_ line: String) -> String {
        line.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    /// Masks comments and string contents while preserving every newline. The
    /// source contract therefore inventories executable colour expressions,
    /// not the contrast table in Theme documentation or words in test/demo
    /// fixtures. Swift block comments can nest, and raw/multiline strings can
    /// contain comment delimiters, so the scanner handles both explicitly.
    private static func removingCommentsAndStringLiterals(from source: String) -> String {
        enum State {
            case code
            case lineComment
            case blockComment(depth: Int)
            case string(hashCount: Int, multiline: Bool)
        }

        let characters = Array(source)
        var output = String()
        output.reserveCapacity(source.utf8.count)
        var index = 0
        var state = State.code

        func matches(_ text: [Character], at offset: Int) -> Bool {
            guard offset + text.count <= characters.count else { return false }
            return Array(characters[offset..<(offset + text.count)]) == text
        }

        func appendMask(for character: Character) {
            output.append(character == "\n" ? "\n" : " ")
        }

        while index < characters.count {
            switch state {
            case .code:
                if matches(["/", "/"], at: index) {
                    output.append("  ")
                    index += 2
                    state = .lineComment
                } else if matches(["/", "*"], at: index) {
                    output.append("  ")
                    index += 2
                    state = .blockComment(depth: 1)
                } else {
                    var hashCount = 0
                    while index + hashCount < characters.count,
                          characters[index + hashCount] == "#" {
                        hashCount += 1
                    }
                    let quoteOffset = index + hashCount
                    if quoteOffset < characters.count, characters[quoteOffset] == "\"" {
                        let multiline = matches(["\"", "\"", "\""], at: quoteOffset)
                        let delimiterLength = hashCount + (multiline ? 3 : 1)
                        for character in characters[index..<(index + delimiterLength)] {
                            appendMask(for: character)
                        }
                        index += delimiterLength
                        state = .string(hashCount: hashCount, multiline: multiline)
                    } else {
                        output.append(characters[index])
                        index += 1
                    }
                }

            case .lineComment:
                let character = characters[index]
                appendMask(for: character)
                index += 1
                if character == "\n" {
                    state = .code
                }

            case let .blockComment(depth):
                if matches(["/", "*"], at: index) {
                    output.append("  ")
                    index += 2
                    state = .blockComment(depth: depth + 1)
                } else if matches(["*", "/"], at: index) {
                    output.append("  ")
                    index += 2
                    state = depth == 1 ? .code : .blockComment(depth: depth - 1)
                } else {
                    appendMask(for: characters[index])
                    index += 1
                }

            case let .string(hashCount, multiline):
                let quoteCount = multiline ? 3 : 1
                let terminator = Array(repeating: Character("\""), count: quoteCount)
                    + Array(repeating: Character("#"), count: hashCount)
                if matches(terminator, at: index) {
                    for character in characters[index..<(index + terminator.count)] {
                        appendMask(for: character)
                    }
                    index += terminator.count
                    state = .code
                } else if hashCount == 0, !multiline, characters[index] == "\\" {
                    appendMask(for: characters[index])
                    index += 1
                    if index < characters.count {
                        appendMask(for: characters[index])
                        index += 1
                    }
                } else {
                    appendMask(for: characters[index])
                    index += 1
                }
            }
        }

        return output
    }
}
