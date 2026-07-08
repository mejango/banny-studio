import SwiftUI
import BannyCore
import BannyMedia

/// Ship: export the show playlist (or active scene) to an mp4 and hand it to the
/// system share sheet / save panel.
struct ShipButton: View {
    @Bindable var model: StudioModel
    let file: ShowDocumentFile
    /// Timeline-corner style: small plain label on the Export row.
    var compact = false

    @State private var shipping = false
    @State private var progress: Double = 0
    @State private var exportError: String?

    var body: some View {
        HStack(spacing: 8) {
            let hasRange = model.exportRange != nil
            Menu {
                Button("Export media (mp4)…") { ship() }
                    .disabled(compact && !hasRange)
                Button("Export project (.bs)…") { exportProject() }
            } label: {
                Text(shipping ? "Exporting… \(Int(progress * 100))%" : "Export")
                    .font(.system(size: compact ? 10 : 12, weight: compact ? .semibold : .bold))
                    .foregroundStyle(compact && !hasRange ? Color.secondary.opacity(0.55) : Color.primary)
                    .padding(.horizontal, compact ? 7 : 10).padding(.vertical, compact ? 1 : 3)
                    .background(Color.primary.opacity(compact && !hasRange ? 0.04 : 0.09), in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(compact && !hasRange ? 0.1 : 0.3),
                                              lineWidth: 1))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(shipping)
            .help(compact
                  ? "Media exports the marked range (drag on this row to set it); .bs shares the whole project."
                  : "Export media or a shareable project file.")
        }
        .alert("Export failed", isPresented: .init(get: { exportError != nil },
                                                   set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    /// Save panel + reveal in Finder. Two stacked .fileExporter modifiers on
    /// one view silently break each other, so exports go through NSSavePanel.
    @MainActor
    private func saveExport(_ url: URL, suggested: String) {
        #if os(macOS)
        let panel = NSSavePanel()
        let project = NSDocumentController.shared.currentDocument?.displayName
        let base = (project as NSString?)?.deletingPathExtension ?? "banny-show"
        panel.nameFieldStringValue = suggested.replacingOccurrences(of: "SHOW", with: base)
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: url, to: dest)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            } catch {
                exportError = error.localizedDescription
            }
        }
        #endif
    }

    /// Packages the whole document as a single shareable .bs file (a zip of
    /// the .bannyshow package) that any Banny Studio can import.
    private func exportProject() {
        do {
            let wrapper = try file.projectFileWrapper()
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("banny-bs-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let pkg = dir.appendingPathComponent("show.bannyshow")
            try wrapper.write(to: pkg, options: .atomic, originalContentsURL: nil)
            let out = dir.appendingPathComponent("show.bs")
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-c", "-k", pkg.path, out.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else {
                exportError = "Could not package the project."
                return
            }
            saveExport(out, suggested: "SHOW.bs")
        } catch {
            exportError = String(describing: error)
        }
    }

    private func ship() {
        model.pause()
        shipping = true
        progress = 0
        let document = model.document
        let audio = file.audio
        let assetsMedia = file.assetsMedia

        Task.detached(priority: .userInitiated) {
            // Media to temp files for AVFoundation.
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("banny-ship-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var audioURLs: [String: URL] = [:]
            for (id, m) in audio {
                let url = dir.appendingPathComponent("a-\(id).\(m.ext)")
                try? m.data.write(to: url)
                audioURLs[id] = url
            }
            var assetURLs: [String: URL] = [:]
            for (id, m) in assetsMedia {
                let url = dir.appendingPathComponent("asset-\(id).\(m.ext)")
                try? m.data.write(to: url)
                assetURLs[id] = url
            }
            let out = dir.appendingPathComponent("banny-show.mp4")
            do {
                try ShowExporter.export(
                    document: document,
                    assets: SharedAssets.catalog,
                    audioURL: { audioURLs[$0] },
                    assetURL: { assetURLs[$0] },
                    options: .p1080,
                    to: out,
                    progress: { p in
                        Task { @MainActor in progress = p }
                    })
                await MainActor.run {
                    shipping = false
                    saveExport(out, suggested: "SHOW.mp4")
                }
            } catch {
                await MainActor.run {
                    shipping = false
                    exportError = String(describing: error)
                }
            }
        }
    }
}

