import CoreGraphics
import Foundation
import ImageIO
import Testing

@Suite("Brand illustration source assets")
struct BrandIllustrationSourceAssetTests {
    private static let assets: [(name: String, slug: String)] = [
        ("BrandEmptyDashboard", "brand-empty-dashboard"),
        ("BrandEmptyInsights", "brand-empty-insights"),
        ("BrandEmptySessions", "brand-empty-sessions"),
        ("BrandEmptyExperiment", "brand-empty-experiment"),
        ("BrandEmptyWorkspace", "brand-empty-workspace"),
        ("BrandAllClear", "brand-all-clear"),
    ]

    private static let variants: [(scale: String, pixels: Int)] = [
        ("1x", 160),
        ("2x", 320),
        ("3x", 480),
    ]

    @Test("Every committed source PNG has the expected format, dimensions, and transparency")
    func everySourcePNGIsValid() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("GetHog/Resources/Assets.xcassets")

        for asset in Self.assets {
            let imageSet = root.appendingPathComponent("\(asset.name).imageset")
            let expectedNames = Set(Self.variants.map { "\(asset.slug)-\($0.scale).png" })
            let actualNames = Set(
                try FileManager.default.contentsOfDirectory(
                    at: imageSet,
                    includingPropertiesForKeys: nil
                )
                .filter { $0.pathExtension.lowercased() == "png" }
                .map(\.lastPathComponent)
            )
            #expect(actualNames == expectedNames)

            for variant in Self.variants {
                let url = imageSet.appendingPathComponent("\(asset.slug)-\(variant.scale).png")
                let data = try Data(contentsOf: url)
                #expect(data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))

                let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
                #expect(CGImageSourceGetCount(source) == 1)
                let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
                #expect(image.width == variant.pixels)
                #expect(image.height == variant.pixels)
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
