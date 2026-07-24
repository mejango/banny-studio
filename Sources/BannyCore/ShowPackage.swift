import Foundation

/// Reads/writes the `.bs` document package:
/// ```
/// MyShow.bs/
///   show.json              — ShowDocument (schema v4)
///   audio/<clipId>.<ext>   — audio sources
///   assets/<assetId>.<ext> — bank assets (images/videos; v2 wrote bg/<sceneId>)
///   thumbnail.png          — optional, written by the app
/// ```
public enum ShowPackage {

    public struct Contents {
        public var document: ShowDocument
        /// clipId → file URL inside the package.
        public var audioURLs: [String: URL]
        /// assetId → file URL inside the package (v2 bg/ files appear here too).
        public var assetURLs: [String: URL]
    }

    public enum PackageError: Error, Equatable {
        case missingShowJSON
    }

    public static func write(_ document: ShowDocument,
                             audio: [String: (data: Data, ext: String)] = [:],
                             assets: [String: (data: Data, ext: String)] = [:],
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
        if !assets.isEmpty {
            let dir = url.appendingPathComponent("assets")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for (id, media) in assets {
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
        // v2 packages kept backgrounds in bg/; merge them into the asset index.
        var assets = mediaIndex(dir: url.appendingPathComponent("bg"))
        assets.merge(mediaIndex(dir: url.appendingPathComponent("assets"))) { _, new in new }
        return Contents(document: document,
                        audioURLs: mediaIndex(dir: url.appendingPathComponent("audio")),
                        assetURLs: assets)
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
