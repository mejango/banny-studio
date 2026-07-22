import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import BannyCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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

/// Still/GIF/video import targeted at one general media track.
struct VisualMediaSection: View {
    @Bindable var model: StudioModel
    let trackIndex: Int
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("VISUAL MEDIA").font(.caption.bold()).foregroundStyle(.secondary)
            Button("＋ Import image/GIF/video…") { importing = true }
                .font(.caption)
            Text("onto this media track at the playhead")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .movie]) { result in
            if case .success(let url) = result,
               let asset = model.addAsset(from: url) {
                model.addMediaImageCue(trackIndex: trackIndex, assetID: asset.id, at: model.time)
            }
        }
    }
}

/// The set's reusable assets: import once, use as backgrounds or stage visuals.
struct AssetBankSection: View {
    @Bindable var model: StudioModel
    let file: ShowDocumentFile
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ASSET BANK").font(.caption.bold()).foregroundStyle(.secondary)
            Button("＋ Add image/video…") { importing = true }.font(.caption)
            if model.document.assets.isEmpty {
                Text("Assets you add live with the show and can back any number of scene or visual cues.")
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
                    Button("Add") { model.addBackgroundCueApplyingAutoFrame(assetID: asset.id, assetName: asset.name) }
                        .font(.system(size: 9, weight: .bold))
                        .help("Add to the show from the playhead onward (right-click for a floating stage visual)")
                        .contextMenu {
                            Button("Add as floating stage visual") {
                                model.addImageTrack(assetID: asset.id, assetName: asset.name)
                            }
                        }
                    Button("×") { model.removeAsset(id: asset.id) }
                        .buttonStyle(.plain).foregroundStyle(.red)
                }
                .padding(3)
                .background(Color.primary.opacity(0.06))
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.image, .movie]) { result in
            if case .success(let url) = result {
                model.addAsset(from: url)
            }
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

/// Progressive inspector for a selected still/GIF/video cue. The common
/// transform stays visible; specialized controls live in disclosure sections.
struct ImageCueInspector: View {
    @Bindable var model: StudioModel
    @State private var playbackExpanded = true
    @State private var maskExpanded = false
    @State private var lookExpanded = false
    @State private var advancedExpanded = false

    var body: some View {
        if let current = model.selectedImageCueValue {
            let binding = Binding(
                get: { model.selectedImageCueValue ?? current },
                set: { newValue in model.updateSelectedImageCue { $0 = newValue } })
            VStack(alignment: .leading, spacing: 6) {
                Text("VISUAL CUE").font(.caption.bold()).foregroundStyle(.secondary)
                Text("Drag on the stage to place it. Speed and rotation speed control the keyboard while placing or recording.")
                    .font(.caption2).foregroundStyle(.secondary)
                placement("speed", value: Binding(
                    get: { binding.wrappedValue.speed },
                    set: { v in
                        var cue = binding.wrappedValue
                        cue.speed = v
                        binding.wrappedValue = cue
                    }), range: 1...10, format: "%.1f")
                placement("rotation speed", value: Binding(
                    get: { binding.wrappedValue.rotationSpeed },
                    set: { v in
                        var cue = binding.wrappedValue
                        cue.rotationSpeed = v
                        binding.wrappedValue = cue
                    }), range: 1...100, format: "%.1f")
                placement("scale ⤢", value: Binding(
                    get: { binding.wrappedValue.from.scale },
                    set: { v in
                        var cue = binding.wrappedValue
                        cue.from.scale = v
                        if cue.to != nil { cue.to?.scale = v }
                        binding.wrappedValue = cue
                    }), range: 0.05...1.2, format: "%.2f")
                placement("rotate °", value: Binding(
                    get: { binding.wrappedValue.from.rotation },
                    set: { v in
                        var cue = binding.wrappedValue
                        cue.from.rotation = v
                        if cue.to != nil { cue.to?.rotation = v }
                        binding.wrappedValue = cue
                    }), range: -180...180, format: "%.0f°")
                Button("Set start state") {
                    model.commitSelectedImageCueStartState()
                }
                .buttonStyle(.bordered)
                .disabled(!model.selectedImageCueStartStateMismatch)
                .help("Use the exact position, scale, and rotation visible at the playhead as this cue's start")
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

                if let duration = model.visualSourceDuration(assetID: current.assetID) {
                    Divider()
                    DisclosureGroup(isExpanded: $playbackExpanded) {
                        playbackControls(binding, duration: duration)
                            .padding(.top, 4)
                    } label: {
                        Text("PLAYBACK").font(.caption.bold()).foregroundStyle(.secondary)
                    }
                }

                Divider()
                DisclosureGroup(isExpanded: $maskExpanded) {
                    maskControls(binding).padding(.top, 4)
                } label: {
                    Text("MASK").font(.caption.bold()).foregroundStyle(.secondary)
                }

                Divider()
                DisclosureGroup(isExpanded: $lookExpanded) {
                    appearanceControls(binding).padding(.top, 4)
                } label: {
                    Text("LOOK").font(.caption.bold()).foregroundStyle(.secondary)
                }

                Divider()
                DisclosureGroup(isExpanded: $advancedExpanded) {
                    advancedControls(binding).padding(.top, 4)
                } label: {
                    Text("ADVANCED").font(.caption.bold()).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func playbackControls(_ cue: Binding<ImageCue>, duration: Double) -> some View {
        let minGap = min(0.02, max(0.001, duration / 100))
        let trimEnd = cue.wrappedValue.playback.trimEnd ?? duration
        VStack(alignment: .leading, spacing: 6) {
            Text(String(format: "source duration %.2fs", duration))
                .font(.caption2).foregroundStyle(.secondary)
            placement("trim in", value: Binding(
                get: { min(duration, max(0, cue.wrappedValue.playback.trimStart)) },
                set: { value in
                    var updated = cue.wrappedValue
                    let end = updated.playback.trimEnd ?? duration
                    updated.playback.trimStart = min(max(0, value), max(0, end - minGap))
                    if let frozen = updated.playback.freezeAt {
                        updated.playback.freezeAt = max(updated.playback.trimStart, frozen)
                    }
                    cue.wrappedValue = updated
                }), range: 0...max(minGap, duration), format: "%.2fs")
            placement("trim out", value: Binding(
                get: { min(duration, max(0, trimEnd)) },
                set: { value in
                    var updated = cue.wrappedValue
                    updated.playback.trimEnd = min(duration,
                        max(updated.playback.trimStart + minGap, value))
                    if let frozen = updated.playback.freezeAt {
                        updated.playback.freezeAt = min(updated.playback.trimEnd ?? duration, frozen)
                    }
                    cue.wrappedValue = updated
                }), range: minGap...max(minGap, duration), format: "%.2fs")
            placement("playback speed", value: Binding(
                get: { cue.wrappedValue.playback.rate },
                set: { value in
                    var updated = cue.wrappedValue
                    updated.playback.rate = value
                    cue.wrappedValue = updated
                }), range: 0.1...4, format: "%.2f×")
            HStack(spacing: 12) {
                Toggle("reverse", isOn: playbackBool(cue, keyPath: \MediaPlayback.reverse))
                Toggle("loop", isOn: playbackBool(cue, keyPath: \MediaPlayback.loop))
            }
            #if os(macOS)
            .toggleStyle(.checkbox)
            #endif
            Toggle("freeze frame", isOn: Binding(
                get: { cue.wrappedValue.playback.freezeAt != nil },
                set: { frozen in
                    var updated = cue.wrappedValue
                    updated.playback.freezeAt = frozen
                        ? updated.sourceTime(at: model.time, sourceDuration: duration) : nil
                    cue.wrappedValue = updated
                }))
            #if os(macOS)
            .toggleStyle(.checkbox)
            #endif
            if cue.wrappedValue.playback.freezeAt != nil {
                placement("frame", value: Binding(
                    get: { cue.wrappedValue.playback.freezeAt ?? 0 },
                    set: { value in
                        var updated = cue.wrappedValue
                        let end = updated.playback.trimEnd ?? duration
                        updated.playback.freezeAt = min(end, max(updated.playback.trimStart, value))
                        cue.wrappedValue = updated
                    }), range: 0...max(minGap, duration), format: "%.2fs")
            }
        }
    }

    private func playbackBool(_ cue: Binding<ImageCue>,
                              keyPath: WritableKeyPath<MediaPlayback, Bool>) -> Binding<Bool> {
        Binding(get: { cue.wrappedValue.playback[keyPath: keyPath] }, set: { value in
            var updated = cue.wrappedValue
            updated.playback[keyPath: keyPath] = value
            cue.wrappedValue = updated
        })
    }

    @ViewBuilder
    private func maskControls(_ cue: Binding<ImageCue>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("shape", selection: Binding(
                get: { cue.wrappedValue.mask },
                set: { value in
                    var updated = cue.wrappedValue
                    updated.mask = value
                    cue.wrappedValue = updated
                })) {
                Text("None").tag(MediaMask.none)
                Text("Rect").tag(MediaMask.rectangle)
                Text("Rounded").tag(MediaMask.roundedRectangle)
                Text("Circle").tag(MediaMask.circle)
            }
            .pickerStyle(.segmented)
            if cue.wrappedValue.mask == .roundedRectangle {
                placement("corner radius", value: Binding(
                    get: { cue.wrappedValue.maskRadius },
                    set: { value in
                        var updated = cue.wrappedValue
                        updated.maskRadius = value
                        cue.wrappedValue = updated
                    }), range: 0...0.5, format: "%.2f")
            }
        }
    }

    @ViewBuilder
    private func appearanceControls(_ cue: Binding<ImageCue>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("tint").font(.caption2).frame(width: 88, alignment: .leading)
                ColorPicker("", selection: tintColor(cue), supportsOpacity: false)
                    .labelsHidden().frame(width: 28)
                Slider(value: appearance(cue, \MediaAppearance.tintAmount), in: 0...1)
                Text(String(format: "%.0f%%", cue.wrappedValue.appearance.tintAmount * 100))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            placement("brightness", value: appearance(cue, \MediaAppearance.brightness),
                      range: -1...1, format: "%+.2f")
            placement("contrast", value: appearance(cue, \MediaAppearance.contrast),
                      range: 0...2, format: "%.2f")
            placement("saturation", value: appearance(cue, \MediaAppearance.saturation),
                      range: 0...2, format: "%.2f")
            placement("outline", value: appearance(cue, \MediaAppearance.outline),
                      range: 0...32, format: "%.0fpx")
            placement("light shadow", value: appearance(cue, \MediaAppearance.shadow),
                      range: 0...1, format: "%.0f%%", displayScale: 100)
            Text("Shadows point away from active light sources and follow their intensity and size.")
                .font(.caption2).foregroundStyle(.secondary)
            Button("Reset look") {
                var updated = cue.wrappedValue
                updated.appearance = MediaAppearance()
                cue.wrappedValue = updated
            }
            .font(.caption2)
        }
    }

    @ViewBuilder
    private func advancedControls(_ cue: Binding<ImageCue>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            placement("alpha cleanup", value: appearance(cue, \MediaAppearance.cleanup),
                      range: 0...1, format: "%.0f%%", displayScale: 100)
            Text("Tightens faint semi-transparent fringes around cut-out artwork.")
                .font(.caption2).foregroundStyle(.secondary)
            Text("rotation pivot").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                pivotButton("↖", .topLeft, cue)
                pivotButton("↗", .topRight, cue)
                pivotButton("Center", .center, cue)
                pivotButton("↙", .bottomLeft, cue)
                pivotButton("↘", .bottomRight, cue)
            }
            placement("pivot x", value: pivot(cue, \MediaPivot.x),
                      range: 0...1, format: "%.2f")
            placement("pivot y", value: pivot(cue, \MediaPivot.y),
                      range: 0...1, format: "%.2f")
        }
    }

    private func appearance(_ cue: Binding<ImageCue>,
                            _ keyPath: WritableKeyPath<MediaAppearance, Double>) -> Binding<Double> {
        Binding(get: { cue.wrappedValue.appearance[keyPath: keyPath] }, set: { value in
            var updated = cue.wrappedValue
            updated.appearance[keyPath: keyPath] = value
            cue.wrappedValue = updated
        })
    }

    private func pivot(_ cue: Binding<ImageCue>,
                       _ keyPath: WritableKeyPath<MediaPivot, Double>) -> Binding<Double> {
        Binding(get: { cue.wrappedValue.pivot[keyPath: keyPath] }, set: { value in
            var updated = cue.wrappedValue
            updated.pivot[keyPath: keyPath] = value
            cue.wrappedValue = updated
        })
    }

    private func pivotButton(_ label: String, _ value: MediaPivot,
                             _ cue: Binding<ImageCue>) -> some View {
        let selected = abs(cue.wrappedValue.pivot.x - value.x) < 0.001
            && abs(cue.wrappedValue.pivot.y - value.y) < 0.001
        return Button(label) {
            var updated = cue.wrappedValue
            updated.pivot = value
            cue.wrappedValue = updated
        }
        .font(.caption2)
        .buttonStyle(.bordered)
        .tint(selected ? .orange : .gray)
    }

    private func tintColor(_ cue: Binding<ImageCue>) -> Binding<Color> {
        Binding(get: {
            let color = cue.wrappedValue.appearance.tint
            return Color(red: color.red, green: color.green, blue: color.blue)
        }, set: { value in
            var updated = cue.wrappedValue
            #if os(macOS)
            if let color = NSColor(value).usingColorSpace(.sRGB) {
                updated.appearance.tint = MediaColor(
                    red: Double(color.redComponent), green: Double(color.greenComponent),
                    blue: Double(color.blueComponent))
            }
            #else
            let color = UIColor(value)
            var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
            if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
                updated.appearance.tint = MediaColor(
                    red: Double(r), green: Double(g), blue: Double(b))
            }
            #endif
            cue.wrappedValue = updated
        })
    }

    private func placement(_ label: String, value: Binding<Double>, range: ClosedRange<Double>,
                           format: String, displayScale: Double = 1) -> some View {
        HStack {
            Text(label).font(.caption2).frame(width: 88, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue * displayScale))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
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

/// Output frame shape: horizontal, vertical, or a custom W:H ratio.
struct FrameSection: View {
    @Bindable var model: StudioModel

    private enum Preset: String, CaseIterable, Identifiable {
        case horizontal = "16:9", vertical = "9:16", square = "1:1", custom = "Custom"
        var id: String { rawValue }
    }

    private var preset: Preset {
        let s = model.document.settings
        if s.frameW == 16, s.frameH == 9 { return .horizontal }
        if s.frameW == 9, s.frameH == 16 { return .vertical }
        if s.frameW == s.frameH { return .square }
        return .custom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FRAME").font(.caption.bold()).foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { preset },
                set: { p in
                    model.registerUndoSnapshot(label: "Frame")
                    switch p {
                    case .horizontal: setFrame(16, 9)
                    case .vertical: setFrame(9, 16)
                    case .square: setFrame(1, 1)
                    case .custom: setFrame(4, 3) // distinct from the presets
                    }
                })) {
                ForEach(Preset.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if preset == .custom {
                HStack(spacing: 4) {
                    TextField("W", value: Binding(get: { model.document.settings.frameW },
                                                  set: { setFrame(max(1, $0), model.document.settings.frameH) }),
                              format: .number)
                        .textFieldStyle(.roundedBorder).font(.caption2).frame(width: 48)
                    Text(":").font(.caption2)
                    TextField("H", value: Binding(get: { model.document.settings.frameH },
                                                  set: { setFrame(model.document.settings.frameW, max(1, $0)) }),
                              format: .number)
                        .textFieldStyle(.roundedBorder).font(.caption2).frame(width: 48)
                }
            }
            Text("The whole project renders in this shape — stage and export.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func setFrame(_ w: Double, _ h: Double) {
        model.document.settings.frameW = w
        model.document.settings.frameH = h
    }
}

/// Camera pan/zoom for the selected scene cue (or the one under the playhead).
struct CameraSection: View {
    @Bindable var model: StudioModel

    /// (track, cue) of the cue being edited.
    private var path: (track: Int, cue: Int)? {
        let id = model.selectedBackgroundCue
            ?? model.scene.activeBackgroundCue(at: model.time)?.id
        guard let id else { return nil }
        for (ti, track) in model.scene.backgroundTracks.enumerated() {
            if let ci = track.cues.firstIndex(where: { $0.id == id }) { return (ti, ci) }
        }
        return nil
    }

    var body: some View {
        if let path {
            let binding = Binding(
                get: { model.scene.backgroundTracks[path.track].cues[path.cue] },
                set: { model.scene.backgroundTracks[path.track].cues[path.cue] = $0 })
            VStack(alignment: .leading, spacing: 6) {
                Text("CAMERA").font(.caption.bold()).foregroundStyle(.secondary)
                Toggle(isOn: Binding(
                    get: { binding.wrappedValue.camFrom != nil },
                    set: { on in
                        model.registerUndoSnapshot(label: "Camera")
                        var cue = binding.wrappedValue
                        cue.camFrom = on ? CameraState() : nil
                        if !on { cue.camTo = nil }
                        binding.wrappedValue = cue
                    })) {
                    Text("Pan/zoom this scene").font(.caption2)
                }
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
                if let cam = binding.wrappedValue.camFrom {
                    camSliders(binding: binding, cam: cam, end: false)
                    Toggle(isOn: Binding(
                        get: { binding.wrappedValue.camTo != nil },
                        set: { on in
                            model.registerUndoSnapshot(label: "Animate Camera")
                            var cue = binding.wrappedValue
                            cue.camTo = on ? cue.camFrom : nil
                            binding.wrappedValue = cue
                        })) {
                        Text("animate over the scene (these values become the START; set the END below)")
                            .font(.caption2)
                    }
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #endif
                    if let end = binding.wrappedValue.camTo {
                        camSliders(binding: binding, cam: end, end: true)
                    }
                    Text("Drag the stage to move the focus (second half of the scene moves the end).")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                slider("pan speed", value: Binding(get: { model.cameraPanSpeed },
                                                   set: { model.cameraPanSpeed = $0 }),
                       range: 0.1...1.5)
                slider("zoom speed", value: Binding(get: { model.cameraZoomSpeed },
                                                    set: { model.cameraZoomSpeed = $0 }),
                       range: 0.2...3)
                Text("How fast arrows pan and +/− zoom while recording the camera.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func camSliders(binding: Binding<BackgroundCue>, cam: CameraState, end: Bool) -> some View {
        let set: (WritableKeyPath<CameraState, Double>, Double) -> Void = { key, v in
            var cue = binding.wrappedValue
            if end { cue.camTo?[keyPath: key] = v } else { cue.camFrom?[keyPath: key] = v }
            binding.wrappedValue = cue
        }
        slider(end ? "end zoom" : "zoom", value: Binding(get: { cam.zoom }, set: { set(\.zoom, $0) }),
               range: 0.5...4)
        slider(end ? "end ←→" : "focus ←→", value: Binding(get: { cam.x }, set: { set(\.x, $0) }),
               range: 0...1)
        slider(end ? "end ↑↓" : "focus ↑↓", value: Binding(get: { cam.y }, set: { set(\.y, $0) }),
               range: 0...1)
    }

    private func slider(_ label: String, value: Binding<Double>,
                        range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).font(.caption2).frame(width: 60, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
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

/// Per-character motion feel, including independent translation and rotation rates.
struct MotionSection: View {
    @Bindable var model: StudioModel
    let characterIndex: Int

    /// Motion params resolved at the playhead: editing writes the base value
    /// at t≈0, otherwise a timed keyframe (like outfits/visibility).
    private var m: (speed: Double, rotationSpeed: Double, wobble: Double, size: Double) {
        model.resolvedMotion(characterIndex: characterIndex, at: model.time)
    }
    private var keyframing: Bool { model.time >= 0.05 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("MOTION").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Text(keyframing ? String(format: "keyframe @ %.1fs", model.time) : "base")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(keyframing ? .orange : .secondary)
            }
            HStack {
                Text("speed").font(.caption2).frame(width: 80, alignment: .leading)
                Slider(value: Binding(
                    get: { StudioModel.uiSpeed(m.speed) },
                    set: { model.setMotionParam(characterIndex: characterIndex, at: model.time,
                                                speed: StudioModel.speed(fromUI: ($0 * 10).rounded() / 10)) }),
                    in: 1...10)
                Text(String(format: "%.1f", StudioModel.uiSpeed(m.speed)))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }
            HStack {
                Text("rotation speed").font(.caption2).frame(width: 80, alignment: .leading)
                Slider(value: Binding(
                    get: { StudioModel.uiRotationSpeed(m.rotationSpeed) },
                    set: { model.setMotionParam(
                        characterIndex: characterIndex, at: model.time,
                        rotationSpeed: StudioModel.rotationSpeed(fromUI: ($0 * 10).rounded() / 10)) }),
                    in: 1...100)
                Text(String(format: "%.1f", StudioModel.uiRotationSpeed(m.rotationSpeed)))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            HStack {
                Text("wobble").font(.caption2).frame(width: 80, alignment: .leading)
                Slider(value: Binding(
                    get: { StudioModel.uiWobble(m.wobble) },
                    set: { model.setMotionParam(characterIndex: characterIndex, at: model.time,
                                                wobble: StudioModel.wobble(fromUI: ($0 * 10).rounded() / 10)) }),
                    in: 1...10)
                Text(String(format: "%.1f", StudioModel.uiWobble(m.wobble)))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }
            HStack {
                Text("Body size").font(.caption2).frame(width: 80, alignment: .leading)
                ForEach([("Normal", 1.0), ("Small", 0.62), ("Baby", 0.38)], id: \.0) { name, value in
                    Button(name) {
                        model.setMotionParam(characterIndex: characterIndex, at: model.time, size: value)
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .tint(abs(m.size - value) < 0.01 ? .orange : .gray)
                }
            }
            if keyframing {
                Text("Editing at the playhead — creates a timed change. Park at 0s to edit the base.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Reusable composite performances. Saving replaces the selected raw marks
/// (plus outfit changes inside their time span) with one editable block.
struct ReactionLibrarySection: View {
    @Bindable var model: StudioModel
    let characterIndex: Int
    @State private var naming = false
    @State private var draftName = ""
    @State private var renamingID: String?
    @State private var renameDraft = ""

    private var selected: (definition: ReactionDefinition, instance: ReactionInstance)? {
        guard model.selectedReaction?.character == characterIndex else { return nil }
        return model.selectedReactionValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("REACTIONS").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Button {
                    draftName = model.suggestedReactionName()
                    naming = true
                } label: {
                    Label("Save selection", systemImage: "square.stack.3d.up")
                        .font(.caption2.bold())
                }
                .buttonStyle(.borderless)
                .disabled(!model.canCaptureReaction(characterIndex: characterIndex))
                .help("Replace the selected performance marks and in-range outfit changes with a reusable reaction block")
            }

            if let selected {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(selected.definition.name).font(.caption.bold())
                        Spacer()
                        Text("SELECTED BLOCK").font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.purple)
                    }
                    reactionSlider("intensity", value: Binding(
                        get: { model.selectedReactionValue?.instance.intensity ?? 1 },
                        set: { model.setSelectedReactionIntensity($0) }), in: 0...4,
                                   format: "%.2f")
                    reactionSlider("duration", value: Binding(
                        get: { model.selectedReactionValue?.instance.dur ?? selected.definition.dur },
                        set: { model.setSelectedReactionDuration($0) }),
                                   in: 0.08...max(10, selected.definition.dur * 4), format: "%.2fs")
                    Text(channelSummary(selected.definition))
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Button("Expand to events") {
                            model.expandReactionBlock(character: characterIndex,
                                                      id: selected.instance.id)
                        }
                        .font(.caption2)
                        Spacer()
                        Button("Delete block", role: .destructive) {
                            model.deleteTimelineSelection()
                        }
                        .font(.caption2)
                    }
                }
                .padding(8)
                .background(Color.purple.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.purple.opacity(0.4), lineWidth: 1))
            }

            if model.scene.reactionLibrary.isEmpty {
                Text(model.canCaptureReaction(characterIndex: characterIndex)
                     ? "Save the selected performance as your first reusable reaction."
                     : "Select one or more performance bars on this character to make a reaction.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(model.scene.reactionLibrary) { reaction in
                    HStack(spacing: 7) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(reaction.name).font(.caption)
                            Text(channelSummary(reaction))
                                .font(.system(size: 8)).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(String(format: "%.1fs", reaction.dur))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button {
                            model.insertReaction(reaction.id, characterIndex: characterIndex)
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Insert at the playhead")
                    }
                    .contextMenu {
                        Button("Insert at playhead") {
                            model.insertReaction(reaction.id, characterIndex: characterIndex)
                        }
                        Button("Rename…") {
                            renameDraft = reaction.name
                            renamingID = reaction.id
                        }
                        let used = model.scene.characters.contains { character in
                            character.reactions.contains { $0.reactionID == reaction.id }
                        }
                        Button("Delete from library", role: .destructive) {
                            model.deleteReactionDefinition(id: reaction.id)
                        }
                        .disabled(used)
                    }
                }
            }
        }
        .alert("Save as Reaction", isPresented: $naming) {
            TextField("Reaction name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                model.captureReaction(name: draftName, characterIndex: characterIndex)
            }
        } message: {
            Text("The selected performance and outfit changes in its time span become one reusable block.")
        }
        .alert("Rename Reaction", isPresented: Binding(
            get: { renamingID != nil },
            set: { if !$0 { renamingID = nil } })) {
            TextField("Reaction name", text: $renameDraft)
            Button("Cancel", role: .cancel) { renamingID = nil }
            Button("Rename") {
                if let id = renamingID { model.renameReaction(id: id, to: renameDraft) }
                renamingID = nil
            }
        }
    }

    private func reactionSlider(_ label: String, value: Binding<Double>,
                                in range: ClosedRange<Double>, format: String) -> some View {
        HStack {
            Text(label).font(.caption2).frame(width: 52, alignment: .leading)
            Slider(value: value, in: range) { editing in
                if editing { model.registerUndoSnapshot(label: "Edit Reaction") }
            }
            Text(String(format: format, value.wrappedValue))
                .font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }

    private func channelSummary(_ reaction: ReactionDefinition) -> String {
        var names = EventGroup.allCases.filter { reaction.ownedGroups.contains($0) }
            .map { $0.rawValue.capitalized }
        if reaction.ownsWobble { names.append("Wobble") }
        if reaction.ownsSize { names.append("Body size") }
        if !reaction.outfitSlots.isEmpty {
            let slots = reaction.outfitSlots.sorted().map {
                SharedAssets.catalog.slotName($0) ?? "slot \($0)"
            }
            names.append("Outfit: " + slots.joined(separator: ", "))
        }
        return names.isEmpty ? "No owned channels" : names.joined(separator: " · ")
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
