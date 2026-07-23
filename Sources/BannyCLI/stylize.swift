import BannyRender
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Pixel stylizing remains available through the shared CLI engine.

func stylizeCommand(_ args: [String]) throws {
    let usage = "banny stylize <in.png> <out.png> [gridWidth] [dither]"
    guard (2...4).contains(args.count) else {
        throw CLIError.usage(usage)
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: args[0]))
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw CLIError.invalid("cannot decode image: \(args[0])")
    }
    var opts = PixelStyler.Options()
    if args.count > 2 {
        guard let gridWidth = Int(args[2]), (16...4_096).contains(gridWidth) else {
            throw CLIError.invalid("gridWidth must be an integer inside 16...4096")
        }
        opts.gridWidth = gridWidth
    }
    if args.count > 3 {
        guard let dither = Double(args[3]), dither.isFinite,
              (0...1).contains(dither) else {
            throw CLIError.invalid("dither must be a number inside 0...1")
        }
        opts.dither = dither
    }
    guard let styled = PixelStyler.stylize(img, palette: nil, options: opts) else {
        throw CLIError.invalid("could not stylize \(args[0])")
    }
    // upscale nearest to source size for viewing parity
    let scale = max(1, img.width / styled.width)
    let outputWidth = styled.width * scale
    let outputHeight = styled.height * scale
    guard let context = CGContext(
        data: nil,
        width: outputWidth,
        height: outputHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw CLIError.invalid("could not allocate the stylized output image")
    }
    context.interpolationQuality = .none
    context.draw(
        styled,
        in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
    guard let outputImage = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              URL(fileURLWithPath: args[1]) as CFURL,
              UTType.png.identifier as CFString,
              1,
              nil) else {
        throw CLIError.invalid("could not create PNG output: \(args[1])")
    }
    CGImageDestinationAddImage(destination, outputImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CLIError.invalid("could not finish PNG output: \(args[1])")
    }
    print("stylized → \(args[1]) (grid \(styled.width)x\(styled.height))")
}
