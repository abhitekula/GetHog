import AppKit
import Foundation
import Testing

/// Every SF Symbol named as a labelled literal in shared app source resolves
/// on the macOS host. This source-tree contract deliberately runs outside an
/// iOS Simulator process: following `#filePath` back into the host checkout
/// from a simulated process can block indefinitely in file coordination.
@Suite("Source symbol names")
struct SourceSymbolNameTests {
    @Test("Every symbol name written in the app's source resolves")
    func sourceLiteralsResolve() throws {
        let names = try Self.sourceLiterals()
        let manifest = try Self.manifestLiterals()

        // A scan that finds nothing passes vacuously, which would be worse than
        // no test at all: it would read as coverage while checking nothing. The
        // app names well over a hundred symbols, so any small number here means
        // the scan broke, not that the app got tidier.
        #expect(names.count > 100, "only \(names.count) symbol literals found — the scan is broken")
        #expect(manifest.count > 100, "only \(manifest.count) manifest symbols found — the manifest is broken")
        #expect(
            manifest == Array(Set(manifest)).sorted(),
            "source-symbol manifest must stay sorted and duplicate-free"
        )

        let scanned = Set(names.keys)
        let manifested = Set(manifest)
        let missing = scanned.subtracting(manifested).sorted()
        let excess = manifested.subtracting(scanned).sorted()
        #expect(
            missing.isEmpty && excess.isEmpty,
            "source-symbol manifest drifted; missing: \(missing), excess: \(excess)"
        )

        for (name, origin) in names.sorted(by: { $0.key < $1.key }) {
            #expect(
                NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                "\(origin) names \"\(name)\""
            )
        }
    }

    private static func manifestLiterals() throws -> [String] {
        let url = repositoryRoot.appending(path: "GetHog/Tests/SourceSymbolManifest.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"^\s*"([^"\\]+)",?$"#, options: .anchorsMatchLines)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            guard let captured = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[captured])
        }
    }

    /// Symbol names written as a labelled argument anywhere under `Sources`,
    /// keyed by name, valued by where one of them was found.
    ///
    /// The labels below are the complete set of ways this app names a symbol in
    /// an argument position: SwiftUI's own two, App Intents' `systemImageName`,
    /// and the three the app's own components declare (`DataRow(glyph:)`,
    /// `RowGlyph(systemName:)`, `ReplayPlayerView.notice(icon:)`). A literal
    /// reached through any of these is unambiguously a symbol name, which is
    /// what keeps this scan free of the false positives a bare "looks dotted"
    /// heuristic would produce — `app.gethog.widget.health` and
    /// `chart.line.uptrend.xyaxis` are the same shape.
    private static func sourceLiterals() throws -> [String: String] {
        let pattern = try NSRegularExpression(
            pattern: #"\b(?:systemName|systemImage|systemImageName|glyph|icon)\s*:\s*"([^"\\]+)""#
        )

        var found: [String: String] = [:]
        for url in try sourceFiles() {
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let captured = Range(match.range(at: 1), in: text) else { continue }
                let line = text[text.startIndex..<captured.lowerBound]
                    .reduce(into: 1) { count, character in
                        if character == "\n" { count += 1 }
                    }
                found[String(text[captured])] = "\(url.lastPathComponent):\(line)"
            }
        }
        return found
    }

    private static func sourceFiles() throws -> [URL] {
        let root = repositoryRoot
            .appending(path: "GetHog/Sources")

        let enumerator = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
            "couldn't read \(root.path) — the sources moved, or the host test cannot reach them"
        )
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
