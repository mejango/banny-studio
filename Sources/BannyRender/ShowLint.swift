import Foundation
import BannyCore

/// Semantic integrity checks shared by the editor and command-line tooling.
/// Decode failures are the caller's problem (they throw earlier); this catches
/// what decodes successfully but renders wrong or silently drops content.
public enum ShowLint {
    /// Validation policy for the caller. Normal rendering tolerates the
    /// editor's repairable container shape; raw JSON replacement must preserve
    /// the canonical schema and identity invariants before it is applied.
    public enum Profile: Sendable {
        case renderable
        case editableShow
    }

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
                             catalog: AssetCatalog?,
                             profile: Profile = .renderable) -> [Diagnostic] {
        var out: [Diagnostic] = []
        let stage = document.stage
        if case .editableShow = profile {
            checkEditableStructure(document, into: &out)
        }
        let bankIDs = Set(document.assets.map(\.id))
        let reactionIDs = stage.reactionLibrary.map(\.id)
        let reactionsByID = Dictionary(stage.reactionLibrary.map { ($0.id, $0) },
                                       uniquingKeysWith: { first, _ in first })
        if reactionsByID.count != reactionIDs.count {
            out.append(.init(.error, "reaction library contains duplicate identifiers"))
        }
        for reaction in stage.reactionLibrary {
            let label = "reaction \"\(reaction.name)\""
            if reaction.id.isEmpty {
                out.append(.init(.error, "reaction library contains an empty identifier"))
            }
            if reaction.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(.init(.warning, "reaction \"\(reaction.id)\" has no name"))
            }
            if reaction.dur <= 0 {
                out.append(.init(.error, "\(label) has non-positive duration \(clean(reaction.dur))"))
            }
            if reaction.events.isEmpty {
                out.append(.init(.warning, "\(label) has no performance or outfit events"))
            }
            if zip(reaction.events, reaction.events.dropFirst())
                .contains(where: { pair in pair.0.t > pair.1.t }) {
                out.append(.init(.error, "\(label) events are not sorted by time"))
            }
            for event in reaction.events {
                if event.t < 0 || event.t > reaction.dur + 1e-9 {
                    out.append(.init(.error, "\(label) has event outside its range at t=\(clean(event.t))"))
                }
                if case .outfit(_, let slot, let name) = event, let name, let catalog {
                    checkOutfit(name: name, slot: slot, owner: label, catalog: catalog, into: &out)
                }
            }
        }

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
                    checkOutfit(name: name, slot: slot, owner: who,
                                catalog: catalog, into: &out)
                }
            }
            let instanceIDs = ch.reactions.map(\.id)
            if Set(instanceIDs).count != instanceIDs.count {
                out.append(.init(.error, "\(who): reaction blocks contain duplicate identifiers"))
            }
            for block in ch.reactions {
                if block.id.isEmpty {
                    out.append(.init(.error, "\(who): reaction block has an empty identifier"))
                }
                if reactionsByID[block.reactionID] == nil {
                    out.append(.init(.error, "\(who): reaction block \(block.id) references unknown reaction \"\(block.reactionID)\""))
                }
                if block.start < 0 || block.dur <= 0 {
                    out.append(.init(.error, "\(who): reaction block \(block.id) has invalid range start=\(clean(block.start)) dur=\(clean(block.dur))"))
                }
                if block.intensity < 0 || block.intensity > 4 {
                    out.append(.init(.error, "\(who): reaction block \(block.id) has intensity outside 0...4"))
                }
            }
            if let pivot = ch.rotationPivot,
               !pivot.x.isFinite || !pivot.y.isFinite
                || !(0...1).contains(pivot.x) || !(0...1).contains(pivot.y) {
                out.append(.init(
                    .error,
                    "\(who): rotation pivot must contain finite x/y values inside 0...1"))
            }
            checkVoiceRecipe(ch.speechVoice.recipe, owner: who, into: &out)
            checkClips(ch.clips, owner: who, audioIDs: audioIDs, into: &out)
            checkCues(ch.subs.map { ("subtitle \"\($0.text)\"", $0.start, $0.dur) }, owner: who, into: &out)
        }

        for track in stage.audioTracks {
            checkClips(track.clips, owner: "track \"\(track.name)\"", audioIDs: audioIDs, into: &out)
            checkAssetRefs(track.cues.map { ($0.id, $0.assetID, $0.start, $0.dur) },
                           owner: "track \"\(track.name)\"", bankIDs: bankIDs, into: &out)
            for cue in track.cues { checkVisualCue(cue, owner: "track \"\(track.name)\"", into: &out) }
        }
        for track in stage.imageTracks {
            checkAssetRefs(track.cues.map { ($0.id, $0.assetID, $0.start, $0.dur) },
                           owner: "image track \"\(track.name)\"", bankIDs: bankIDs, into: &out)
            for cue in track.cues {
                checkVisualCue(cue, owner: "image track \"\(track.name)\"", into: &out)
            }
        }
        for track in stage.backgroundTracks {
            checkAssetRefs(track.cues.map { ($0.id, $0.assetID, $0.start, $0.dur) },
                           owner: "background track \"\(track.name)\"", bankIDs: bankIDs, into: &out)
        }
        for track in stage.lightTracks {
            let owner = "light track \"\(track.name)\""
            checkCues(track.cues.map { ("cue \($0.id)", $0.start, $0.dur) },
                      owner: owner, into: &out)
            for cue in track.cues {
                checkLightState(cue.from, cueID: cue.id, owner: owner, into: &out)
                if let to = cue.to {
                    checkLightState(to, cueID: cue.id, owner: owner, into: &out)
                }
            }
        }
        let markerIDs = stage.markers.map(\.id)
        if Set(markerIDs).count != markerIDs.count {
            out.append(.init(.error, "timeline markers contain duplicate identifiers"))
        }
        for marker in stage.markers {
            let label = marker.kind == .section ? "section" : "marker"
            if marker.id.isEmpty {
                out.append(.init(.error, "timeline \(label) has an empty identifier"))
            }
            if marker.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(.init(.warning, "timeline \(label) \(marker.id) has no name"))
            }
            if !marker.start.isFinite || marker.start < 0 {
                out.append(.init(.error, "timeline \(label) \"\(marker.name)\" has invalid start \(clean(marker.start))"))
            }
            if marker.kind == .section,
               !marker.duration.isFinite || marker.duration <= 0 {
                out.append(.init(.error, "timeline section \"\(marker.name)\" has invalid duration \(clean(marker.duration))"))
            }
        }
        for asset in document.assets where !assetFileIDs.contains(asset.id) {
            out.append(.init(.error, "asset \"\(asset.name)\" (\(asset.id)) has no file in assets/"))
        }
        return out
    }

    private static func checkEditableStructure(_ document: ShowDocument,
                                               into out: inout [Diagnostic]) {
        let stage = document.stage
        if document.version != 4 {
            out.append(.init(.error, "The editable show schema version must remain 4."))
        }
        if stage.backgroundTracks.count != 1 {
            out.append(.init(.error, "The show must contain exactly one Scenes track."))
        }

        checkIdentifiers(document.assets.map(\.id), label: "asset", into: &out)
        checkIdentifiers(stage.audioTracks.map(\.id)
                         + stage.imageTracks.map(\.id)
                         + stage.lightTracks.map(\.id)
                         + stage.backgroundTracks.map(\.id), label: "track", into: &out)
        let audioIDs = stage.characters.flatMap(\.clips).map(\.id)
            + stage.audioTracks.flatMap(\.clips).map(\.id)
        if audioIDs.contains("") {
            out.append(.init(.error, "Audio clip identifiers cannot be empty."))
        }
        checkIdentifiers(stage.imageTracks.flatMap(\.cues).map(\.id)
                         + stage.audioTracks.flatMap(\.cues).map(\.id),
                         label: "visual cue", into: &out)
        checkIdentifiers(stage.backgroundTracks.flatMap(\.cues).map(\.id),
                         label: "scene cue", into: &out)
        checkIdentifiers(stage.lightTracks.flatMap(\.cues).map(\.id),
                         label: "light cue", into: &out)
        checkIdentifiers(stage.markers.map(\.id), label: "timeline marker", into: &out)
    }

    /// Audio clip identifiers are reusable media references, so this helper is
    /// intentionally used only for true editor identities.
    private static func checkIdentifiers(_ values: [String], label: String,
                                         into out: inout [Diagnostic]) {
        var seen: Set<String> = []
        var duplicates: Set<String> = []
        for value in values where !value.isEmpty {
            if !seen.insert(value).inserted { duplicates.insert(value) }
        }
        if !duplicates.isEmpty {
            out.append(.init(.error,
                             "Duplicate \(label) identifiers: \(duplicates.sorted().joined(separator: ", "))."))
        }
        if values.contains("") {
            out.append(.init(.error, "\(label.capitalized) identifiers cannot be empty."))
        }
    }

    private static func checkClips(_ clips: [AudioClip], owner: String,
                                   audioIDs: Set<String>, into out: inout [Diagnostic]) {
        for clip in clips {
            if !audioIDs.contains(clip.id) {
                out.append(.init(.error, "\(owner): audio clip \"\(clip.name)\" (\(clip.id)) has no file in audio/"))
            }
            if !clip.dur.isFinite || clip.dur <= 0 {
                out.append(.init(.error, "\(owner): audio clip \"\(clip.name)\" has non-positive duration \(clean(clip.dur))"))
            }
            if !clip.start.isFinite || clip.start < 0 {
                out.append(.init(.error, "\(owner): audio clip \"\(clip.name)\" starts before 0 (start=\(clean(clip.start)))"))
            }
            if !clip.offset.isFinite || clip.offset < 0
                || !clip.srcDur.isFinite || clip.srcDur <= 0
                || clip.offset + clip.dur > clip.srcDur + 0.001 {
                out.append(.init(.error, "\(owner): audio clip \"\(clip.name)\" has invalid source range offset=\(clean(clip.offset)) dur=\(clean(clip.dur)) source=\(clean(clip.srcDur))"))
            }
            if !clip.fadeIn.isFinite || clip.fadeIn < 0 || clip.fadeIn > max(0, clip.dur) {
                out.append(.init(.error, "\(owner): audio clip \"\(clip.name)\" has invalid fade-in \(clean(clip.fadeIn))"))
            }
            if !clip.fadeOut.isFinite || clip.fadeOut < 0 || clip.fadeOut > max(0, clip.dur) {
                out.append(.init(.error, "\(owner): audio clip \"\(clip.name)\" has invalid fade-out \(clean(clip.fadeOut))"))
            }
            if zip(clip.mouthCues, clip.mouthCues.dropFirst())
                .contains(where: { $0.start > $1.start }) {
                out.append(.init(.error, "\(owner): speech clip \"\(clip.name)\" mouth timing is not sorted"))
            }
            for cue in clip.mouthCues {
                if !cue.start.isFinite || !cue.dur.isFinite
                    || cue.start < 0 || cue.dur <= 0
                    || cue.start + cue.dur > clip.srcDur + 0.001 {
                    out.append(.init(.error, "\(owner): speech clip \"\(clip.name)\" has mouth cue outside its source at \(clean(cue.start))"))
                }
            }
        }
    }

    private static func checkVoiceRecipe(_ recipe: VoiceRecipe, owner: String,
                                         into out: inout [Diagnostic]) {
        let values = [
            recipe.flavor, recipe.pitchCents, recipe.low, recipe.mid, recipe.high,
            recipe.compression, recipe.distortionMix, recipe.delayTime,
            recipe.delayFeedback, recipe.delayMix, recipe.reverbMix,
            recipe.doubling, recipe.outputGainDB,
        ]
        if values.contains(where: { !$0.isFinite }) {
            out.append(.init(.error, "\(owner): voice recipe contains a non-finite value"))
            return
        }
        if !(0...1).contains(recipe.flavor)
            || !(-2_400...2_400).contains(recipe.pitchCents)
            || !(-24...24).contains(recipe.low)
            || !(-24...24).contains(recipe.mid)
            || !(-24...24).contains(recipe.high)
            || !(0...1).contains(recipe.compression)
            || !(0...1).contains(recipe.distortionMix)
            || !(0.001...0.5).contains(recipe.delayTime)
            || !(0...0.8).contains(recipe.delayFeedback)
            || !(0...1).contains(recipe.delayMix)
            || !(0...1).contains(recipe.reverbMix)
            || !(0...1).contains(recipe.doubling)
            || !(-24...12).contains(recipe.outputGainDB) {
            out.append(.init(.error, "\(owner): voice recipe contains a value outside its supported range"))
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

    private static func checkVisualCue(_ cue: ImageCue, owner: String,
                                       into out: inout [Diagnostic]) {
        func error(_ message: String) {
            out.append(.init(.error, "\(owner): cue \(cue.id) \(message)"))
        }
        if cue.playback.rate <= 0 { error("has non-positive playback rate") }
        if cue.playback.trimStart < 0 { error("has a trim-in before 0") }
        if cue.playback.phaseOffset < 0 { error("has a playback phase before 0") }
        if let end = cue.playback.trimEnd, end <= cue.playback.trimStart {
            error("has trim-out at or before trim-in")
        }
        if !(0...1).contains(cue.pivot.x) || !(0...1).contains(cue.pivot.y) {
            error("has a pivot outside 0...1")
        }
        if !(0...0.5).contains(cue.maskRadius) { error("has maskRadius outside 0...0.5") }
        if cue.appearance.outline < 0 { error("has a negative outline width") }
        if !(0...1).contains(cue.appearance.shadow) { error("has shadow outside 0...1") }
        if !(0...1).contains(cue.appearance.cleanup) { error("has cleanup outside 0...1") }
        if !(0...1).contains(cue.appearance.tintAmount) { error("has tintAmount outside 0...1") }
        if cue.from.scale <= 0 || (cue.to?.scale ?? 1) <= 0 {
            error("has a non-positive placement scale")
        }
    }

    private static func checkLightState(_ state: LightState, cueID: String,
                                        owner: String, into out: inout [Diagnostic]) {
        if !(0...1).contains(state.intensity) {
            out.append(.init(.error, "\(owner): cue \(cueID) has intensity outside 0...1"))
        }
        if state.size <= 0 {
            out.append(.init(.error, "\(owner): cue \(cueID) has non-positive size"))
        }
    }

    private static func checkOutfit(name: String, slot: Int, owner: String,
                                    catalog: AssetCatalog, into out: inout [Diagnostic]) {
        switch catalog.outfitSlot(name) {
        case nil:
            out.append(.init(.error, "\(owner): outfit event references unknown outfit \"\(name)\""))
        case .some(let actual) where actual != slot:
            out.append(.init(.warning, "\(owner): outfit \"\(name)\" belongs to slot \(actual), event says slot \(slot)"))
        default: break
        }
    }

    private static func clean(_ v: Double) -> String {
        guard v.isFinite else { return String(v) }
        return v == v.rounded() ? String(Int(v)) : String(v)
    }
}
