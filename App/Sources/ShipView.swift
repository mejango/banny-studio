import SwiftUI
import BannyCore
import BannyMedia

private final class ExportCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        let result = value
        lock.unlock()
        return result
    }
}

/// Ship: export the show playlist (or active scene) to an mp4 and hand it to the
/// system share sheet / save panel.
struct ShipButton: View {
    private struct ExportRequest {
        let destination: URL
        let options: ShowExporter.Options
    }

    @Bindable var model: StudioModel
    let file: ShowDocumentFile
    /// Timeline-corner style: small plain label on the Export row.
    var compact = false

    @State private var shipping = false
    @State private var progress: Double = 0
    @State private var exportError: String?
    @State private var cancellationToken: ExportCancellationToken?
    @State private var exportTask: Task<Void, Never>?
    @State private var retryRequest: ExportRequest?

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Menu("Export video (mp4)") {
                    let dur = exportSeconds
                    Button("Small · 480p\(sizeHint(.p480, dur))") { exportVideo(.p480) }
                    Button("Medium · 720p\(sizeHint(.p720, dur))") { exportVideo(.p720) }
                    Button("Large · 1080p\(sizeHint(.p1080, dur))") { exportVideo(.p1080) }
                    Button("Max · 4K\(sizeHint(.p2160, dur))") { exportVideo(.p2160) }
                }
                Button("Export project (.bs)…") {
                    askSaveURL(suggested: "SHOW.bs") { dest in
                        if let dest { exportProject(to: dest) }
                    }
                }
            } label: {
                Text(shipping ? "Exporting… \(Int(progress * 100))%" : "Export")
                    .font(.system(size: compact ? 10 : 12, weight: compact ? .semibold : .bold))
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, compact ? 7 : 10).padding(.vertical, compact ? 1 : 3)
                    .background(Color.primary.opacity(0.09), in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.3), lineWidth: 1))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(shipping)
            .help("Export media (the marked range, or the whole show if none is marked) or a shareable project file.")
            if shipping {
                Button {
                    cancellationToken?.cancel()
                    exportTask?.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel export")
                .accessibilityLabel("Cancel export")
            }
        }
        .alert("Export failed", isPresented: .init(get: { exportError != nil },
                                                   set: { if !$0 { exportError = nil } })) {
            if let request = retryRequest {
                Button("Retry") {
                    exportError = nil
                    ship(to: request.destination, tier: request.options)
                }
            }
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    /// Asks for the destination BEFORE doing any work — as a window sheet, so
    /// it can't be missed (a floating end-of-render panel could open unnoticed
    /// behind the app, stranding finished exports in temp).
    @MainActor
    private func askSaveURL(suggested: String, completion: @escaping (URL?) -> Void) {
        #if os(macOS)
        let panel = NSSavePanel()
        let project = NSDocumentController.shared.currentDocument?.displayName
        let base = (project as NSString?)?.deletingPathExtension ?? "banny-show"
        panel.nameFieldStringValue = suggested.replacingOccurrences(of: "SHOW", with: base)
        if let win = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: win) { r in
                completion(r == .OK ? panel.url : nil)
            }
        } else {
            panel.begin { r in completion(r == .OK ? panel.url : nil) }
        }
        #else
        completion(nil)
        #endif
    }

    @MainActor
    private func deliver(_ tmp: URL, to dest: URL) {
        #if os(macOS)
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: tmp, to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            exportError = error.localizedDescription
        }
        #endif
    }

    /// Packages the whole document as a single shareable .bs file (a zip of
    /// the .bannyshow package) that any Banny Studio can import.
    private func exportProject(to dest: URL) {
        #if os(macOS)
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
            deliver(out, to: dest)
        } catch {
            exportError = String(describing: error)
        }
        #endif
    }

    private func exportVideo(_ tier: ShowExporter.Options) {
        askSaveURL(suggested: "SHOW.mp4") { dest in
            if let dest { ship(to: dest, tier: tier) }
        }
    }

    /// Length of what will be exported (the marked range, else the whole show).
    private var exportSeconds: Double {
        model.exportRange.map { $0.to - $0.from } ?? max(1, model.scene.contentEnd + 0.5)
    }

    /// Rough output size " · ~12 MB" for a tier at the export length.
    private func sizeHint(_ tier: ShowExporter.Options, _ seconds: Double) -> String {
        let bytes = Double(tier.videoBitrate + 128_000) * seconds / 8
        let mb = bytes / 1_000_000
        return mb >= 1 ? String(format: "  ·  ~%.0f MB", mb) : String(format: "  ·  ~%.1f MB", mb)
    }

    private func ship(to dest: URL, tier: ShowExporter.Options = .p1080) {
        let missingAudio = model.scene.characters.flatMap(\.clips)
            .map(\.id) + model.scene.audioTracks.flatMap(\.clips).map(\.id)
        let unresolvedAudio = Set(missingAudio).filter { file.audio[$0] == nil }
        let referencedAssets = Set(
            model.scene.backgroundTracks.flatMap(\.cues).map(\.assetID)
            + model.scene.imageTracks.flatMap(\.cues).map(\.assetID)
            + model.scene.audioTracks.flatMap(\.cues).map(\.assetID))
        let unresolvedAssets = referencedAssets.filter { file.assetsMedia[$0] == nil }
        guard unresolvedAudio.isEmpty, unresolvedAssets.isEmpty else {
            let count = unresolvedAudio.count + unresolvedAssets.count
            exportError = "\(count) linked media \(count == 1 ? "file is" : "files are") missing. Open Browse → Media and relink before exporting."
            retryRequest = nil
            return
        }

        let blocking = ShowExportPreflight.errors(
            document: model.document,
            availableAudioIDs: Set(file.audio.keys),
            availableAssetIDs: Set(file.assetsMedia.keys),
            catalog: SharedAssets.catalog)
        guard blocking.isEmpty else {
            let visible = blocking.prefix(4).map { "• \($0)" }
            let remainder = blocking.count - visible.count
            let suffix = remainder > 0 ? "\n…and \(remainder) more." : ""
            exportError = "This show needs attention before export:\n\(visible.joined(separator: "\n"))\(suffix)"
            retryRequest = nil
            return
        }

        model.pause()
        shipping = true
        progress = 0
        exportError = nil
        let document = model.document
        let audio = file.audio
        let assetsMedia = file.assetsMedia
        let options = tier.fitted(aspect: document.settings.frameAspect)
        let token = ExportCancellationToken()
        cancellationToken = token
        retryRequest = nil

        exportTask = Task.detached(priority: .userInitiated) {
            // Media to temp files for AVFoundation.
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("banny-ship-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
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
                    options: options,
                    to: out,
                    progress: { p in
                        Task { @MainActor in progress = p }
                    },
                    shouldCancel: { token.isCancelled })
                await MainActor.run {
                    shipping = false
                    cancellationToken = nil
                    exportTask = nil
                    retryRequest = nil
                    deliver(out, to: dest)
                }
            } catch ShowExporter.ExportError.cancelled {
                await MainActor.run {
                    shipping = false
                    progress = 0
                    cancellationToken = nil
                    exportTask = nil
                    retryRequest = nil
                }
            } catch {
                await MainActor.run {
                    shipping = false
                    cancellationToken = nil
                    exportTask = nil
                    retryRequest = ExportRequest(destination: dest, options: tier)
                    exportError = error.localizedDescription
                }
            }
        }
    }
}
