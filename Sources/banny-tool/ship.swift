import Foundation
import BannyCore
import BannyRender
import BannyMedia

func shipCommand(_ args: [String]) throws {
    // banny-tool ship <show.bannyshow> <out.mp4> [--720|--1080|--4k]
    let pkgURL = URL(fileURLWithPath: args[0])
    let outURL = URL(fileURLWithPath: args[1])
    let options: ShowExporter.Options = args.contains("--720") ? .p720
        : args.contains("--4k") ? .p2160 : .p1080

    let contents = try ShowPackage.read(from: pkgURL)
    let assetsRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/BannyAssets")
    let assets = try AssetCatalog(assetsRoot: assetsRoot)

    let clock = ContinuousClock()
    let elapsed = try clock.measure {
        try ShowExporter.export(
            document: contents.document,
            activeScene: contents.document.settings.activeScene,
            assets: assets,
            audioURL: { contents.audioURLs[$0] },
            backgroundURL: { contents.backgroundURLs[$0] },
            options: options,
            to: outURL,
            progress: { p in
                if Int(p * 100) % 20 == 0 { print("  \(Int(p * 100))%", terminator: "\r") }
            })
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int).flatMap { $0 } ?? 0
    print("shipped \(outURL.lastPathComponent): \(size) bytes in \(elapsed)")
}
