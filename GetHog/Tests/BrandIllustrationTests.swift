import CoreGraphics
import ImageIO
import SwiftUI
import Testing
import UIKit

@testable import GetHog

@Suite("Brand illustrations")
@MainActor
struct BrandIllustrationTests {
    private static let expected: [(BrandIllustration, String)] = [
        (.dashboard, "BrandEmptyDashboard"),
        (.insights, "BrandEmptyInsights"),
        (.sessions, "BrandEmptySessions"),
        (.experiment, "BrandEmptyExperiment"),
        (.workspace, "BrandEmptyWorkspace"),
        (.allClear, "BrandAllClear"),
    ]

    @Test("Every semantic illustration has one stable asset name")
    func stableAssetNames() {
        #expect(BrandIllustration.allCases.count == Self.expected.count)
        for (illustration, name) in Self.expected {
            #expect(illustration.assetName == name)
        }
    }

    @Test("Every illustration is compiled into the app bundle")
    func compiledAssetsLoad() throws {
        for (_, name) in Self.expected {
            let image = try #require(UIImage(named: name))
            #expect(image.size.width > 0)
            #expect(image.size.height > 0)
        }
    }

    @Test("The shared empty state renders with branded art and with its symbol fallback")
    func emptyStateSupportsBothDecorations() throws {
        let branded = ImageRenderer(content:
            EmptyStateView(
                title: "No dashboards",
                systemImage: "square.grid.2x2",
                illustration: .dashboard,
                message: "Synthetic empty state."
            )
            .frame(width: 393, height: 600)
        )
        let fallback = ImageRenderer(content:
            EmptyStateView(title: "No matches", systemImage: "magnifyingglass")
                .frame(width: 393, height: 600)
        )
        #expect(branded.uiImage != nil)
        #expect(fallback.uiImage != nil)
    }

    @Test("Every source image set contains clean Retina alpha PNGs")
    func sourcePNGsAreValid() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Assets.xcassets")
        let variants = [("1x", 160), ("2x", 320), ("3x", 480)]

        for (_, assetName) in Self.expected {
            for (scale, pixels) in variants {
                let slug = assetName
                    .replacingOccurrences(of: "Brand", with: "brand-")
                    .replacingOccurrences(of: "Empty", with: "empty-")
                    .replacingOccurrences(of: "AllClear", with: "all-clear")
                    .flatMap { $0.isUppercase ? ["-", $0.lowercased()] : [$0.lowercased()] }
                    .joined()
                    .replacingOccurrences(of: "--", with: "-")
                let url = root
                    .appendingPathComponent("\(assetName).imageset")
                    .appendingPathComponent("\(slug)-\(scale).png")
                let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
                let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
                #expect(image.width == pixels)
                #expect(image.height == pixels)
                #expect(image.alphaInfo != .none)
                #expect(image.alphaInfo != .noneSkipFirst)
                #expect(image.alphaInfo != .noneSkipLast)
                #expect(try cornerAlpha(of: image) == [0, 0, 0, 0])
            }
        }
    }

    private func cornerAlpha(of image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return [
            pixels[3],
            pixels[(width - 1) * 4 + 3],
            pixels[(height - 1) * bytesPerRow + 3],
            pixels[(height - 1) * bytesPerRow + (width - 1) * 4 + 3],
        ]
    }
}
