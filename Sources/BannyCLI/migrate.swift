import BannyCore
import BannyRender
import Foundation

/// Explicit legacy migration keeps normal production reads strict. Agents can
/// upgrade an old package deliberately, inspect the hash transition, and then
/// use the v4-only editing surface.
private struct MigrationReport: Codable {
    let project: String
    let fromVersion: Int
    let toVersion: Int
    let dryRun: Bool
    let changed: Bool
    let beforeSHA256: String
    let afterSHA256: String
    let warnings: [String]
}

func migrateCommand(_ args: [String]) throws {
    let usage =
        "banny migrate <folder.bs> [--dry-run] [--if-hash SHA256] [--json]"
    guard let projectPath = args.first else {
        throw CLIError.usage(usage)
    }
    var options = CLIOptions(Array(args.dropFirst()))
    let dryRun = try options.flag("--dry-run")
    let expectedHash = try options.value("--if-hash")
    let json = try options.flag("--json")
    try options.finish(usage: usage)

    let root = try editablePackageRoot(at: projectPath)
    let showURL = root.appendingPathComponent("show.json")
    let beforeData = try Data(contentsOf: showURL)
    let beforeHash = sha256Hex(beforeData)
    if let expectedHash {
        let expected = try validatedSHA256(expectedHash)
        guard expected == beforeHash else {
            throw CLIError.invalid(
                "project changed: expected SHA-256 \(expected), found \(beforeHash)")
        }
    }

    let object = try JSONSerialization.jsonObject(with: beforeData)
    guard let dictionary = object as? [String: Any] else {
        throw CLIError.invalid("show.json must contain a JSON object")
    }
    let fromVersion = (dictionary["version"] as? NSNumber)?.intValue ?? 2
    guard fromVersion <= BannyCLIContract.schemaVersion else {
        throw CLIError.invalid(
            "show schema \(fromVersion) is newer than this CLI's schema "
                + "\(BannyCLIContract.schemaVersion)")
    }

    var contents: ShowPackage.Contents
    if fromVersion == BannyCLIContract.schemaVersion {
        contents = try readEditablePackage(at: projectPath).contents
    } else {
        do {
            contents = try ShowPackage.read(from: root)
        } catch {
            throw CLIError.invalid(
                "could not migrate \(showURL.path): \(error.localizedDescription)")
        }
        contents.document.version = BannyCLIContract.schemaVersion
        if contents.document.stage.backgroundTracks.isEmpty {
            contents.document.stage.backgroundTracks = [
                BackgroundTrack(id: "scenes", name: "Scenes"),
            ]
        }
    }

    let catalog = try? AssetCatalog(assetsRoot: locateAssetsRoot())
    try requireEditableDocument(contents, catalog: catalog)
    let outputData = try canonicalDocumentData(contents.document)
    // Re-enter through the strict v4 decoder before publishing the migration.
    _ = try ShowJSONCodec.decodeDocument(
        String(decoding: outputData, as: UTF8.self))
    let afterHash = sha256Hex(outputData)
    let changed = beforeData != outputData
    if changed, !dryRun {
        try outputData.write(to: showURL, options: .atomic)
    }

    let warnings = editableDiagnostics(for: contents, catalog: catalog)
        .filter { $0.severity == .warning }
        .map(\.message)
    let report = MigrationReport(
        project: root.path,
        fromVersion: fromVersion,
        toVersion: BannyCLIContract.schemaVersion,
        dryRun: dryRun,
        changed: changed,
        beforeSHA256: beforeHash,
        afterSHA256: afterHash,
        warnings: warnings)
    if json {
        try printJSON(report)
    } else {
        let verb = dryRun ? "would migrate" : (changed ? "migrated" : "already canonical")
        print("\(verb) \(root.path): schema \(fromVersion) → "
              + "\(BannyCLIContract.schemaVersion)")
        print("sha256 \(beforeHash) → \(afterHash)")
        for warning in warnings {
            print("warning: \(warning)")
        }
    }
}
