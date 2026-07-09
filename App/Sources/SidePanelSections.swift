import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import BannyCore

/// Audio: import a file or record from the mic onto the selected character's track.
struct AudioSection: View {
    @Bindable var model: StudioModel
    let file: ShowDocumentFile
    /// When set, clips land on this standalone audio track instead of a character.
    var audioTrackIndex: Int? = nil
    @State private var importing = false

    private var target: Int? { audioTrackIndex == nil ? model.selection.first : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AUDIO").font(.caption.bold()).foregroundStyle(.secondary)
            Button("＋ Import…") { importing = true }
                .font(.caption)
            Text(target.map { i in
                "onto \(model.scene.characters[safe: i]?.name.isEmpty == false ? model.scene.characters[i].name : "banny \((i + 1) % 10)")'s track at the playhead"
            } ?? "onto this audio track at the playhead")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav]) { result in
            if case .success(let url) = result {
                model.addAudioClip(from: url, characterIndex: target, audioTrackIndex: audioTrackIndex)
            }
        }
    }
}

/// The set's reusable assets: import once, use as backgrounds or stage images.
struct AssetBankSection: View {
    @Bindable var model: StudioModel
    let file: ShowDocumentFile
    @State private var importing = false
    @State private var stylizing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ASSET BANK").font(.caption.bold()).foregroundStyle(.secondary)
            Button("＋ Add image/video…") { importing = true }.font(.caption)
            Button("✨ Stylize into backdrop…") { stylizing = true }.font(.caption)
                .help("Turn any image into a pixel backdrop on the show's palette")
            if model.document.assets.isEmpty {
                Text("Assets you add live with the show and can back any number of background or image cues.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array(model.document.assets.enumerated()), id: \.element.id) { i, asset in
                HStack(spacing: 6) {
                    AssetThumb(assetID: asset.id, file: file)
                        .frame(width: 34, height: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        TextField("name", text: Binding(
                            get: { model.document.assets[safe: i]?.name ?? "" },
                            set: { if model.document.assets.indices.contains(i) { model.document.assets[i].name = $0 } }))
                            .textFieldStyle(.plain).font(.caption2.bold())
                        Text(asset.kind.rawValue).font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("BG") { model.addBackgroundCue(assetID: asset.id, assetName: asset.name) }
                        .font(.system(size: 9, weight: .bold))
                        .help("Set as the background from the playhead onward")
                    if asset.kind == .image {
                        Button("Stage") { model.addImageTrack(assetID: asset.id, assetName: asset.name) }
                            .font(.system(size: 9, weight: .bold))
                            .help("Add to the stage as an image track at the playhead")
                    }
                    Button("×") { model.removeAsset(id: asset.id) }
                        .buttonStyle(.plain).foregroundStyle(.red)
                }
                .padding(3)
                .background(Color.primary.opacity(0.06))
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.png, .jpeg, .gif, .webP, .svg, .mpeg4Movie, .quickTimeMovie]) { result in
            if case .success(let url) = result {
                model.addAsset(from: url)
            }
        }
        .sheet(isPresented: $stylizing) {
            StylizeSheet(model: model, file: file, isPresented: $stylizing)
        }
    }
}

/// Animalese voice profile + caption voicing for one character.
struct VoiceSection: View {
    @Bindable var model: StudioModel
    let characterIndex: Int
    @State private var player: AVAudioPlayer?
    @State private var lastCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("VOICE").font(.caption.bold()).foregroundStyle(.secondary)
            if let c = model.scene.characters[safe: characterIndex] {
                HStack {
                    Text("Pitch").font(.caption)
                    Slider(value: Binding(
                        get: { model.scene.characters[safe: characterIndex]?.voicePitch ?? 0 },
                        set: { if model.scene.characters.indices.contains(characterIndex) {
                            model.scene.characters[characterIndex].voicePitch = $0 } }),
                        in: -12...12, step: 1)
                    Text("\(Int(c.voicePitch))").font(.caption.monospacedDigit()).frame(width: 26)
                }
                HStack {
                    Text("Speed").font(.caption)
                    Slider(value: Binding(
                        get: { model.scene.characters[safe: characterIndex]?.voiceSpeed ?? 1 },
                        set: { if model.scene.characters.indices.contains(characterIndex) {
                            model.scene.characters[characterIndex].voiceSpeed = $0 } }),
                        in: 0.6...1.6)
                    Text(String(format: "%.2f", c.voiceSpeed))
                        .font(.caption.monospacedDigit()).frame(width: 34)
                }
                HStack {
                    Button("▶ Preview") {
                        if let data = model.animalesePreview(characterIndex: characterIndex) {
                            player = try? AVAudioPlayer(data: data)
                            player?.play()
                        }
                    }.font(.caption)
                    Spacer()
                    Button("Voice all captions") {
                        lastCount = model.generateAnimalese(characterIndex: characterIndex)
                    }
                    .font(.caption.bold())
                    .disabled(c.subs.isEmpty)
                    .help("Generates a gibberish-speech clip for every caption; re-run any time — generated clips are replaced, imported ones untouched")
                }
                if let lastCount {
                    Text("Voiced \(lastCount) caption\(lastCount == 1 ? "" : "s").")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if c.subs.isEmpty {
                    Text("Add captions first — each caption becomes a spoken clip.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Tiny bank thumbnail (images only; videos get a film icon).
struct AssetThumb: View {
    let assetID: String
    let file: ShowDocumentFile

    var body: some View {
        Group {
            if let media = file.assetsMedia[assetID],
               let img = decodeThumb(media.data) {
                Image(decorative: img, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: "film").foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func decodeThumb(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 80,
        ] as CFDictionary)
    }
}

/// Placement controls for the selected image cue: position, size, motion.
struct ImageCueInspector: View {
    @Bindable var model: StudioModel

    var body: some View {
        if let current = model.selectedImageCueValue {
            let binding = Binding(
                get: { model.selectedImageCueValue ?? current },
                set: { newValue in model.updateSelectedImageCue { $0 = newValue } })
            VStack(alignment: .leading, spacing: 6) {
                Text("IMAGE CUE").font(.caption.bold()).foregroundStyle(.secondary)
                Text("drag it on the stage to place; use ⤢ size below")
                    .font(.caption2).foregroundStyle(.secondary)
                placement("size ⤢", value: Binding(
                    get: { binding.wrappedValue.from.scale },
                    set: { v in
                        var cue = binding.wrappedValue
                        cue.from.scale = v
                        if cue.to != nil { cue.to?.scale = v }
                        binding.wrappedValue = cue
                    }), range: 0.05...1.2)
                Toggle(isOn: Binding(
                    get: { binding.wrappedValue.to != nil },
                    set: { on in
                        var cue = binding.wrappedValue
                        cue.to = on ? cue.from : nil
                        binding.wrappedValue = cue
                    })) {
                    Text("move over time (drag the stage while the playhead is in the second half of the cue to set the end position)")
                        .font(.caption2)
                }
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
            }
        }
    }

    private func placement(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).font(.caption2).frame(width: 60, alignment: .leading)
            Slider(value: value, in: range)
        }
    }
}

/// Position/intensity controls for the selected light cue.
struct LightCueInspector: View {
    @Bindable var model: StudioModel
    /// When set, edits this track's cue even if none is selected on the timeline.
    var trackIndex: Int? = nil

    private var path: (track: Int, cue: Int)? {
        if let sel = model.selectedLightCuePath,
           trackIndex == nil || sel.track == trackIndex {
            return sel
        }
        if let ti = trackIndex, model.scene.lightTracks.indices.contains(ti),
           !model.scene.lightTracks[ti].cues.isEmpty {
            return (ti, 0)
        }
        return nil
    }

    var body: some View {
        if let path {
            let binding = Binding(
                get: { model.scene.lightTracks[path.track].cues[path.cue] },
                set: { model.scene.lightTracks[path.track].cues[path.cue] = $0 })
            VStack(alignment: .leading, spacing: 6) {
                Text("LIGHT CUE").font(.caption.bold()).foregroundStyle(.secondary)
                Text("drag the yellow point on the stage to aim the shadows; hit REC on the track to draw its motion")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Text("size").font(.caption2).frame(width: 60, alignment: .leading)
                    Slider(value: Binding(
                        get: { binding.wrappedValue.from.size },
                        set: { v in
                            var cue = binding.wrappedValue
                            cue.from.size = v
                            if cue.to != nil { cue.to?.size = v }
                            binding.wrappedValue = cue
                        }), in: 40...300)
                }
                HStack {
                    Text("intensity").font(.caption2).frame(width: 60, alignment: .leading)
                    Slider(value: Binding(
                        get: { binding.wrappedValue.from.intensity },
                        set: { v in
                            var cue = binding.wrappedValue
                            cue.from.intensity = v
                            binding.wrappedValue = cue
                        }), in: 0...1)
                }
                if binding.wrappedValue.to != nil {
                    HStack {
                        Text("end int.").font(.caption2).frame(width: 60, alignment: .leading)
                        Slider(value: Binding(
                            get: { binding.wrappedValue.to?.intensity ?? 1 },
                            set: { v in
                                var cue = binding.wrappedValue
                                cue.to?.intensity = v
                                binding.wrappedValue = cue
                            }), in: 0...1)
                    }
                }
            }
        }
    }
}

/// Larger preview of the background under the playhead (or the selected cue).
struct BackgroundPreview: View {
    @Bindable var model: StudioModel
    let file: ShowDocumentFile
    @State private var thumbs = CueThumbCache()

    var body: some View {
        let cue = selectedCue ?? model.scene.activeBackgroundCue(at: model.time)
        if let cue, let asset = model.document.assets.first(where: { $0.id == cue.assetID }) {
            VStack(alignment: .leading, spacing: 4) {
                Text("CURRENT BACKGROUND").font(.caption.bold()).foregroundStyle(.secondary)
                ZStack(alignment: .bottomLeading) {
                    Group {
                        if let img = thumbs.thumb(assetID: asset.id, file: file) {
                            Image(decorative: img, scale: 1).resizable().scaledToFill()
                        } else {
                            Color.primary.opacity(0.08)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 110)
                    Text(asset.name + (asset.kind == .video ? " · video, loops" : ""))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.black.opacity(0.55))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var selectedCue: BackgroundCue? {
        guard let id = model.selectedBackgroundCue else { return nil }
        for track in model.scene.backgroundTracks {
            if let cue = track.cues.first(where: { $0.id == id }) { return cue }
        }
        return nil
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
                    get: { StudioModel.uiSpeed(model.scene.characters[safe: characterIndex]?.speed ?? 320) },
                    set: { if model.scene.characters.indices.contains(characterIndex) {
                        model.scene.characters[characterIndex].speed =
                            StudioModel.speed(fromUI: ($0 * 10).rounded() / 10) } }),
                    in: 1...10)
                Text(String(format: "%.1f",
                            StudioModel.uiSpeed(model.scene.characters[safe: characterIndex]?.speed ?? 320)))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }
            HStack {
                Text("wobble").font(.caption2).frame(width: 80, alignment: .leading)
                Slider(value: Binding(
                    get: { StudioModel.uiWobble(model.scene.characters[safe: characterIndex]?.wobble ?? 7) },
                    set: { if model.scene.characters.indices.contains(characterIndex) {
                        model.scene.characters[characterIndex].wobble =
                            StudioModel.wobble(fromUI: ($0 * 10).rounded() / 10) } }),
                    in: 1...10)
                Text(String(format: "%.1f",
                            StudioModel.uiWobble(model.scene.characters[safe: characterIndex]?.wobble ?? 7)))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
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

/// Audio mix for a character's voice or an audio track: gain, 3-band EQ,
/// pan mode, reverb. Gain drives the track bus; EQ/pan/reverb write through
/// to every clip on the track (the audio graph reads them per clip).
struct MixSection: View {
    @Bindable var model: StudioModel
    let kind: TrackRowKind
    /// When set, edits ONE clip as an override (track mix then leaves it alone).
    var clipID: String? = nil

    private enum PanChoice: String, CaseIterable {
        case centered = "Centered"
        case follow = "Follow"
        case wide = "Wide"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(clipID == nil ? "AUDIO MIX" : "CLIP MIX").font(.caption.bold()).foregroundStyle(.secondary)
            if clipID != nil {
                Text("Overrides the track mix for this clip only.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            slider("gain", get: { $0.gain }, set: { $0.gain = $1 }, in: 0...2, fmt: "%.2f",
                   trackOnly: true)
            slider("EQ low", get: { $0.low }, set: { $0.low = $1 }, in: -12...12, fmt: "%+.0fdB")
            slider("EQ mid", get: { $0.mid }, set: { $0.mid = $1 }, in: -12...12, fmt: "%+.0fdB")
            slider("EQ high", get: { $0.high }, set: { $0.high = $1 }, in: -12...12, fmt: "%+.0fdB")
            HStack {
                Text("pan").font(.caption2).frame(width: 60, alignment: .leading)
                Picker("", selection: panBinding) {
                    ForEach(panChoices, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if panBinding.wrappedValue == .follow {
                Text("Sound leans left/right as the character moves, staying near center.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            slider("reverb", get: { $0.reverb }, set: { $0.reverb = $1 }, in: 0...1, fmt: "%.0f%%",
                   display: { $0 * 100 })
            if clipID != nil {
                Button("Reset to track mix") { resetClipOverride() }
                    .font(.caption)
            }
            Text("Changes apply from the next play.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Clears the clip's override and re-syncs it to the track mix.
    private func resetClipOverride() {
        guard let id = clipID else { return }
        let track = trackFxValue
        updateClip(id) { f in
            f.low = track.low; f.mid = track.mid; f.high = track.high
            f.reverb = track.reverb; f.pan = track.pan; f.gain = 1
        }
        setClipOverride(id, false)
    }

    private var panChoices: [PanChoice] {
        if case .character = kind { return PanChoice.allCases }
        return [.centered, .wide]
    }

    private var trackFxValue: Fx {
        switch kind {
        case .character(let i): return model.scene.characters[safe: i]?.trackFx ?? .defaultTrack
        case .audio(let i): return model.scene.audioTracks[safe: i]?.fx ?? .defaultTrack
        default: return .defaultTrack
        }
    }

    private var fx: Fx {
        guard let id = clipID else { return trackFxValue }
        switch kind {
        case .character(let i):
            return model.scene.characters[safe: i]?.clips.first { $0.id == id }?.fx ?? .defaultClip
        case .audio(let i):
            return model.scene.audioTracks[safe: i]?.clips.first { $0.id == id }?.fx ?? .defaultClip
        default: return .defaultClip
        }
    }

    private func updateClip(_ id: String, _ transform: (inout Fx) -> Void) {
        switch kind {
        case .character(let i):
            guard model.scene.characters.indices.contains(i),
                  let ci = model.scene.characters[i].clips.firstIndex(where: { $0.id == id }) else { return }
            transform(&model.scene.characters[i].clips[ci].fx)
        case .audio(let i):
            guard model.scene.audioTracks.indices.contains(i),
                  let ci = model.scene.audioTracks[i].clips.firstIndex(where: { $0.id == id }) else { return }
            transform(&model.scene.audioTracks[i].clips[ci].fx)
        default: break
        }
    }

    private func setClipOverride(_ id: String, _ on: Bool) {
        switch kind {
        case .character(let i):
            guard model.scene.characters.indices.contains(i),
                  let ci = model.scene.characters[i].clips.firstIndex(where: { $0.id == id }) else { return }
            model.scene.characters[i].clips[ci].fxOverride = on ? true : nil
        case .audio(let i):
            guard model.scene.audioTracks.indices.contains(i),
                  let ci = model.scene.audioTracks[i].clips.firstIndex(where: { $0.id == id }) else { return }
            model.scene.audioTracks[i].clips[ci].fxOverride = on ? true : nil
        default: break
        }
    }

    /// Track mode: writes the track fx and mirrors onto every non-overridden
    /// clip (unless `trackOnly`). Clip mode: writes just that clip + marks it.
    private func update(trackOnly: Bool = false, _ transform: @escaping (inout Fx) -> Void) {
        if let id = clipID {
            updateClip(id, transform)
            setClipOverride(id, true)
            return
        }
        switch kind {
        case .character(let i):
            guard model.scene.characters.indices.contains(i) else { return }
            transform(&model.scene.characters[i].trackFx)
            if !trackOnly {
                for ci in model.scene.characters[i].clips.indices
                    where model.scene.characters[i].clips[ci].fxOverride != true {
                    transform(&model.scene.characters[i].clips[ci].fx)
                }
            }
        case .audio(let i):
            guard model.scene.audioTracks.indices.contains(i) else { return }
            transform(&model.scene.audioTracks[i].fx)
            if !trackOnly {
                for ci in model.scene.audioTracks[i].clips.indices
                    where model.scene.audioTracks[i].clips[ci].fxOverride != true {
                    transform(&model.scene.audioTracks[i].clips[ci].fx)
                }
            }
        default: break
        }
    }

    private func slider(_ label: String, get: @escaping (Fx) -> Double,
                        set: @escaping (inout Fx, Double) -> Void,
                        in range: ClosedRange<Double>, fmt: String,
                        trackOnly: Bool = false,
                        display: @escaping (Double) -> Double = { $0 }) -> some View {
        HStack {
            Text(label).font(.caption2).frame(width: 60, alignment: .leading)
            Slider(value: Binding(get: { get(fx) },
                                  set: { v in update(trackOnly: trackOnly) { set(&$0, v) } }),
                   in: range)
            Text(String(format: fmt, display(get(fx))))
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private var panBinding: Binding<PanChoice> {
        Binding(
            get: {
                switch fx.pan {
                case .follow: return .follow
                case .wide: return .wide
                case .narrow, .value: return .centered
                }
            },
            set: { choice in
                let pan: Pan = choice == .follow ? .follow : choice == .wide ? .wide : .narrow
                update { $0.pan = pan }
            })
    }
}
