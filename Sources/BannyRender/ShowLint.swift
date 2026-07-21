import Foundation
import BannyCore

/// Semantic checks an agent runs before shipping. Decode failures are the
/// caller's problem (they throw earlier); this catches what decodes fine but
/// renders wrong or silently drops content.
public enum ShowLint {
    public struct Diagnostic: Codable, Equatable, Sendable {
        public enum Severity: String, Codable, Sendable { case error, warning }
        public var severity: Severity
        public var message: String

        public init(_ severity: Severity, _ message: String) {
            self.severity = severity
            self.message = message
        }
    }

    /// - Parameters:
    ///   - audioIDs: clip ids that have a file in the package's `audio/`.
    ///   - assetFileIDs: asset ids that have a file in the package's `assets/`.
    ///   - catalog: nil skips wardrobe-name checks (assets unavailable).
    public static func check(document: ShowDocument,
                             audioIDs: Set<String>,
                             assetFileIDs: Set<String>,
                             catalog: AssetCatalog?) -> [Diagnostic] {
        var out: [Diagnostic] = []
        let stage = document.stage
        let bankIDs = Set(document.assets.map(\.id))

        for (i, ch) in stage.characters.enumerated() {
            let who = ch.name.isEmpty ? "character \(i + 1)" : ch.name
            if let catalog {
                for (slot, name) in ch.baseOutfit.sorted(by: { $0.key < $1.key })
                    where catalog.outfitSlot(name) == nil {
                    out.append(.init(.error, "\(who): baseOutfit slot \(slot) references unknown outfit \"\(name)\" — run `banny catalog` for valid names"))
                }
            }
            for event in ch.events {
                if event.t < 0 {
                    out.append(.init(.error, "\(who): event at t=\(clean(event.t)) is before 0"))
                }
                if case .outfit(_, let slot, let name) = event, let name, let catalog {
                    switch catalog.outfitSlot(name) {
                    case nil:
                        out.append(.init(.error, "\(who): outfit event references unknown outfit \"\(name)\""))
                    case .some(let actual) where actual != slot:
                        out.append(.init(.warning, "\(who): outfit \"\(name)\" belongs to slot \(actual), event says slot \(slot)"))
                    default: break
                    }
                }
            }
            checkClips(ch.clips, owner: who, audioIDs: audioIDs, into: &out)
            checkCues(ch.subs.map { ("subtitle \"\($0.text)\"", $0.start, $0.dur) }, owner: who, into: &out)
        }

        for track in stage.audioTracks {
            checkClips(track.clips, owner: "track \"\(track.name)\"", audioIDs: audioIDs, into: &out)
            checkAssetRefs(track.cues.map { ($0.id, $0.assetID, $0.start, $0.dur) },
                           owner: "track \"\(track.name)\"", bankIDs: bankIDs, into: &out)
        }
        for track in stage.imageTracks {
            checkAssetRefs(track.cues.map { ($0.id, $0.assetID, $0.start, $0.dur) },
                           owner: "image track \"\(track.name)\"", bankIDs: bankIDs, into: &out)
        }
        for track in stage.backgroundTracks {
            checkAssetRefs(track.cues.map { ($0.id, $0.assetID, $0.start, $0.dur) },
                           owner: "background track \"\(track.name)\"", bankIDs: bankIDs, into: &out)
        }
        for asset in document.assets where !assetFileIDs.contains(asset.id) {
            out.append(.init(.error, "asset \"\(asset.name)\" (\(asset.id)) has no file in assets/"))
        }
        return out
    }

    private static func checkClips(_ clips: [AudioClip], owner: String,
                                   audioIDs: Set<String>, into out: inout [Diagnostic]) {
        for clip in clips {
            if !audioIDs.contains(clip.id) {
                out.append(.init(.error, "\(owner): audio clip \"\(clip.name)\" (\(clip.id)) has no file in audio/"))
            }
            if clip.dur <= 0 {
                out.append(.init(.error, "\(owner): audio clip \"\(clip.name)\" has non-positive duration \(clean(clip.dur))"))
            }
        }
    }

    private static func checkCues(_ items: [(label: String, start: Double, dur: Double)],
                                  owner: String, into out: inout [Diagnostic]) {
        for item in items where item.dur <= 0 || item.start < 0 {
            out.append(.init(.error, "\(owner): \(item.label) has invalid range start=\(clean(item.start)) dur=\(clean(item.dur))"))
        }
    }

    private static func checkAssetRefs(_ cues: [(id: String, assetID: String, start: Double, dur: Double)],
                                       owner: String, bankIDs: Set<String>, into out: inout [Diagnostic]) {
        for cue in cues {
            if !bankIDs.contains(cue.assetID) {
                out.append(.init(.error, "\(owner): cue \(cue.id) references unknown asset \"\(cue.assetID)\""))
            }
            if cue.dur <= 0 || cue.start < 0 {
                out.append(.init(.error, "\(owner): cue \(cue.id) has invalid range start=\(clean(cue.start)) dur=\(clean(cue.dur))"))
            }
        }
    }

    private static func clean(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }
}
