import Foundation
import BannyCore
import BannyMedia
import BannyRender

enum ShippingSupport {
    /// One shared preflight for local export and direct publishing.
    static func preflight(document: ShowDocument,
                          availableAudioIDs: Set<String>,
                          availableAssetIDs: Set<String>) -> String? {
        let stage = document.stage
        let referencedAudio = Set(
            stage.characters.flatMap(\.clips).map(\.id)
                + stage.audioTracks.flatMap(\.clips).map(\.id))
        let referencedAssets = Set(
            stage.backgroundTracks.flatMap(\.cues).map(\.assetID)
                + stage.imageTracks.flatMap(\.cues).map(\.assetID)
                + stage.audioTracks.flatMap(\.cues).map(\.assetID))
        let missing = referencedAudio.subtracting(availableAudioIDs).count
            + referencedAssets.subtracting(availableAssetIDs).count
        if missing > 0 {
            return "\(missing) linked media \(missing == 1 ? "file is" : "files are") missing. Open Browse → Media and relink before exporting."
        }

        let blocking = ShowExportPreflight.errors(
            document: document,
            availableAudioIDs: availableAudioIDs,
            availableAssetIDs: availableAssetIDs,
            catalog: SharedAssets.catalog)
        guard !blocking.isEmpty else { return nil }
        let visible = blocking.prefix(4).map { "• \($0)" }
        let remainder = blocking.count - visible.count
        let suffix = remainder > 0 ? "\n…and \(remainder) more." : ""
        return "This show needs attention before export:\n\(visible.joined(separator: "\n"))\(suffix)"
    }

    struct MaterializedMedia {
        let audioURLs: [String: URL]
        let assetURLs: [String: URL]
    }

    static func materialize(
        audio: [String: (data: Data, ext: String)],
        assets: [String: (data: Data, ext: String)],
        in directory: URL
    ) throws -> MaterializedMedia {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        var audioURLs: [String: URL] = [:]
        for (index, id) in audio.keys.sorted().enumerated() {
            guard let media = audio[id] else { continue }
            let url = directory.appendingPathComponent(
                "audio-\(index).\(safeExtension(media.ext))")
            try media.data.write(to: url)
            audioURLs[id] = url
        }
        var assetURLs: [String: URL] = [:]
        for (index, id) in assets.keys.sorted().enumerated() {
            guard let media = assets[id] else { continue }
            let url = directory.appendingPathComponent(
                "asset-\(index).\(safeExtension(media.ext))")
            try media.data.write(to: url)
            assetURLs[id] = url
        }
        return MaterializedMedia(audioURLs: audioURLs, assetURLs: assetURLs)
    }

    private static func safeExtension(_ value: String) -> String {
        let filtered = value.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        let result = String(String.UnicodeScalarView(filtered))
        return result.isEmpty ? "bin" : String(result.prefix(12))
    }
}
