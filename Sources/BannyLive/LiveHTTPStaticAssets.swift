import Foundation

public struct LiveHTTPStaticAsset: Equatable, Sendable {
    public var data: Data
    public var contentType: String
    public var cacheControl: String

    public init(
        data: Data,
        contentType: String,
        cacheControl: String = "no-cache"
    ) {
        self.data = data
        self.contentType = contentType
        self.cacheControl = cacheControl
    }
}

public protocol LiveHTTPStaticAssetProviding: Sendable {
    /// `path` is normalized, relative, and never begins with a slash.
    func asset(at path: String) async throws -> LiveHTTPStaticAsset?

    /// Whether this provider owns the path even when no asset exists there.
    /// Authoritative namespaces do not fall through to another provider or to
    /// the web client's SPA index.
    func isAuthoritative(for path: String) -> Bool
}

public extension LiveHTTPStaticAssetProviding {
    func isAuthoritative(for path: String) -> Bool { false }
}

public struct LiveHTTPInMemoryStaticAssets: LiveHTTPStaticAssetProviding {
    private let assets: [String: LiveHTTPStaticAsset]

    public init(assets: [String: LiveHTTPStaticAsset]) {
        self.assets = assets
    }

    public func asset(at path: String) async throws -> LiveHTTPStaticAsset? {
        assets[path]
    }
}

/// Exposes another provider below one decoded URL path component. Requests in
/// the mounted namespace are authoritative: a miss stays a miss instead of
/// resolving through a later provider or the SPA fallback.
public struct LiveHTTPMountedStaticAssets: LiveHTTPStaticAssetProviding {
    private let mount: String
    private let assets: any LiveHTTPStaticAssetProviding

    public init(
        mount: String,
        assets: any LiveHTTPStaticAssetProviding
    ) {
        precondition(Self.isSafeMount(mount))
        self.mount = mount
        self.assets = assets
    }

    public func asset(at path: String) async throws -> LiveHTTPStaticAsset? {
        let prefix = mount + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let relativePath = String(path.dropFirst(prefix.count))
        guard !relativePath.isEmpty else { return nil }
        return try await assets.asset(at: relativePath)
    }

    public func isAuthoritative(for path: String) -> Bool {
        path == mount || path.hasPrefix(mount + "/")
    }

    private static func isSafeMount(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.unicodeScalars.contains(where: {
                $0.value == 0 || $0.value < 32 || $0.value == 127
            })
    }
}

/// Resolves assets from several providers while respecting authoritative
/// mounts regardless of provider order.
public struct LiveHTTPCompositeStaticAssets: LiveHTTPStaticAssetProviding {
    private let providers: [any LiveHTTPStaticAssetProviding]

    public init(providers: [any LiveHTTPStaticAssetProviding]) {
        self.providers = providers
    }

    public func asset(at path: String) async throws -> LiveHTTPStaticAsset? {
        if let provider = providers.first(where: {
            $0.isAuthoritative(for: path)
        }) {
            return try await provider.asset(at: path)
        }
        for provider in providers {
            if let asset = try await provider.asset(at: path) {
                return asset
            }
        }
        return nil
    }

    public func isAuthoritative(for path: String) -> Bool {
        providers.contains { $0.isAuthoritative(for: path) }
    }
}

/// The web client packaged in `Sources/BannyLive/Resources/Web`. SwiftPM
/// processes those files into BannyLive's resource bundle.
public struct LiveHTTPBundledWebAssets: LiveHTTPStaticAssetProviding {
    private let directory: LiveHTTPDirectoryStaticAssets?

    public init(maximumAssetBytes: Int = LiveHTTPDirectoryStaticAssets.defaultMaximumAssetBytes) {
        directory = Bundle.module.resourceURL.map {
            LiveHTTPDirectoryStaticAssets(
                rootDirectory: $0,
                maximumAssetBytes: maximumAssetBytes)
        }
    }

    public func asset(at path: String) async throws -> LiveHTTPStaticAsset? {
        try await directory?.asset(at: path)
    }
}

/// Serves a deliberately bounded directory. Symlinks and normalized paths
/// which escape the configured root are rejected.
public struct LiveHTTPDirectoryStaticAssets: LiveHTTPStaticAssetProviding {
    public static let defaultMaximumAssetBytes = 16 * 1_024 * 1_024

    private let rootDirectory: URL
    private let maximumAssetBytes: Int

    public init(
        rootDirectory: URL,
        maximumAssetBytes: Int = Self.defaultMaximumAssetBytes
    ) {
        precondition(rootDirectory.isFileURL)
        precondition(maximumAssetBytes > 0)
        self.rootDirectory = rootDirectory
            .standardizedFileURL.resolvingSymlinksInPath()
        self.maximumAssetBytes = maximumAssetBytes
    }

    public func asset(at path: String) async throws -> LiveHTTPStaticAsset? {
        guard Self.isSafeRelativePath(path) else { return nil }

        let candidate = rootDirectory
            .appendingPathComponent(path, isDirectory: false)
            .standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = rootDirectory.path.hasSuffix("/")
            ? rootDirectory.path : rootDirectory.path + "/"
        guard candidate.path.hasPrefix(rootPath) else { return nil }

        let values: URLResourceValues
        do {
            values = try candidate.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey, .isReadableKey,
            ])
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch CocoaError.fileNoSuchFile {
            return nil
        }
        guard values.isRegularFile == true, values.isReadable != false,
              let size = values.fileSize, size <= maximumAssetBytes
        else { return nil }

        let data = try Data(contentsOf: candidate, options: [.mappedIfSafe])
        guard data.count <= maximumAssetBytes else { return nil }
        return LiveHTTPStaticAsset(
            data: data,
            contentType: Self.contentType(forExtension: candidate.pathExtension),
            cacheControl: path == "index.html"
                ? "no-cache"
                : "public, max-age=3600")
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".")
        }
    }

    public static func contentType(forExtension fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "py": "text/x-python; charset=utf-8"
        case "json", "map": "application/json; charset=utf-8"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        case "gif": "image/gif"
        case "ico": "image/x-icon"
        case "mp3": "audio/mpeg"
        case "mp4", "m4v": "video/mp4"
        case "webm": "video/webm"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        case "txt": "text/plain; charset=utf-8"
        default: "application/octet-stream"
        }
    }
}
