import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum ProbedMediaKind: String, Codable, Sendable {
    case audio
    case image
    case video
}

/// Machine-readable facts needed to place media correctly without opening the
/// Studio UI. Dimensions are display-oriented (video transforms applied).
public struct MediaProbeResult: Codable, Sendable {
    public let path: String
    public let kind: ProbedMediaKind
    public let fileExtension: String
    public let mimeType: String?
    public let byteCount: UInt64
    public let duration: Double?
    public let width: Int?
    public let height: Int?
    public let frameRate: Double?
    public let animated: Bool

    public init(path: String, kind: ProbedMediaKind, fileExtension: String,
                mimeType: String?, byteCount: UInt64, duration: Double?,
                width: Int?, height: Int?, frameRate: Double?, animated: Bool) {
        self.path = path
        self.kind = kind
        self.fileExtension = fileExtension
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.duration = duration
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.animated = animated
    }
}

public enum MediaProbeError: LocalizedError, Sendable {
    case missing(String)
    case unsupported(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let path): "No media file exists at \(path)."
        case .unsupported(let path): "Unsupported media type at \(path)."
        case .unreadable(let path): "Could not read media metadata from \(path)."
        }
    }
}

public enum MediaProbe {
    public static func inspect(_ url: URL) async throws -> MediaProbeResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw MediaProbeError.missing(url.path)
        }
        let byteCount = ((try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?
            .uint64Value ?? 0
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        let mime = type?.preferredMIMEType

        if type?.conforms(to: .image) == true,
           let result = imageResult(url, ext: ext, mime: mime, byteCount: byteCount) {
            return result
        }
        if type?.conforms(to: .audio) == true,
           let result = audioResult(url, ext: ext, mime: mime, byteCount: byteCount) {
            return result
        }
        if type?.conforms(to: .movie) == true || type?.conforms(to: .audiovisualContent) == true {
            return try await videoResult(url, ext: ext, mime: mime, byteCount: byteCount)
        }

        // Extensionless or uncommon provider formats: probe decoders in a
        // deterministic order before declaring the file unsupported.
        if let result = imageResult(url, ext: ext, mime: mime, byteCount: byteCount) {
            return result
        }
        if let result = audioResult(url, ext: ext, mime: mime, byteCount: byteCount) {
            return result
        }
        do {
            return try await videoResult(url, ext: ext, mime: mime, byteCount: byteCount)
        } catch {
            throw MediaProbeError.unsupported(url.path)
        }
    }

    private static func audioResult(_ url: URL, ext: String, mime: String?,
                                    byteCount: UInt64) -> MediaProbeResult? {
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate > 0,
              file.length > 0 else { return nil }
        return MediaProbeResult(
            path: url.path,
            kind: .audio,
            fileExtension: ext,
            mimeType: mime,
            byteCount: byteCount,
            duration: Double(file.length) / file.processingFormat.sampleRate,
            width: nil,
            height: nil,
            frameRate: nil,
            animated: false)
    }

    private static func imageResult(_ url: URL, ext: String, mime: String?,
                                    byteCount: UInt64) -> MediaProbeResult? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        let count = CGImageSourceGetCount(source)
        var duration = 0.0
        if count > 1 {
            for index in 0..<count {
                guard let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                    as? [CFString: Any] else { continue }
                let gif = frame[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                let png = frame[kCGImagePropertyPNGDictionary] as? [CFString: Any]
                let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?
                    .doubleValue
                    ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
                    ?? (png?[kCGImagePropertyAPNGUnclampedDelayTime] as? NSNumber)?
                        .doubleValue
                    ?? (png?[kCGImagePropertyAPNGDelayTime] as? NSNumber)?.doubleValue
                    ?? 0.1
                duration += max(0.01, delay)
            }
        }
        return MediaProbeResult(
            path: url.path,
            kind: .image,
            fileExtension: ext,
            mimeType: mime,
            byteCount: byteCount,
            duration: count > 1 ? duration : nil,
            width: width,
            height: height,
            frameRate: count > 1 && duration > 0 ? Double(count) / duration : nil,
            animated: count > 1)
    }

    private static func videoResult(_ url: URL, ext: String, mime: String?,
                                    byteCount: UInt64) async throws -> MediaProbeResult {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw MediaProbeError.unreadable(url.path)
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let oriented = naturalSize.applying(transform)
        let frameRate = try await track.load(.nominalFrameRate)
        return MediaProbeResult(
            path: url.path,
            kind: .video,
            fileExtension: ext,
            mimeType: mime,
            byteCount: byteCount,
            duration: duration.isFinite && duration > 0 ? duration : nil,
            width: Int(abs(oriented.width).rounded()),
            height: Int(abs(oriented.height).rounded()),
            frameRate: frameRate > 0 ? Double(frameRate) : nil,
            animated: true)
    }
}
