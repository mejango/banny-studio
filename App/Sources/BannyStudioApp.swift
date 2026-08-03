import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif
import BannyCore
import BannyRender

extension UTType {
    static let bannyShow = UTType(exportedAs: "com.banny.show", conformingTo: .package)
}

@main
struct BannyStudioApp: App {
    init() {
        #if os(macOS)
        // Launch straight into a blank project instead of the open panel.
        // (Restored documents still reopen; this only governs a cold launch
        // with nothing to restore.) register() so the user can still override.
        UserDefaults.standard.register(
            defaults: ["NSShowAppCentricOpenPanelInsteadOfUntitledFile": false])
        #endif
    }

    var body: some SwiftUI.Scene {
        DocumentGroup(newDocument: { ShowDocumentFile() }) { config in
            EditorView(file: config.document)
                #if os(macOS)
                .background(SnapshotOnLaunch())
                #else
                .background(DebugDocOpener(file: config.document))
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 860)
        #endif
        #if os(macOS)
        .commands {
            CommandGroup(after: .newItem) {
                ImportProjectCommand()
                Divider()
                AppUpdateCommand()
            }
            CommandGroup(after: .help) {
                Button("Set up CLI & AI Skill…") {
                    NSWorkspace.shared.open(
                        URL(string: "https://github.com/mejango/banny-studio/blob/main/skills/banny-studio/SKILL.md")!)
                }
            }
        }
        #endif
    }
}

#if !os(macOS)
/// Screenshot-harness hook: when BANNY_OPEN_DOC names a .bs path, load
/// its contents into the open (untitled) document — iOS has no programmatic
/// document-open, and UI tests can't drive the system browser reliably.
private struct DebugDocOpener: View {
    let file: ShowDocumentFile

    var body: some View {
        Color.clear.task {
            let docs = FileManager.default.urls(for: .documentDirectory,
                                                in: .userDomainMask)[0]
            let env = ProcessInfo.processInfo.environment["BANNY_OPEN_DOC"]
            guard let p = env, !p.isEmpty else { return }
            try? ("editor open, env=\(p)\n")
                .write(to: docs.appendingPathComponent("debug-editor.log"),
                       atomically: true, encoding: .utf8)
            // A bare name resolves inside our own Documents (the container
            // UUID changes on reinstall, so absolute host paths go stale).
            let root = p.contains("/") ? URL(fileURLWithPath: p)
                                       : docs.appendingPathComponent(p)
            func dlog(_ m: String) {
                let f = docs.appendingPathComponent("debug-open.log")
                let line = m + "\n"
                if let h = try? FileHandle(forWritingTo: f) {
                    h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
                } else { try? line.write(to: f, atomically: true, encoding: .utf8) }
            }
            dlog("hook fired, root=\(root.path), exists=\(FileManager.default.fileExists(atPath: root.path))")
            guard let showData = try? Data(contentsOf: root.appendingPathComponent("show.json")),
                  let doc = try? JSONDecoder().decode(ShowDocument.self, from: showData)
            else { dlog("decode FAILED"); return }
            func media(_ folder: String) -> [String: (data: Data, ext: String)] {
                var out: [String: (data: Data, ext: String)] = [:]
                let dir = root.appendingPathComponent(folder)
                for f in (try? FileManager.default.contentsOfDirectory(
                            at: dir, includingPropertiesForKeys: nil)) ?? [] {
                    guard let d = try? Data(contentsOf: f) else { continue }
                    out[f.deletingPathExtension().lastPathComponent] = (d, f.pathExtension)
                }
                return out
            }
            file.audio = media("audio")
            file.assetsMedia = media("bg").merging(media("assets")) { _, new in new }
            file.model.document = doc
            dlog("applied: \(file.audio.count) audio, \(file.assetsMedia.count) assets")
        }
    }
}
#endif

/// Shared baked-part catalog, loaded once from the app bundle.
enum SharedAssets {
    static let catalog: AssetCatalog = {
        guard let root = Bundle.main.url(forResource: "BannyAssets", withExtension: nil) else {
            fatalError("Baked assets missing from bundle")
        }
        let catalog = try! AssetCatalog(assetsRoot: root)
        for outfit in CustomOutfitStorage.loadAll() {
            _ = catalog.registerCustomOutfit(
                name: outfit.assetName,
                label: outfit.manifest.name,
                slot: outfit.manifest.category.rawValue,
                pngData: outfit.pngData,
                framePNGData: outfit.framePNGData,
                frameDelay: outfit.frameDelay
            )
        }
        return catalog
    }()
}

#if os(macOS)
/// Debug aid: BANNY_SNAPSHOT=/path.png makes the app write a self-capture of its
/// window shortly after launch (no screen-recording permission involved).
struct SnapshotOnLaunch: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        guard UserDefaults.standard.bool(forKey: "debugSnapshot") else { return v }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak v] in
            guard let content = v?.window?.contentView,
                  let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
            content.cacheDisplay(in: content.bounds, to: rep)
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("banny-snap.png")
            try? rep.representation(using: .png, properties: [:])?.write(to: out)
            NSLog("snapshot written to %@", out.path)
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// File > Import Project… accepts canonical packages, `.bs.zip` share archives,
/// legacy `.bannyshow` packages, and old zipped `.bs` files. One-off web→native
/// JSON migration remains available through the CLI.
struct ImportProjectCommand: View {
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        Button("Import Project…") { importing = true }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [.bannyShow, .zip, .data]) { result in
                if case .success(let url) = result {
                    importError = BannyProjectImport.open(url)
                }
            }
            .alert("Import failed", isPresented: .init(get: { importError != nil },
                                                       set: { if !$0 { importError = nil } })) {
                Button("OK") { importError = nil }
            } message: { Text(importError ?? "") }
    }
}

/// Mac App Store apps cannot replace their own signed bundle. This command
/// checks Apple's live listing, then hands the install to the App Store.
struct AppUpdateCommand: View {
    @State private var checking = false
    @State private var result: AppUpdateResult?

    var body: some View {
        Button(checking ? "Checking for Updates…" : "Check for Updates…") {
            checkForUpdates()
        }
        .disabled(checking)
        .accessibilityIdentifier("check-for-updates")
        .alert(
            result?.title ?? "Software Update",
            isPresented: Binding(
                get: { result != nil },
                set: { if !$0 { result = nil } }
            )
        ) {
            if let updateURL = result?.updateURL {
                Button("Update in App Store") {
                    NSWorkspace.shared.open(updateURL)
                    result = nil
                }
            }
            Button("OK", role: .cancel) { result = nil }
        } message: {
            Text(result?.message ?? "")
        }
    }

    private func checkForUpdates() {
        checking = true
        Task {
            defer { checking = false }
            do {
                let listing = try await AppStoreUpdateService.latestListing()
                let current = AppStoreUpdateService.installedVersion
                if AppStoreUpdateService.isNewer(listing.version, than: current) {
                    result = AppUpdateResult(
                        title: "Banny Studio \(listing.version) Is Available",
                        message: "You’re using version \(current). The App Store can install the latest version now.",
                        updateURL: AppStoreUpdateService.updateURL
                    )
                } else {
                    result = AppUpdateResult(
                        title: "Banny Studio Is Up to Date",
                        message: "Version \(current) is the latest available version.",
                        updateURL: nil
                    )
                }
            } catch {
                result = AppUpdateResult(
                    title: "Couldn’t Check for Updates",
                    message: "Check your internet connection and try again.\n\n\(error.localizedDescription)",
                    updateURL: nil
                )
            }
        }
    }
}

private struct AppUpdateResult {
    let title: String
    let message: String
    let updateURL: URL?
}

enum AppStoreUpdateService {
    static let appID = "6788916305"
    static let bundleID = "com.banny.BannyStudio"

    static var installedVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "Unknown"
    }

    static var updateURL: URL {
        URL(string: "macappstore://itunes.apple.com/app/id\(appID)")!
    }

    static func latestListing() async throws -> Listing {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        var items = [URLQueryItem(name: "bundleId", value: bundleID)]
        if let country = Locale.current.region?.identifier.lowercased() {
            items.append(URLQueryItem(name: "country", value: country))
        }
        components.queryItems = items

        guard let url = components.url else { throw UpdateError.invalidURL }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode) else {
            throw UpdateError.badResponse
        }
        let lookup = try JSONDecoder().decode(LookupResponse.self, from: data)
        guard let listing = lookup.results.first else {
            throw UpdateError.appNotFound
        }
        return listing
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        candidate.compare(installed, options: .numeric) == .orderedDescending
    }

    struct Listing: Decodable {
        let version: String
    }

    private struct LookupResponse: Decodable {
        let results: [Listing]
    }

    private enum UpdateError: LocalizedError {
        case invalidURL
        case badResponse
        case appNotFound

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "The update service URL is invalid."
            case .badResponse: return "Apple’s update service didn’t respond."
            case .appNotFound: return "Banny Studio wasn’t found in the App Store."
            }
        }
    }
}

/// Copies or expands an imported project into a private canonical `.bs`
/// package, opens it, then asks where to save the converted editable document.
/// Working from a private copy also prevents a generator or file watcher from
/// racing Studio's autosave.
enum BannyProjectImport {
    static func open(_ url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("banny-import-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let pkg = dir.appendingPathComponent(canonicalPackageName(for: url),
                                                isDirectory: true)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory)
            guard exists else {
                return "That project no longer exists."
            }
            if isDirectory.boolValue {
                try FileManager.default.copyItem(at: url, to: pkg)
            } else {
                let extracted = dir.appendingPathComponent("expanded", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: extracted, withIntermediateDirectories: true)
                let ditto = Process()
                ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                ditto.arguments = ["-x", "-k", url.path, extracted.path]
                try ditto.run()
                ditto.waitUntilExit()
                guard ditto.terminationStatus == 0 else {
                    return "That file doesn't look like a Banny Studio project."
                }
                guard let source = packageRoot(in: extracted) else {
                    return "That archive contains no Banny Studio project."
                }
                try FileManager.default.copyItem(at: source, to: pkg)
            }
            guard FileManager.default.fileExists(
                atPath: pkg.appendingPathComponent("show.json").path) else {
                return "That file doesn't look like a Banny Studio project."
            }
            NSDocumentController.shared.openDocument(
                withContentsOf: pkg, display: true
            ) { document, _, error in
                if let error {
                    NSApp.presentError(error)
                } else if let document {
                    // Imported projects live in a private temporary location.
                    // Save As makes the canonical `.bs` destination explicit.
                    DispatchQueue.main.async { document.saveAs(nil) }
                }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func canonicalPackageName(for url: URL) -> String {
        let name = url.lastPathComponent
        let withoutZip = name.lowercased().hasSuffix(".zip")
            ? (name as NSString).deletingPathExtension
            : name
        if withoutZip.lowercased().hasSuffix(".bs") { return withoutZip }
        return ((withoutZip as NSString).deletingPathExtension) + ".bs"
    }

    private static func packageRoot(in directory: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(
            atPath: directory.appendingPathComponent("show.json").path) {
            return directory
        }
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return nil }
        var roots: [URL] = []
        for case let candidate as URL in enumerator
        where candidate.lastPathComponent == "show.json" {
            roots.append(candidate.deletingLastPathComponent())
        }
        guard roots.count == 1 else { return nil }
        return roots[0]
    }
}
#endif
