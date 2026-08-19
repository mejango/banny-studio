import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import BannyMedia

final class ShimmerEncoderTests: XCTestCase {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("banny-shimmer-\(UUID().uuidString)-\(name)")
    }

    private func writePointLightPNG(to url: URL) throws {
        let width = 18
        let height = 18
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) { pixels[pixel * 4 + 3] = 255 }
        let bright = (9 * width + 9) * 4
        pixels[bright] = 255
        pixels[bright + 1] = 244
        pixels[bright + 2] = 210
        let image = pixels.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
        XCTAssertNotNil(destination)
        CGImageDestinationAddImage(try XCTUnwrap(destination), try XCTUnwrap(image), nil)
        XCTAssertTrue(CGImageDestinationFinalize(try XCTUnwrap(destination)))
    }

    func testEncodesDeterministicAnimatedGIF() throws {
        let source = temporaryURL("source.png")
        let output = temporaryURL("output.gif")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        try writePointLightPNG(to: source)

        let report = try ShimmerEncoder.encode(
            source: source,
            to: output,
            options: .init(frames: 6, frameDelay: 0.12, scale: 1))

        XCTAssertEqual(report.frames, 6)
        XCTAssertEqual(report.loopSeconds, 0.72, accuracy: 0.000_001)
        let gif = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(gif), 6)
    }

    func testRejectsInvalidOptionsBeforeWriting() throws {
        let source = temporaryURL("source.png")
        let output = temporaryURL("output.gif")
        defer { try? FileManager.default.removeItem(at: source) }
        try writePointLightPNG(to: source)

        XCTAssertThrowsError(try ShimmerEncoder.encode(
            source: source,
            to: output,
            options: .init(frames: 1, frameDelay: 0.12, scale: 1))) { error in
                XCTAssertEqual(error as? ShimmerEncoder.EncodingError, .invalidFrameCount)
            }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
