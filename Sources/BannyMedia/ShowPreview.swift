import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import BannyCore
import BannyRender

/// One frame of a show as a PNG — an agent's eyes before a full `ship`.
public enum ShowPreview {
    public enum PreviewError: Error { case contextFailed, encodeFailed }

    public static func writePNG(contents: ShowPackage.Contents,
                                assets: AssetCatalog,
                                at t: Double,
                                to url: URL) throws {
        let document = contents.document
        let options = ShowExporter.Options.p1080.fitted(aspect: document.settings.frameAspect)
        let width = Int(options.size.width), height = Int(options.size.height)
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PreviewError.contextFailed
        }
        let bg = ShowExporter.BackgroundSampler(assets: document.assets,
                                                assetURL: { contents.assetURLs[$0] })
        let stills = ShowExporter.StillAssetCache(assets: document.assets,
                                                  assetURL: { contents.assetURLs[$0] })
        FrameRenderer(assets: assets).draw(
            scene: document.stage, at: t, size: options.size,
            background: document.stage.activeBackgroundCue(at: t).flatMap { bg.frame(cue: $0, at: t) },
            imageAsset: { stills.image(for: $0) },
            flipped: true, in: ctx)

        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw PreviewError.encodeFailed }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw PreviewError.encodeFailed }
    }
}
