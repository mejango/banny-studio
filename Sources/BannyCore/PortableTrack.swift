import Foundation

/// A single Studio track plus every media file it references. The binary
/// property-list representation is saved as `.bannytrack`; keeping the archive
/// versioned lets future Studio builds migrate it independently of show files.
public struct PortableTrack: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public struct MediaFile: Codable, Equatable, Sendable {
        public var data: Data
        public var fileExtension: String

        public init(data: Data, fileExtension: String) {
            self.data = data
            self.fileExtension = fileExtension
        }
    }

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case character, audio, image, light, background
    }

    public enum Payload: Equatable, Sendable {
        case character(Character)
        case audio(AudioTrack)
        case image(ImageTrack)
        case light(LightTrack)
        case background(BackgroundTrack)

        public var kind: Kind {
            switch self {
            case .character: return .character
            case .audio: return .audio
            case .image: return .image
            case .light: return .light
            case .background: return .background
            }
        }

        public var name: String {
            switch self {
            case .character(let character):
                return character.name.isEmpty ? "\(character.body.rawValue) character" : character.name
            case .audio(let track): return track.name
            case .image(let track): return track.name
            case .light(let track): return track.name
            case .background(let track): return track.name
            }
        }

        public var referencedAudioIDs: Set<String> {
            switch self {
            case .character(let character): return Set(character.clips.map(\.id))
            case .audio(let track): return Set(track.clips.map(\.id))
            case .image, .light, .background: return []
            }
        }

        public var referencedAssetIDs: Set<String> {
            switch self {
            case .audio(let track): return Set(track.cues.map(\.assetID))
            case .image(let track): return Set(track.cues.map(\.assetID))
            case .background(let track): return Set(track.cues.map(\.assetID))
            case .character, .light: return []
            }
        }

        public var referencedReactionIDs: Set<String> {
            guard case .character(let character) = self else { return [] }
            return Set(character.reactions.map(\.reactionID))
        }
    }

    public var version: Int
    public var payload: Payload
    /// Reaction definitions required by a portable character's blocks.
    public var reactionLibrary: [ReactionDefinition]
    public var assets: [Asset]
    /// Source clip id -> the source audio bytes.
    public var audio: [String: MediaFile]
    /// Source asset id -> the image/video bytes.
    public var assetMedia: [String: MediaFile]

    public init(version: Int = PortableTrack.currentVersion, payload: Payload,
                reactionLibrary: [ReactionDefinition] = [], assets: [Asset] = [],
                audio: [String: MediaFile] = [:],
                assetMedia: [String: MediaFile] = [:]) {
        self.version = version
        self.payload = payload
        self.reactionLibrary = reactionLibrary
        self.assets = assets
        self.audio = audio
        self.assetMedia = assetMedia
    }

    private enum CodingKeys: String, CodingKey {
        case version, payload, reactionLibrary, assets, audio, assetMedia
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        payload = try c.decode(Payload.self, forKey: .payload)
        reactionLibrary = try c.decodeIfPresent([ReactionDefinition].self,
                                                forKey: .reactionLibrary) ?? []
        assets = try c.decodeIfPresent([Asset].self, forKey: .assets) ?? []
        audio = try c.decodeIfPresent([String: MediaFile].self, forKey: .audio) ?? [:]
        assetMedia = try c.decodeIfPresent([String: MediaFile].self, forKey: .assetMedia) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(payload, forKey: .payload)
        try c.encode(reactionLibrary, forKey: .reactionLibrary)
        try c.encode(assets, forKey: .assets)
        try c.encode(audio, forKey: .audio)
        try c.encode(assetMedia, forKey: .assetMedia)
    }

    /// Decodes and validates a `.bannytrack` file.
    public init(data: Data) throws {
        self = try PropertyListDecoder().decode(Self.self, from: data)
        try validate()
    }

    /// Encodes a compact, media-safe single file (Data is stored directly,
    /// rather than base64-inflated as it would be in JSON).
    public func encoded() throws -> Data {
        try validate()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    /// Reject incomplete archives before an import can silently lose media.
    public func validate() throws {
        guard version == Self.currentVersion else {
            throw PortableTrackError.unsupportedVersion(version)
        }
        for id in payload.referencedAudioIDs.sorted() where audio[id] == nil {
            throw PortableTrackError.missingAudio(id)
        }
        let reactionsByID = Dictionary(reactionLibrary.map { ($0.id, $0) },
                                       uniquingKeysWith: { first, _ in first })
        guard reactionsByID.count == reactionLibrary.count else {
            throw PortableTrackError.duplicateReactionID
        }
        for id in payload.referencedReactionIDs.sorted() where reactionsByID[id] == nil {
            throw PortableTrackError.missingReaction(id)
        }
        let assetsByID = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard assetsByID.count == assets.count else {
            throw PortableTrackError.duplicateAssetID
        }
        for id in payload.referencedAssetIDs.sorted() {
            guard assetsByID[id] != nil else { throw PortableTrackError.missingAsset(id) }
            guard assetMedia[id] != nil else { throw PortableTrackError.missingAssetMedia(id) }
        }
    }

    /// Produces an independent copy for insertion into a project. Track, cue,
    /// clip, and asset identifiers are all replaced; repeated references to the
    /// same source media continue to share one newly assigned identifier.
    public func remapped(makeID: () -> String) throws -> PortableTrack {
        try validate()

        let audioIDs = Set(audio.keys).union(payload.referencedAudioIDs)
        let assetIDs = Set(assets.map(\.id)).union(assetMedia.keys)
            .union(payload.referencedAssetIDs)
        let audioMap = Dictionary(uniqueKeysWithValues:
            audioIDs.sorted().map { ($0, makeID()) })
        let assetMap = Dictionary(uniqueKeysWithValues:
            assetIDs.sorted().map { ($0, makeID()) })
        let reactionIDs = Set(reactionLibrary.map(\.id)).union(payload.referencedReactionIDs)
        let reactionMap = Dictionary(uniqueKeysWithValues:
            reactionIDs.sorted().map { ($0, makeID()) })

        func remapClips(_ clips: [AudioClip]) -> [AudioClip] {
            clips.map { source in
                var clip = source
                clip.id = audioMap[source.id]!
                return clip
            }
        }
        func remapImageCues(_ cues: [ImageCue]) -> [ImageCue] {
            cues.map { source in
                var cue = source
                cue.id = makeID()
                cue.assetID = assetMap[source.assetID]!
                return cue
            }
        }

        let remappedPayload: Payload
        switch payload {
        case .character(var character):
            character.clips = remapClips(character.clips)
            for index in character.reactions.indices {
                character.reactions[index].id = makeID()
                character.reactions[index].reactionID = reactionMap[character.reactions[index].reactionID]!
            }
            remappedPayload = .character(character)
        case .audio(var track):
            track.id = makeID()
            track.clips = remapClips(track.clips)
            track.cues = remapImageCues(track.cues)
            remappedPayload = .audio(track)
        case .image(var track):
            track.id = makeID()
            track.cues = remapImageCues(track.cues)
            remappedPayload = .image(track)
        case .light(var track):
            track.id = makeID()
            for index in track.cues.indices { track.cues[index].id = makeID() }
            remappedPayload = .light(track)
        case .background(var track):
            track.id = makeID()
            for index in track.cues.indices {
                track.cues[index].id = makeID()
                track.cues[index].assetID = assetMap[track.cues[index].assetID]!
            }
            remappedPayload = .background(track)
        }

        let remappedAssets = assets.map { source -> Asset in
            var asset = source
            let newID = assetMap[source.id]!
            let ext = assetMedia[source.id]?.fileExtension
                ?? URL(fileURLWithPath: source.file).pathExtension
            asset.id = newID
            asset.file = ext.isEmpty ? newID : "\(newID).\(ext)"
            return asset
        }
        let remappedAudio = Dictionary(uniqueKeysWithValues: audio.map { id, media in
            (audioMap[id]!, media)
        })
        let remappedAssetMedia = Dictionary(uniqueKeysWithValues: assetMedia.map { id, media in
            (assetMap[id]!, media)
        })
        let remappedReactions = reactionLibrary.map { source -> ReactionDefinition in
            var reaction = source
            reaction.id = reactionMap[source.id]!
            return reaction
        }
        return PortableTrack(payload: remappedPayload, reactionLibrary: remappedReactions,
                             assets: remappedAssets,
                             audio: remappedAudio, assetMedia: remappedAssetMedia)
    }
}

extension PortableTrack.Payload: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, character, audio, image, light, background
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(PortableTrack.Kind.self, forKey: .kind) {
        case .character:
            self = .character(try container.decode(Character.self, forKey: .character))
        case .audio:
            self = .audio(try container.decode(AudioTrack.self, forKey: .audio))
        case .image:
            self = .image(try container.decode(ImageTrack.self, forKey: .image))
        case .light:
            self = .light(try container.decode(LightTrack.self, forKey: .light))
        case .background:
            self = .background(try container.decode(BackgroundTrack.self, forKey: .background))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .character(let character): try container.encode(character, forKey: .character)
        case .audio(let track): try container.encode(track, forKey: .audio)
        case .image(let track): try container.encode(track, forKey: .image)
        case .light(let track): try container.encode(track, forKey: .light)
        case .background(let track): try container.encode(track, forKey: .background)
        }
    }
}

public enum PortableTrackError: Error, Equatable, LocalizedError {
    case unsupportedVersion(Int)
    case missingAudio(String)
    case missingAsset(String)
    case missingAssetMedia(String)
    case duplicateAssetID
    case missingReaction(String)
    case duplicateReactionID

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "This track uses unsupported format version \(version)."
        case .missingAudio:
            return "This track is missing one of its audio files."
        case .missingAsset:
            return "This track is missing information about one of its media assets."
        case .missingAssetMedia:
            return "This track is missing one of its image or video files."
        case .duplicateAssetID:
            return "This track contains duplicate media identifiers."
        case .missingReaction:
            return "This character track is missing one of its reaction definitions."
        case .duplicateReactionID:
            return "This character track contains duplicate reaction identifiers."
        }
    }
}
