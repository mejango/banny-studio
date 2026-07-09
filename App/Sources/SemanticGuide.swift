import CoreGraphics
import Vision

/// What the image IS, before we redraw it: Vision's subject segmentation
/// separates the things a viewer looks at (people, trees, props) from the
/// backdrop behind them, so the stylizer can spend detail where it matters.
enum SemanticGuide {

    /// Foreground probability per grid pixel (row-major, w*h, 0...1),
    /// or nil when Vision finds no confident subject.
    static func foregroundMask(of image: CGImage, gridW: Int, gridH: Int) -> [Float]? {
        let handler = VNImageRequestHandler(cgImage: image)
        var mask: CVPixelBuffer?
        let request = VNGenerateForegroundInstanceMaskRequest()
        if (try? handler.perform([request])) != nil,
           let result = request.results?.first,
           !result.allInstances.isEmpty {
            mask = try? result.generateScaledMaskForImage(
                forInstances: result.allInstances, from: handler)
        }
        if mask == nil {
            // Landscapes rarely have liftable subjects; fall back to the
            // objectness saliency heatmap (what a viewer would look at).
            let saliency = VNGenerateObjectnessBasedSaliencyImageRequest()
            if (try? handler.perform([saliency])) != nil,
               let obs = saliency.results?.first {
                mask = obs.pixelBuffer
            }
        }
        guard let mask else { return nil }

        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let mw = CVPixelBufferGetWidth(mask)
        let mh = CVPixelBufferGetHeight(mask)
        let stride = CVPixelBufferGetBytesPerRow(mask) / MemoryLayout<Float>.size
        let ptr = base.assumingMemoryBound(to: Float.self)

        var out = [Float](repeating: 0, count: gridW * gridH)
        var any = false
        for y in 0..<gridH {
            let sy = min(mh - 1, y * mh / gridH)
            for x in 0..<gridW {
                let sx = min(mw - 1, x * mw / gridW)
                let v = ptr[sy * stride + sx]
                out[y * gridW + x] = v
                if v > 0.5 { any = true }
            }
        }
        return any ? out : nil
    }
}
