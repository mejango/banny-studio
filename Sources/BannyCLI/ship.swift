import Foundation
import BannyCore
import BannyRender
import BannyMedia

// Headless shipping is staged and preflighted by the shared CLI engine.

private struct ShipReport: Codable {
    let project: String
    let output: String
    let width: Int
    let height: Int
    let fps: Int
    let bytes: UInt64
    let renderSeconds: Double
    let rangeFrom: Double
    let rangeTo: Double
}

func shipCommand(_ args: [String]) throws {
    let usage = """
    banny ship <show.bs> <out.mp4> [--480|--720|--1080|--4k] \
    [--range FROM TO] [--overwrite] [--json]
    """
    guard args.count >= 2 else { throw CLIError.usage(usage) }
    let projectPath = args[0]
    let outputURL = URL(fileURLWithPath: args[1])
    var options = CLIOptions(Array(args.dropFirst(2)))
    let p480 = try options.flag("--480")
    let p720 = try options.flag("--720")
    let p1080 = try options.flag("--1080")
    let p2160 = try options.flag("--4k")
    let rangeValues = try options.pair("--range")
    let overwrite = try options.flag("--overwrite")
    let json = try options.flag("--json")
    try options.finish(usage: usage)
    guard [p480, p720, p1080, p2160].filter({ $0 }).count <= 1 else {
        throw CLIError.invalid("choose only one output tier")
    }
    if FileManager.default.fileExists(atPath: outputURL.path), !overwrite {
        throw CLIError.invalid(
            "\(outputURL.path) already exists; pass --overwrite to replace it")
    }

    let parent = outputURL.deletingLastPathComponent()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(
        atPath: parent.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        throw CLIError.invalid("output directory does not exist: \(parent.path)")
    }
    try withReadPackage(at: projectPath) { _, loadedContents in
        var contents = loadedContents
        if let rangeValues {
            guard let from = Double(rangeValues.0), from.isFinite,
                  let to = Double(rangeValues.1), to.isFinite,
                  from >= 0, to > from else {
                throw CLIError.invalid(
                    "--range requires finite FROM TO values with 0 ≤ FROM < TO")
            }
            contents.document.show = [
                ShowSegment(name: "CLI export range", from: from, to: to),
            ]
        }
        let tier: ShowExporter.Options = p480 ? .p480
            : p720 ? .p720
            : p2160 ? .p2160
            : .p1080
        let exportOptions = tier.fitted(
            aspect: contents.document.settings.frameAspect)
        let assets = try AssetCatalog(assetsRoot: locateAssetsRoot())
        let preflightErrors = ShowExportPreflight.errors(
            document: contents.document,
            availableAudioIDs: Set(contents.audioURLs.keys),
            availableAssetIDs: Set(contents.assetURLs.keys),
            catalog: assets)
        guard preflightErrors.isEmpty else {
            throw CLIError.validationFailed(preflightErrors)
        }

        let stagingURL = parent.appendingPathComponent(
            ".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp.mp4")
        let start = ContinuousClock.now
        do {
            try ShowExporter.export(
                document: contents.document,
                assets: assets,
                audioURL: { contents.audioURLs[$0] },
                assetURL: { contents.assetURLs[$0] },
                options: exportOptions,
                to: stagingURL,
                progress: json ? nil : { progress in
                    let percentage = Int((progress * 100).rounded())
                    if percentage % 10 == 0 {
                        print("  \(percentage)%", terminator: "\r")
                        fflush(stdout)
                    }
                })
            if FileManager.default.fileExists(atPath: outputURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    outputURL, withItemAt: stagingURL)
            } else {
                try FileManager.default.moveItem(at: stagingURL, to: outputURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
        let elapsed = start.duration(to: .now)
        let elapsedSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        let bytes = ((try? FileManager.default.attributesOfItem(
            atPath: outputURL.path)[.size]) as? NSNumber)?.uint64Value ?? 0
        guard let segment = ShowExporter.resolveSegments(
            document: contents.document).first else {
            throw CLIError.invalid("the show has no exportable duration")
        }
        let report = ShipReport(
            project: projectPath,
            output: outputURL.path,
            width: Int(exportOptions.size.width),
            height: Int(exportOptions.size.height),
            fps: exportOptions.fps,
            bytes: bytes,
            renderSeconds: elapsedSeconds,
            rangeFrom: segment.from,
            rangeTo: segment.to)
        if json {
            try printJSON(report)
        } else {
            print("shipped \(outputURL.lastPathComponent): \(bytes) bytes "
                  + "in \(String(format: "%.2fs", elapsedSeconds))")
        }
    }
}
