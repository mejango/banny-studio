import SwiftUI
import UniformTypeIdentifiers
import BannyCore
import BannyRender

extension UTType {
    static let bannyShow = UTType(exportedAs: "com.banny.show", conformingTo: .package)
    /// The shareable single-file project: a zip of the .bannyshow package.
    static let bannyShowArchive = UTType(exportedAs: "com.banny.show-archive", conformingTo: .zip)
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
            }
        }
        #endif
    }
}

#if !os(macOS)
/// Screenshot-harness hook: when BANNY_OPEN_DOC names a .bannyshow path, load
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
        return try! AssetCatalog(assetsRoot: root)
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

/// File > Import Project (.bs)… — the single import path. Shared projects are
/// always .bs files (a zipped .bannyshow); the legacy web-studio JSON import
/// was removed (it confused the workflow and only ever accepted one exact
/// format). One-off web→native migration still lives in `banny-tool import`.
struct ImportProjectCommand: View {
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        Button("Import Project (.bs)…") { importing = true }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [UTType(filenameExtension: "bs") ?? .data,
                                                .zip, .data]) { result in
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

/// Unpacks a .bs archive into a temp .bannyshow package and opens it as a
/// document. Returns an error message on failure, nil on success.
enum BannyProjectImport {
    static func open(_ url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("banny-import-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let pkg = dir.appendingPathComponent(
                url.deletingPathExtension().lastPathComponent + ".bannyshow")
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", url.path, pkg.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0,
                  FileManager.default.fileExists(
                    atPath: pkg.appendingPathComponent("show.json").path) else {
                return "That file doesn't look like a Banny Studio project."
            }
            NSDocumentController.shared.openDocument(withContentsOf: pkg, display: true) { _, _, _ in }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
#endif
