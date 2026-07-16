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

final class ShowDocumentFile: ReferenceFileDocument {
    let saveIndicator = SaveIndicator()
    typealias Snapshot = ShowDocument

    static let readableContentTypes: [UTType] = [.bannyShow]

    /// The document as read from disk; the live model is created lazily on main.
    private let initialDocument: ShowDocument

    /// Media bytes carried alongside the document JSON. Keyed by clip/scene id.
    var audio: [String: (data: Data, ext: String)]
    var assetsMedia: [String: (data: Data, ext: String)]

    @MainActor private var _model: StudioModel?
    @MainActor private var _audioEngine: LiveAudioEngine?

    @MainActor var audioEngine: LiveAudioEngine? {
        if let e = _audioEngine { return e }
        let e = LiveAudioEngine(file: self)
        _audioEngine = e
        return e
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
    }

    init(imported: V1Importer.Result) {
        self.initialDocument = imported.document
        self.audio = imported.audioFiles
        self.assetsMedia = imported.backgroundFiles
    }

    required init(configuration: ReadConfiguration) throws {
        let wrapper = configuration.file
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
        self.initialDocument = doc
    }

    @MainActor
    func snapshot(contentType: UTType) throws -> ShowDocument {
        let indicator = saveIndicator
        DispatchQueue.main.async { indicator.pulse() }
        return model.document
    }

    func fileWrapper(snapshot: ShowDocument, configuration: WriteConfiguration) throws -> FileWrapper {
        try packageWrapper(for: snapshot)
    }

    /// The full package for the CURRENT in-memory state — used by "Export
    /// project (.bs)" so unsaved edits ship too.
    @MainActor
    func projectFileWrapper() throws -> FileWrapper {
        try packageWrapper(for: model.document)
    }

    private func packageWrapper(for snapshot: ShowDocument) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let root = FileWrapper(directoryWithFileWrappers: [:])
        let show = FileWrapper(regularFileWithContents: try encoder.encode(snapshot))
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
        folder("audio", audio)
        folder("assets", assetsMedia)
        return root
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
