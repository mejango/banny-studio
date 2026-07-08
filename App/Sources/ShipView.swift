import SwiftUI
import BannyCore
import BannyMedia

/// Ship: export the show playlist (or active scene) to an mp4 and hand it to the
/// system share sheet / save panel.
struct ShipButton: View {
    @Bindable var model: StudioModel
    let file: ShowDocumentFile

    @State private var shipping = false
    @State private var progress: Double = 0
    @State private var exportedURL: URL?
    @State private var exportError: String?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                ship()
            } label: {
                Text(shipping ? "Shipping… \(Int(progress * 100))%" : "🚀 Ship")
                    .font(.system(size: 12, weight: .bold))
            }
            .disabled(shipping)
            .keyboardShortcut("e", modifiers: .command)
            .help("Render the show to an mp4 (⌘E)")
        }
        .alert("Export failed", isPresented: .init(get: { exportError != nil },
                                                   set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        #if os(macOS)
        .fileExporter(isPresented: .init(get: { exportedURL != nil },
                                         set: { if !$0 { exportedURL = nil } }),
                      item: exportedURL.map(ShippedVideo.init),
                      defaultFilename: "banny-show.mp4") { _ in exportedURL = nil }
        #endif
    }

    private func ship() {
        model.pause()
        shipping = true
        progress = 0
        let document = model.document
        let activeScene = model.activeSceneIndex
        let audio = file.audio
        let backgrounds = file.backgrounds

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
            var bgURLs: [String: URL] = [:]
            for (id, m) in backgrounds {
                let url = dir.appendingPathComponent("bg-\(id).\(m.ext)")
                try? m.data.write(to: url)
                bgURLs[id] = url
            }
            let out = dir.appendingPathComponent("banny-show.mp4")
            do {
                try ShowExporter.export(
                    document: document, activeScene: activeScene,
                    assets: SharedAssets.catalog,
                    audioURL: { audioURLs[$0] },
                    backgroundURL: { bgURLs[$0] },
                    options: .p1080,
                    to: out,
                    progress: { p in
                        Task { @MainActor in progress = p }
                    })
                await MainActor.run {
                    shipping = false
                    exportedURL = out
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

/// Transferable wrapper so the exported mp4 flows into fileExporter/share sheets.
struct ShippedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .mpeg4Movie) { video in
            SentTransferredFile(video.url)
        }
    }
}
