import Foundation

/// Reads/writes the `.bannyshow` document package:
/// ```
/// MyShow.bannyshow/
///   show.json            — ShowDocument (schema v2)
///   audio/<clipId>.<ext> — audio sources
///   bg/<sceneId>.<ext>   — background media
///   thumbnail.png        — optional, written by the app
/// ```
public enum ShowPackage {

    public struct Contents {
        public var document: ShowDocument
        /// clipId → file URL inside the package.
        public var audioURLs: [String: URL]
        /// sceneId → file URL inside the package.
        public var backgroundURLs: [String: URL]
    }

    public enum PackageError: Error, Equatable {
        case missingShowJSON
    }

    public static func write(_ document: ShowDocument,
                             audio: [String: (data: Data, ext: String)] = [:],
                             backgrounds: [String: (data: Data, ext: String)] = [:],
                             to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]  // diffable, human-readable
        try encoder.encode(document).write(to: url.appendingPathComponent("show.json"), options: .atomic)

        if !audio.isEmpty {
            let dir = url.appendingPathComponent("audio")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for (id, media) in audio {
                try media.data.write(to: dir.appendingPathComponent("\(id).\(media.ext)"), options: .atomic)
            }
        }
        if !backgrounds.isEmpty {
            let dir = url.appendingPathComponent("bg")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for (id, media) in backgrounds {
                try media.data.write(to: dir.appendingPathComponent("\(id).\(media.ext)"), options: .atomic)
            }
        }
    }

    public static func read(from url: URL) throws -> Contents {
        let showURL = url.appendingPathComponent("show.json")
        guard FileManager.default.fileExists(atPath: showURL.path) else {
            throw PackageError.missingShowJSON
        }
        let document = try JSONDecoder().decode(ShowDocument.self, from: Data(contentsOf: showURL))
        return Contents(document: document,
                        audioURLs: mediaIndex(dir: url.appendingPathComponent("audio")),
                        backgroundURLs: mediaIndex(dir: url.appendingPathComponent("bg")))
    }

    /// Maps `<id>.<ext>` files in a package subfolder to id → URL.
    private static func mediaIndex(dir: URL) -> [String: URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var index: [String: URL] = [:]
        for f in files where !f.lastPathComponent.hasPrefix(".") {
            index[f.deletingPathExtension().lastPathComponent] = f
        }
        return index
    }
}
