import CoreGraphics
import Foundation

/// Re-draws any raster image as authored-looking pixel art rather than a
/// posterized photo. The pipeline treats the source as a GUIDE and paints
/// above it:
///
///   1. Kuwahara smoothing — melts photographic texture into painterly
///      patches while keeping edges hard.
///   2. Region segmentation — flood-merge similar neighbors, flatten each
///      region to one color (the "flat fills" that read as deliberate).
///   3. Speckle merge — tiny regions dissolve into their closest neighbor.
///   4. Palette quantization — region colors land on the (house) palette.
///   5. Selective dithering — ordered dither ONLY inside large regions that
///      had a real gradient (skies, water), between that region's two
///      nearest palette colors. Flat things stay flat.
///   6. Inked boundaries — high-contrast region borders get a darkened
///      edge pixel, the hand-drawn outline look.
///
/// Deterministic: same inputs, same pixels.
public enum PixelStyler {

    public struct Options: Sendable {
        /// Output grid width in art pixels.
        public var gridWidth: Int
        /// Palette entry count after quantization.
        public var paletteSize: Int
        /// Dither strength inside gradient regions (0 = never dither).
        public var dither: Double
        /// Kuwahara radius (0 = off, 2–3 = painterly).
        public var smooth: Int
        /// Region-merge color threshold (higher = flatter, fewer regions).
        public var flatness: Double
        /// Darken high-contrast region borders.
        public var outline: Bool
        /// Nearest-neighbor upscale factor of the returned image.
        public var scale: Int

        public init(gridWidth: Int = 480, paletteSize: Int = 28, dither: Double = 0.5,
                    smooth: Int = 2, flatness: Double = 16, outline: Bool = true,
                    scale: Int = 3) {
            self.gridWidth = gridWidth
            self.paletteSize = paletteSize
            self.dither = dither
            self.smooth = smooth
            self.flatness = flatness
            self.outline = outline
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

    private static func floats(_ px: [UInt8]) -> [SIMD3<Float>] {
        var out = [SIMD3<Float>]()
        out.reserveCapacity(px.count / 4)
        for i in stride(from: 0, to: px.count, by: 4) {
            out.append(SIMD3(Float(px[i]), Float(px[i+1]), Float(px[i+2])))
        }
        return out
    }

    private static func dist2(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = a - b
        return d.x * d.x * 0.30 + d.y * d.y * 0.59 + d.z * d.z * 0.11
    }

    private static func lum(_ c: SIMD3<Float>) -> Float {
        0.299 * c.x + 0.587 * c.y + 0.114 * c.z
    }

    // MARK: - Palette (k-means, deterministic)

    public static func palette(from images: [CGImage], size: Int) -> [SIMD3<Float>] {
        var samples: [SIMD3<Float>] = []
        for image in images {
            guard let px = rgba(of: image, width: 64, height: 36) else { continue }
            samples.append(contentsOf: floats(px))
        }
        return kMeans(samples: samples, k: size)
    }

    private static func kMeans(samples: [SIMD3<Float>], k: Int) -> [SIMD3<Float>] {
        guard !samples.isEmpty else { return [SIMD3(0, 0, 0)] }
        let k = min(k, samples.count)
        let sorted = samples.sorted { lum($0) < lum($1) }
        var centers = (0..<k).map { sorted[$0 * (sorted.count - 1) / max(1, k - 1)] }
        var assignment = [Int](repeating: 0, count: samples.count)
        for _ in 0..<12 {
            for (i, s) in samples.enumerated() {
                var best = 0; var bestD = Float.greatestFiniteMagnitude
                for (c, center) in centers.enumerated() {
                    let d = dist2(s, center)
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

    private static func nearest(_ c: SIMD3<Float>, in pal: [SIMD3<Float>]) -> Int {
        var best = 0; var bestD = Float.greatestFiniteMagnitude
        for (i, p) in pal.enumerated() {
            let d = dist2(c, p)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    // MARK: - Kuwahara (edge-preserving painterly smoothing)

    private static func kuwahara(_ src: [SIMD3<Float>], w: Int, h: Int, r: Int) -> [SIMD3<Float>] {
        guard r > 0 else { return src }
        var out = src
        let quads: [(Int, Int, Int, Int)] = [(-r, 0, -r, 0), (0, r, -r, 0),
                                             (-r, 0, 0, r), (0, r, 0, r)]
        for y in 0..<h {
            for x in 0..<w {
                var bestVar = Float.greatestFiniteMagnitude
                var bestMean = src[y * w + x]
                for q in quads {
                    var sum = SIMD3<Float>.zero
                    var sum2: Float = 0
                    var n: Float = 0
                    for dy in q.2...q.3 {
                        let yy = y + dy
                        guard yy >= 0, yy < h else { continue }
                        for dx in q.0...q.1 {
                            let xx = x + dx
                            guard xx >= 0, xx < w else { continue }
                            let c = src[yy * w + xx]
                            sum += c
                            sum2 += lum(c) * lum(c)
                            n += 1
                        }
                    }
                    guard n > 0 else { continue }
                    let mean = sum / n
                    let variance = sum2 / n - lum(mean) * lum(mean)
                    if variance < bestVar { bestVar = variance; bestMean = mean }
                }
                out[y * w + x] = bestMean
            }
        }
        return out
    }

    // MARK: - Compositing (subject-aware two-pass)

    /// Blends two stylized renders by a foreground mask (grid resolution,
    /// values 0...1): subjects come from `fg`, backdrop from `bg`. Both
    /// should share a palette so seams read as region borders, not cuts.
    public static func composite(fg: CGImage, bg: CGImage, mask: [Float],
                                 gridW: Int, gridH: Int, scale: Int) -> CGImage? {
        let w = gridW * max(1, scale), h = gridH * max(1, scale)
        guard var fgPx = rgba(of: fg, width: w, height: h),
              let bgPx = rgba(of: bg, width: w, height: h) else { return nil }
        for y in 0..<h {
            let my = min(gridH - 1, y / max(1, scale))
            for x in 0..<w {
                let mx = min(gridW - 1, x / max(1, scale))
                if mask[my * gridW + mx] < 0.5 {
                    let i = (y * w + x) * 4
                    fgPx[i] = bgPx[i]; fgPx[i+1] = bgPx[i+1]; fgPx[i+2] = bgPx[i+2]
                }
            }
        }
        return fgPx.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: w, height: h,
                      bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    /// Grid height the stylizer will use for a source at a given grid width.
    public static func gridHeight(of image: CGImage, gridWidth: Int) -> Int {
        max(9, Int((Double(image.height) / Double(image.width)
            * Double(max(16, gridWidth))).rounded()))
    }

    // MARK: - Stylize

    private static let bayer: [Float] = [
        0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5
    ].map { $0 / 16.0 - 0.5 }

    public static func stylize(_ image: CGImage, palette housePalette: [SIMD3<Float>]?,
                               options: Options = Options()) -> CGImage? {
        let w = max(16, options.gridWidth)
        let h = max(9, Int((Double(image.height) / Double(image.width) * Double(w)).rounded()))
        guard let raw = rgba(of: image, width: w, height: h) else { return nil }
        let original = floats(raw)

        // 1. Painterly smoothing (kills photo texture, keeps edges).
        let smooth = kuwahara(original, w: w, h: h, r: options.smooth)

        // 2. Palette FIRST: flatness mixes the smoothed color toward a local
        //    quantization so nearby shades collapse onto the same entry —
        //    then regions are connected components of EQUAL palette index.
        //    (No threshold chaining, so sky can never bleed into sand.)
        var pal = housePalette ?? []
        if pal.isEmpty {
            pal = kMeans(samples: smooth, k: options.paletteSize)
        }
        // Flatness folds palette entries together: entries closer than the
        // threshold merge, so fills get broader as flatness rises.
        var effective = pal
        if options.flatness > 0 {
            let t2 = Float(options.flatness * options.flatness) * 4
            var merged: [SIMD3<Float>] = []
            for c in effective.sorted(by: { lum($0) < lum($1) }) {
                if let last = merged.last, dist2(last, c) < t2 { continue }
                merged.append(c)
            }
            if merged.count >= 4 { effective = merged }
        }

        var index = [Int](repeating: 0, count: w * h)
        for i in 0..<(w * h) { index[i] = nearest(smooth[i], in: effective) }

        // 3. Connected components of equal palette index.
        var regionOf = [Int](repeating: -1, count: w * h)
        var regionColor: [Int] = []
        var regionCount: [Int] = []
        var stack: [Int] = []
        for seed in 0..<(w * h) where regionOf[seed] == -1 {
            let rid = regionColor.count
            regionColor.append(index[seed])
            regionCount.append(0)
            stack.append(seed)
            regionOf[seed] = rid
            while let i = stack.popLast() {
                regionCount[rid] += 1
                let x = i % w, y = i / w
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, xx < w, yy >= 0, yy < h else { continue }
                    let j = yy * w + xx
                    if regionOf[j] == -1, index[j] == index[seed] {
                        regionOf[j] = rid
                        stack.append(j)
                    }
                }
            }
        }

        // 4. Dissolve speckle: small regions adopt their dominant neighbor.
        let minSize = max(3, (w * h) / 12000)
        for _ in 0..<2 {
            var remap: [Int: Int] = [:]
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    let r = regionOf[i]
                    guard regionCount[r] < minSize, remap[r] == nil else { continue }
                    var votes: [Int: Int] = [:]
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let xx = x + dx, yy = y + dy
                        guard xx >= 0, xx < w, yy >= 0, yy < h else { continue }
                        let nr = regionOf[yy * w + xx]
                        if nr != r, regionCount[nr] >= minSize { votes[nr, default: 0] += 1 }
                    }
                    if let bestN = votes.max(by: { $0.value < $1.value })?.key {
                        remap[r] = bestN
                    }
                }
            }
            guard !remap.isEmpty else { break }
            for i in 0..<(w * h) {
                if let to = remap[regionOf[i]] { regionOf[i] = to }
            }
            for (from, to) in remap {
                regionCount[to] += regionCount[from]
                regionCount[from] = 0
            }
        }

        // Gradient stats per (post-dissolve) region from the ORIGINAL image.
        var lumSum = [Float](repeating: 0, count: regionColor.count)
        var lum2Sum = [Float](repeating: 0, count: regionColor.count)
        var finalCount = [Int](repeating: 0, count: regionColor.count)
        for i in 0..<(w * h) {
            let r = regionOf[i]
            let l = lum(original[i])
            lumSum[r] += l
            lum2Sum[r] += l * l
            finalCount[r] += 1
        }

        // 5+6. Paint: flat fills, gradient-only dither, inked borders.
        var out = [UInt8](repeating: 255, count: w * h * 4)
        let ditherOn = options.dither > 0.01
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let r = regionOf[i]
                let cIdx = regionColor[r]
                var color = effective[cIdx]
                if ditherOn, finalCount[r] > 300 {
                    let n = Float(finalCount[r])
                    let mean = lumSum[r] / n
                    let std = max(0, lum2Sum[r] / n - mean * mean).squareRoot()
                    if std > 10 {
                        // Blend toward the neighbor palette entry in the
                        // direction this pixel's original luminance points.
                        let darker = lum(original[i]) < mean
                        let target = cIdx + (darker ? -1 : 1)
                        if target >= 0, target < effective.count {
                            let frac = min(1, abs(lum(original[i]) - mean) / max(1, std * 2))
                            let threshold = 0.5 + bayer[(y & 3) * 4 + (x & 3)]
                            if frac * Float(options.dither) * 1.6 > threshold {
                                color = effective[target]
                            }
                        }
                    }
                }
                if options.outline {
                    for (dx, dy) in [(1, 0), (0, 1)] {
                        let xx = x + dx, yy = y + dy
                        guard xx < w, yy < h else { continue }
                        let nr = regionOf[yy * w + xx]
                        guard nr != r else { continue }
                        let myLum = lum(effective[regionColor[r]])
                        let theirLum = lum(effective[regionColor[nr]])
                        if abs(myLum - theirLum) > 46, myLum < theirLum {
                            color *= 0.62
                        }
                    }
                }
                out[i * 4] = UInt8(max(0, min(255, color.x)))
                out[i * 4 + 1] = UInt8(max(0, min(255, color.y)))
                out[i * 4 + 2] = UInt8(max(0, min(255, color.z)))
            }
        }

        guard let small = out.withUnsafeMutableBytes({ raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: w, height: h,
                      bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }) else { return nil }
        let s = max(1, options.scale)
        guard s > 1 else { return small }
        guard let up = CGContext(data: nil, width: w * s, height: h * s,
                                 bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return small }
        up.interpolationQuality = .none
        up.draw(small, in: CGRect(x: 0, y: 0, width: w * s, height: h * s))
        return up.makeImage()
    }
}
