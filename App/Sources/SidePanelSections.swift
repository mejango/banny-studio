import SwiftUI
import UniformTypeIdentifiers
import BannyCore

/// Audio: import a file or record from the mic onto the selected character's track.
struct AudioSection: View {
    @Bindable var model: StudioModel
    let file: ShowDocumentFile
    @State private var importing = false
    @State private var mic = MicRecorder()

    private var target: Int? { model.selection.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AUDIO").font(.caption.bold()).foregroundStyle(.secondary)
            HStack {
                Button("＋ Import…") { importing = true }
                    .font(.caption)
                Button {
                    mic.toggle(model: model, characterIndex: target)
                } label: {
                    Label(mic.isRecording ? "Stop" : "Mic",
                          systemImage: mic.isRecording ? "stop.circle.fill" : "mic.fill")
                        .font(.caption)
                        .foregroundStyle(mic.isRecording ? .red : .primary)
                }
            }
            Text(target.map { i in
                "onto \(model.scene.characters[safe: i]?.name.isEmpty == false ? model.scene.characters[i].name : "banny \((i + 1) % 10)")'s track at the playhead"
            } ?? "onto the audio track at the playhead")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav]) { result in
            if case .success(let url) = result {
                model.addAudioClip(from: url, characterIndex: target)
            }
        }
    }
}

/// Background: pick an image, choose crop mode, clear.
struct BackgroundSection: View {
    @Bindable var model: StudioModel
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("BACKGROUND").font(.caption.bold()).foregroundStyle(.secondary)
            HStack {
                Button("Choose Image…") { importing = true }.font(.caption)
                if model.scene.background != nil {
                    Button("Clear") { model.clearBackground() }
                        .font(.caption).foregroundStyle(.red)
                }
            }
            if case .image(_, let crop) = model.scene.background {
                Picker("", selection: Binding(
                    get: { crop },
                    set: { model.setBackgroundCrop($0) })) {
                    ForEach([Crop.cover, .fit, .stretch, .tile], id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.png, .jpeg, .gif, .webP, .svg]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
            model.setBackground(imageData: data, ext: ext, crop: .cover)
        }
    }
}

/// Script: one caption per line for the selected character (web SCRIPT box).
struct ScriptSection: View {
    @Bindable var model: StudioModel
    let characterIndex: Int
    @State private var text = ""
    @State private var loadedFor: Int = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SCRIPT").font(.caption.bold()).foregroundStyle(.secondary)
            Text("one caption per line; drag blocks on the timeline to time them")
                .font(.caption2).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.caption)
                .frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                .onChange(of: text) {
                    model.syncCaptions(characterIndex: characterIndex, fromText: text)
                }
        }
        .onAppear { reload() }
        .onChange(of: characterIndex) { reload() }
    }

    private func reload() {
        text = model.captionsText(characterIndex: characterIndex)
        loadedFor = characterIndex
    }
}

/// Per-character motion feel (web speed/wobble sliders; persisted in v2).
struct MotionSection: View {
    @Bindable var model: StudioModel
    let characterIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MOTION").font(.caption.bold()).foregroundStyle(.secondary)
            HStack {
                Text("speed").font(.caption2).frame(width: 80, alignment: .leading)
                Slider(value: Binding(
                    get: { model.scene.characters[safe: characterIndex]?.speed ?? 320 },
                    set: { if model.scene.characters.indices.contains(characterIndex) {
                        model.scene.characters[characterIndex].speed = $0 } }),
                    in: 40...600)
            }
            HStack {
                Text("wobble").font(.caption2).frame(width: 80, alignment: .leading)
                Slider(value: Binding(
                    get: { model.scene.characters[safe: characterIndex]?.wobble ?? 7 },
                    set: { if model.scene.characters.indices.contains(characterIndex) {
                        model.scene.characters[characterIndex].wobble = $0 } }),
                    in: 0...16)
            }
            HStack {
                Text("size").font(.caption2).frame(width: 80, alignment: .leading)
                ForEach([("Normal", 1.0), ("Small", 0.62), ("Baby", 0.38)], id: \.0) { name, value in
                    Button(name) {
                        if model.scene.characters.indices.contains(characterIndex) {
                            model.registerUndoSnapshot(label: "Size")
                            model.scene.characters[characterIndex].size = value
                        }
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .tint(abs((model.scene.characters[safe: characterIndex]?.size ?? 1) - value) < 0.01
                          ? .orange : .gray)
                }
            }
        }
    }
}
