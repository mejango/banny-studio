import Foundation
import BannyCore
import BannyRender
import BannyMedia

// Headless shipping is staged, preflighted, and introspectable before a costly render.

private struct ShipPlan: Codable {
    let project: String
    let output: String?
    let width: Int
    let height: Int
    let fps: Int
    let rangeFrom: Double
    let rangeTo: Double
    let duration: Double
    let frames: Int
    let ready: Bool
    let preflightErrors: [String]
}

private struct ShipReport: Codable {
    let project: String
    let output: String
    let width: Int
    let height: Int
    let fps: Int
    let frames: Int
    let bytes: UInt64
    let renderSeconds: Double
    let rangeFrom: Double
    let rangeTo: Double
}

private struct ShipProgress: Codable {
    let type: String
    let command: String
    let fraction: Double
    let percent: Int
}

private func emitProgressJSON(_ fraction: Double) {
    let value = min(1, max(0, fraction))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(ShipProgress(
        type: "progress", command: "ship", fraction: value,
        percent: Int((value * 100).rounded()))) else { return }
    FileHandle.standardError.write(data + Data("\n".utf8))
}

func shipCommand(_ args: [String]) throws -> Int32 {
    let usage = "banny ship <show.bs> [out.mp4] [--plan] "
        + "[--480|--720|--1080|--4k] [--range FROM TO] "
        + "[--overwrite] [--progress-json] [--json]"
    guard let projectPath = args.first else { throw CLIError.usage(usage) }
    var remainder = Array(args.dropFirst())
    let outputPath: String?
    if let first = remainder.first, !first.hasPrefix("--") {
        outputPath = first
        remainder.removeFirst()
    } else {
        outputPath = nil
    }
    var options = CLIOptions(remainder)
    let planOnly = try options.flag("--plan")
    let p480 = try options.flag("--480")
    let p720 = try options.flag("--720")
    let p1080 = try options.flag("--1080")
    let p2160 = try options.flag("--4k")
    let rangeValues = try options.pair("--range")
    let overwrite = try options.flag("--overwrite")
    let progressJSON = try options.flag("--progress-json")
    let json = try options.flag("--json")
    try options.finish(usage: usage)
    guard planOnly || outputPath != nil else {
        throw CLIError.usage(usage)
    }
    guard [p480, p720, p1080, p2160].filter({ $0 }).count <= 1 else {
        throw CLIError.invalid("choose only one output tier")
    }
    guard !(planOnly && overwrite) else {
        throw CLIError.invalid("--overwrite is not meaningful with --plan")
    }
    guard !(planOnly && progressJSON) else {
        throw CLIError.invalid("--progress-json is not meaningful with --plan")
    }

    return try withReadPackage(at: projectPath) { _, loadedContents in
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
        let segments = ShowExporter.resolveSegments(document: contents.document)
        guard let first = segments.first, let last = segments.last else {
            throw CLIError.invalid("the show has no exportable duration")
        }
        let duration = segments.reduce(0) { $0 + max(0, $1.to - $1.from) }
        let frames = segments.reduce(0) {
            $0 + Int((max(0, $1.to - $1.from) * Double(exportOptions.fps)).rounded(.up))
        }
        let plan = ShipPlan(
            project: projectPath, output: outputPath,
            width: Int(exportOptions.size.width),
            height: Int(exportOptions.size.height), fps: exportOptions.fps,
            rangeFrom: first.from, rangeTo: last.to,
            duration: duration, frames: frames,
            ready: preflightErrors.isEmpty,
            preflightErrors: preflightErrors)
        if planOnly {
            if json {
                try printJSON(plan)
            } else {
                print("\(plan.ready ? "ready" : "blocked") — \(plan.width)x\(plan.height) "
                      + "@ \(plan.fps)fps, \(plan.frames) frames / \(plan.duration)s")
                for error in preflightErrors { print("  error: \(error)") }
            }
            return plan.ready ? 0 : 1
        }
        guard preflightErrors.isEmpty else {
            throw CLIError.validationFailed(preflightErrors)
        }
        let outputURL = URL(fileURLWithPath: outputPath!)
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

        let stagingURL = parent.appendingPathComponent(
            ".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp.mp4")
        let start = ContinuousClock.now
        var lastProgress = -1
        do {
            try ShowExporter.export(
                document: contents.document,
                assets: assets,
                audioURL: { contents.audioURLs[$0] },
                assetURL: { contents.assetURLs[$0] },
                options: exportOptions,
                to: stagingURL,
                progress: { progress in
                    let percentage = Int((progress * 100).rounded())
                    guard percentage != lastProgress else { return }
                    lastProgress = percentage
                    if progressJSON {
                        emitProgressJSON(progress)
                    } else if !json, percentage % 10 == 0 {
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
        let report = ShipReport(
            project: projectPath, output: outputURL.path,
            width: plan.width, height: plan.height, fps: plan.fps,
            frames: frames, bytes: bytes, renderSeconds: elapsedSeconds,
            rangeFrom: plan.rangeFrom, rangeTo: plan.rangeTo)
        if json {
            try printJSON(report)
        } else {
            print("shipped \(outputURL.lastPathComponent): \(bytes) bytes "
                  + "in \(String(format: "%.2fs", elapsedSeconds))")
        }
        return 0
    }
}
