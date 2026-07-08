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
                          backgrounds: result.backgroundFiles,
                          to: URL(fileURLWithPath: args[3]))
    print("imported \(result.document.scenes.count) scenes, \(result.audioFiles.count) audio clips → \(args[3])")
case "info":
    let contents = try ShowPackage.read(from: URL(fileURLWithPath: args[2]))
    for s in contents.document.scenes {
        print("\(s.name): \(s.state.characters.count) characters, \(s.state.characters.map { $0.events.count }.reduce(0,+)) events")
    }
case "ship":
    try shipCommand(Array(args.dropFirst(2)))
default:
    print("usage: banny-tool import <v1.json> <out.bannyshow> | info <show.bannyshow> | ship <show.bannyshow> <out.mp4> [--720|--1080|--4k]")
    exit(1)
}
