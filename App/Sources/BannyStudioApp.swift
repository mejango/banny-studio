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
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 860)
        #endif
        .commands {
            CommandGroup(after: .newItem) {
                ImportLegacyCommand()
            }
        }
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

/// File > Import Web Studio JSON… converts a v1 export into a new document.
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
