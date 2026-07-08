import Foundation
import AVFoundation
import BannyCore
import BannyMedia

/// Realtime playback audio for the editor: rebuilds the clip graph per scene,
/// follows the transport, and updates "follow" pans from character positions.
@MainActor
final class LiveAudioEngine: StudioAudioEngine {
    private var graph: AudioGraph?
    private var builtSceneIndex: Int = -1
    private var builtSceneRevision: Int = 0
    private weak var file: ShowDocumentFile?
    private var tempDir: URL

    init(file: ShowDocumentFile) {
        self.file = file
        self.tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("banny-audio-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    /// Media lives as Data inside the document; AVAudioFile needs URLs.
    func audioURL(for clipID: String) -> URL? {
        guard let media = file?.audio[clipID] else { return nil }
        let url = tempDir.appendingPathComponent("\(clipID).\(media.ext)")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? media.data.write(to: url)
        }
        return url
    }

    func syncPlayback(_ model: StudioModel) {
        if model.playing {
            start(model: model)
        } else {
            graph?.stopAll()
            graph?.engine.stop()
        }
    }

    private func start(model: StudioModel) {
        // Rebuild the graph when the scene changes (clip edits mid-scene rebuild too:
        // stop/start is cheap at this scale).
        graph?.stopAll()
        graph?.engine.stop()
        let g = AudioGraph()
        do {
            try g.build(scene: model.scene) { audioURL(for: $0) }
            guard !g.clipNodes.isEmpty else { graph = nil; return }
            try g.engine.start()
            g.schedule(from: model.time)
            let sim = model.simulator
            let t = model.time
            g.updatePans { i in
                model.scene.characters.indices.contains(i) ? sim.pose(characterIndex: i, at: t).x : nil
            }
            g.playAll()
            graph = g
        } catch {
            graph = nil
        }
    }

    /// Called from the render loop while playing (follow-pan tracking).
    func tick(model: StudioModel) {
        guard model.playing, let g = graph else { return }
        let sim = model.simulator
        let t = model.time
        g.updatePans { i in
            model.scene.characters.indices.contains(i) ? sim.pose(characterIndex: i, at: t).x : nil
        }
    }
}
