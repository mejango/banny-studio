import SwiftUI
import UniformTypeIdentifiers
import BannyCore

private struct LegacyBSArchiveError: LocalizedError {
    var errorDescription: String? {
        "This is a legacy zipped .bs file. Choose File > Import Project to convert it into an editable .bs project."
    }
}

/// The `.bs` package as a SwiftUI reference document:
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

    static let readableContentTypes: [UTType] = [.bannyShow]
    static let writableContentTypes: [UTType] = [.bannyShow]

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
        // Older Studio releases used `.bs` for a ZIP. Never autosave a package
        // over that regular file: import it first so conversion has a distinct,
        // user-selected destination.
        if wrapper.isRegularFile {
            throw LegacyBSArchiveError()
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

    /// The full package for the CURRENT in-memory state — used by "Share
    /// editable project (.bs.zip)" so unsaved edits ship too.
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
                               lights: [Light(x: 0.80, y: 0.18)],
                               gSize: SceneState.newSceneCharacterSize)
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
