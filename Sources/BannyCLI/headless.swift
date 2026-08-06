import Foundation
import BannyCore

// High-level, typed edits for agents. These deliberately cover common intent
// without forcing callers to synthesize RFC 6902 paths into show.json.

private struct StartPoseReport: Codable {
    let summary: MutationSummary
    let character: Int
    let name: String
    let start: StartPoseValue?

    struct StartPoseValue: Codable {
        let x: Double
        let depth: Double
        let face: Int
        let spin: Double
        let zoom: Double
        let size: Double
    }
}

func characterCommand(_ args: [String]) throws {
    guard args.first == "set-start" else {
        throw CLIError.usage(
            "banny character set-start <project.bs> --character N "
            + "[--x N --depth N --face left|right|-1|1 --spin DEG --zoom N --size N] "
            + "[--clear] [--dry-run] [--if-hash SHA256] [--json]")
    }
    try characterSetStartCommand(Array(args.dropFirst()))
}

private func characterSetStartCommand(_ args: [String]) throws {
    let usage = "banny character set-start <project.bs> --character N "
        + "[--x N --depth N --face left|right|-1|1 --spin DEG --zoom N --size N] "
        + "[--clear] [--dry-run] [--if-hash SHA256] [--json]"
    guard let projectPath = args.first else { throw CLIError.usage(usage) }
    var options = CLIOptions(Array(args.dropFirst()))
    let characterNumber = try options.int("--character")
    let x = try options.double("--x")
    let depth = try options.double("--depth")
    let faceRaw = try options.value("--face")
    let spin = try options.double("--spin")
    let zoom = try options.double("--zoom")
    let size = try options.double("--size")
    let clear = try options.flag("--clear")
    let dryRun = try options.flag("--dry-run")
    let expectedHash = try options.value("--if-hash")
    let json = try options.flag("--json")
    try options.finish(usage: usage)

    guard let characterNumber else {
        throw CLIError.invalid("missing required option --character")
    }
    guard x == nil || (0...1).contains(x!) else {
        throw CLIError.invalid("--x must be inside 0...1")
    }
    guard depth == nil || (-12...1).contains(depth!) else {
        throw CLIError.invalid("--depth must be inside -12...1")
    }
    guard zoom == nil || zoom! > 0 else {
        throw CLIError.invalid("--zoom must be greater than 0")
    }
    guard size == nil || size! > 0 else {
        throw CLIError.invalid("--size must be greater than 0")
    }
    let face: Int?
    switch faceRaw?.lowercased() {
    case nil: face = nil
    case "left", "-1": face = -1
    case "right", "1": face = 1
    default: throw CLIError.invalid("--face must be left, right, -1, or 1")
    }
    let hasTransform = [x, depth, spin, zoom, size].contains { $0 != nil } || face != nil
    guard clear ? !hasTransform : hasTransform else {
        throw CLIError.invalid(clear
            ? "--clear cannot be combined with start values"
            : "provide at least one of --x, --depth, --face, --spin, --zoom, or --size")
    }

    var mutation = try prepareEditableMutation(
        projectPath: projectPath, expectedHash: expectedHash)
    let index = try validatedCharacterIndex(
        characterNumber, in: mutation.contents.document)
    var character = mutation.contents.document.stage.characters[index]
    guard !character.locked else {
        throw CLIError.invalid("character \(characterNumber) is locked")
    }
    if clear {
        character.recStart = nil
    } else {
        let current = character.recStart
            ?? StartPose(x: character.x, depth: character.depth, face: character.face)
        let resolved = StartPose(
            x: x ?? current.x,
            depth: depth ?? current.depth,
            face: face ?? current.face,
            spin: spin ?? current.spin,
            zoom: zoom ?? current.zoom)
        // Keep the track's visible base and recorded start coherent. Studio
        // uses the same values while stopped and when simulation starts.
        character.x = resolved.x
        character.depth = resolved.depth
        character.face = resolved.face
        if let size { character.size = size }
        character.recStart = resolved
    }
    mutation.contents.document.stage.characters[index] = character
    let summary = try finishEditableMutation(
        mutation, operation: "character.set-start", dryRun: dryRun)
    let start = character.recStart.map {
        StartPoseReport.StartPoseValue(
            x: $0.x, depth: $0.depth, face: $0.face,
            spin: $0.spin, zoom: $0.zoom, size: character.size)
    }
    let report = StartPoseReport(
        summary: summary, character: characterNumber,
        name: character.name, start: start)
    if json {
        try printJSON(report)
    } else {
        let action = dryRun ? "would update" : (summary.changed ? "updated" : "unchanged")
        if let start {
            print("\(action) character \(characterNumber) start: "
                  + "x=\(start.x), depth=\(start.depth), face=\(start.face), "
                  + "spin=\(start.spin), zoom=\(start.zoom), size=\(start.size)")
        } else {
            print("\(action) character \(characterNumber): recorded start cleared")
        }
    }
}

private struct PerformanceAddReport: Codable {
    let summary: MutationSummary
    let character: Int
    let code: String
    let at: Double
    let duration: Double
    let eventsAdded: Int
}

func performanceCommand(_ args: [String]) throws {
    guard args.first == "add" else {
        throw CLIError.usage(
            "banny performance add <project.bs> --character N --code CODE --at SECONDS "
            + "[--duration SECONDS] [--dry-run] [--if-hash SHA256] [--json]")
    }
    let usage = "banny performance add <project.bs> --character N --code CODE --at SECONDS "
        + "[--duration SECONDS] [--dry-run] [--if-hash SHA256] [--json]"
    let tail = Array(args.dropFirst())
    guard let projectPath = tail.first else { throw CLIError.usage(usage) }
    var options = CLIOptions(Array(tail.dropFirst()))
    let characterNumber = try options.int("--character")
    let rawCode = try options.value("--code")
    let at = try options.double("--at")
    let duration = try options.double("--duration") ?? 0.1
    let dryRun = try options.flag("--dry-run")
    let expectedHash = try options.value("--if-hash")
    let json = try options.flag("--json")
    try options.finish(usage: usage)
    guard let characterNumber else {
        throw CLIError.invalid("missing required option --character")
    }
    guard let rawCode, let code = EventCode(rawValue: rawCode) else {
        throw CLIError.invalid(
            "--code must be one of: \(EventCode.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    guard let at, at >= 0 else {
        throw CLIError.invalid("--at must be a finite number at or after 0")
    }
    guard duration > 0 else {
        throw CLIError.invalid("--duration must be greater than 0")
    }

    var mutation = try prepareEditableMutation(
        projectPath: projectPath, expectedHash: expectedHash)
    let index = try validatedCharacterIndex(
        characterNumber, in: mutation.contents.document)
    var character = mutation.contents.document.stage.characters[index]
    guard !character.locked else {
        throw CLIError.invalid("character \(characterNumber) is locked")
    }
    let additions: [PerfEvent] = [
        .key(t: at, code: code, down: true),
        .key(t: at + duration, code: code, down: false),
    ]
    let missing = additions.filter { !character.events.contains($0) }
    character.events.append(contentsOf: missing)
    character.events = character.events.enumerated().sorted { lhs, rhs in
        if lhs.element.t != rhs.element.t { return lhs.element.t < rhs.element.t }
        return lhs.offset < rhs.offset
    }.map(\.element)
    mutation.contents.document.stage.characters[index] = character
    let summary = try finishEditableMutation(
        mutation, operation: "performance.add", dryRun: dryRun)
    let report = PerformanceAddReport(
        summary: summary, character: characterNumber,
        code: code.rawValue, at: at, duration: duration,
        eventsAdded: missing.count)
    if json {
        try printJSON(report)
    } else {
        let action = dryRun ? "would add" : "added"
        print("\(action) \(missing.count) event(s) for \(code.rawValue) "
              + "on character \(characterNumber) @ \(at)s")
    }
}

private struct StateReport: Codable {
    struct CharacterState: Codable {
        struct Jump: Codable { let progress: Double; let height: Double }
        struct Flip: Codable { let progress: Double; let rotation: Double; let height: Double }

        let character: Int
        let name: String
        let visible: Bool
        let x: Double
        let depth: Double
        let face: Int
        let phase: Double
        let tilt: Double
        let leanTilt: Double
        let eye: String
        let mouth: String
        let talking: Bool
        let moving: Bool
        let spin: Double
        let zoom: Double
        let wobble: Double
        let size: Double
        let outfit: [Int: String]
        let activeSubtitle: String?
        let jump: Jump?
        let flip: Flip?
    }

    struct Background: Codable {
        struct Camera: Codable { let x: Double; let y: Double; let zoom: Double }
        let cueID: String
        let assetID: String
        let camera: Camera?
    }

    struct Light: Codable {
        let x: Double
        let y: Double
        let intensity: Double
        let size: Double
    }

    let project: String
    let at: Double
    let contentEnd: Double
    let frameWidth: Double
    let frameHeight: Double
    let background: Background?
    let lights: [Light]
    let characters: [CharacterState]
}

func stateCommand(_ args: [String]) throws {
    let usage = "banny state <show.bs> --at SECONDS [--json]"
    guard let projectPath = args.first else { throw CLIError.usage(usage) }
    var options = CLIOptions(Array(args.dropFirst()))
    let at = try options.double("--at")
    let json = try options.flag("--json")
    try options.finish(usage: usage)
    guard let at, at >= 0 else {
        throw CLIError.invalid("--at must be a finite number at or after 0")
    }
    try withReadPackage(at: projectPath) { _, contents in
        let document = contents.document
        let stage = document.stage
        let simulator = SceneSimulator(state: stage)
        let characters = stage.characters.enumerated().map { index, character in
            let pose = simulator.pose(characterIndex: index, at: at)
            return StateReport.CharacterState(
                character: index + 1,
                name: character.name,
                visible: !character.hidden && character.presence.isPresent(at: at),
                x: pose.x, depth: pose.depth, face: pose.face,
                phase: pose.phase, tilt: pose.tilt, leanTilt: pose.leanTilt,
                eye: pose.eye.rawValue, mouth: pose.mouthShape.rawValue,
                talking: pose.talking, moving: pose.moving,
                spin: pose.spin, zoom: pose.zoom,
                wobble: pose.wobble, size: pose.size,
                outfit: pose.outfit, activeSubtitle: pose.activeSubtitle,
                jump: pose.jump.map { .init(progress: $0.progress, height: $0.height) },
                flip: pose.flip.map {
                    .init(progress: $0.progress, rotation: $0.rotation, height: $0.height)
                })
        }
        let background = stage.activeBackgroundCue(at: at).map { cue in
            StateReport.Background(
                cueID: cue.id, assetID: cue.assetID,
                camera: cue.camera(at: at).map {
                    .init(x: $0.x, y: $0.y, zoom: $0.zoom)
                })
        }
        let report = StateReport(
            project: projectPath, at: at, contentEnd: stage.contentEnd,
            frameWidth: document.settings.frameW,
            frameHeight: document.settings.frameH,
            background: background,
            lights: stage.activeLights(at: at).map {
                .init(x: $0.x, y: $0.y, intensity: $0.intensity, size: $0.size)
            },
            characters: characters)
        if json {
            try printJSON(report)
        } else {
            print("state @ \(at)s — \(characters.count) character(s), "
                  + "content ends \(stage.contentEnd)s")
            for character in characters {
                print("  \(character.character). \(character.name): "
                      + "\(character.visible ? "visible" : "hidden") "
                      + "x=\(character.x) depth=\(character.depth) face=\(character.face) "
                      + "spin=\(character.spin) zoom=\(character.zoom)")
            }
        }
    }
}
