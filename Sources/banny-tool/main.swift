import Foundation
import BannyCore
import BannyRender
import BannyMedia

// banny-tool import <v1.json> <out.bannyshow>
// banny-tool info <show.bannyshow>
func run() throws {
let args = CommandLine.arguments
switch args.count >= 2 ? args[1] : "" {
case "import":
    let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    let result = try V1Importer.importStudio(json: data)
    try ShowPackage.write(result.document, audio: result.audioFiles,
                          assets: result.backgroundFiles,
                          to: URL(fileURLWithPath: args[3]))
    let stage = result.document.stage
    print("imported → \(args[3]): \(stage.characters.count) character tracks, \(result.audioFiles.count) audio clips, \(result.document.assets.count) assets")
case "info":
    guard args.count >= 3 else { throw CLIError.usage("banny info <show.bs> [--json]") }
    let contents = try ShowPackage.read(from: URL(fileURLWithPath: args[2]))
    let st = contents.document.stage
    if args.contains("--json") {
        struct Info: Codable {
            var characters: Int; var events: Int; var audioTracks: Int
            var imageTracks: Int; var backgroundTracks: Int
            var assets: Int; var contentEnd: Double
            var characterNames: [String]
        }
        let info = Info(characters: st.characters.count,
                        events: st.characters.map(\.events.count).reduce(0, +),
                        audioTracks: st.audioTracks.count,
                        imageTracks: st.imageTracks.count,
                        backgroundTracks: st.backgroundTracks.count,
                        assets: contents.document.assets.count,
                        contentEnd: st.contentEnd,
                        characterNames: st.characters.map(\.name))
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        print(String(data: try enc.encode(info), encoding: .utf8)!)
    } else {
        print("tracks: \(st.characters.count) characters (\(st.characters.map(\.events.count).reduce(0,+)) events), \(st.audioTracks.count) audio, \(st.imageTracks.count) image, \(st.backgroundTracks.count) background; \(contents.document.assets.count) assets; end \(st.contentEnd)s")
    }
case "ship":
    try shipCommand(Array(args.dropFirst(2)))
case "stylize":
    try stylizeCommand(Array(args.dropFirst(2)))
case "catalog":
    let catalog = try AssetCatalog(assetsRoot: locateAssetsRoot())
    let summary = catalog.summary()
    if args.contains("--json") {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        print(String(data: try enc.encode(summary), encoding: .utf8)!)
    } else {
        print("bodies: \(summary.bodies.joined(separator: ", "))")
        for slot in summary.slots {
            print("\n\(slot.name) (slot \(slot.slot)):")
            for o in slot.outfits { print("  \(o.name) — \(o.label)") }
        }
        print("\neyes: \(summary.eyes.joined(separator: ", "))")
        print("mouths: \(summary.mouths.joined(separator: ", "))")
    }
case "validate":
    guard args.count >= 3 else { throw CLIError.usage("banny validate <show.bs> [--json]") }
    let contents = try ShowPackage.read(from: URL(fileURLWithPath: args[2]))
    let catalog = try? AssetCatalog(assetsRoot: locateAssetsRoot())
    let diags = ShowLint.check(document: contents.document,
                               audioIDs: Set(contents.audioURLs.keys),
                               assetFileIDs: Set(contents.assetURLs.keys),
                               catalog: catalog)
    if args.contains("--json") {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        print(String(data: try enc.encode(diags), encoding: .utf8)!)
    } else if diags.isEmpty {
        print("ok — no issues")
    } else {
        for d in diags { print("\(d.severity.rawValue): \(d.message)") }
    }
    if catalog == nil { print("note: assets not found — wardrobe names not checked") }
    exit(diags.contains { $0.severity == .error } ? 1 : 0)
case "preview":
    guard args.count >= 4 else { throw CLIError.usage("banny preview <show.bs> <out.png> [--t SECONDS]") }
    let t: Double
    if let i = args.firstIndex(of: "--t") {
        guard args.indices.contains(i + 1), let parsed = Double(args[i + 1]) else {
            throw CLIError.usage("banny preview <show.bs> <out.png> [--t SECONDS]")
        }
        t = parsed
    } else {
        t = 0
    }
    let contents = try ShowPackage.read(from: URL(fileURLWithPath: args[2]))
    let assets = try AssetCatalog(assetsRoot: locateAssetsRoot())
    try ShowPreview.writePNG(contents: contents, assets: assets, at: t,
                             to: URL(fileURLWithPath: args[3]))
    print("wrote \(args[3]) @ t=\(t)s")
case "new":
    guard args.count >= 3 else { throw CLIError.usage("banny new <out.bs> [--characters N]") }
    let out = URL(fileURLWithPath: args[2])
    guard !FileManager.default.fileExists(atPath: out.path) else {
        print("error: \(out.path) already exists"); exit(1)
    }
    let count: Int
    if let i = args.firstIndex(of: "--characters") {
        guard args.indices.contains(i + 1), let parsed = Int(args[i + 1]) else {
            throw CLIError.usage("banny new <out.bs> [--characters N]")
        }
        count = parsed
    } else {
        count = 2
    }
    try ShowPackage.write(.starter(characterCount: count), to: out)
    print("created \(out.path) — edit show.json, then `banny validate` before shipping")
case "skill":
    try skillCommand(Array(args.dropFirst(2)))
default:
    print("""
    usage: banny <command>
      catalog [--json]                                — wardrobe options (bodies, outfits, eyes, mouths)
      new <out.bs> [--characters N]                   — create a starter project
      validate <show.bs> [--json]                     — lint; exit 1 on errors
      preview <show.bs> <out.png> [--t SECONDS]       — render one frame
      info <show.bs> [--json]                         — track/event/asset counts
      ship <show.bs> <out.mp4> [--480|--720|--1080|--4k] [--range FROM TO]
      import <v1.json> <out.bannyshow>                — web v1 → native
      stylize <in.png> <out.png> [gridWidth]          — pixel-art stylizer
      skill [install|print]                           — the AI production skill
    """)
    exit(1)
}
}

do {
    try run()
} catch {
    print(error)
    exit(1)
}
