import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import BannyCore
import BannyRender

/// A room-scoped renderer for browser/OBS live previews.
///
/// Keep one instance for the lifetime of a room. The actor serializes access to
/// the persistent random-access media sampler and character sprite cache. Late
/// video frames seek directly instead of replaying the source from zero, while
/// repeated requests can reuse decoded media and flattened character artwork.
public actor LiveFrameJPEGRenderer {
    public enum RenderError: Error, Equatable, LocalizedError, Sendable {
        case invalidTime
        case documentAssetsChanged
        case contextFailed
        case encodeFailed
        case imageTooLarge(maximumBytes: Int)

        public var errorDescription: String? {
            switch self {
            case .invalidTime:
                return "The live frame time must be finite."
            case .documentAssetsChanged:
                return "The live document's assets changed after its renderer was created."
            case .contextFailed:
                return "The live frame drawing context could not be created."
            case .encodeFailed:
                return "The live frame could not be encoded as JPEG."
            case .imageTooLarge(let maximumBytes):
                return "The live JPEG could not fit within \(maximumBytes) bytes."
            }
        }
    }

    public static let defaultMaximumBytes = 2_000_000

    // A live room has at most ten characters. Twenty-four 640px RGBA sprites
    // retain two steady appearances per performer plus a small transition
    // margin while bounding raw cache storage to about 37.5 MiB. The old
    // 64 x 800px configuration could retain about 156 MiB per room.
    static let spriteCachePixelSize = 640
    static let spriteCacheCapacity = 24
    static let approximateSpriteCacheByteBudget =
        spriteCachePixelSize * spriteCachePixelSize * 4 * spriteCacheCapacity

    private let documentAssets: [Asset]
    private let catalog: AssetCatalog
    private let maximumBytes: Int
    private let sampler: ShowExporter.AssetSampler
    private let characterSpriteCache: CharacterSpriteCache

    /// Creates a renderer for an immutable room media bank.
    ///
    /// `documentAssets` and `assetURLs` must describe the media bank for every
    /// document subsequently passed to `render(document:at:)`. Live room
    /// documents may continue accumulating performance events, but changing
    /// their asset declarations requires a new renderer.
    public init(documentAssets: [Asset],
                assetURLs: [String: URL],
                catalog: AssetCatalog,
                maximumBytes: Int = LiveFrameJPEGRenderer.defaultMaximumBytes) {
        self.documentAssets = documentAssets
        self.catalog = catalog
        self.maximumBytes = max(1, maximumBytes)
        self.sampler = ShowExporter.AssetSampler(
            assets: documentAssets,
            assetURL: { assetURLs[$0] },
            videoSamplingMode: .randomAccess)
        self.characterSpriteCache = CharacterSpriteCache(
            pixelSize: Self.spriteCachePixelSize,
            capacity: Self.spriteCacheCapacity)
    }

    /// Renders the current room document through Studio's normal p720 stage
    /// path and returns a complete JPEG no larger than `maximumBytes`.
    public func render(document: ShowDocument, at time: Double) throws -> Data {
        try Task.checkCancellation()
        guard time.isFinite else { throw RenderError.invalidTime }
        guard document.assets == documentAssets else {
            throw RenderError.documentAssetsChanged
        }

        let t = max(0, time)
        let options = ShowExporter.Options.p720.fitted(aspect: document.settings.frameAspect)
        let width = Int(options.size.width)
        let height = Int(options.size.height)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RenderError.contextFailed }
        try Task.checkCancellation()

        // Building PreparedScenePerformance through `t` here would integrate
        // every character from zero on every 8 fps live request. Leaving it
        // nil uses SceneSimulator's locked, exact-input PositionTimelineCache:
        // immutable timelines are safely shared across actors/rooms, and a
        // stable event stream answers subsequent late-room frames from a
        // nearby checkpoint instead of rebuilding an hour of performance.
        let renderer = FrameRenderer(
            assets: catalog,
            assetMaxPixelSize: 1_280,
            characterSpriteCache: characterSpriteCache)
        let background = document.stage.activeBackgroundCue(at: t)
            .flatMap { sampler.frame(cue: $0, at: t) }
        try Task.checkCancellation()
        renderer.draw(
            scene: document.stage,
            at: t,
            size: options.size,
            background: background,
            visualAsset: {
                guard !Task.isCancelled else { return nil }
                return self.sampler.visualFrame(cue: $0, at: $1)
            },
            flipped: true,
            in: context)
        try Task.checkCancellation()

        guard let image = context.makeImage() else { throw RenderError.encodeFailed }
        // The low tail is intentional: the byte ceiling is an API invariant,
        // even for photographic backdrops or unusually small configured caps.
        for quality in [0.90, 0.78, 0.66, 0.54, 0.42, 0.30, 0.20, 0.12, 0.06] {
            try Task.checkCancellation()
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil)
            else { throw RenderError.encodeFailed }
            CGImageDestinationAddImage(
                destination,
                image,
                [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw RenderError.encodeFailed
            }
            try Task.checkCancellation()
            if data.length <= maximumBytes { return data as Data }
        }
        throw RenderError.imageTooLarge(maximumBytes: maximumBytes)
    }
}
