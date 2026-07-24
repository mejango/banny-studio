import Foundation
import BannyCore
import BannyRender
import BannyMedia

// Speech generation and lip sync share BannyMedia with the Studio app.

func voicesCommand(_ args: [String]) throws {
    var options = CLIOptions(args)
    let language = try options.value("--language")?.lowercased()
    let json = try options.flag("--json")
    try options.finish(usage: "banny voices [--language PREFIX] [--json]")
    let voices = SpeechVoiceDescriptor.installed().filter { voice in
        guard let language else { return true }
        return voice.language.lowercased().hasPrefix(language)
    }
    if json {
        try printJSON(voices)
    } else if voices.isEmpty {
        print("no installed voices matched")
    } else {
        for voice in voices {
            let traits = [
                voice.quality,
                voice.gender,
                voice.isPersonal ? "Personal Voice" : "",
                voice.isNovelty ? "Novelty" : "",
            ].filter { !$0.isEmpty }.joined(separator: " · ")
            print("\(voice.id)\t\(voice.name)\t\(voice.language)\t\(traits)")
        }
    }
}

private struct SpeechClipReport: Codable {
    let id: String
    let name: String
    let start: Double
    let duration: Double
    let mouthCues: Int
}

private struct TTSReport: Codable {
    let project: String
    let character: Int
    let voice: SpeechVoiceDescriptor
    let recipe: VoiceRecipe
    let replacedGeneratedClips: Int
    let clips: [SpeechClipReport]
}

func ttsCommand(_ args: [String]) async throws {
    let usage = """
    banny tts <project.bs> --character N [--text TEXT|--text-file FILE|--captions] \
    [--at SECONDS] [--voice ID] [--preset NAME] [--flavor 0...1] \
    [--rate 0...1] [--pitch 0.5...2] [--name NAME] [--no-caption] \
    [--fade-in SECONDS] [--fade-out SECONDS] [--no-lipsync] \
    [--replace-generated] [--json]
    """
    guard let projectPath = args.first else { throw CLIError.usage(usage) }
    var options = CLIOptions(Array(args.dropFirst()))
    let characterNumber = try options.int("--character")
    let text = try options.value("--text")
    let textFile = try options.value("--text-file")
    let captionsFlag = try options.flag("--captions")
    let at = try options.double("--at") ?? 0
    let requestedVoice = try options.value("--voice")
    let presetName = try options.value("--preset")
    let flavor = try options.double("--flavor")
    let rate = try options.double("--rate")
    let pitch = try options.double("--pitch")
    let requestedName = try options.value("--name")
    let fadeIn = try options.double("--fade-in") ?? 0.04
    let fadeOut = try options.double("--fade-out") ?? 0.06
    let noCaption = try options.flag("--no-caption")
    let noLipSync = try options.flag("--no-lipsync")
    let replaceFlag = try options.flag("--replace-generated")
    let json = try options.flag("--json")
    try options.finish(usage: usage)

    guard let characterNumber else { throw CLIError.invalid("missing required option --character") }
    guard at >= 0 else { throw CLIError.invalid("--at cannot be before 0") }
    guard fadeIn >= 0, fadeOut >= 0 else {
        throw CLIError.invalid("speech fades cannot be negative")
    }
    guard [text != nil, textFile != nil, captionsFlag].filter({ $0 }).count <= 1 else {
        throw CLIError.invalid("choose only one of --text, --text-file, or --captions")
    }
    if let flavor, !(0...1).contains(flavor) {
        throw CLIError.invalid("--flavor must be inside 0...1")
    }
    if let rate, !(0...1).contains(rate) {
        throw CLIError.invalid("--rate must be inside 0...1")
    }
    if let pitch, !(0.5...2).contains(pitch) {
        throw CLIError.invalid("--pitch must be inside 0.5...2")
    }

    let (root, loadedContents) = try readEditablePackage(at: projectPath)
    var contents = loadedContents
    let catalog = try? AssetCatalog(assetsRoot: locateAssetsRoot())
    try requireEditableDocument(contents, catalog: catalog)
    let characterIndex = try validatedCharacterIndex(characterNumber, in: contents.document)
    guard !contents.document.stage.characters[characterIndex].locked else {
        throw CLIError.invalid("character \(characterNumber) is locked")
    }

    let voices = SpeechVoiceDescriptor.installed()
    let voiceID = requestedVoice
        ?? contents.document.stage.characters[characterIndex].speechVoice.voiceIdentifier
        ?? SpeechVoiceDescriptor.recommendedIdentifier(in: voices)
    guard let voiceID, let voice = voices.first(where: { $0.id == voiceID }) else {
        throw SpeechProductionError.voiceUnavailable
    }

    var sourceLines: [(text: String, start: Double, captionIndex: Int?)] = []
    let useCaptions = captionsFlag || (text == nil && textFile == nil)
    if useCaptions {
        sourceLines = contents.document.stage.characters[characterIndex].subs.enumerated()
            .compactMap { index, subtitle in
                let value = subtitle.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : (value, subtitle.start, index)
            }
        guard !sourceLines.isEmpty else {
            throw CLIError.invalid(
                "character \(characterNumber) has no nonempty captions to synthesize")
        }
    } else {
        let sourceText: String
        if let text {
            sourceText = text
        } else if let textFile {
            sourceText = try String(
                contentsOf: URL(fileURLWithPath: textFile),
                encoding: .utf8)
        } else {
            throw CLIError.invalid("provide --text, --text-file, or --captions")
        }
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CLIError.invalid("speech text is empty") }
        sourceLines = [(trimmed, at, nil)]
    }

    let synthesisRate = rate.map(Float.init) ?? 0.5
    let synthesisPitch = pitch.map(Float.init) ?? 1
    var staged: [(clip: AudioClip, data: Data, report: SpeechClipReport)] = []
    for (lineNumber, line) in sourceLines.enumerated() {
        let speech = try await SpeechProduction.render(
            text: line.text,
            voiceIdentifier: voice.id,
            rate: synthesisRate,
            pitchMultiplier: synthesisPitch)
        let mouthCues = noLipSync
            ? []
            : SpeechProduction.mouthCues(text: line.text, speech: speech)
        let id = newMediaID(prefix: "tts")
        let name = requestedName.map {
            sourceLines.count == 1 ? $0 : "\($0) \(lineNumber + 1)"
        } ?? "Speech \(line.captionIndex.map { $0 + 1 } ?? lineNumber + 1) · \(voice.name)"
        let clip = AudioClip(
            id: id,
            name: name,
            start: line.start,
            dur: speech.duration,
            srcDur: speech.duration,
            fadeIn: min(fadeIn, speech.duration),
            fadeOut: min(fadeOut, speech.duration),
            kind: .speech,
            mouthCues: mouthCues)
        staged.append((
            clip,
            speech.data,
            SpeechClipReport(
                id: id,
                name: name,
                start: line.start,
                duration: speech.duration,
                mouthCues: mouthCues.count)))
    }

    var character = contents.document.stage.characters[characterIndex]
    let replaceGenerated = useCaptions || replaceFlag
    let beforeCount = character.clips.count
    if replaceGenerated {
        character.clips.removeAll {
            $0.id.hasPrefix("tts-") || $0.id.hasPrefix("ani-")
        }
    }
    let replaced = beforeCount - character.clips.count
    character.clips.append(contentsOf: staged.map(\.clip))
    character.clips.sort { lhs, rhs in
        if lhs.start == rhs.start {
            return lhs.id < rhs.id
        }
        return lhs.start < rhs.start
    }
    character.speechVoice.voiceIdentifier = voice.id
    if let presetName {
        guard let preset = VoiceRecipe.Preset(rawValue: presetName) else {
            throw CLIError.invalid(
                "unknown voice preset \(presetName); use: "
                    + VoiceRecipe.Preset.allCases.map(\.rawValue).joined(separator: ", "))
        }
        character.speechVoice.recipe = VoiceRecipe.preset(
            preset, flavor: flavor ?? 1)
    } else if let flavor {
        character.speechVoice.recipe.flavor = flavor
    }
    if !useCaptions, !noCaption, let item = staged.first {
        character.subs.append(Subtitle(
            text: sourceLines[0].text,
            start: item.clip.start,
            dur: item.clip.dur))
        character.subs.sort { $0.start < $1.start }
    }
    contents.document.stage.characters[characterIndex] = character

    let audioDirectory = root.appendingPathComponent("audio", isDirectory: true)
    try FileManager.default.createDirectory(
        at: audioDirectory, withIntermediateDirectories: true)
    let destinations = staged.map {
        audioDirectory.appendingPathComponent("\($0.clip.id).caf")
    }
    for (item, destination) in zip(staged, destinations) {
        contents.audioURLs[item.clip.id] = destination
    }
    try requireEditableDocument(contents, catalog: catalog)

    var written: [URL] = []
    do {
        for (item, destination) in zip(staged, destinations) {
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw CLIError.invalid("generated audio destination already exists: \(destination.path)")
            }
            try item.data.write(to: destination, options: .atomic)
            written.append(destination)
        }
        try writeDocument(contents.document, to: root)
    } catch {
        for url in written { try? FileManager.default.removeItem(at: url) }
        throw error
    }

    let report = TTSReport(
        project: root.path,
        character: characterNumber,
        voice: voice,
        recipe: character.speechVoice.recipe,
        replacedGeneratedClips: replaced,
        clips: staged.map(\.report))
    if json {
        try printJSON(report)
    } else {
        print("generated \(staged.count) speech clip\(staged.count == 1 ? "" : "s") "
              + "for \(character.name.isEmpty ? "character \(characterNumber)" : character.name)")
        print("voice: \(voice.name) (\(voice.language)) · recipe: \(character.speechVoice.recipe.name)")
        for clip in staged.map(\.report) {
            print(String(format: "  %@ @ %.3fs, %.3fs, %d mouth cues",
                         clip.id, clip.start, clip.duration, clip.mouthCues))
        }
    }
}

private struct LipSyncReport: Codable {
    let project: String
    let character: Int
    let clip: String
    let cleared: Bool
    let mouthCues: Int
}

func lipSyncCommand(_ args: [String]) throws {
    let usage = "banny lipsync <project.bs> --character N --clip ID [--clear] [--json]"
    guard let projectPath = args.first else { throw CLIError.usage(usage) }
    var options = CLIOptions(Array(args.dropFirst()))
    let characterNumber = try options.int("--character")
    let clipID = try options.value("--clip")
    let clear = try options.flag("--clear")
    let json = try options.flag("--json")
    try options.finish(usage: usage)
    guard let characterNumber else { throw CLIError.invalid("missing required option --character") }
    guard let clipID else { throw CLIError.invalid("missing required option --clip") }

    let (root, loadedContents) = try readEditablePackage(at: projectPath)
    var contents = loadedContents
    let catalog = try? AssetCatalog(assetsRoot: locateAssetsRoot())
    try requireEditableDocument(contents, catalog: catalog)
    let characterIndex = try validatedCharacterIndex(characterNumber, in: contents.document)
    var character = contents.document.stage.characters[characterIndex]
    guard !character.locked else {
        throw CLIError.invalid("character \(characterNumber) is locked")
    }
    let matching = character.clips.indices.filter { character.clips[$0].id == clipID }
    guard !matching.isEmpty else {
        throw CLIError.invalid("character \(characterNumber) has no clip with id \(clipID)")
    }
    let cues: [SpeechMouthCue]
    if clear {
        cues = []
    } else {
        guard let url = contents.audioURLs[clipID] else {
            throw SpeechProductionError.missingMedia
        }
        cues = try SpeechProduction.analyzeMouth(url: url)
    }
    for index in matching { character.clips[index].mouthCues = cues }
    contents.document.stage.characters[characterIndex] = character
    try requireEditableDocument(contents, catalog: catalog)
    try writeDocument(contents.document, to: root)

    let report = LipSyncReport(
        project: root.path,
        character: characterNumber,
        clip: clipID,
        cleared: clear,
        mouthCues: cues.count)
    if json {
        try printJSON(report)
    } else {
        print(clear
              ? "cleared mouth timing for \(clipID)"
              : "analyzed \(clipID) — \(cues.count) source-aligned mouth cues")
    }
}
