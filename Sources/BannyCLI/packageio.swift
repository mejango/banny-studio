import Foundation
import BannyCore
import BannyRender

// Package I/O is shared so every command enforces the same strict decoder.

private struct PackageLocation {
    let root: URL
    let temporaryRoot: URL?
}

/// Decodes the package through the strict JSON codec. `ShowPackage.read`
/// deliberately supports migration, while CLI production commands must also
/// reject unknown v4 fields instead of silently discarding them.
private func readPackageRoot(_ root: URL) throws -> ShowPackage.Contents {
    var contents = try ShowPackage.read(from: root)
    let showURL = root.appendingPathComponent("show.json")
    let text = try String(contentsOf: showURL, encoding: .utf8)
    do {
        contents.document = try ShowJSONCodec.decodeDocument(text)
    } catch {
        throw CLIError.invalid(
            "invalid \(showURL.path): \(ShowJSONCodec.readableMessage(for: error))")
    }
    return contents
}

/// Opens a mutable project once and returns its canonical root together with
/// strict contents. Mutation commands never extract an archive implicitly.
func readEditablePackage(
    at path: String
) throws -> (root: URL, contents: ShowPackage.Contents) {
    let root = try editablePackageRoot(at: path)
    return (root, try readPackageRoot(root))
}

/// Keeps an extracted archive alive only for the duration of a read-only
/// operation, then removes its private temporary directory on success or
/// failure. This makes the library safe for long-running automation hosts.
func withReadPackage<Result>(
    at path: String,
    _ operation: (URL, ShowPackage.Contents) throws -> Result
) throws -> Result {
    let location = try readablePackageLocation(at: path)
    defer {
        if let temporaryRoot = location.temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }
    return try operation(location.root, readPackageRoot(location.root))
}

/// Returns a package directory that can be changed in place. Read-only
/// commands accept `.bs` packages or `.bs.zip` archives; mutation commands
/// require an unpacked package with an explicit, inspectable destination.
func editablePackageRoot(at path: String) throws -> URL {
    let fm = FileManager.default
    let url = URL(fileURLWithPath: path)
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else {
        throw CLIError.notAPackage(path, "no such file")
    }
    guard isDirectory.boolValue else {
        throw CLIError.notAPackage(
            path,
            "this command changes a project; run "
            + "`banny unpack \(path) <project.bs>` first")
    }
    guard fm.fileExists(atPath: url.appendingPathComponent("show.json").path) else {
        throw CLIError.notAPackage(path, "no show.json — not a package directory")
    }
    return url
}

func canonicalDocumentData(_ document: ShowDocument) throws -> Data {
    Data(try ShowJSONCodec.encode(document: document).utf8)
}

func writeDocument(_ document: ShowDocument, to packageRoot: URL) throws {
    try canonicalDocumentData(document)
        .write(to: packageRoot.appendingPathComponent("show.json"), options: .atomic)
}

/// Creates a new editable project through a sibling staging directory. The
/// destination appears only after every file is written and strictly decoded.
func writeNewPackage(
    _ document: ShowDocument,
    audio: [String: (data: Data, ext: String)] = [:],
    assets: [String: (data: Data, ext: String)] = [:],
    to output: URL
) throws {
    try requireNativeProjectOutput(output)
    let staging = try newStagingSibling(for: output, directory: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    try ShowPackage.write(document, audio: audio, assets: assets, to: staging)
    try FileManager.default.createDirectory(
        at: staging.appendingPathComponent("audio"),
        withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: staging.appendingPathComponent("assets"),
        withIntermediateDirectories: true)
    let contents = try readPackageRoot(staging)
    try requireEditableDocument(
        contents,
        catalog: try? AssetCatalog(assetsRoot: locateAssetsRoot()))
    try FileManager.default.moveItem(at: staging, to: output)
}

/// Validates and archives an editable package through a sibling staging file.
func packPackage(at input: String, to output: URL) throws {
    let (source, contents) = try readEditablePackage(at: input)
    try requireShareArchiveOutput(output)
    try requireEditableDocument(
        contents,
        catalog: try? AssetCatalog(assetsRoot: locateAssetsRoot()))
    try rejectNestedOutput(output, inside: source)
    let staging = try newStagingSibling(for: output, directory: false)
    defer { try? FileManager.default.removeItem(at: staging) }
    try zipPackage(source, to: staging)
    try withReadPackage(at: staging.path) { _, stagedContents in
        try requireEditableDocument(
            stagedContents,
            catalog: try? AssetCatalog(assetsRoot: locateAssetsRoot()))
    }
    try FileManager.default.moveItem(at: staging, to: output)
}

/// Extracts a package through a sibling staging directory, validates it, then
/// atomically publishes it under the requested name.
func unpackPackage(at input: String, to output: URL) throws {
    try requireNativeProjectOutput(output)
    try withReadPackage(at: input) { source, sourceContents in
        try requireEditableDocument(
            sourceContents,
            catalog: try? AssetCatalog(assetsRoot: locateAssetsRoot()))
        try rejectNestedOutput(output, inside: source)
        let staging = try newStagingSibling(for: output, directory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        let stagedContents = try readPackageRoot(staging)
        try requireEditableDocument(
            stagedContents,
            catalog: try? AssetCatalog(assetsRoot: locateAssetsRoot()))
        try FileManager.default.moveItem(at: staging, to: output)
    }
}

/// A live project is always a package named `.bs`. A regular ZIP must retain
/// its `.zip` suffix so Finder and autosave can never mistake one for the other.
private func requireNativeProjectOutput(_ output: URL) throws {
    guard output.pathExtension.lowercased() == "bs" else {
        throw CLIError.invalid(
            "editable project packages must end in .bs (for example, show.bs)")
    }
}

private func requireShareArchiveOutput(_ output: URL) throws {
    guard output.lastPathComponent.lowercased().hasSuffix(".bs.zip") else {
        throw CLIError.invalid(
            "shared project archives must end in .bs.zip (for example, show.bs.zip)")
    }
}

private func newStagingSibling(for output: URL, directory: Bool) throws -> URL {
    let fm = FileManager.default
    guard !fm.fileExists(atPath: output.path) else {
        throw CLIError.invalid("\(output.path) already exists")
    }
    let parent = output.deletingLastPathComponent()
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: parent.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        throw CLIError.invalid("output directory does not exist: \(parent.path)")
    }
    return parent.appendingPathComponent(
        ".\(output.lastPathComponent).\(UUID().uuidString).staging",
        isDirectory: directory)
}

private func rejectNestedOutput(_ output: URL, inside source: URL) throws {
    let sourcePath = source.standardizedFileURL.path
    let outputPath = output.standardizedFileURL.path
    guard outputPath != sourcePath,
          !outputPath.hasPrefix(sourcePath + "/") else {
        throw CLIError.invalid("output cannot be placed inside its source package")
    }
}

func editableDiagnostics(for contents: ShowPackage.Contents,
                         catalog: AssetCatalog?) -> [ShowLint.Diagnostic] {
    ShowLint.check(
        document: contents.document,
        audioIDs: Set(contents.audioURLs.keys),
        assetFileIDs: Set(contents.assetURLs.keys),
        catalog: catalog,
        profile: .editableShow)
}

func requireEditableDocument(_ contents: ShowPackage.Contents,
                             catalog: AssetCatalog? = nil) throws {
    let errors = editableDiagnostics(for: contents, catalog: catalog)
        .filter { $0.severity == .error }
        .map(\.message)
    if !errors.isEmpty { throw CLIError.validationFailed(errors) }
}

/// Locates show.json for a `.bs` package or shareable `.bs.zip` archive. Archive
/// extraction is owned by `withReadPackage`, which guarantees cleanup.
private func readablePackageLocation(at path: String) throws -> PackageLocation {
    let fm = FileManager.default
    let url = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
        throw CLIError.notAPackage(path, "no such file")
    }
    if isDir.boolValue {
        guard fm.fileExists(
            atPath: url.appendingPathComponent("show.json").path) else {
            throw CLIError.notAPackage(path, "no show.json — not a package directory")
        }
        return PackageLocation(root: url, temporaryRoot: nil)
    }

    let fh = try FileHandle(forReadingFrom: url)
    defer { try? fh.close() }
    let magic = try fh.read(upToCount: 2)
    guard magic == Data([0x50, 0x4B]) else {  // "PK"
        throw CLIError.notAPackage(path, "not a .bs package or ZIP archive")
    }
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("banny-unpack-\(UUID().uuidString)", isDirectory: true)
    do {
        try unzipArchive(url, to: tmp)
    } catch {
        try? fm.removeItem(at: tmp)
        throw error
    }
    if fm.fileExists(atPath: tmp.appendingPathComponent("show.json").path) {
        return PackageLocation(root: tmp, temporaryRoot: tmp)
    }
    // Some zips wrap the package in a single top-level folder.
    let entries = (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
    for entry in entries where fm.fileExists(atPath: entry.appendingPathComponent("show.json").path) {
        return PackageLocation(root: entry, temporaryRoot: tmp)
    }
    try? fm.removeItem(at: tmp)
    throw CLIError.notAPackage(path, "zip contains no show.json")
}

/// Zip a package into a shareable `.bs.zip`, preserving the top-level `.bs`
/// directory so ordinary Finder expansion recreates the editable document.
func zipPackage(_ dir: URL, to out: URL) throws {
    try ditto(["-c", "-k", "--keepParent", dir.path, out.path])
}

func unzipArchive(_ zip: URL, to dir: URL) throws {
    try ditto(["-x", "-k", zip.path, dir.path])
}

private func ditto(_ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    p.arguments = args
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        throw CLIError.notAPackage(args.last ?? "", "ditto failed (status \(p.terminationStatus))")
    }
}
