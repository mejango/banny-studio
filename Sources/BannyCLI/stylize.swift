import BannyRender
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Pixel stylizing remains available through the shared CLI engine.

func stylizeCommand(_ args: [String]) throws {
    let usage = "banny stylize <in.png> <out.png> [gridWidth] [dither] [--json]"
    var positional = args
    let json: Bool
    if let index = positional.firstIndex(of: "--json") {
        guard positional.lastIndex(of: "--json") == index else {
            throw CLIError.invalid("option --json was provided more than once")
        }
        positional.remove(at: index)
        json = true
    } else {
        json = false
    }
    guard (2...4).contains(positional.count),
          !positional.contains(where: { $0.hasPrefix("--") }) else {
        throw CLIError.usage(usage)
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: positional[0]))
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw CLIError.invalid("cannot decode image: \(positional[0])")
    }
    var opts = PixelStyler.Options()
    if positional.count > 2 {
        guard let gridWidth = Int(positional[2]), (16...4_096).contains(gridWidth) else {
            throw CLIError.invalid("gridWidth must be an integer inside 16...4096")
        }
        opts.gridWidth = gridWidth
    }
    if positional.count > 3 {
        guard let dither = Double(positional[3]), dither.isFinite,
              (0...1).contains(dither) else {
            throw CLIError.invalid("dither must be a number inside 0...1")
        }
        opts.dither = dither
    }
    guard let styled = PixelStyler.stylize(img, palette: nil, options: opts) else {
        throw CLIError.invalid("could not stylize \(positional[0])")
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
              URL(fileURLWithPath: positional[1]) as CFURL,
              UTType.png.identifier as CFString,
              1,
              nil) else {
        throw CLIError.invalid("could not create PNG output: \(positional[1])")
    }
    CGImageDestinationAddImage(destination, outputImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CLIError.invalid("could not finish PNG output: \(positional[1])")
    }
    if json {
        struct StylizeReport: Codable {
            let source: String; let output: String
            let gridWidth: Int; let gridHeight: Int
            let outputWidth: Int; let outputHeight: Int
        }
        try printJSON(StylizeReport(
            source: positional[0], output: positional[1],
            gridWidth: styled.width, gridHeight: styled.height,
            outputWidth: outputWidth, outputHeight: outputHeight))
    } else {
        print("stylized → \(positional[1]) (grid \(styled.width)x\(styled.height))")
    }
}

/// Wraps `PixelStyler.sparkleFrames` — the sparse point-light loop the house
/// backdrops use — and writes an animated GIF the background track can import.
/// Under 1% of pixels move per frame, so the still reads as a still that
/// happens to breathe.
func shimmerCommand(_ args: [String]) throws {
    let usage = "banny shimmer <in.png> <out.gif> [--frames N] [--delay S] [--scale N] [--json]"
    guard args.count >= 2 else { throw CLIError.usage(usage) }
    let positional = [args[0], args[1]]
    var options = CLIOptions(Array(args.dropFirst(2)))
    let frames = try options.int("--frames") ?? 8
    let delay = try options.double("--delay") ?? 0.14
    let scale = try options.int("--scale") ?? 2
    let json = try options.flag("--json")
    try options.finish(usage: usage)

    guard (2...24).contains(frames) else {
        throw CLIError.invalid("--frames must be an integer inside 2...24")
    }
    guard delay.isFinite, (0.04...2).contains(delay) else {
        throw CLIError.invalid("--delay must be a number inside 0.04...2 seconds")
    }
    guard (1...8).contains(scale) else {
        throw CLIError.invalid("--scale must be an integer inside 1...8")
    }

    let data = try Data(contentsOf: URL(fileURLWithPath: positional[0]))
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let still = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw CLIError.invalid("cannot decode image: \(positional[0])")
    }
    let loop = PixelStyler.sparkleFrames(still, frames: frames, scale: scale)
    guard loop.count > 1 else {
        throw CLIError.invalid(
            "no point lights found in \(positional[0]) — try a larger --scale")
    }
    let output = URL(fileURLWithPath: positional[1])
    guard output.pathExtension.lowercased() == "gif" else {
        throw CLIError.invalid("shimmer output must end in .gif")
    }
    guard let destination = CGImageDestinationCreateWithURL(
        output as CFURL, UTType.gif.identifier as CFString, loop.count, nil) else {
        throw CLIError.invalid("could not create GIF output: \(positional[1])")
    }
    CGImageDestinationSetProperties(destination, [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
    ] as CFDictionary)
    for frame in loop {
        CGImageDestinationAddImage(destination, frame, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ],
        ] as CFDictionary)
    }
    guard CGImageDestinationFinalize(destination) else {
        throw CLIError.invalid("could not finish GIF output: \(positional[1])")
    }
    if json {
        struct ShimmerReport: Codable {
            let source: String, output: String
            let frames: Int, delay: Double, loopSeconds: Double
            let width: Int, height: Int
        }
        try printJSON(ShimmerReport(
            source: positional[0], output: positional[1],
            frames: loop.count, delay: delay,
            loopSeconds: (delay * Double(loop.count) * 1000).rounded() / 1000,
            width: still.width, height: still.height))
    } else {
        print("shimmer → \(positional[1]) (\(loop.count) frames, "
              + "\(delay * Double(loop.count))s loop)")
    }
}
