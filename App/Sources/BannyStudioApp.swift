import SwiftUI
import UniformTypeIdentifiers
import BannyCore
import BannyRender

extension UTType {
    static let bannyShow = UTType(exportedAs: "com.banny.show", conformingTo: .package)
}

@main
struct BannyStudioApp: App {
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
                ImportLegacyCommand()
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

/// File > Import Web Studio JSON… converts a v1 export into a new document.
/// (iOS gets legacy import by opening the JSON via the Files app in a later pass.)
struct ImportLegacyCommand: View {
    @State private var importing = false
    @Environment(\.newDocument) private var newDocument

    var body: some View {
        Button("Import Web Studio JSON…") { importing = true }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url),
                      let imported = try? V1Importer.importStudio(json: data) else { return }
                newDocument { ShowDocumentFile(imported: imported) }
            }
    }
}
#endif
