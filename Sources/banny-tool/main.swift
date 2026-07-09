import Foundation
import BannyCore

// banny-tool import <v1.json> <out.bannyshow>
// banny-tool info <show.bannyshow>
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
    let contents = try ShowPackage.read(from: URL(fileURLWithPath: args[2]))
    let st = contents.document.stage
    print("tracks: \(st.characters.count) characters (\(st.characters.map(\.events.count).reduce(0,+)) events), \(st.audioTracks.count) audio, \(st.imageTracks.count) image, \(st.backgroundTracks.count) background; \(contents.document.assets.count) assets; end \(st.contentEnd)s")
case "ship":
    try shipCommand(Array(args.dropFirst(2)))
case "stylize":
    try stylizeCommand(Array(args.dropFirst(2)))
default:
    print("usage: banny-tool import <v1.json> <out.bannyshow> | info <show.bannyshow> | ship <show.bannyshow> <out.mp4> [--720|--1080|--4k] | stylize <in.png> <out.png> [gridWidth]")
    exit(1)
}
