import Foundation
import ImageIO

/// Decoded animated-GIF frames with their cumulative timeline. frame(at:) is a
/// pure function of t, so live playback, scrubbing, and export pick the
/// identical frame — same determinism contract as the rest of the renderer.
public struct GifSequence {
    public let frames: [CGImage]
    /// Start time of each frame; one extra trailing entry = total duration.
    public let starts: [Double]
    public var duration: Double { starts.last ?? 0 }

    /// nil unless the data decodes to 2+ frames (static images stay stills).
    public init?(data: Data) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) > 1 else { return nil }
        var frames: [CGImage] = []
        var starts: [Double] = [0]
        for i in 0..<CGImageSourceGetCount(src) {
            guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            var delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? 0
            if delay <= 0 { delay = gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0 }
            if delay <= 0.011 { delay = 0.1 } // browser convention for 0-delay frames
            frames.append(img)
            starts.append(starts[starts.count - 1] + delay)
        }
        guard frames.count > 1, starts[starts.count - 1] > 0 else { return nil }
        self.frames = frames
        self.starts = starts
    }

    /// The frame showing at t (loops past the end).
    public func frame(at t: Double) -> CGImage {
        var looped = t.truncatingRemainder(dividingBy: duration)
        if looped < 0 { looped += duration }
        // ponytail: linear scan — GIFs are tens of frames, not thousands.
        for i in (0..<frames.count).reversed() where starts[i] <= looped + 1e-9 {
            return frames[i]
        }
        return frames[0]
    }
}
