import Foundation
import BannyCore

/// Reads a project from an unpacked `.bannyshow` directory or a zipped `.bs`
/// archive (the app's shareable format). Zips are extracted to a temp folder.
func readPackage(at path: String) throws -> ShowPackage.Contents {
    try ShowPackage.read(from: packageRoot(at: path))
}

/// The directory containing show.json for a path that may be a package
/// directory or a `.bs` zip.
func packageRoot(at path: String) throws -> URL {
    let fm = FileManager.default
    let url = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
        throw CLIError.notAPackage(path, "no such file")
    }
    if isDir.boolValue { return url }

    let fh = try FileHandle(forReadingFrom: url)
    let magic = try fh.read(upToCount: 2)
    try fh.close()
    guard magic == Data([0x50, 0x4B]) else {  // "PK"
        throw CLIError.notAPackage(path, "not a package directory or .bs zip")
    }
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("banny-unpack-\(UUID().uuidString)", isDirectory: true)
    try unzipArchive(url, to: tmp)
    if fm.fileExists(atPath: tmp.appendingPathComponent("show.json").path) {
        return tmp
    }
    // Some zips wrap the package in a single top-level folder.
    let entries = (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
    for entry in entries where fm.fileExists(atPath: entry.appendingPathComponent("show.json").path) {
        return entry
    }
    throw CLIError.notAPackage(path, "zip contains no show.json")
}

/// Zip a package directory into a shareable `.bs` (same format the app's
/// File > Export Project writes: package contents at the zip root).
func zipPackage(_ dir: URL, to out: URL) throws {
    try ditto(["-c", "-k", dir.path, out.path])
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
