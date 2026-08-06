import Foundation
import BannyCore
import BannyRender

/// Shared optimistic-concurrency and atomic-write plumbing for typed edits.
/// Commands mutate an in-memory document, run the full editable preflight,
/// then publish one canonical show.json write or leave the package untouched.
struct EditableMutation {
    let root: URL
    let showURL: URL
    let beforeData: Data
    let beforeSHA256: String
    var contents: ShowPackage.Contents
    let catalog: AssetCatalog?
}

struct MutationSummary: Codable {
    let project: String
    let operation: String
    let dryRun: Bool
    let changed: Bool
    let beforeSHA256: String
    let afterSHA256: String
    let warnings: [String]
}

func prepareEditableMutation(projectPath: String,
                             expectedHash: String?) throws -> EditableMutation {
    let (root, contents) = try readEditablePackage(at: projectPath)
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
    let catalog = try? AssetCatalog(assetsRoot: locateAssetsRoot())
    try requireEditableDocument(contents, catalog: catalog)
    return EditableMutation(root: root, showURL: showURL,
                            beforeData: beforeData, beforeSHA256: beforeHash,
                            contents: contents, catalog: catalog)
}

func finishEditableMutation(_ mutation: EditableMutation,
                            operation: String,
                            dryRun: Bool) throws -> MutationSummary {
    try requireEditableDocument(mutation.contents, catalog: mutation.catalog)
    let outputData = try canonicalDocumentData(mutation.contents.document)
    _ = try ShowJSONCodec.decodeDocument(String(decoding: outputData, as: UTF8.self))
    let afterHash = sha256Hex(outputData)
    let changed = mutation.beforeData != outputData
    if changed, !dryRun {
        try outputData.write(to: mutation.showURL, options: .atomic)
    }
    let warnings = editableDiagnostics(
        for: mutation.contents, catalog: mutation.catalog)
        .filter { $0.severity == .warning }
        .map(\.message)
    return MutationSummary(
        project: mutation.root.path,
        operation: operation,
        dryRun: dryRun,
        changed: changed,
        beforeSHA256: mutation.beforeSHA256,
        afterSHA256: afterHash,
        warnings: warnings)
}
