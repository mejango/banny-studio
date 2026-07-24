import Foundation
import BannyCore
import BannyRender
import BannyMedia

// Media production commands shared by the binary and integration tests.

private struct MediaImportReport: Codable {
    let project: String
    let id: String
    let target: String
    let start: Double
    let duration: Double
    let destination: String
    let mouthCues: Int
    let media: MediaProbeResult
}

func mediaCommand(_ args: [String]) async throws {
    guard let command = args.first else {
        throw CLIError.usage(
            "banny media <probe FILE [--json] | import FOLDER.BS FILE [options]>")
    }
    switch command {
    case "probe":
        try await mediaProbeCommand(Array(args.dropFirst()))
    case "import":
        try await mediaImportCommand(Array(args.dropFirst()))
    default:
        throw CLIError.usage(
            "banny media <probe FILE [--json] | import FOLDER.BS FILE [options]>")
    }
}

private func mediaProbeCommand(_ args: [String]) async throws {
    let usage = "banny media probe <file> [--json]"
    guard let path = args.first else { throw CLIError.usage(usage) }
    var options = CLIOptions(Array(args.dropFirst()))
    let json = try options.flag("--json")
    try options.finish(usage: usage)
    let result = try await MediaProbe.inspect(URL(fileURLWithPath: path))
    if json {
        try printJSON(result)
    } else {
        var facts = [result.kind.rawValue, "\(result.byteCount) bytes"]
        if let duration = result.duration {
            facts.append(String(format: "%.3fs", duration))
        }
        if let width = result.width, let height = result.height {
            facts.append("\(width)×\(height)")
        }
        if result.animated { facts.append("animated") }
        print("\(result.path): \(facts.joined(separator: " · "))")
    }
}

private func mediaImportCommand(_ args: [String]) async throws {
    let usage = """
    banny media import <project.bs> <file> [--id ID] [--name NAME] [--at SECONDS] \
    [--duration SECONDS] [--character N|--track ID|--background] \
    [--kind imported|microphone|speech] [--lipsync] \
    [--crop cover|fit|stretch|tile] [--x N --y N --scale N --rotation N] [--json]
    """
    guard args.count >= 2 else { throw CLIError.usage(usage) }
    let projectPath = args[0]
    let sourceURL = URL(fileURLWithPath: args[1])
    var options = CLIOptions(Array(args.dropFirst(2)))
    let requestedID = try options.value("--id")
    let requestedName = try options.value("--name")
    let start = try options.double("--at") ?? 0
    let requestedDuration = try options.double("--duration")
    let characterNumber = try options.int("--character")
    let trackID = try options.value("--track")
    let background = try options.flag("--background")
    let clipKindName = try options.value("--kind")
    let lipSync = try options.flag("--lipsync")
    let requestedCropName = try options.value("--crop")
    let requestedX = try options.double("--x")
    let requestedY = try options.double("--y")
    let requestedScale = try options.double("--scale")
    let requestedRotation = try options.double("--rotation")
    let cropName = requestedCropName ?? Crop.cover.rawValue
    let x = requestedX ?? 0.5
    let y = requestedY ?? 0.5
    let scale = requestedScale ?? 0.3
    let rotation = requestedRotation ?? 0
    let json = try options.flag("--json")
    try options.finish(usage: usage)

    guard start >= 0 else { throw CLIError.invalid("--at cannot be before 0") }
    if let requestedDuration, requestedDuration <= 0 {
        throw CLIError.invalid("--duration must be greater than 0")
    }
    guard scale > 0 else { throw CLIError.invalid("--scale must be greater than 0") }
    guard [characterNumber != nil, trackID != nil, background]
        .filter({ $0 }).count <= 1 else {
        throw CLIError.invalid("choose only one of --character, --track, or --background")
    }

    let probe = try await MediaProbe.inspect(sourceURL)
    guard !probe.fileExtension.isEmpty else {
        throw CLIError.invalid(
            "the source needs a file extension so its portable package filename is unambiguous")
    }
    let prefix: String
    switch probe.kind {
    case .audio: prefix = "audio"
    case .image: prefix = "image"
    case .video: prefix = "video"
    }
    let id = requestedID ?? newMediaID(prefix: prefix)
    try validateMediaID(id)
    let name = requestedName
        ?? sourceURL.deletingPathExtension().lastPathComponent
    let (root, loadedContents) = try readEditablePackage(at: projectPath)
    var contents = loadedContents
    let catalog = try? AssetCatalog(assetsRoot: locateAssetsRoot())
    try requireEditableDocument(contents, catalog: catalog)

    let duration: Double
    let destinationDirectory: URL
    let destination: URL
    let targetDescription: String
    var mouthCueCount = 0

    switch probe.kind {
    case .audio:
        guard !background else {
            throw CLIError.invalid("audio cannot be imported as a background")
        }
        guard requestedCropName == nil, requestedX == nil, requestedY == nil,
              requestedScale == nil, requestedRotation == nil else {
            throw CLIError.invalid(
                "--crop/--x/--y/--scale/--rotation apply only to visual media")
        }
        guard !lipSync || characterNumber != nil else {
            throw CLIError.invalid(
                "--lipsync requires --character because mouth timing belongs to a character")
        }
        guard !contents.audioURLs.keys.contains(id),
              !allAudioClipIDs(in: contents.document).contains(id) else {
            throw CLIError.invalid("audio id \(id) already exists")
        }
        guard let sourceDuration = probe.duration, sourceDuration > 0 else {
            throw MediaProbeError.unreadable(sourceURL.path)
        }
        duration = requestedDuration ?? sourceDuration
        guard duration <= sourceDuration + 0.001 else {
            throw CLIError.invalid(
                String(format: "--duration %.3f exceeds the %.3fs audio source",
                       duration, sourceDuration))
        }
        let kind: AudioClip.Kind
        if let clipKindName {
            guard let parsed = AudioClip.Kind(rawValue: clipKindName) else {
                throw CLIError.invalid(
                    "--kind must be imported, microphone, or speech")
            }
            kind = parsed
        } else {
            kind = .imported
        }
        let mouthCues: [SpeechMouthCue]
        if lipSync {
            mouthCues = try SpeechProduction.analyzeMouth(url: sourceURL)
            mouthCueCount = mouthCues.count
        } else {
            mouthCues = []
        }
        let clip = AudioClip(
            id: id,
            name: name,
            start: start,
            dur: duration,
            srcDur: sourceDuration,
            fadeIn: min(0.02, duration),
            fadeOut: min(0.04, duration),
            kind: kind,
            mouthCues: mouthCues)
        if let characterNumber {
            let index = try validatedCharacterIndex(
                characterNumber, in: contents.document)
            guard !contents.document.stage.characters[index].locked else {
                throw CLIError.invalid("character \(characterNumber) is locked")
            }
            contents.document.stage.characters[index].clips.append(clip)
            contents.document.stage.characters[index].clips.sort { $0.start < $1.start }
            targetDescription = "character \(characterNumber)"
        } else {
            let trackIndex: Int
            if let trackID {
                guard let found = contents.document.stage.audioTracks
                    .firstIndex(where: { $0.id == trackID }) else {
                    throw CLIError.invalid("no audio track has id \(trackID)")
                }
                trackIndex = found
            } else if contents.document.stage.audioTracks.isEmpty {
                let track = AudioTrack(
                    id: newMediaID(prefix: "audio-track"),
                    name: "Audio")
                contents.document.stage.audioTracks.append(track)
                trackIndex = 0
            } else {
                trackIndex = 0
            }
            guard !contents.document.stage.audioTracks[trackIndex].locked else {
                throw CLIError.invalid(
                    "track \(contents.document.stage.audioTracks[trackIndex].id) is locked")
            }
            contents.document.stage.audioTracks[trackIndex].clips.append(clip)
            contents.document.stage.audioTracks[trackIndex].clips.sort { $0.start < $1.start }
            targetDescription = "audio track \(contents.document.stage.audioTracks[trackIndex].id)"
        }
        destinationDirectory = root.appendingPathComponent("audio", isDirectory: true)
        destination = destinationDirectory
            .appendingPathComponent("\(id).\(probe.fileExtension)")
        contents.audioURLs[id] = destination

    case .image, .video:
        guard characterNumber == nil else {
            throw CLIError.invalid("visual media uses --track or --background, not --character")
        }
        guard clipKindName == nil else {
            throw CLIError.invalid("--kind applies only to audio")
        }
        guard !lipSync else {
            throw CLIError.invalid("--lipsync applies only to audio")
        }
        if background,
           requestedX != nil || requestedY != nil
            || requestedScale != nil || requestedRotation != nil {
            throw CLIError.invalid(
                "--x/--y/--scale/--rotation apply to visual tracks, not full-frame backgrounds")
        }
        if !background, requestedCropName != nil {
            throw CLIError.invalid("--crop applies only with --background")
        }
        guard !contents.document.assets.contains(where: { $0.id == id }),
              !contents.assetURLs.keys.contains(id) else {
            throw CLIError.invalid("asset id \(id) already exists")
        }
        duration = requestedDuration ?? probe.duration ?? 5
        contents.document.assets.append(Asset(
            id: id,
            name: name,
            kind: probe.kind == .video ? .video : .image,
            file: "\(id).\(probe.fileExtension)"))
        if background {
            guard let crop = Crop(rawValue: cropName) else {
                throw CLIError.invalid("--crop must be cover, fit, stretch, or tile")
            }
            guard contents.document.stage.backgroundTracks.count == 1 else {
                throw CLIError.invalid("the project must contain exactly one Scenes track")
            }
            guard !contents.document.stage.backgroundTracks[0].locked else {
                throw CLIError.invalid("the Scenes track is locked")
            }
            contents.document.stage.backgroundTracks[0].cues.append(BackgroundCue(
                id: newMediaID(prefix: "scene"),
                assetID: id,
                start: start,
                dur: duration,
                crop: crop,
                label: name))
            contents.document.stage.backgroundTracks[0].cues.sort { $0.start < $1.start }
            targetDescription = "Scenes"
        } else {
            let cue = ImageCue(
                id: newMediaID(prefix: "visual"),
                assetID: id,
                start: start,
                dur: duration,
                from: ImagePlacement(x: x, y: y, scale: scale, rotation: rotation),
                label: name)
            if let trackID,
               let index = contents.document.stage.imageTracks
                .firstIndex(where: { $0.id == trackID }) {
                guard !contents.document.stage.imageTracks[index].locked else {
                    throw CLIError.invalid("track \(trackID) is locked")
                }
                contents.document.stage.imageTracks[index].cues.append(cue)
                contents.document.stage.imageTracks[index].cues.sort { $0.start < $1.start }
                targetDescription = "image track \(trackID)"
            } else if let trackID,
                      let index = contents.document.stage.audioTracks
                        .firstIndex(where: { $0.id == trackID }) {
                guard !contents.document.stage.audioTracks[index].locked else {
                    throw CLIError.invalid("track \(trackID) is locked")
                }
                contents.document.stage.audioTracks[index].cues.append(cue)
                contents.document.stage.audioTracks[index].cues.sort { $0.start < $1.start }
                targetDescription = "media track \(trackID)"
            } else if let trackID {
                throw CLIError.invalid("no visual/media track has id \(trackID)")
            } else {
                if contents.document.stage.imageTracks.isEmpty {
                    contents.document.stage.imageTracks.append(ImageTrack(
                        id: newMediaID(prefix: "visual-track"),
                        name: "Visuals"))
                }
                contents.document.stage.imageTracks[0].cues.append(cue)
                contents.document.stage.imageTracks[0].cues.sort { $0.start < $1.start }
                targetDescription =
                    "image track \(contents.document.stage.imageTracks[0].id)"
            }
        }
        destinationDirectory = root.appendingPathComponent("assets", isDirectory: true)
        destination = destinationDirectory
            .appendingPathComponent("\(id).\(probe.fileExtension)")
        contents.assetURLs[id] = destination
    }

    guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw CLIError.invalid("destination already exists: \(destination.path)")
    }
    try requireEditableDocument(contents, catalog: catalog)
    try FileManager.default.createDirectory(
        at: destinationDirectory, withIntermediateDirectories: true)
    let staging = destinationDirectory
        .appendingPathComponent(".\(id)-\(UUID().uuidString).tmp")
    do {
        try FileManager.default.copyItem(at: sourceURL, to: staging)
        try FileManager.default.moveItem(at: staging, to: destination)
        do {
            try writeDocument(contents.document, to: root)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    } catch {
        try? FileManager.default.removeItem(at: staging)
        throw error
    }

    let report = MediaImportReport(
        project: root.path,
        id: id,
        target: targetDescription,
        start: start,
        duration: duration,
        destination: destination.path,
        mouthCues: mouthCueCount,
        media: probe)
    if json {
        try printJSON(report)
    } else {
        print("imported \(name) → \(targetDescription)")
        print(String(format: "id %@ @ %.3fs for %.3fs", id, start, duration))
        if mouthCueCount > 0 { print("\(mouthCueCount) source-aligned mouth cues") }
    }
}

private func validateMediaID(_ id: String) throws {
    let allowed = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "._-"))
    guard let first = id.unicodeScalars.first,
          CharacterSet.alphanumerics.contains(first),
          id.unicodeScalars.allSatisfy(allowed.contains),
          id != ".", id != ".." else {
        throw CLIError.invalid(
            "media ids must start with a letter/number and contain only letters, numbers, ., _, or -")
    }
}

private func allAudioClipIDs(in document: ShowDocument) -> Set<String> {
    Set(document.stage.characters.flatMap(\.clips).map(\.id)
        + document.stage.audioTracks.flatMap(\.clips).map(\.id))
}
