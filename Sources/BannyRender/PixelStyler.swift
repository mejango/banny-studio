import CoreGraphics
import Foundation

/// Turns any raster image into a house-style pixel backdrop: box-downsample
/// to a coarse grid, quantize to a small shared palette (k-means), optional
/// ordered dithering. Deterministic — same inputs, same pixels.
///
/// The consistency of the output comes from the quantizer, not the source:
/// feed it photos, AI renders, or sketches and everything lands on the same
/// grid and palette as the rest of the show.
public enum PixelStyler {

    public struct Options: Sendable {
        /// Output grid width in art pixels (stage art is 16:9-ish; height
        /// follows the source aspect).
        public var gridWidth: Int
        /// Palette entry count after quantization.
        public var paletteSize: Int
        /// 4x4 ordered (Bayer) dithering strength, 0 = off, ~0.08 typical.
        public var dither: Double
        /// Nearest-neighbor upscale factor of the returned image.
        public var scale: Int

        public init(gridWidth: Int = 480, paletteSize: Int = 28,
                    dither: Double = 0.06, scale: Int = 3) {
            self.gridWidth = gridWidth
            self.paletteSize = paletteSize
            self.dither = dither
            self.scale = scale
        }
    }

    // MARK: - Pixel access

    private static func rgba(of image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &buf, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buf
    }

    // MARK: - Palette (k-means, deterministic)

    /// Builds a palette from one or more reference images (the show's
    /// existing backdrops) so new art matches old art.
    public static func palette(from images: [CGImage], size: Int) -> [SIMD3<Float>] {
        var samples: [SIMD3<Float>] = []
        for image in images {
            // ~64x36 sample grid per image is plenty for palette work.
            guard let px = rgba(of: image, width: 64, height: 36) else { continue }
            for i in stride(from: 0, to: px.count, by: 4) {
                samples.append(SIMD3(Float(px[i]), Float(px[i+1]), Float(px[i+2])))
            }
        }
        return kMeans(samples: samples, k: size)
    }

    private static func kMeans(samples: [SIMD3<Float>], k: Int) -> [SIMD3<Float>] {
        guard !samples.isEmpty else { return [SIMD3(0, 0, 0)] }
        let k = min(k, samples.count)
        // Deterministic init: sort by luminance, pick evenly spaced samples.
        let lum: (SIMD3<Float>) -> Float = { 0.299 * $0.x + 0.587 * $0.y + 0.114 * $0.z }
        let sorted = samples.sorted { lum($0) < lum($1) }
        var centers = (0..<k).map { sorted[$0 * (sorted.count - 1) / max(1, k - 1)] }

        var assignment = [Int](repeating: 0, count: samples.count)
        for _ in 0..<12 {
            for (i, s) in samples.enumerated() {
                var best = 0; var bestD = Float.greatestFiniteMagnitude
                for (c, center) in centers.enumerated() {
                    let d = simd_distance_squared(s, center)
                    if d < bestD { bestD = d; best = c }
                }
                assignment[i] = best
            }
            var sums = [SIMD3<Float>](repeating: .zero, count: k)
            var counts = [Int](repeating: 0, count: k)
            for (i, s) in samples.enumerated() {
                sums[assignment[i]] += s
                counts[assignment[i]] += 1
            }
            for c in 0..<k where counts[c] > 0 {
                centers[c] = sums[c] / Float(counts[c])
            }
        }
        return centers.sorted { lum($0) < lum($1) }
    }

    private static func simd_distance_squared(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = a - b
        // Perceptual-ish weighting: eyes are most sensitive to green.
        return d.x * d.x * 0.30 + d.y * d.y * 0.59 + d.z * d.z * 0.11
    }

    // MARK: - Stylize

    /// 4x4 Bayer matrix, normalized -0.5...0.5.
    private static let bayer: [Float] = [
        0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5
    ].map { $0 / 16.0 - 0.5 }

    /// `palette == nil` derives a fresh palette from the image itself.
    public static func stylize(_ image: CGImage, palette housePalette: [SIMD3<Float>]?,
                               options: Options = Options()) -> CGImage? {
        let gw = max(16, options.gridWidth)
        let gh = max(9, Int((Double(image.height) / Double(image.width) * Double(gw)).rounded()))
        guard var px = rgba(of: image, width: gw, height: gh) else { return nil }

        var pal = housePalette ?? []
        if pal.isEmpty {
            var samples: [SIMD3<Float>] = []
            samples.reserveCapacity(gw * gh)
            for i in stride(from: 0, to: px.count, by: 4) {
                samples.append(SIMD3(Float(px[i]), Float(px[i+1]), Float(px[i+2])))
            }
            pal = kMeans(samples: samples, k: options.paletteSize)
        }

        let spread = Float(options.dither) * 255
        for y in 0..<gh {
            for x in 0..<gw {
                let i = (y * gw + x) * 4
                var c = SIMD3(Float(px[i]), Float(px[i+1]), Float(px[i+2]))
                if spread > 0 {
                    c += SIMD3(repeating: bayer[(y & 3) * 4 + (x & 3)] * spread)
                }
                var best = 0; var bestD = Float.greatestFiniteMagnitude
                for (ci, center) in pal.enumerated() {
                    let d = simd_distance_squared(c, center)
                    if d < bestD { bestD = d; best = ci }
                }
                let out = pal[best]
                px[i] = UInt8(max(0, min(255, out.x)))
                px[i+1] = UInt8(max(0, min(255, out.y)))
                px[i+2] = UInt8(max(0, min(255, out.z)))
                px[i+3] = 255
            }
        }

        // Grid-res image, then crisp nearest-neighbor upscale.
        guard let small = px.withUnsafeMutableBytes({ raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: gw, height: gh,
                      bitsPerComponent: 8, bytesPerRow: gw * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }) else { return nil }
        let s = max(1, options.scale)
        guard s > 1 else { return small }
        guard let up = CGContext(data: nil, width: gw * s, height: gh * s,
                                 bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return small }
        up.interpolationQuality = .none
        up.draw(small, in: CGRect(x: 0, y: 0, width: gw * s, height: gh * s))
        return up.makeImage()
    }
}
