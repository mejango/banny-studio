import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import BannyCore
import BannyMedia
import BannyRender

/// The bounded, dependency-free upload shape accepted by `POST /v1/rooms`.
public struct LiveRoomMediaUpload: Codable, Equatable, Sendable {
    public var filename: String
    public var contentType: String
    public var base64: String

    public init(filename: String, contentType: String, base64: String) {
        self.filename = filename
        self.contentType = contentType
        self.base64 = base64
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case filename
        case contentType = "content_type"
        case base64
    }

    public init(from decoder: Decoder) throws {
        try liveRoomRejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filename = try container.decode(String.self, forKey: .filename)
        contentType = try container.decode(String.self, forKey: .contentType)
        base64 = try container.decode(String.self, forKey: .base64)
    }
}

public struct LiveRoomCreateRequest: Codable, Equatable, Sendable {
    public var title: String
    public var premise: String?
    public var background: LiveRoomMediaUpload
    public var music: LiveRoomMediaUpload
    public var maxOccupancy: Int
    public var allowlist: [String]
    public var animateStill: Bool

    public init(
        title: String,
        premise: String? = nil,
        background: LiveRoomMediaUpload,
        music: LiveRoomMediaUpload,
        maxOccupancy: Int,
        allowlist: [String] = [],
        animateStill: Bool = false
    ) {
        self.title = title
        self.premise = premise
        self.background = background
        self.music = music
        self.maxOccupancy = maxOccupancy
        self.allowlist = allowlist
        self.animateStill = animateStill
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case title, premise, background, music, allowlist
        case maxOccupancy = "max_occupancy"
        case animateStill = "animate_still"
    }

    public init(from decoder: Decoder) throws {
        try liveRoomRejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        premise = try container.decodeIfPresent(String.self, forKey: .premise)
        background = try container.decode(LiveRoomMediaUpload.self, forKey: .background)
        music = try container.decode(LiveRoomMediaUpload.self, forKey: .music)
        maxOccupancy = try container.decode(Int.self, forKey: .maxOccupancy)
        allowlist = try container.decodeIfPresent([String].self, forKey: .allowlist) ?? []
        animateStill = try container.decodeIfPresent(Bool.self, forKey: .animateStill) ?? false
    }
}

public struct LiveRoomPackageSeed: Sendable {
    public let packageURL: URL
    public let document: ShowDocument
    public let backgroundURL: URL
    public let musicURL: URL
    public let backgroundWasShimmered: Bool

    public init(
        packageURL: URL,
        document: ShowDocument,
        backgroundURL: URL,
        musicURL: URL,
        backgroundWasShimmered: Bool
    ) {
        self.packageURL = packageURL
        self.document = document
        self.backgroundURL = backgroundURL
        self.musicURL = musicURL
        self.backgroundWasShimmered = backgroundWasShimmered
    }
}

public enum LiveRoomPackageBuilderError: Error, Equatable, Sendable, LocalizedError {
    case invalidTitle
    case invalidPremise
    case invalidOccupancy
    case invalidAllowlistIdentity
    case duplicateAllowlistIdentity
    case allowlistTooLarge
    case invalidFilename(String)
    case invalidBase64(String)
    case uploadTooLarge
    case invalidBackground
    case invalidMusic
    case stillAnimationRequiresStillImage
    case outputExists
    case invalidPackage([String])

    public var errorDescription: String? {
        switch self {
        case .invalidTitle:
            "Room titles must contain 1...100 visible characters."
        case .invalidPremise:
            "Room premises may contain at most 2,000 visible characters."
        case .invalidOccupancy:
            "Room occupancy must be inside 1...10."
        case .invalidAllowlistIdentity:
            "Allowlist identities must contain 1...200 visible characters."
        case .duplicateAllowlistIdentity:
            "The room allowlist contains a duplicate identity."
        case .allowlistTooLarge:
            "A room recording can contain at most 10 invited identities."
        case .invalidFilename(let name):
            "The uploaded filename is not accepted: \(name)."
        case .invalidBase64(let name):
            "The uploaded file is not valid base64: \(name)."
        case .uploadTooLarge:
            "The decoded room media exceeds the 70 MiB limit."
        case .invalidBackground:
            "The room background must be a decodable image or video."
        case .invalidMusic:
            "The room soundtrack must be a decodable MP3."
        case .stillAnimationRequiresStillImage:
            "Still animation can be enabled only for a non-animated image."
        case .outputExists:
            "A recording package already exists for this room."
        case .invalidPackage(let messages):
            "The generated Banny Studio package is invalid: \(messages.joined(separator: "; "))."
        }
    }
}

/// Creates the editable recording package before a room is published.
///
/// Creation is staged in a hidden sibling directory and the completed room
/// directory is moved into place only after strict-v4 decoding and editable
/// lint both succeed. Room credentials and admission policy are intentionally
/// absent from this API's document model.
public enum LiveRoomPackageBuilder {
    /// Keeps the base64 JSON create request below the common 100 MB edge
    /// ceiling while still leaving room for metadata and encoding padding.
    public static let maximumDecodedMediaBytes = 70 * 1_024 * 1_024
    public static let maximumBackgroundPixels = 16 * 1_024 * 1_024
    public static let maximumAnimatedImageFrames = 600
    /// 64 Mi-pixels, or roughly 256 MiB if every frame is decoded as RGBA.
    public static let maximumAnimatedImageAggregatePixels = 64 * 1_024 * 1_024
    public static let maximumShimmerPixels = 4 * 1_024 * 1_024
    public static let recordingHorizonSeconds: Double = 3_600

    private static let acceptedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif",
    ]
    private static let acceptedVideoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "webm",
    ]

    public static func create(
        request: LiveRoomCreateRequest,
        roomID: String,
        storageURL: URL,
        catalog: AssetCatalog? = nil
    ) async throws -> LiveRoomPackageSeed {
        try validateMetadata(request)
        guard Self.isSafeIdentifier(roomID) else {
            throw LiveRoomPackageBuilderError.invalidFilename(roomID)
        }

        let backgroundData = try decoded(request.background)
        let musicData = try decoded(request.music)
        guard backgroundData.count <= maximumDecodedMediaBytes,
              musicData.count <= maximumDecodedMediaBytes,
              backgroundData.count <= maximumDecodedMediaBytes - musicData.count
        else { throw LiveRoomPackageBuilderError.uploadTooLarge }

        let fm = FileManager.default
        try fm.createDirectory(at: storageURL, withIntermediateDirectories: true)
        let finalRoomURL = storageURL.appendingPathComponent(roomID, isDirectory: true)
        guard !fm.fileExists(atPath: finalRoomURL.path) else {
            throw LiveRoomPackageBuilderError.outputExists
        }

        let stagingURL = storageURL.appendingPathComponent(
            ".\(roomID)-\(UUID().uuidString.lowercased()).tmp",
            isDirectory: true)
        try fm.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        do {
            let inputURL = stagingURL.appendingPathComponent("input", isDirectory: true)
            try fm.createDirectory(at: inputURL, withIntermediateDirectories: false)

            let backgroundExtension = try safeExtension(
                request.background.filename,
                fallbackContentType: request.background.contentType)
            let musicExtension = try safeExtension(
                request.music.filename,
                fallbackContentType: request.music.contentType)
            let uploadedBackgroundURL = inputURL.appendingPathComponent(
                "background.\(backgroundExtension)")
            let uploadedMusicURL = inputURL.appendingPathComponent("music.\(musicExtension)")
            try backgroundData.write(to: uploadedBackgroundURL, options: .atomic)
            try musicData.write(to: uploadedMusicURL, options: .atomic)

            let backgroundProbe = try await inspectBackground(
                uploadedBackgroundURL,
                fileExtension: backgroundExtension,
                byteCount: backgroundData.count)
            let musicProbe: MediaProbeResult
            do { musicProbe = try await MediaProbe.inspect(uploadedMusicURL) }
            catch { throw LiveRoomPackageBuilderError.invalidMusic }
            guard backgroundProbe.kind == .image || backgroundProbe.kind == .video else {
                throw LiveRoomPackageBuilderError.invalidBackground
            }
            let validBackgroundExtensions = backgroundProbe.kind == .image
                ? acceptedImageExtensions
                : acceptedVideoExtensions
            guard validBackgroundExtensions.contains(backgroundExtension),
                  let width = backgroundProbe.width,
                  let height = backgroundProbe.height,
                  width > 0, height > 0,
                  width <= maximumBackgroundPixels / height
            else { throw LiveRoomPackageBuilderError.invalidBackground }
            let backgroundPixels = width * height
            guard musicProbe.kind == .audio,
                  musicExtension == "mp3",
                  isMPEGLayerIII(uploadedMusicURL)
            else { throw LiveRoomPackageBuilderError.invalidMusic }
            if request.animateStill,
               backgroundProbe.kind != .image || backgroundProbe.animated {
                throw LiveRoomPackageBuilderError.stillAnimationRequiresStillImage
            }

            let roomPackageURL = stagingURL.appendingPathComponent(
                "recording.bs", isDirectory: true)
            try fm.createDirectory(at: roomPackageURL, withIntermediateDirectories: false)
            let assetsDirectory = roomPackageURL.appendingPathComponent("assets", isDirectory: true)
            let audioDirectory = roomPackageURL.appendingPathComponent("audio", isDirectory: true)
            try fm.createDirectory(at: assetsDirectory, withIntermediateDirectories: false)
            try fm.createDirectory(at: audioDirectory, withIntermediateDirectories: false)

            let backgroundID = "room-background"
            let musicID = "room-music"
            var packagedExtension = backgroundExtension
            var shimmered = false
            let packagedBackgroundURL: URL
            if request.animateStill, backgroundPixels <= maximumShimmerPixels {
                let gifURL = assetsDirectory.appendingPathComponent("\(backgroundID).gif")
                do {
                    _ = try ShimmerEncoder.encode(source: uploadedBackgroundURL, to: gifURL)
                    packagedExtension = "gif"
                    packagedBackgroundURL = gifURL
                    shimmered = true
                } catch ShimmerEncoder.EncodingError.noPointLights,
                        ShimmerEncoder.EncodingError.outputTooLarge {
                    packagedBackgroundURL = assetsDirectory.appendingPathComponent(
                        "\(backgroundID).\(backgroundExtension)")
                    try backgroundData.write(to: packagedBackgroundURL, options: .atomic)
                }
            } else {
                packagedBackgroundURL = assetsDirectory.appendingPathComponent(
                    "\(backgroundID).\(backgroundExtension)")
                try backgroundData.write(to: packagedBackgroundURL, options: .atomic)
            }

            let packagedMusicURL = audioDirectory.appendingPathComponent("\(musicID).mp3")
            try musicData.write(to: packagedMusicURL, options: .atomic)

            let document = makeDocument(
                request: request,
                backgroundProbe: backgroundProbe,
                backgroundID: backgroundID,
                backgroundExtension: packagedExtension,
                backgroundWasShimmered: shimmered,
                musicID: musicID,
                musicDuration: musicProbe.duration ?? 1)
            let canonical = try ShowJSONCodec.encode(document: document)
            let showURL = roomPackageURL.appendingPathComponent("show.json")
            try Data(canonical.utf8).write(to: showURL, options: .atomic)

            // Strict decode ensures accidental unknown or legacy fields cannot
            // enter a newly created room recording.
            let decoded = try ShowJSONCodec.decodeDocument(canonical)
            let diagnostics = ShowLint.check(
                document: decoded,
                audioIDs: [musicID],
                assetFileIDs: [backgroundID],
                catalog: catalog,
                profile: .editableShow)
            let errors = diagnostics
                .filter { $0.severity == .error }
                .map(\.message)
            guard errors.isEmpty else {
                throw LiveRoomPackageBuilderError.invalidPackage(errors)
            }

            try fm.removeItem(at: inputURL)
            try fm.moveItem(at: stagingURL, to: finalRoomURL)
            let finalPackageURL = finalRoomURL.appendingPathComponent("recording.bs")
            return LiveRoomPackageSeed(
                packageURL: finalPackageURL,
                document: decoded,
                backgroundURL: finalPackageURL.appendingPathComponent(
                    "assets/\(backgroundID).\(packagedExtension)"),
                musicURL: finalPackageURL.appendingPathComponent("audio/\(musicID).mp3"),
                backgroundWasShimmered: shimmered)
        } catch {
            try? fm.removeItem(at: stagingURL)
            throw error
        }
    }

    private static func validateMetadata(_ request: LiveRoomCreateRequest) throws {
        guard visibleScalarCount(request.title, maximum: 100, allowEmpty: false) else {
            throw LiveRoomPackageBuilderError.invalidTitle
        }
        if let premise = request.premise,
           !visibleScalarCount(premise, maximum: 2_000, allowEmpty: true) {
            throw LiveRoomPackageBuilderError.invalidPremise
        }
        guard (1...10).contains(request.maxOccupancy) else {
            throw LiveRoomPackageBuilderError.invalidOccupancy
        }
        var seen: Set<String> = []
        guard request.allowlist.count <= 10 else {
            throw LiveRoomPackageBuilderError.allowlistTooLarge
        }
        for identity in request.allowlist {
            guard visibleScalarCount(identity, maximum: 200, allowEmpty: false) else {
                throw LiveRoomPackageBuilderError.invalidAllowlistIdentity
            }
            guard seen.insert(identity).inserted else {
                throw LiveRoomPackageBuilderError.duplicateAllowlistIdentity
            }
        }
    }

    private static func visibleScalarCount(
        _ value: String,
        maximum: Int,
        allowEmpty: Bool
    ) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowEmpty || !trimmed.isEmpty,
              value.unicodeScalars.count <= maximum
        else { return false }
        return !value.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t"
        })
    }

    private static func decoded(_ upload: LiveRoomMediaUpload) throws -> Data {
        guard let data = Data(base64Encoded: upload.base64), !data.isEmpty else {
            throw LiveRoomPackageBuilderError.invalidBase64(upload.filename)
        }
        return data
    }

    /// Live-room image inspection walks at most 600 property dictionaries with
    /// ImageIO caching disabled. It validates each frame and the aggregate
    /// decoded-pixel budget without decoding pixel buffers or calculating
    /// animation timing.
    private static func inspectBackground(
        _ url: URL,
        fileExtension: String,
        byteCount: Int
    ) async throws -> MediaProbeResult {
        let imageOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        if let source = CGImageSourceCreateWithURL(url as CFURL, imageOptions) {
            let frameCount = CGImageSourceGetCount(source)
            if frameCount > 0 {
                guard frameCount <= maximumAnimatedImageFrames,
                      let detectedIdentifier = CGImageSourceGetType(source),
                      let detectedType = UTType(detectedIdentifier as String),
                      let claimedType = UTType(filenameExtension: fileExtension),
                      claimedType.conforms(to: .image),
                      detectedType == claimedType || detectedType.conforms(to: claimedType)
                else { throw LiveRoomPackageBuilderError.invalidBackground }

                var aggregatePixels = 0
                var firstWidth: Int?
                var firstHeight: Int?
                for index in 0..<frameCount {
                    try Task.checkCancellation()
                    guard let properties = CGImageSourceCopyPropertiesAtIndex(
                        source,
                        index,
                        imageOptions) as? [CFString: Any],
                        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?
                            .intValue,
                        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?
                            .intValue,
                        width > 0, height > 0,
                        width <= maximumBackgroundPixels / height,
                        width <= (maximumAnimatedImageAggregatePixels - aggregatePixels) / height
                    else { throw LiveRoomPackageBuilderError.invalidBackground }
                    aggregatePixels += width * height
                    if index == 0 {
                        firstWidth = width
                        firstHeight = height
                    }
                }
                guard let firstWidth, let firstHeight else {
                    throw LiveRoomPackageBuilderError.invalidBackground
                }

                return MediaProbeResult(
                    path: url.path,
                    kind: .image,
                    fileExtension: fileExtension,
                    mimeType: detectedType.preferredMIMEType,
                    byteCount: UInt64(byteCount),
                    duration: nil,
                    width: firstWidth,
                    height: firstHeight,
                    frameRate: nil,
                    animated: frameCount > 1)
            }
        }

        do { return try await MediaProbe.inspect(url) }
        catch { throw LiveRoomPackageBuilderError.invalidBackground }
    }

    /// AVFoundation exposes the stream format stored in the file, so a valid
    /// MPEG-1/2 Layer I or II stream cannot pass merely because it has an MPEG
    /// sync word or has been renamed to `.mp3`.
    private static func isMPEGLayerIII(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url),
              file.fileFormat.streamDescription.pointee.mFormatID
                == kAudioFormatMPEGLayer3,
              file.fileFormat.sampleRate > 0,
              file.length > 0
        else { return false }
        return true
    }

    private static func safeExtension(
        _ filename: String,
        fallbackContentType: String
    ) throws -> String {
        guard !filename.isEmpty, filename.count <= 255,
              !filename.contains("/"), !filename.contains("\\"),
              filename != ".", filename != ".."
        else { throw LiveRoomPackageBuilderError.invalidFilename(filename) }
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        let accepted = Set([
            "png", "jpg", "jpeg", "gif", "webp", "heic", "heif",
            "mov", "mp4", "m4v", "webm", "mp3",
        ])
        if accepted.contains(ext) { return ext }
        let fallback: String? = switch fallbackContentType.lowercased() {
        case "image/png": "png"
        case "image/jpeg": "jpg"
        case "image/gif": "gif"
        case "image/webp": "webp"
        case "video/quicktime": "mov"
        case "video/mp4": "mp4"
        case "video/webm": "webm"
        case "audio/mpeg", "audio/mp3": "mp3"
        default: nil
        }
        guard let fallback else {
            throw LiveRoomPackageBuilderError.invalidFilename(filename)
        }
        return fallback
    }

    private static func makeDocument(
        request: LiveRoomCreateRequest,
        backgroundProbe: MediaProbeResult,
        backgroundID: String,
        backgroundExtension: String,
        backgroundWasShimmered: Bool,
        musicID: String,
        musicDuration: Double
    ) -> ShowDocument {
        let assetKind: Asset.Kind = backgroundProbe.kind == .video ? .video : .image
        let useCameraDrift = request.animateStill && !backgroundWasShimmered
        let backgroundCues: [BackgroundCue]
        if useCameraDrift {
            // A gentle ping-pong move remains visible throughout the room. A
            // single hour-long interpolation would be effectively motionless.
            let leg = 12.0
            backgroundCues = stride(from: 0.0, to: recordingHorizonSeconds, by: leg)
                .enumerated()
                .map { index, start in
                    let forward = index.isMultiple(of: 2)
                    let left = CameraState(x: 0.495, y: 0.502, zoom: 1.018)
                    let right = CameraState(x: 0.505, y: 0.498, zoom: 1.035)
                    return BackgroundCue(
                        id: "room-background-cue-\(index + 1)",
                        assetID: backgroundID,
                        start: start,
                        dur: min(leg, recordingHorizonSeconds - start),
                        crop: .cover,
                        label: index == 0 ? request.title : nil,
                        camFrom: forward ? left : right,
                        camTo: forward ? right : left)
                }
        } else {
            backgroundCues = [BackgroundCue(
                id: "room-background-cue",
                assetID: backgroundID,
                start: 0,
                dur: recordingHorizonSeconds,
                crop: .cover,
                label: request.title)]
        }
        let duration = max(0.001, musicDuration)
        let musicClip = AudioClip(
            id: musicID,
            name: "Room music",
            start: 0,
            dur: duration,
            srcDur: duration,
            fadeIn: min(0.25, duration / 2),
            fadeOut: min(0.25, duration / 2),
            kind: .imported)
        let stage = SceneState(
            characters: [],
            reactionLibrary: SunsetBarPerformancePreset.reactionLibrary,
            audioTracks: [AudioTrack(
                id: "room-soundtrack",
                name: "Room soundtrack",
                clips: [musicClip])],
            backgroundTracks: [BackgroundTrack(
                id: "scenes",
                name: "Scenes",
                cues: backgroundCues)],
            gSize: SceneState.newSceneCharacterSize,
            wings: 0.12,
            rowOrder: ["scenes", "room-soundtrack"])
        let frameW = Double(backgroundProbe.width ?? 16)
        let frameH = Double(backgroundProbe.height ?? 9)
        return ShowDocument(
            stage: stage,
            assets: [Asset(
                id: backgroundID,
                name: "Room background",
                kind: assetKind,
                file: "\(backgroundID).\(backgroundExtension)")],
            settings: Settings(frameW: frameW, frameH: frameH))
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || $0 == "-" || $0 == "_"
        }
    }
}

private struct LiveRoomDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func liveRoomRejectUnknownKeys<Key: CodingKey & CaseIterable>(
    _ decoder: Decoder,
    allowed: Key.Type
) throws where Key.AllCases: Sequence {
    let allowedNames = Set(Key.allCases.map(\.stringValue))
    let container = try decoder.container(keyedBy: LiveRoomDynamicCodingKey.self)
    if let unknown = container.allKeys.first(where: {
        !allowedNames.contains($0.stringValue)
    }) {
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "Unknown field \(unknown.stringValue)."))
    }
}
