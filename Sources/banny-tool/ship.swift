import Foundation
import BannyCore
import BannyRender
import BannyMedia

func shipCommand(_ args: [String]) throws {
    // banny ship <show.bs> <out.mp4> [--480|--720|--1080|--4k] [--range FROM TO]
    guard args.count >= 2 else {
        throw CLIError.usage("banny ship <show.bs> <out.mp4> [--480|--720|--1080|--4k] [--range FROM TO]")
    }
    let outURL = URL(fileURLWithPath: args[1])
    let tier: ShowExporter.Options = args.contains("--480") ? .p480
        : args.contains("--720") ? .p720
        : args.contains("--4k") ? .p2160 : .p1080

    var contents = try readPackage(at: args[0])
    if let i = args.firstIndex(of: "--range") {
        guard args.indices.contains(i + 2),
              let from = Double(args[i + 1]), let to = Double(args[i + 2]), to > from else {
            throw CLIError.usage("banny ship <show.bs> <out.mp4> [--480|--720|--1080|--4k] [--range FROM TO]")
        }
        contents.document.show = [ShowSegment(name: "range", from: from, to: to)]
    }
    let options = tier.fitted(aspect: contents.document.settings.frameAspect)
    let assets = try AssetCatalog(assetsRoot: locateAssetsRoot())

    let clock = ContinuousClock()
    let elapsed = try clock.measure {
        try ShowExporter.export(
            document: contents.document,
            assets: assets,
            audioURL: { contents.audioURLs[$0] },
            assetURL: { contents.assetURLs[$0] },
            options: options,
            to: outURL,
            progress: { p in
                if Int(p * 100) % 20 == 0 { print("  \(Int(p * 100))%", terminator: "\r") }
            })
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int).flatMap { $0 } ?? 0
    print("shipped \(outURL.lastPathComponent): \(size) bytes in \(elapsed)")
}
