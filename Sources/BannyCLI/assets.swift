import Foundation

// Shared CLI engine; the executable target is intentionally a tiny entry point.

enum CLIError: Error, CustomStringConvertible {
    case assetsNotFound
    case usage(String)
    case notAPackage(String, String)
    case invalid(String)
    case validationFailed([String])

    var description: String {
        switch self {
        case .assetsNotFound:
            return """
            Banny assets not found. Install Banny Studio from the App Store, or set
            BANNY_ASSETS to a folder containing catalog.json + png/.
            """
        case .usage(let u): return "usage: \(u)"
        case .notAPackage(let path, let why):
            return "cannot read \(path): \(why)"
        case .invalid(let message):
            return message
        case .validationFailed(let messages):
            return (["validation failed:"] + messages.map { "  - \($0)" })
                .joined(separator: "\n")
        }
    }
}

private struct CLIErrorEnvelope: Codable {
    struct Payload: Codable {
        let code: String
        let message: String
        let usage: String?
        let details: [String]?
    }

    let ok: Bool
    let error: Payload
}

/// Stable machine-readable failure output for every command that accepts
/// `--json`. Errors always go to stderr so stdout remains safe to parse.
public func writeCLIError(_ error: Error, json: Bool) {
    guard json else {
        FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
        return
    }
    let payload: CLIErrorEnvelope.Payload
    switch error {
    case CLIError.assetsNotFound:
        payload = .init(code: "assets_not_found", message: String(describing: error),
                        usage: nil, details: nil)
    case CLIError.usage(let usage):
        payload = .init(code: "usage", message: "invalid command usage",
                        usage: usage, details: nil)
    case CLIError.notAPackage(let path, let why):
        payload = .init(code: "not_a_package", message: "cannot read \(path): \(why)",
                        usage: nil, details: nil)
    case CLIError.invalid(let message):
        payload = .init(code: "invalid_argument", message: message,
                        usage: nil, details: nil)
    case CLIError.validationFailed(let details):
        payload = .init(code: "validation_failed", message: "validation failed",
                        usage: nil, details: details)
    default:
        payload = .init(code: "operation_failed", message: String(describing: error),
                        usage: nil, details: nil)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(CLIErrorEnvelope(ok: false, error: payload)))
        ?? Data(#"{"error":{"code":"encoding_failed","message":"could not encode error"},"ok":false}"#.utf8)
    FileHandle.standardError.write(data + Data("\n".utf8))
}

public func cliExitCode(for error: Error) -> Int32 {
    switch error {
    case CLIError.usage, CLIError.invalid: return 2
    case CLIError.validationFailed: return 3
    case CLIError.notAPackage: return 4
    default: return 1
    }
}

/// $BANNY_ASSETS → packaged sibling → installed app bundle → repo checkout (dev).
///
/// A standalone CLI distribution places `BannyAssets` beside the real
/// executable. Resolve symlinks before deriving that path so an installation
/// exposed through `/usr/local/bin/banny` still finds the immutable assets in
/// its versioned release directory.
func locateAssetsRoot(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    executableURL: URL? = Bundle.main.executableURL
) throws -> URL {
    let fm = FileManager.default
    var candidates: [URL] = []
    if let env = environment["BANNY_ASSETS"], !env.isEmpty {
        candidates.append(URL(fileURLWithPath: env))
    }
    if let executableURL {
        candidates.append(executableURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("BannyAssets", isDirectory: true))
    }
    for app in ["/Applications/Banny Studio.app", "/Applications/BannyStudio.app"] {
        candidates.append(URL(fileURLWithPath: app).appendingPathComponent("Contents/Resources/BannyAssets"))
    }
    candidates.append(URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/BannyAssets"))
    for url in candidates {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let catalog = resolved.appendingPathComponent("catalog.json", isDirectory: false)
        let png = resolved.appendingPathComponent("png", isDirectory: true)
        var catalogIsDirectory: ObjCBool = false
        var pngIsDirectory: ObjCBool = false
        guard fm.fileExists(atPath: catalog.path, isDirectory: &catalogIsDirectory),
              !catalogIsDirectory.boolValue,
              fm.fileExists(atPath: png.path, isDirectory: &pngIsDirectory),
              pngIsDirectory.boolValue
        else { continue }
        return resolved
    }
    throw CLIError.assetsNotFound
}
