import Foundation

/// Sidecar metadata derived from the exact range Banny Studio ships.
///
/// This deliberately lives in Core: the GUI, CLI, and future publishing
/// destinations can all produce identical chapters and captions without
/// depending on AVFoundation or a network connection.
public enum YouTubePublishPlan {
    public static let titleCharacterLimit = 100
    public static let descriptionByteLimit = 5_000

    public struct Range: Equatable, Sendable {
        public var from: Double
        public var to: Double

        public init(from: Double, to: Double) {
            self.from = from
            self.to = to
        }

        public var duration: Double { max(0, to - from) }
    }

    public struct Chapter: Equatable, Sendable {
        public var title: String
        public var seconds: Double

        public init(title: String, seconds: Double) {
            self.title = title
            self.seconds = seconds
        }
    }

    /// Mirrors `ShowExporter.resolveSegments`: the first marked range wins;
    /// otherwise the whole content timeline ships.
    public static func exportRange(for document: ShowDocument) -> Range {
        if let segment = document.show.first, segment.to > segment.from {
            return Range(from: max(0, segment.from), to: max(0, segment.to))
        }
        return Range(from: 0, to: max(1, document.stage.contentEnd + 0.5))
    }

    /// YouTube only recognizes manual chapters when:
    /// - the first timestamp is 00:00,
    /// - there are at least three chapters, and
    /// - every chapter is at least ten seconds long.
    ///
    /// A section crossing the beginning of the export is retimed to 00:00.
    /// If the first named section begins later, the export title provides a
    /// useful first chapter rather than inventing an anonymous label.
    public static func chapters(for document: ShowDocument,
                                firstTitle: String = "Start") -> [Chapter] {
        let range = exportRange(for: document)
        guard range.duration >= 30 else { return [] }

        let sections = document.stage.markers
            .filter {
                $0.kind == .section
                    && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.end > range.from
                    && $0.start < range.to
            }
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }

        var result: [Chapter] = []
        for section in sections {
            let shifted = max(0, section.start - range.from)
            let title = sanitizedChapterTitle(section.name)
            guard !title.isEmpty else { continue }
            if let last = result.last, abs(last.seconds - shifted) < 0.001 {
                continue
            }
            result.append(Chapter(title: title, seconds: shifted))
        }

        if result.first?.seconds ?? .infinity > 0.001 {
            let title = sanitizedChapterTitle(firstTitle)
            result.insert(Chapter(title: title.isEmpty ? "Start" : title, seconds: 0), at: 0)
        } else if !result.isEmpty {
            result[0].seconds = 0
        }

        guard result.count >= 3 else { return [] }
        for index in result.indices {
            let end = index + 1 < result.count ? result[index + 1].seconds : range.duration
            guard end - result[index].seconds >= 10 else { return [] }
        }
        return result
    }

    public static func chapterText(for document: ShowDocument,
                                   firstTitle: String = "Start") -> String {
        chapters(for: document, firstTitle: firstTitle)
            .map { "\(timestamp($0.seconds, milliseconds: false)) \($0.title)" }
            .joined(separator: "\n")
    }

    /// Generates a standards-compliant WebVTT sidecar from captions that are
    /// visible inside the exported cut. Cues are clipped and shifted so the
    /// first frame of the rendered video is always time zero.
    public static func webVTT(for document: ShowDocument) -> String? {
        let range = exportRange(for: document)
        struct Cue {
            var start: Double
            var end: Double
            var text: String
            var order: Int
        }

        var cues: [Cue] = []
        var order = 0
        for character in document.stage.characters where !character.hidden {
            for subtitle in character.subs {
                defer { order += 1 }
                let sourceStart = subtitle.start
                let sourceEnd = subtitle.start + max(0, subtitle.dur)
                let clippedStart = max(range.from, sourceStart)
                let clippedEnd = min(range.to, sourceEnd)
                guard clippedEnd - clippedStart >= 0.01,
                      character.presence.isPresent(at: (clippedStart + clippedEnd) / 2)
                else { continue }
                let text = sanitizedCaption(subtitle.text)
                guard !text.isEmpty else { continue }
                cues.append(Cue(start: clippedStart - range.from,
                                end: clippedEnd - range.from,
                                text: text,
                                order: order))
            }
        }
        cues.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.order < $1.order
        }
        guard !cues.isEmpty else { return nil }

        let body = cues.enumerated().map { index, cue in
            """
            \(index + 1)
            \(timestamp(cue.start, milliseconds: true)) --> \(timestamp(cue.end, milliseconds: true))
            \(cue.text)
            """
        }.joined(separator: "\n\n")
        return "WEBVTT\n\n\(body)\n"
    }

    /// Adds chapters without silently exceeding YouTube's description limit.
    public static func description(_ description: String,
                                   appendingChaptersFrom document: ShowDocument,
                                   firstTitle: String = "Start") -> String {
        let base = sanitizedMetadataText(description)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let chapterBlock = chapterText(for: document, firstTitle: firstTitle)
        guard !chapterBlock.isEmpty else { return videoDescription(base) }
        var chapterLines = chapterBlock.split(separator: "\n").map(String.init)
        while chapterLines.joined(separator: "\n").utf8.count > descriptionByteLimit,
              chapterLines.count > 3 {
            chapterLines.removeLast()
        }
        let boundedChapterBlock = chapterLines.joined(separator: "\n")
        guard !base.isEmpty else { return boundedChapterBlock }

        // Preserve complete chapter timestamps. Truncating the combined value
        // could cut the final chapter line and make YouTube ignore the block.
        let separator = "\n\n"
        let availableForBase = max(
            0, descriptionByteLimit - separator.utf8.count
                - boundedChapterBlock.utf8.count)
        return "\(utf8Prefix(base, maxBytes: availableForBase))\(separator)\(boundedChapterBlock)"
    }

    /// YouTube permits 100 characters and rejects angle brackets in titles.
    public static func videoTitle(_ value: String) -> String {
        String(sanitizedMetadataText(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(titleCharacterLimit))
    }

    /// YouTube measures its description ceiling in UTF-8 bytes.
    public static func videoDescription(_ value: String) -> String {
        utf8Prefix(sanitizedMetadataText(value), maxBytes: descriptionByteLimit)
    }

    private static func timestamp(_ seconds: Double, milliseconds: Bool) -> String {
        let clamped = max(0, seconds)
        let totalMilliseconds = Int((clamped * 1_000).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds / 60_000) % 60
        let secs = (totalMilliseconds / 1_000) % 60
        let millis = totalMilliseconds % 1_000
        if milliseconds {
            return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, millis)
        }
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    private static func sanitizedChapterTitle(_ value: String) -> String {
        let line = sanitizedMetadataText(value)
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(line.prefix(titleCharacterLimit))
    }

    private static func sanitizedCaption(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "-->", with: "→")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitizedMetadataText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "<", with: "‹")
            .replacingOccurrences(of: ">", with: "›")
    }

    private static func utf8Prefix(_ value: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var result = ""
        result.reserveCapacity(min(value.count, maxBytes))
        var used = 0
        for character in value {
            let bytes = character.utf8.count
            guard used + bytes <= maxBytes else { break }
            result.append(character)
            used += bytes
        }
        return result
    }
}
