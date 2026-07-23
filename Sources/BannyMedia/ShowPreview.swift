import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import BannyCore
import BannyRender

/// One frame of a show as a PNG — an agent's eyes before a full `ship`.
public enum ShowPreview {
    public enum PreviewError: Error { case contextFailed, encodeFailed, imageTooLarge }

    public static func writePNG(contents: ShowPackage.Contents,
                                assets: AssetCatalog,
                                at t: Double,
                                to url: URL) throws {
        try writePNG(document: contents.document, assets: assets,
                     assetURL: { contents.assetURLs[$0] }, at: t, to: url)
    }

    /// App-side preview entry point for a live document whose media has
    /// already been materialized as files.
    public static func writePNG(document: ShowDocument,
                                assets: AssetCatalog,
                                assetURL: @escaping (String) -> URL?,
                                at t: Double,
                                to url: URL) throws {
        let options = ShowExporter.Options.p1080.fitted(aspect: document.settings.frameAspect)
        let image = try render(document: document, assets: assets,
                               assetURL: assetURL, at: t, options: options)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw PreviewError.encodeFailed }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw PreviewError.encodeFailed }
    }

    /// YouTube thumbnail data rendered from the same deterministic stage as
    /// export. It steps JPEG quality down only as needed to meet the API's
    /// hard 2 MB upload limit.
    public static func thumbnailJPEG(document: ShowDocument,
                                     assets: AssetCatalog,
                                     assetURL: @escaping (String) -> URL?,
                                     at t: Double,
                                     maxBytes: Int = 2_000_000) throws -> Data {
        let options = ShowExporter.Options.p720.fitted(aspect: document.settings.frameAspect)
        let image = try render(document: document, assets: assets,
                               assetURL: assetURL, at: t, options: options)
        for quality in [0.9, 0.78, 0.66, 0.54] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil)
            else { throw PreviewError.encodeFailed }
            CGImageDestinationAddImage(
                destination, image,
                [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw PreviewError.encodeFailed
            }
            if data.length <= maxBytes { return data as Data }
        }
        throw PreviewError.imageTooLarge
    }

    private static func render(document: ShowDocument,
                               assets: AssetCatalog,
                               assetURL: @escaping (String) -> URL?,
                               at t: Double,
                               options: ShowExporter.Options) throws -> CGImage {
        let width = Int(options.size.width), height = Int(options.size.height)
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PreviewError.contextFailed
        }
        let media = ShowExporter.AssetSampler(assets: document.assets,
                                              assetURL: assetURL)
        FrameRenderer(assets: assets).draw(
            scene: document.stage, at: t, size: options.size,
            background: document.stage.activeBackgroundCue(at: t)
                .flatMap { media.frame(cue: $0, at: t) },
            visualAsset: { media.visualFrame(cue: $0, at: $1) },
            flipped: true, in: ctx)

        guard let image = ctx.makeImage() else { throw PreviewError.encodeFailed }
        return image
    }
}
