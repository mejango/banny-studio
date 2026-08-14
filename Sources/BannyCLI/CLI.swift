import Foundation
import BannyCore
import BannyRender
import BannyMedia

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let cliUsage = """
usage: banny <command>              (read-only commands accept .bs or .bs.zip)
  capabilities [--json]                            — machine-readable CLI feature contract
  schema [--compact|--example]                     — canonical show.json JSON Schema/example
  catalog [--json]                                 — wardrobe bodies, outfits, eyes, mouths
  voices [--language PREFIX] [--json]              — installed/system/personal TTS voices
  new <project.bs> [--characters N]                — create a canonical starter project
  migrate <project.bs> [options]                   — atomically upgrade v2/v3 to strict v4
  validate <show.bs> [--json]                      — strict schema + semantic/package checks
  preview <show.bs> <out.png> [--t SEC|--times CSV] — render a frame/contact sheet
  info <show.bs> [--json]                          — track/event/asset counts
  state <show.bs> --at SECONDS [--json]             — resolve stage state at a time
  character set-start <project.bs> [options]        — atomically set a start pose
  performance add <project.bs> [options]            — add a typed key press interval
  ship <show.bs> [out.mp4] [--plan] [options]       — plan or render an mp4
  apply <project.bs> <patch.json|-> [options]      — atomic RFC 6902 JSON Patch
  tts <project.bs> --character N [options]         — synthesize portable speech clips
  lipsync <project.bs> --character N --clip ID     — analyze/clear precise mouth timing
  media probe <file> [--json]                      — inspect media type/duration/dimensions
  media import <project.bs> <file> [options]       — copy and place media safely
  pack <project.bs> <out.bs.zip>                   — zip for sharing/app import
  unpack <in.bs.zip> <project.bs>                  — extract for editing
  import <v1.json> <out.bs>                        — web v1 → native
  stylize <in.png> <out.png> [gridWidth] [dither]  — pixel-art stylizer
  shimmer <in.png> <out.gif> [options]             — sparse point-light loop
  skill [install|print] [--target TARGET]          — AI production skill

Use `banny capabilities --json` for exact command contracts and vocabulary.
Mutation commands require an unpacked folder and reject unknown options/JSON fields.
"""

public func runCLI(arguments args: [String]) async throws -> Int32 {
    let command = args.count >= 2 ? args[1] : ""
    let tail = Array(args.dropFirst(2))

    switch command {
    case "--version", "-V", "version":
        print("banny \(BannyCLIContract.version) (show schema \(BannyCLIContract.schemaVersion))")

    case "--help", "-h", "":
        print(cliUsage)

    case "help":
        try helpCommand(tail)

    case "capabilities":
        try capabilitiesCommand(tail)

    case "schema":
        try schemaCommand(tail)

    case "import":
        guard tail.count >= 2 else {
            throw CLIError.usage("banny import <v1.json> <out.bs> [--json]")
        }
        var options = CLIOptions(Array(tail.dropFirst(2)))
        let json = try options.flag("--json")
        try options.finish(usage: "banny import <v1.json> <out.bs> [--json]")
        let data = try Data(contentsOf: URL(fileURLWithPath: tail[0]))
        let result = try V1Importer.importStudio(json: data)
        try writeNewPackage(
            result.document,
            audio: result.audioFiles,
            assets: result.backgroundFiles,
            to: URL(fileURLWithPath: tail[1]))
        let stage = result.document.stage
        struct ImportReport: Codable {
            let source: String; let output: String; let characters: Int
            let audioClips: Int; let assets: Int; let schemaVersion: Int
        }
        let report = ImportReport(
            source: tail[0], output: tail[1], characters: stage.characters.count,
            audioClips: result.audioFiles.count, assets: result.document.assets.count,
            schemaVersion: result.document.version)
        if json { try printJSON(report) }
        else {
            print("imported → \(tail[1]): \(stage.characters.count) character tracks, "
                  + "\(result.audioFiles.count) audio clips, \(result.document.assets.count) assets")
        }

    case "info":
        guard let path = tail.first, tail.count == 1 || tail == [path, "--json"] else {
            throw CLIError.usage("banny info <show.bs> [--json]")
        }
        try withReadPackage(at: path) { root, contents in
            let stage = contents.document.stage
            if tail.contains("--json") {
                struct Info: Codable {
                    var schemaVersion: Int
                    var characters: Int
                    var events: Int
                    var audioTracks: Int
                    var imageTracks: Int
                    var backgroundTracks: Int
                    var lightTracks: Int
                    var reactionDefinitions: Int
                    var reactionBlocks: Int
                    var markers: Int
                    var assets: Int
                    var contentEnd: Double
                    var characterNames: [String]
                    var showJSONSHA256: String
                }
                let data = try Data(
                    contentsOf: root.appendingPathComponent("show.json"))
                try printJSON(Info(
                    schemaVersion: contents.document.version,
                    characters: stage.characters.count,
                    events: stage.characters.map(\.events.count).reduce(0, +),
                    audioTracks: stage.audioTracks.count,
                    imageTracks: stage.imageTracks.count,
                    backgroundTracks: stage.backgroundTracks.count,
                    lightTracks: stage.lightTracks.count,
                    reactionDefinitions: stage.reactionLibrary.count,
                    reactionBlocks: stage.characters.map(\.reactions.count).reduce(0, +),
                    markers: stage.markers.count,
                    assets: contents.document.assets.count,
                    contentEnd: stage.contentEnd,
                    characterNames: stage.characters.map(\.name),
                    showJSONSHA256: sha256Hex(data)))
            } else {
                print("tracks: \(stage.characters.count) characters "
                      + "(\(stage.characters.map(\.events.count).reduce(0, +)) events, "
                      + "\(stage.characters.map(\.reactions.count).reduce(0, +)) reaction blocks / "
                      + "\(stage.reactionLibrary.count) definitions), "
                      + "\(stage.audioTracks.count) audio, \(stage.imageTracks.count) image, "
                      + "\(stage.backgroundTracks.count) background, "
                      + "\(stage.lightTracks.count) light; "
                      + "\(stage.markers.count) markers; "
                      + "\(contents.document.assets.count) assets; "
                      + "end \(stage.contentEnd)s")
            }
        }

    case "ship":
        return try shipCommand(tail)

    case "state":
        try stateCommand(tail)

    case "character":
        try characterCommand(tail)

    case "performance":
        try performanceCommand(tail)

    case "stylize":
        try stylizeCommand(tail)

    case "shimmer":
        try shimmerCommand(tail)

    case "catalog":
        var options = CLIOptions(tail)
        let json = try options.flag("--json")
        try options.finish(usage: "banny catalog [--json]")
        let catalog = try AssetCatalog(assetsRoot: locateAssetsRoot())
        let summary = catalog.summary()
        if json {
            try printJSON(summary)
        } else {
            print("bodies: \(summary.bodies.joined(separator: ", "))")
            for slot in summary.slots {
                print("\n\(slot.name) (slot \(slot.slot)):")
                for outfit in slot.outfits {
                    print("  \(outfit.name) — \(outfit.label)")
                }
            }
            print("\neyes: \(summary.eyes.joined(separator: ", "))")
            print("mouths: \(summary.mouths.joined(separator: ", "))")
        }

    case "voices":
        try voicesCommand(tail)

    case "validate":
        guard let path = tail.first else {
            throw CLIError.usage("banny validate <show.bs> [--json]")
        }
        var options = CLIOptions(Array(tail.dropFirst()))
        let json = try options.flag("--json")
        try options.finish(usage: "banny validate <show.bs> [--json]")
        do {
            return try withReadPackage(at: path) { _, contents in
                let catalog = try? AssetCatalog(assetsRoot: locateAssetsRoot())
                let diagnostics = editableDiagnostics(
                    for: contents,
                    catalog: catalog)
                if json {
                    try printJSON(diagnostics)
                } else if diagnostics.isEmpty {
                    print("ok — strict schema and production preflight passed")
                } else {
                    for diagnostic in diagnostics {
                        print("\(diagnostic.severity.rawValue): \(diagnostic.message)")
                    }
                }
                if catalog == nil, !json {
                    printErr("note: assets not found — wardrobe names were not checked")
                }
                return diagnostics.contains { $0.severity == .error } ? 1 : 0
            }
        } catch {
            let diagnostic = ShowLint.Diagnostic(.error, String(describing: error))
            if json {
                try printJSON([diagnostic])
            } else {
                print("error: \(diagnostic.message)")
            }
            return 1
        }

    case "preview":
        guard tail.count >= 2 else {
            throw CLIError.usage(
                "banny preview <show.bs> <out.png> [--t SEC|--times CSV] [--columns N] [--json]")
        }
        var options = CLIOptions(Array(tail.dropFirst(2)))
        let singleTime = try options.double("--t")
        let timesRaw = try options.value("--times")
        let columns = try options.int("--columns")
        let json = try options.flag("--json")
        try options.finish(
            usage: "banny preview <show.bs> <out.png> [--t SEC|--times CSV] [--columns N] [--json]")
        guard !(singleTime != nil && timesRaw != nil) else {
            throw CLIError.invalid("choose only one of --t or --times")
        }
        guard columns == nil || columns! > 0 else {
            throw CLIError.invalid("--columns must be at least 1")
        }
        let times: [Double]
        if let timesRaw {
            times = try timesRaw.split(separator: ",", omittingEmptySubsequences: false).map {
                guard let value = Double($0.trimmingCharacters(in: .whitespaces)),
                      value.isFinite, value >= 0 else {
                    throw CLIError.invalid("--times must contain comma-separated numbers at or after 0")
                }
                return value
            }
            guard !times.isEmpty else { throw CLIError.invalid("--times cannot be empty") }
        } else {
            times = [singleTime ?? 0]
        }
        guard times.allSatisfy({ $0 >= 0 }) else {
            throw CLIError.invalid("preview times cannot be before 0")
        }
        let assets = try AssetCatalog(assetsRoot: locateAssetsRoot())
        struct PreviewReport: Codable {
            let project: String
            let output: String
            let times: [Double]
            let columns: Int
            let width: Int?
            let height: Int?
        }
        var report: PreviewReport!
        try withReadPackage(at: tail[0]) { _, contents in
            if times.count == 1 {
                try ShowPreview.writePNG(
                    contents: contents, assets: assets, at: times[0],
                    to: URL(fileURLWithPath: tail[1]))
                report = PreviewReport(project: tail[0], output: tail[1], times: times,
                                       columns: 1, width: nil, height: nil)
            } else {
                let result = try ShowPreview.writeContactSheet(
                    contents: contents, assets: assets, at: times,
                    columns: columns, to: URL(fileURLWithPath: tail[1]))
                report = PreviewReport(project: tail[0], output: tail[1], times: times,
                                       columns: result.columns,
                                       width: result.width, height: result.height)
            }
        }
        if json { try printJSON(report) }
        else if times.count == 1 { print("wrote \(tail[1]) @ t=\(times[0])s") }
        else { print("wrote \(tail[1]) — \(times.count)-frame contact sheet") }

    case "new":
        guard let outputPath = tail.first else {
            throw CLIError.usage("banny new <project.bs> [--characters N]")
        }
        var options = CLIOptions(Array(tail.dropFirst()))
        let count = try options.int("--characters") ?? 2
        let json = try options.flag("--json")
        try options.finish(
            usage: "banny new <project.bs> [--characters N] [--json]")
        guard (1...10).contains(count) else {
            throw CLIError.invalid("--characters must be inside 1...10")
        }
        let output = URL(fileURLWithPath: outputPath)
        try writeNewPackage(.starter(characterCount: count), to: output)
        if json {
            struct NewReport: Codable {
                let project: String; let schemaVersion: Int
                let characters: Int; let showJSONSHA256: String
            }
            let showData = try Data(contentsOf: output.appendingPathComponent("show.json"))
            try printJSON(NewReport(
                project: output.path, schemaVersion: BannyCLIContract.schemaVersion,
                characters: count, showJSONSHA256: sha256Hex(showData)))
        } else {
            print("created \(output.path) — strict v4 project ready for Studio or CLI")
        }

    case "migrate":
        try migrateCommand(tail)

    case "apply":
        try patchCommand(tail)

    case "tts":
        try await ttsCommand(tail)

    case "lipsync":
        try lipSyncCommand(tail)

    case "media":
        try await mediaCommand(tail)

    case "pack":
        guard tail.count >= 2 else {
            throw CLIError.usage("banny pack <project.bs> <out.bs.zip> [--json]")
        }
        var options = CLIOptions(Array(tail.dropFirst(2)))
        let json = try options.flag("--json")
        try options.finish(usage: "banny pack <project.bs> <out.bs.zip> [--json]")
        let output = URL(fileURLWithPath: tail[1])
        try packPackage(at: tail[0], to: output)
        if json {
            struct PackageReport: Codable { let source: String; let output: String; let operation: String }
            try printJSON(PackageReport(source: tail[0], output: output.path, operation: "pack"))
        } else { print("packed \(tail[1]) — importable by Banny Studio") }

    case "unpack":
        guard tail.count >= 2 else {
            throw CLIError.usage("banny unpack <in.bs.zip> <project.bs> [--json]")
        }
        var options = CLIOptions(Array(tail.dropFirst(2)))
        let json = try options.flag("--json")
        try options.finish(usage: "banny unpack <in.bs.zip> <project.bs> [--json]")
        let output = URL(fileURLWithPath: tail[1])
        try unpackPackage(at: tail[0], to: output)
        if json {
            struct PackageReport: Codable { let source: String; let output: String; let operation: String }
            try printJSON(PackageReport(source: tail[0], output: output.path, operation: "unpack"))
        } else { print("unpacked \(tail[1]) — editable strict v4 project") }

    case "skill":
        try skillCommand(tail)

    default:
        throw CLIError.usage("unknown command \(command)\n\n\(cliUsage)")
    }
    return 0
}
