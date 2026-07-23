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

private let usage = """
usage: banny <command>              (read-only commands accept folder or zipped .bs)
  capabilities [--json]                            — machine-readable CLI feature contract
  schema [--compact|--example]                     — canonical show.json JSON Schema/example
  catalog [--json]                                 — wardrobe bodies, outfits, eyes, mouths
  voices [--language PREFIX] [--json]              — installed/system/personal TTS voices
  new <folder.bs> [--characters N]                 — create a canonical starter project
  migrate <folder.bs> [options]                    — atomically upgrade v2/v3 to strict v4
  validate <show.bs> [--json]                      — strict schema + semantic/package checks
  preview <show.bs> <out.png> [--t SECONDS]        — render one frame
  info <show.bs> [--json]                          — track/event/asset counts
  ship <show.bs> <out.mp4> [tier] [--range F T]    — preflight and render an mp4
  apply <folder.bs> <patch.json|-> [options]       — atomic RFC 6902 JSON Patch
  tts <folder.bs> --character N [source/options]   — synthesize portable speech clips
  lipsync <folder.bs> --character N --clip ID      — analyze/clear precise mouth timing
  media probe <file> [--json]                      — inspect media type/duration/dimensions
  media import <folder.bs> <file> [options]        — copy and place media safely
  pack <folder.bs> <out.bs>                        — zip a project for sharing/app import
  unpack <in.bs> <folder.bs>                       — extract a zipped project for editing
  import <v1.json> <out.bannyshow>                 — web v1 → native
  stylize <in.png> <out.png> [gridWidth] [dither]  — pixel-art stylizer
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

    case "--help", "-h", "help", "":
        print(usage)

    case "capabilities":
        try capabilitiesCommand(tail)

    case "schema":
        try schemaCommand(tail)

    case "import":
        guard tail.count == 2 else {
            throw CLIError.usage("banny import <v1.json> <out.bannyshow>")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: tail[0]))
        let result = try V1Importer.importStudio(json: data)
        try writeNewPackage(
            result.document,
            audio: result.audioFiles,
            assets: result.backgroundFiles,
            to: URL(fileURLWithPath: tail[1]))
        let stage = result.document.stage
        print("imported → \(tail[1]): \(stage.characters.count) character tracks, "
              + "\(result.audioFiles.count) audio clips, \(result.document.assets.count) assets")

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
        try shipCommand(tail)

    case "stylize":
        try stylizeCommand(tail)

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
                "banny preview <show.bs> <out.png> [--t SECONDS]")
        }
        var options = CLIOptions(Array(tail.dropFirst(2)))
        let time = try options.double("--t") ?? 0
        try options.finish(
            usage: "banny preview <show.bs> <out.png> [--t SECONDS]")
        guard time >= 0 else { throw CLIError.invalid("--t cannot be before 0") }
        let assets = try AssetCatalog(assetsRoot: locateAssetsRoot())
        try withReadPackage(at: tail[0]) { _, contents in
            try ShowPreview.writePNG(
                contents: contents,
                assets: assets,
                at: time,
                to: URL(fileURLWithPath: tail[1]))
        }
        print("wrote \(tail[1]) @ t=\(time)s")

    case "new":
        guard let outputPath = tail.first else {
            throw CLIError.usage("banny new <folder.bs> [--characters N]")
        }
        var options = CLIOptions(Array(tail.dropFirst()))
        let count = try options.int("--characters") ?? 2
        try options.finish(
            usage: "banny new <folder.bs> [--characters N]")
        guard (1...4).contains(count) else {
            throw CLIError.invalid("--characters must be inside 1...4")
        }
        let output = URL(fileURLWithPath: outputPath)
        try writeNewPackage(.starter(characterCount: count), to: output)
        print("created \(output.path) — strict v4 project ready for Studio or CLI")

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
        guard tail.count == 2 else {
            throw CLIError.usage("banny pack <folder.bs> <out.bs>")
        }
        let output = URL(fileURLWithPath: tail[1])
        try packPackage(at: tail[0], to: output)
        print("packed \(tail[1]) — importable by Banny Studio")

    case "unpack":
        guard tail.count == 2 else {
            throw CLIError.usage("banny unpack <in.bs> <folder.bs>")
        }
        let output = URL(fileURLWithPath: tail[1])
        try unpackPackage(at: tail[0], to: output)
        print("unpacked \(tail[1]) — editable strict v4 project")

    case "skill":
        try skillCommand(tail)

    default:
        printErr("unknown command: \(command)\n")
        printErr(usage)
        return 1
    }
    return 0
}
