import SwiftUI
import UniformTypeIdentifiers
import BannyCore

/// The .bannyshow package as a SwiftUI reference document:
/// show.json + audio/<clipId>.<ext> + bg/<sceneId>.<ext> (+ thumbnail.png).
/// Pulses every time the document writes to disk (drives the header badge).
@Observable
final class SaveIndicator {
    private(set) var count = 0
    func pulse() { count += 1 }
}

/// A lightweight, named recovery point stored beside show.json. Media remains
/// embedded once per project; edit deletion intentionally retains those bytes,
/// so restoring a checkpoint can recover clips without ballooning the package.
struct ShowCheckpoint: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    let createdAt: Date
    let document: ShowDocument
    let time: Double
}

final class ShowDocumentFile: ReferenceFileDocument {
    struct PackageSnapshot {
        let document: ShowDocument
        let audio: [String: (data: Data, ext: String)]
        let assetsMedia: [String: (data: Data, ext: String)]
        let checkpoints: [ShowCheckpoint]
    }

    let saveIndicator = SaveIndicator()
    typealias Snapshot = PackageSnapshot

    static let readableContentTypes: [UTType] = [.bannyShow, .bannyShowArchive]

    /// The document as read from disk; the live model is created lazily on main.
    private let initialDocument: ShowDocument

    /// `ReferenceFileDocument` may request a snapshot from a background queue.
    /// Keep a value-only copy here so saving never reaches into the main-actor
    /// editor model. The same lock protects the media bundled with that copy.
    private let snapshotLock = NSLock()
    private var packageSnapshot: PackageSnapshot

    /// Media bytes carried alongside the document JSON. Keyed by clip/scene id.
    var audio: [String: (data: Data, ext: String)] {
        didSet { updateMediaSnapshot() }
    }
    var assetsMedia: [String: (data: Data, ext: String)] {
        didSet { updateMediaSnapshot() }
    }
    private(set) var checkpoints: [ShowCheckpoint] {
        didSet { updateCheckpointSnapshot() }
    }

    @MainActor private var _model: StudioModel?
    @MainActor private var _audioEngine: LiveAudioEngine?
    @MainActor private var _micRecorder: MicRecorder?

    @MainActor var audioEngine: LiveAudioEngine? {
        if let e = _audioEngine { return e }
        let e = LiveAudioEngine(file: self)
        _audioEngine = e
        return e
    }

    /// One recorder per open project so closing/reopening an inspector cannot
    /// orphan an in-progress take.
    @MainActor var micRecorder: MicRecorder {
        if let recorder = _micRecorder { return recorder }
        let recorder = MicRecorder()
        _micRecorder = recorder
        return recorder
    }

    @MainActor var isMicRecording: Bool {
        _micRecorder?.isRecording == true
    }

    /// Live editor state — main-actor, created on first access.
    @MainActor var model: StudioModel {
        if let m = _model { return m }
        let m = StudioModel(document: initialDocument)
        m.file = self
        _model = m
        return m
    }

    init() {
        var doc = ShowDocument()
        doc.stage = Self.defaultSceneState()
        self.initialDocument = doc
        self.audio = [:]
        self.assetsMedia = [:]
        self.checkpoints = []
        self.packageSnapshot = PackageSnapshot(document: doc, audio: [:], assetsMedia: [:],
                                               checkpoints: [])
    }

    init(imported: V1Importer.Result) {
        self.initialDocument = imported.document
        self.audio = imported.audioFiles
        self.assetsMedia = imported.backgroundFiles
        self.checkpoints = []
        self.packageSnapshot = PackageSnapshot(document: imported.document,
                                               audio: imported.audioFiles,
                                               assetsMedia: imported.backgroundFiles,
                                               checkpoints: [])
    }

    required init(configuration: ReadConfiguration) throws {
        let wrapper = configuration.file
        // A .bs archive arrives as a regular file (zipped .bannyshow); the
        // native .bannyshow arrives as a directory package.
        if wrapper.isRegularFile, let zipData = wrapper.regularFileContents {
            let loaded = try Self.readArchive(zipData)
            self.initialDocument = loaded.document
            self.audio = loaded.audio
            self.assetsMedia = loaded.assets
            self.checkpoints = loaded.checkpoints
            self.packageSnapshot = PackageSnapshot(document: loaded.document,
                                                   audio: loaded.audio,
                                                   assetsMedia: loaded.assets,
                                                   checkpoints: loaded.checkpoints)
            return
        }
        guard let showData = wrapper.fileWrappers?["show.json"]?.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let doc = try JSONDecoder().decode(ShowDocument.self, from: showData)

        func media(in folder: String) -> [String: (data: Data, ext: String)] {
            var out: [String: (data: Data, ext: String)] = [:]
            for (name, child) in wrapper.fileWrappers?[folder]?.fileWrappers ?? [:] {
                guard let data = child.regularFileContents, !name.hasPrefix(".") else { continue }
                let url = URL(fileURLWithPath: name)
                out[url.deletingPathExtension().lastPathComponent] = (data, url.pathExtension)
            }
            return out
        }
        self.audio = media(in: "audio")
        // v3 keeps bank media in assets/; v2 packages used bg/.
        var assets = media(in: "bg")
        assets.merge(media(in: "assets")) { _, new in new }
        self.assetsMedia = assets
        self.checkpoints = Self.checkpoints(in: wrapper.fileWrappers?["checkpoints"])
        self.initialDocument = doc
        self.packageSnapshot = PackageSnapshot(document: doc, audio: self.audio,
                                               assetsMedia: assets,
                                               checkpoints: self.checkpoints)
    }

    /// Expands a .bs (zipped .bannyshow) and reads its document + media.
    /// Same `ditto` path the exporter uses in reverse.
    private static func readArchive(_ zip: Data)
        throws -> (document: ShowDocument, audio: [String: (data: Data, ext: String)],
                   assets: [String: (data: Data, ext: String)],
                   checkpoints: [ShowCheckpoint]) {
        #if os(macOS)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("banny-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let zipURL = tmp.appendingPathComponent("in.bs")
        try zip.write(to: zipURL)
        let outDir = tmp.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipURL.path, outDir.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }

        // The package root is wherever show.json landed (ditto's root layout
        // varies), so find it rather than assume a fixed depth.
        guard let showURL = Self.findFile(named: "show.json", under: outDir) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let root = showURL.deletingLastPathComponent()
        let doc = try JSONDecoder().decode(ShowDocument.self,
                                           from: Data(contentsOf: showURL))
        func media(_ folder: String) -> [String: (data: Data, ext: String)] {
            var out: [String: (data: Data, ext: String)] = [:]
            let dir = root.appendingPathComponent(folder)
            for f in (try? FileManager.default.contentsOfDirectory(
                        at: dir, includingPropertiesForKeys: nil)) ?? [] {
                guard !f.lastPathComponent.hasPrefix("."), let data = try? Data(contentsOf: f)
                else { continue }
                out[f.deletingPathExtension().lastPathComponent] = (data, f.pathExtension)
            }
            return out
        }
        var assets = media("bg")
        assets.merge(media("assets")) { _, new in new }
        var checkpoints: [ShowCheckpoint] = []
        let checkpointsDir = root.appendingPathComponent("checkpoints")
        for file in (try? FileManager.default.contentsOfDirectory(
            at: checkpointsDir, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension.lowercased() == "json" {
            if let data = try? Data(contentsOf: file),
               let checkpoint = try? JSONDecoder().decode(ShowCheckpoint.self, from: data) {
                checkpoints.append(checkpoint)
            }
        }
        checkpoints.sort { $0.createdAt > $1.createdAt }
        return (doc, media("audio"), assets, checkpoints)
        #else
        // iOS has no ditto/Process; zipped .bs import needs a zip reader.
        throw CocoaError(.featureUnsupported)
        #endif
    }

    private static func findFile(named name: String, under dir: URL) -> URL? {
        guard let e = FileManager.default.enumerator(at: dir,
                                                     includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in e where url.lastPathComponent == name { return url }
        return nil
    }

    private static func checkpoints(in wrapper: FileWrapper?) -> [ShowCheckpoint] {
        var result: [ShowCheckpoint] = []
        for (name, child) in wrapper?.fileWrappers ?? [:]
        where name.hasSuffix(".json") {
            guard let data = child.regularFileContents,
                  let checkpoint = try? JSONDecoder().decode(ShowCheckpoint.self, from: data)
            else { continue }
            result.append(checkpoint)
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    func snapshot(contentType: UTType) throws -> PackageSnapshot {
        snapshotLock.lock()
        let snapshot = packageSnapshot
        snapshotLock.unlock()

        let indicator = saveIndicator
        DispatchQueue.main.async { indicator.pulse() }
        return snapshot
    }

    func fileWrapper(snapshot: PackageSnapshot,
                     configuration: WriteConfiguration) throws -> FileWrapper {
        try packageWrapper(for: snapshot)
    }

    /// The full package for the CURRENT in-memory state — used by "Export
    /// project (.bs)" so unsaved edits ship too.
    @MainActor
    func projectFileWrapper() throws -> FileWrapper {
        try packageWrapper(for: PackageSnapshot(document: model.document,
                                                audio: audio,
                                                assetsMedia: assetsMedia,
                                                checkpoints: checkpoints))
    }

    private func packageWrapper(for snapshot: PackageSnapshot) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let root = FileWrapper(directoryWithFileWrappers: [:])
        let show = FileWrapper(regularFileWithContents: try encoder.encode(snapshot.document))
        show.preferredFilename = "show.json"
        root.addFileWrapper(show)

        func folder(_ name: String, _ media: [String: (data: Data, ext: String)]) {
            guard !media.isEmpty else { return }
            var children: [String: FileWrapper] = [:]
            for (id, m) in media {
                children["\(id).\(m.ext)"] = FileWrapper(regularFileWithContents: m.data)
            }
            let dir = FileWrapper(directoryWithFileWrappers: children)
            dir.preferredFilename = name
            root.addFileWrapper(dir)
        }
        folder("audio", snapshot.audio)
        folder("assets", snapshot.assetsMedia)
        if !snapshot.checkpoints.isEmpty {
            var children: [String: FileWrapper] = [:]
            for checkpoint in snapshot.checkpoints {
                let data = try encoder.encode(checkpoint)
                children["\(checkpoint.id).json"] = FileWrapper(regularFileWithContents: data)
            }
            let dir = FileWrapper(directoryWithFileWrappers: children)
            dir.preferredFilename = "checkpoints"
            root.addFileWrapper(dir)
        }
        return root
    }

    /// Called by the main-actor editor whenever its value-type document changes.
    /// The write is short and never waits on UI work from the saving queue.
    func updateDocumentSnapshot(_ document: ShowDocument) {
        snapshotLock.lock()
        packageSnapshot = PackageSnapshot(document: document,
                                          audio: packageSnapshot.audio,
                                          assetsMedia: packageSnapshot.assetsMedia,
                                          checkpoints: packageSnapshot.checkpoints)
        snapshotLock.unlock()
        signalDocumentChange()
    }

    private func updateMediaSnapshot() {
        snapshotLock.lock()
        packageSnapshot = PackageSnapshot(document: packageSnapshot.document,
                                          audio: audio,
                                          assetsMedia: assetsMedia,
                                          checkpoints: packageSnapshot.checkpoints)
        snapshotLock.unlock()
        signalDocumentChange()
    }

    private func updateCheckpointSnapshot() {
        snapshotLock.lock()
        packageSnapshot = PackageSnapshot(document: packageSnapshot.document,
                                          audio: packageSnapshot.audio,
                                          assetsMedia: packageSnapshot.assetsMedia,
                                          checkpoints: checkpoints)
        snapshotLock.unlock()
        signalDocumentChange()
    }

    /// ReferenceFileDocument observes this publisher to schedule autosaves.
    /// Snapshot writes themselves stay thread-safe through `snapshotLock`.
    private func signalDocumentChange() {
        let publisher = objectWillChange
        DispatchQueue.main.async {
            publisher.send()
        }
    }

    @MainActor
    @discardableResult
    func createCheckpoint(name requestedName: String? = nil) -> ShowCheckpoint {
        let cleanName = requestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = checkpoints.count + 1
        let name = cleanName.flatMap { $0.isEmpty ? nil : $0 } ?? "Checkpoint \(number)"
        let checkpoint = ShowCheckpoint(
            id: Self.newID(),
            name: name,
            createdAt: Date(),
            document: model.document,
            time: model.time)
        checkpoints.insert(checkpoint, at: 0)
        return checkpoint
    }

    @MainActor
    func deleteCheckpoint(id: String) {
        checkpoints.removeAll { $0.id == id }
    }

    // MARK: - Defaults (web blankScene)

    static func newID() -> String {
        "a" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
            + String(UInt32.random(in: 0..<UInt32.max), radix: 36)
    }

    static func defaultSceneState() -> SceneState {
        var state = SceneState(characters: [Character(body: .original, x: 0.5)],
                               lights: [Light(x: 0.80, y: 0.18)])
        // A real light track from the start (the legacy `lights` sun stays as
        // the fallback beyond the cue, same position). Short cue: the timeline
        // duration follows contentEnd, so a long cue would bloat a new project
        // to hours and make every timeline redraw resolve thousands of ticks.
        state.lightTracks = [LightTrack(id: newID(), name: "Light 1",
                                        cues: [LightCue(id: newID(), start: 0, dur: 10,
                                                        from: LightState())])]
        return state
    }
}
