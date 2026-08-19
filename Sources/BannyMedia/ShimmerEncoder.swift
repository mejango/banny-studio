import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import BannyRender

/// The subtle sparse-point-light loop used by Banny Studio's ambient sets.
///
/// Keeping the encoder in `BannyMedia` lets the CLI, live-room host, and app
/// produce the same deterministic animation without shelling out to `banny`.
public enum ShimmerEncoder {
    public static let maximumSourcePixels = 4 * 1_024 * 1_024
    public static let maximumOutputBytes = 64 * 1_024 * 1_024

    public struct Options: Codable, Equatable, Sendable {
        public var frames: Int
        public var frameDelay: Double
        public var scale: Int

        public init(frames: Int = 8, frameDelay: Double = 0.14, scale: Int = 2) {
            self.frames = frames
            self.frameDelay = frameDelay
            self.scale = scale
        }
    }

    public struct Report: Codable, Equatable, Sendable {
        public let source: String
        public let output: String
        public let frames: Int
        public let delay: Double
        public let loopSeconds: Double
        public let width: Int
        public let height: Int

        public init(source: String, output: String, frames: Int, delay: Double,
                    loopSeconds: Double, width: Int, height: Int) {
            self.source = source
            self.output = output
            self.frames = frames
            self.delay = delay
            self.loopSeconds = loopSeconds
            self.width = width
            self.height = height
        }
    }

    public enum EncodingError: LocalizedError, Equatable, Sendable {
        case invalidFrameCount
        case invalidDelay
        case invalidScale
        case cannotDecode(String)
        case sourceTooLarge(String)
        case noPointLights(String)
        case outputMustBeGIF
        case cannotCreate(String)
        case cannotFinish(String)
        case outputTooLarge(String)

        public var errorDescription: String? {
            switch self {
            case .invalidFrameCount:
                "frames must be an integer inside 2...24"
            case .invalidDelay:
                "delay must be a number inside 0.04...2 seconds"
            case .invalidScale:
                "scale must be an integer inside 1...8"
            case .cannotDecode(let path):
                "cannot decode image: \(path)"
            case .sourceTooLarge(let path):
                "image exceeds the \(ShimmerEncoder.maximumSourcePixels)-pixel shimmer limit: \(path)"
            case .noPointLights(let path):
                "no point lights found in \(path) — try a larger scale"
            case .outputMustBeGIF:
                "shimmer output must end in .gif"
            case .cannotCreate(let path):
                "could not create GIF output: \(path)"
            case .cannotFinish(let path):
                "could not finish GIF output: \(path)"
            case .outputTooLarge(let path):
                "generated GIF exceeds the \(ShimmerEncoder.maximumOutputBytes)-byte limit: \(path)"
            }
        }
    }

    @discardableResult
    public static func encode(source: URL, to output: URL,
                              options: Options = Options()) throws -> Report {
        guard (2...24).contains(options.frames) else {
            throw EncodingError.invalidFrameCount
        }
        guard options.frameDelay.isFinite, (0.04...2).contains(options.frameDelay) else {
            throw EncodingError.invalidDelay
        }
        guard (1...8).contains(options.scale) else {
            throw EncodingError.invalidScale
        }
        guard output.pathExtension.lowercased() == "gif" else {
            throw EncodingError.outputMustBeGIF
        }

        let data = try Data(contentsOf: source)
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let still = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw EncodingError.cannotDecode(source.path)
        }
        guard still.width > 0, still.height > 0,
              still.width <= maximumSourcePixels / still.height else {
            throw EncodingError.sourceTooLarge(source.path)
        }
        let loop = PixelStyler.sparkleFrames(
            still,
            frames: options.frames,
            scale: options.scale)
        guard loop.count > 1 else {
            throw EncodingError.noPointLights(source.path)
        }
        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, UTType.gif.identifier as CFString, loop.count, nil) else {
            throw EncodingError.cannotCreate(output.path)
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        for frame in loop {
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: options.frameDelay,
                    kCGImagePropertyGIFUnclampedDelayTime: options.frameDelay,
                ],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw EncodingError.cannotFinish(output.path)
        }
        let outputBytes = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            ?? (maximumOutputBytes + 1)
        guard outputBytes <= maximumOutputBytes else {
            try? FileManager.default.removeItem(at: output)
            throw EncodingError.outputTooLarge(output.path)
        }
        return Report(
            source: source.path,
            output: output.path,
            frames: loop.count,
            delay: options.frameDelay,
            loopSeconds: (options.frameDelay * Double(loop.count) * 1_000).rounded() / 1_000,
            width: still.width,
            height: still.height)
    }
}
