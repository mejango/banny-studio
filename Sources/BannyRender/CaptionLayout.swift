import Foundation
import CoreText

/// Deterministic, frame-relative subtitle layout shared by the editor preview,
/// still previews, and video export through `FrameRenderer`.
///
/// Each active speaker gets up to two wrapped lines at the preferred size.
/// Longer captions shrink as a unit so simultaneous speakers retain one
/// consistent type size. Extremely long copy may exceed two lines rather than
/// being truncated; captions are production content and must never disappear.
enum CaptionLayoutEngine {
    struct VisualLine: Equatable, Sendable {
        var captionIndex: Int
        var text: String
        var width: Double
    }

    struct Layout: Equatable, Sendable {
        var fontSize: Double
        var lineHeight: Double
        var horizontalPadding: Double
        var verticalPadding: Double
        var captionGap: Double
        var boxX: Double
        var boxY: Double
        var boxWidth: Double
        var boxHeight: Double
        var lines: [VisualLine]
    }

    private struct Candidate {
        var layout: Layout
        var lineCounts: [Int]

        var usesAtMostTwoLinesPerCaption: Bool {
            lineCounts.allSatisfy { $0 <= 2 }
        }
    }

    private struct CacheKey: Hashable {
        var captions: [String]
        var width: UInt64
        var height: UInt64
    }

    /// Export can render the same subtitle hundreds of times. Keep the layout
    /// pure at the call site without re-running CoreText's wrapping search for
    /// every video frame. The small bounded cache is safe across preview and
    /// background export threads.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var layouts: [CacheKey: Layout] = [:]

        func value(for key: CacheKey) -> Layout? {
            lock.lock()
            defer { lock.unlock() }
            return layouts[key]
        }

        func insert(_ layout: Layout, for key: CacheKey) {
            lock.lock()
            defer { lock.unlock() }
            if layouts.count >= 128 {
                layouts.removeAll(keepingCapacity: true)
            }
            layouts[key] = layout
        }
    }

    private static let cache = Cache()

    static func layout(texts: [String], frameWidth W: Double,
                       outputHeight outH: Double) -> Layout? {
        guard W > 0, outH > 0 else { return nil }
        let captions = texts.map(normalized).filter { !$0.isEmpty }
        guard !captions.isEmpty else { return nil }
        let key = CacheKey(
            captions: captions,
            width: W.bitPattern,
            height: outH.bitPattern)
        if let cached = cache.value(for: key) {
            return cached
        }

        let preferred = StageLayout.captionFontSize(
            frameWidth: W,
            outputHeight: outH)
        let minimum = max(1, preferred * 0.45)
        let safeWidth = StageLayout.captionSafeWidth(frameWidth: W)

        let preferredCandidate = candidate(
            captions: captions,
            fontSize: preferred,
            safeWidth: safeWidth,
            frameWidth: W,
            outputHeight: outH)
        if preferredCandidate.usesAtMostTwoLinesPerCaption {
            cache.insert(preferredCandidate.layout, for: key)
            return preferredCandidate.layout
        }

        let minimumCandidate = candidate(
            captions: captions,
            fontSize: minimum,
            safeWidth: safeWidth,
            frameWidth: W,
            outputHeight: outH)
        guard minimumCandidate.usesAtMostTwoLinesPerCaption else {
            cache.insert(minimumCandidate.layout, for: key)
            return minimumCandidate.layout
        }

        // Find the largest size which keeps every caption to two lines. Word
        // wrapping changes discretely, so a short fixed search is both stable
        // and substantially cheaper than stepping through every point size.
        var low = minimum
        var high = preferred
        var best = minimumCandidate
        for _ in 0..<10 {
            let mid = (low + high) / 2
            let next = candidate(
                captions: captions,
                fontSize: mid,
                safeWidth: safeWidth,
                frameWidth: W,
                outputHeight: outH)
            if next.usesAtMostTwoLinesPerCaption {
                best = next
                low = mid
            } else {
                high = mid
            }
        }
        cache.insert(best.layout, for: key)
        return best.layout
    }

    private static func candidate(captions: [String], fontSize: Double,
                                  safeWidth: Double, frameWidth W: Double,
                                  outputHeight outH: Double) -> Candidate {
        let horizontalPadding = fontSize * 0.48
        let verticalPadding = fontSize * 0.38
        let lineHeight = fontSize * 1.24
        let captionGap = fontSize * 0.18
        let textWidth = max(1, safeWidth - horizontalPadding * 2)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)

        var visualLines: [VisualLine] = []
        var lineCounts: [Int] = []
        for (captionIndex, text) in captions.enumerated() {
            let wrapped = wrap(text, font: font, width: textWidth)
            lineCounts.append(wrapped.count)
            visualLines += wrapped.map {
                VisualLine(captionIndex: captionIndex, text: $0.text, width: $0.width)
            }
        }

        let maxLineWidth = visualLines.map(\.width).max() ?? 0
        let boxWidth = min(safeWidth, maxLineWidth + horizontalPadding * 2)
        let gaps = max(0, captions.count - 1)
        let boxHeight = verticalPadding * 2
            + Double(visualLines.count) * lineHeight
            + Double(gaps) * captionGap
        let bottomMargin = StageLayout.captionBottomMargin(outputHeight: outH)
        let boxX = (W - boxWidth) / 2
        let boxY = max(outH * 0.04, outH - bottomMargin - boxHeight)

        return Candidate(
            layout: Layout(
                fontSize: fontSize,
                lineHeight: lineHeight,
                horizontalPadding: horizontalPadding,
                verticalPadding: verticalPadding,
                captionGap: captionGap,
                boxX: boxX,
                boxY: boxY,
                boxWidth: boxWidth,
                boxHeight: boxHeight,
                lines: visualLines),
            lineCounts: lineCounts)
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func wrap(_ text: String, font: CTFont,
                             width: Double) -> [(text: String, width: Double)] {
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let source = text as NSString
        var offset = 0
        var output: [(text: String, width: Double)] = []

        while offset < source.length {
            let suggested = CTTypesetterSuggestLineBreak(typesetter, offset, width)
            let count: Int
            if suggested > 0 {
                count = min(source.length - offset, suggested)
            } else {
                count = source.rangeOfComposedCharacterSequence(at: offset).length
            }
            let range = NSRange(location: offset, length: count)
            let raw = source.substring(with: range)
            let lineText = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            offset = NSMaxRange(range)
            while offset < source.length,
                  isWhitespace(source.character(at: offset)) {
                offset += 1
            }

            guard !lineText.isEmpty else { continue }
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: lineText,
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                ]))
            output.append((
                text: lineText,
                width: CTLineGetTypographicBounds(line, nil, nil, nil)))
        }
        return output
    }

    private static func isWhitespace(_ codeUnit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(codeUnit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}
