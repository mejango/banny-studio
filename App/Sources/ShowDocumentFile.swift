import SwiftUI
import UniformTypeIdentifiers
import BannyCore

/// The .bannyshow package as a SwiftUI reference document:
/// show.json + audio/<clipId>.<ext> + bg/<sceneId>.<ext> (+ thumbnail.png).
final class ShowDocumentFile: ReferenceFileDocument {
    typealias Snapshot = ShowDocument

    static let readableContentTypes: [UTType] = [.bannyShow]

    @MainActor let model: StudioModel

    /// Media bytes carried alongside the document JSON. Keyed by clip/scene id.
    var audio: [String: (data: Data, ext: String)]
    var backgrounds: [String: (data: Data, ext: String)]

    @MainActor
    init() {
        var doc = ShowDocument()
        doc.scenes = [Scene(id: Self.newID(), name: "Scene 1", state: Self.defaultSceneState())]
        self.audio = [:]
        self.backgrounds = [:]
        self.model = StudioModel(document: doc)
        model.file = self
    }

    @MainActor
    init(imported: V1Importer.Result) {
        self.audio = imported.audioFiles
        self.backgrounds = imported.backgroundFiles
        self.model = StudioModel(document: imported.document)
        model.file = self
    }

    @MainActor
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
        self.backgrounds = media(in: "bg")
        self.model = StudioModel(document: doc)
        model.file = self
    }

    @MainActor
    func snapshot(contentType: UTType) throws -> ShowDocument {
        model.document
    }

    func fileWrapper(snapshot: ShowDocument, configuration: WriteConfiguration) throws -> FileWrapper {
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
        folder("bg", backgrounds)
        return root
    }

    // MARK: - Defaults (web blankScene)

    static func newID() -> String {
        "a" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
            + String(UInt32.random(in: 0..<UInt32.max), radix: 36)
    }

    static func defaultSceneState() -> SceneState {
        SceneState(characters: [Character(body: .orange, x: 0.5)],
                   lights: [Light(x: 0.80, y: 0.18)])
    }
}
