import SwiftUI
import UniformTypeIdentifiers

/// Header project dropdown: rename the current project, spin up a new one,
/// or import a shared .bs archive (zipped .bannyshow package).
struct ProjectMenu: View {
    @Bindable var model: StudioModel
    let file: ShowDocumentFile
    @AppStorage("studioLightMode") private var lightMode = false
    @State private var projectName = ""
    @State private var importing = false
    @State private var importError: String?
    @State private var checkpointName = ""
    @State private var namingCheckpoint = false
    @State private var pendingRestore: ShowCheckpoint?
    @State private var checkpointRevision = 0

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
            Divider()
            Menu("Checkpoints") {
                Button("Create checkpoint…") {
                    checkpointName = defaultCheckpointName
                    namingCheckpoint = true
                }
                if !checkpoints.isEmpty { Divider() }
                ForEach(checkpoints) { checkpoint in
                    Menu {
                        Button("Restore") { pendingRestore = checkpoint }
                            .disabled(file.isMicRecording)
                        Button("Delete", role: .destructive) {
                            file.deleteCheckpoint(id: checkpoint.id)
                            checkpointRevision += 1
                        }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(checkpoint.name)
                            Text(checkpoint.createdAt.formatted(
                                date: .abbreviated, time: .shortened))
                        }
                    }
                }
                if checkpoints.isEmpty {
                    Text("No checkpoints yet")
                }
            }
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
        .help("Rename, create, import, or recover this project")
        .alert("Import failed", isPresented: .init(get: { importError != nil },
                                                   set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert("Create Checkpoint", isPresented: $namingCheckpoint) {
            TextField("Checkpoint name", text: $checkpointName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                file.createCheckpoint(name: checkpointName)
                checkpointRevision += 1
            }
        } message: {
            Text("Saves the current edit state inside this project.")
        }
        .confirmationDialog("Restore \(pendingRestore?.name ?? "checkpoint")?",
                            isPresented: Binding(
                                get: { pendingRestore != nil },
                                set: { if !$0 { pendingRestore = nil } }),
                            titleVisibility: .visible) {
            Button("Restore") {
                if let checkpoint = pendingRestore {
                    model.restoreCheckpoint(checkpoint)
                }
                pendingRestore = nil
            }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("The current state remains available through Undo.")
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

    private var checkpoints: [ShowCheckpoint] {
        _ = checkpointRevision
        return file.checkpoints.sorted { $0.createdAt > $1.createdAt }
    }

    private var defaultCheckpointName: String {
        "Checkpoint \(file.checkpoints.count + 1)"
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
