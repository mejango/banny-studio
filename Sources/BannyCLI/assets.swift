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

/// $BANNY_ASSETS → installed app bundle → repo checkout (dev).
func locateAssetsRoot() throws -> URL {
    let fm = FileManager.default
    var candidates: [URL] = []
    if let env = ProcessInfo.processInfo.environment["BANNY_ASSETS"] {
        candidates.append(URL(fileURLWithPath: env))
    }
    for app in ["/Applications/Banny Studio.app", "/Applications/BannyStudio.app"] {
        candidates.append(URL(fileURLWithPath: app).appendingPathComponent("Contents/Resources/BannyAssets"))
    }
    candidates.append(URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/BannyAssets"))
    for url in candidates where fm.fileExists(atPath: url.appendingPathComponent("catalog.json").path) {
        return url
    }
    throw CLIError.assetsNotFound
}
