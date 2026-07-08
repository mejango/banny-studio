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
