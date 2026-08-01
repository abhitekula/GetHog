import CoreGraphics
import Foundation
import ImageIO
import GetHogKit
import Testing
import UniformTypeIdentifiers

@testable import GetHog

/// Decoding a full-page render.
///
/// The authored stress case is 375 × 12,327 — thirty-three times taller than it
/// is wide, and about 18 MB once decoded to RGBA. Both characteristics are
/// intentional traps, and the suite exists for the first one.
@Suite("Page render decoding")
struct PageRenderDecoderTests {

    /// A JPEG of the requested size. Content is irrelevant; only its dimensions
    /// are under test.
    private func jpeg(width: Int, height: Int) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let image = try #require(context.makeImage())
        let out = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return out as Data
    }

    @Test("a very tall page does not decode to a thread")
    func longEdgeIsNotTheWidth() throws {
        // **The trap.** `kCGImageSourceThumbnailMaxPixelSize` bounds the longer
        // edge, and on a full-page render the longer edge is the height. Passing
        // a device width there — the natural reading of "max size" — would scale
        // 375 × 12,327 to roughly 12 px across, which is a grey thread with
        // clicks scattered beside it.
        let render = try #require(PageRenderDecoder.decode(jpeg(width: 375, height: 12_327)))

        #expect(render.image.width > 200)
        // Aspect ratio must survive the downsample, or every click's depth lands
        // somewhere other than the authored source content.
        let decodedRatio = Double(render.image.height) / Double(render.image.width)
        #expect(abs(decodedRatio - 12_327.0 / 375.0) < 0.5)
    }

    @Test("stays inside the pixel budget")
    func budget() throws {
        let render = try #require(PageRenderDecoder.decode(jpeg(width: 375, height: 12_327)))
        let pixels = render.image.width * render.image.height
        // Page height is unbounded, so the bitmap has to be bounded by something
        // that is not the page. A little slack for rounding on the long edge.
        #expect(pixels <= PageRenderDecoder.pixelBudget + 100_000)
    }

    @Test("reports the render's own size, not the decoded bitmap's")
    func sourceDimensions() throws {
        let render = try #require(PageRenderDecoder.decode(jpeg(width: 375, height: 12_327)))
        // Click coordinates are in these units. Reporting the downsampled size
        // here would scale every depth by the downsampling factor and slide the
        // whole overlay up the page — while still looking like a heatmap.
        #expect(render.sourceWidth == 375)
        #expect(render.sourceHeight == 12_327)
        #expect(render.image.width < render.sourceWidth)
    }

    @Test("a small page is not upscaled")
    func noUpscale() throws {
        let render = try #require(PageRenderDecoder.decode(jpeg(width: 320, height: 480)))
        #expect(render.image.width == 320)
        #expect(render.image.height == 480)
    }

    @Test("a non-image body is rejected rather than half-decoded")
    func garbage() {
        // The content endpoint is the one route in this app that answers bytes
        // instead of JSON, so an error page arriving here is a real possibility.
        #expect(PageRenderDecoder.decode(Data("{\"detail\":\"Not found\"}".utf8)) == nil)
        #expect(PageRenderDecoder.decode(Data()) == nil)
    }
}

/// Placing a click on the render.
///
/// The two axes arrive in different units, which is the whole reason this
/// arithmetic is worth a test: a mistake here produces a picture that looks
/// entirely convincing and is simply wrong.
@Suite("Overlay geometry")
struct OverlayGeometryTests {

    @Test("scales from the render's width, not the bitmap's")
    func scale() {
        // A 425 px render drawn in a 402 pt column.
        let scale = OverlayGeometry.scale(displayWidth: 402, sourceWidth: 425)
        #expect(abs(scale - 402.0 / 425.0) < 0.0001)
    }

    @Test("a zero-width render does not divide by zero")
    func degenerateScale() {
        #expect(OverlayGeometry.scale(displayWidth: 402, sourceWidth: 0) == 1)
    }

    @Test("x is a fraction of the width and y is scaled pixels")
    func placement() {
        let scale = OverlayGeometry.scale(displayWidth: 400, sourceWidth: 400)
        let point = HeatmapPoint(
            count: 3, pointerY: 2_000, pointerRelativeX: 0.5, isTargetFixed: false
        )
        let position = OverlayGeometry.position(for: point, displayWidth: 400, scale: scale)

        // Dead centre horizontally, 2,000 px down — at 1:1, 2,000 pt down.
        #expect(abs(position.x - 200) < 0.001)
        #expect(abs(position.y - 2_000) < 0.001)
    }

    @Test("the horizontal fraction is never scaled a second time")
    func fractionIsNotScaled() {
        // The mistake this guards: applying `scale` to x as well. At a half-size
        // render every click would bunch into the left half of the page, which
        // reads as a real finding about the page rather than as a bug.
        let scale = OverlayGeometry.scale(displayWidth: 200, sourceWidth: 400)
        let point = HeatmapPoint(
            count: 1, pointerY: 100, pointerRelativeX: 1.0, isTargetFixed: false
        )
        let position = OverlayGeometry.position(for: point, displayWidth: 200, scale: scale)

        #expect(abs(position.x - 200) < 0.001)  // the right-hand edge, not 100
        #expect(abs(position.y - 50) < 0.001)   // y *is* scaled
    }

    @Test("dot area, not radius, tracks the click count")
    func intensity() {
        // Four times the clicks should read as four times the ink, not sixteen.
        let quarter = OverlayGeometry.intensity(count: 25, peak: 100)
        #expect(abs(quarter - 0.5) < 0.001)
        #expect(OverlayGeometry.intensity(count: 100, peak: 100) == 1)
        #expect(OverlayGeometry.intensity(count: 0, peak: 0) == 0)
    }

    @Test("the coolest position is still visible")
    func minimumRadius() {
        // A single click among thousands still has to be findable; a radius
        // proportional all the way to zero would erase the long tail entirely.
        #expect(OverlayGeometry.radius(count: 1, peak: 10_000) >= 4)
        #expect(OverlayGeometry.radius(count: 1, peak: 1) > OverlayGeometry.radius(count: 1, peak: 10_000))
    }
}
