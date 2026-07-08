import SwiftUI
import UniformTypeIdentifiers

/// Header project dropdown: rename the current project, spin up a new one,
/// or import a shared .bs archive (zipped .bannyshow package).
struct ProjectMenu: View {
    @State private var renaming = false
    @State private var newName = ""
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        Menu {
            Button("Rename project…") {
                #if os(macOS)
                newName = NSDocumentController.shared.currentDocument?
                    .displayName ?? ""
                #endif
                renaming = true
            }
            Button("New project") {
                #if os(macOS)
                NSDocumentController.shared.newDocument(nil)
                #endif
            }
            Divider()
            Button("Import .bs file…") { importing = true }
        } label: {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.6))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        #if os(macOS)
        .focusEffectDisabled()
        #endif
        .help("Rename, create, or import a project")
        .alert("Rename project", isPresented: $renaming) {
            TextField("Project name", text: $newName)
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Renames the project file on disk.")
        }
        .alert("Import failed", isPresented: .init(get: { importError != nil },
                                                   set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: "bs") ?? .data,
                                            .zip, .data]) { result in
            if case .success(let url) = result { importBS(url) }
        }
    }

    private func rename() {
        #if os(macOS)
        guard let doc = NSDocumentController.shared.currentDocument else { return }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard let current = doc.fileURL else {
            // Never saved: a rename is just the first save.
            NSApp.sendAction(#selector(NSDocument.save(_:)), to: doc, from: nil)
            return
        }
        let dest = current.deletingLastPathComponent()
            .appendingPathComponent(name)
            .appendingPathExtension(current.pathExtension)
        guard dest != current else { return }
        doc.move(to: dest) { error in
            if let error { importError = error.localizedDescription }
        }
        #endif
    }

    /// Unpacks the archive into a fresh .bannyshow package in temp and opens
    /// it as a normal document; the user saves it wherever they like.
    private func importBS(_ url: URL) {
        #if os(macOS)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("banny-import-\(UUID().uuidString)",
                                        isDirectory: true)
            try FileManager.default.createDirectory(at: dir,
                                                    withIntermediateDirectories: true)
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
                importError = "That file doesn't look like a Banny Studio project."
                return
            }
            NSDocumentController.shared.openDocument(withContentsOf: pkg,
                                                     display: true) { _, _, error in
                if let error { importError = error.localizedDescription }
            }
        } catch {
            importError = error.localizedDescription
        }
        #endif
    }
}
