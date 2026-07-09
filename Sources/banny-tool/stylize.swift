import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import BannyRender

// banny-tool stylize <in.png> <out.png> [gridWidth]
func stylizeCommand(_ args: [String]) throws {
    guard args.count >= 2 else {
        print("usage: banny-tool stylize <in.png> <out.png> [gridWidth]")
        exit(1)
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: args[0]))
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fatalError("cannot decode \(args[0])")
    }
    var opts = PixelStyler.Options()
    if args.count > 2, let g = Int(args[2]) { opts.gridWidth = g }
    if args.count > 3, let d = Double(args[3]) { opts.dither = d }
    guard let styled = PixelStyler.stylize(img, palette: nil, options: opts) else {
        fatalError("stylize failed")
    }
    // upscale nearest to source size for viewing parity
    let scale = max(1, img.width / styled.width)
    let ow = styled.width * scale, oh = styled.height * scale
    let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .none
    ctx.draw(styled, in: CGRect(x: 0, y: 0, width: ow, height: oh))
    let out = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: args[1]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, out, nil)
    CGImageDestinationFinalize(dest)
    print("stylized → \(args[1]) (grid \(styled.width)x\(styled.height))")
}
