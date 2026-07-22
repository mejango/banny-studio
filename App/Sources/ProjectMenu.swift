import SwiftUI
import UniformTypeIdentifiers

/// Header project dropdown: rename the current project, spin up a new one,
/// or import a shared .bs archive (zipped .bannyshow package).
struct ProjectMenu: View {
    @AppStorage("studioLightMode") private var lightMode = false
    @State private var projectName = ""
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        Menu {
            Button("Rename project…") { rename() }
            Button("New project") {
                #if os(macOS)
                NSDocumentController.shared.newDocument(nil)
                #endif
            }
            Divider()
            Button("Import .bs file…") { importing = true }
        } label: {
            HStack(spacing: 4) {
                Text(projectName.isEmpty ? "Untitled" : projectName)
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(lightMode ? Color.black : Color(red: 0.92, green: 0.92, blue: 0.92))
        }
        .onHover { if $0 { refreshName() } }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onAppear { refreshName() }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification)) { _ in refreshName() }
        #endif
        .help("Rename, create, or import a project")
        .alert("Import failed", isPresented: .init(get: { importError != nil },
                                                   set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        #if os(macOS)
        .focusEffectDisabled()
        #endif
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: "bs") ?? .data,
                                            .zip, .data]) { result in
            if case .success(let url) = result { importBS(url) }
        }
    }

    private func refreshName() {
        #if os(macOS)
        if let n = NSDocumentController.shared.currentDocument?.displayName {
            projectName = (n as NSString).deletingPathExtension
        }
        #endif
    }

    /// The system titlebar rename: inline, and the ONLY sandbox-legal way to
    /// rename in place — the app has access to the document file, not to
    /// creating a sibling name in its folder; the powerbox handles this one.
    private func rename() {
        #if os(macOS)
        guard let doc = NSDocumentController.shared.currentDocument else { return }
        guard doc.fileURL != nil else {
            // Never saved: a rename is just the first save.
            NSApp.sendAction(#selector(NSDocument.save(_:)), to: doc, from: nil)
            return
        }
        NSApp.sendAction(#selector(NSDocument.rename(_:)), to: doc, from: nil)
        #endif
    }

    /// Unpacks the archive into a fresh .bannyshow package in temp and opens
    /// it as a normal document; the user saves it wherever they like.
    private func importBS(_ url: URL) {
        #if os(macOS)
        importError = BannyProjectImport.open(url)
        #endif
    }
}
