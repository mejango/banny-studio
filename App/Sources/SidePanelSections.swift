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
    /// Explicit owner when hosted in a character inspector.
    var characterIndex: Int? = nil
    /// When set, clips land on this standalone audio track instead of a character.
    var audioTrackIndex: Int? = nil
    @State private var importing = false

    private var target: Int? {
        audioTrackIndex == nil ? (characterIndex ?? model.selection.first) : nil
    }
    private var recorder: MicRecorder { file.micRecorder }
    private var targetLocked: Bool {
        if let i = target { return model.scene.characters[safe: i]?.locked ?? true }
        if let i = audioTrackIndex { return model.scene.audioTracks[safe: i]?.locked ?? true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MissingMediaRecoverySection(model: model, file: file)
            Text("AUDIO").font(.caption.bold()).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("＋ Import…") { importing = true }
                    .font(.caption)
                Button {
                    recorder.toggle(model: model, characterIndex: target,
                                    audioTrackIndex: audioTrackIndex)
                } label: {
                    Label(recorder.isRecording ? "Stop & Keep Take" : "Record from Mic",
                          systemImage: recorder.isRecording ? "stop.fill" : "mic.fill")
                        .font(.caption.bold())
                        .foregroundStyle(recorder.isRecording ? Color.red : Color.primary)
                }
                .buttonStyle(.borderless)
                .disabled(targetLocked && !recorder.isRecording)
            }
            if recorder.isRecording {
                HStack(spacing: 7) {
                    Capsule()
                        .fill(Color.red.opacity(0.2))
                        .overlay(alignment: .leading) {
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(Color.red)
                                    .frame(width: max(3, proxy.size.width * recorder.level))
                            }
                        }
                        .frame(height: 5)
                    Text(Self.clock(recorder.elapsed))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.red)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Microphone recording")
                .accessibilityValue(Self.clock(recorder.elapsed))
            }
            Text(target.map { i in
                "onto \(model.scene.characters[safe: i]?.name.isEmpty == false ? model.scene.characters[i].name : "banny \((i + 1) % 10)")'s track at the playhead"
            } ?? "onto this audio track at the playhead")
                .font(.caption2).foregroundStyle(.secondary)
            if targetLocked {
                Text("Unlock this track to add or record audio.")
                    .font(.caption2).foregroundStyle(.orange)
            } else if !recorder.isRecording {
                Text(target == nil
                     ? "Mic recording rolls the timeline so you can perform against the show."
                     : "Mic recording rolls the timeline and adds sample-aligned mouth timing automatically.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .alert("Microphone unavailable", isPresented: Binding(
            get: { recorder.lastError != nil },
            set: { if !$0 { recorder.dismissError() } })) {
                Button("OK") { recorder.dismissError() }
            } message: {
                Text(recorder.lastError ?? "")
            }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav]) { result in
            if case .success(let url) = result {
                model.addAudioClip(from: url, characterIndex: target, audioTrackIndex: audioTrackIndex)
            }
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds))
        return String(format: "%02d:%02d.%01d", whole / 60, whole % 60,
                      Int((seconds * 10).rounded(.down)) % 10)
    }
}

/// Precision controls appear only after a baked virtual M press is selected,
/// keeping the normal dialogue inspector quiet.
private struct MouthCueFineTuneSection: View {
    @Bindable var model: StudioModel
    let characterIndex: Int
    var clipID: String? = nil
    @State private var step = 0.01

    private var selection: MouthCueSelection? {
        guard let selection = model.selectedMouthCue,
              selection.character == characterIndex,
              clipID == nil || selection.clipID == clipID,
              model.mouthCueValue(selection) != nil else { return nil }
        return selection
    }

    var body: some View {
        if let selection, let cue = model.mouthCueValue(selection) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("MOUTH INTERVAL", systemImage: "mouth")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("virtual M press")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(EventGroup.talk.color)
                }
                Text("Drag the bar or its edges in the Mouth lane. Use these controls for exact timing.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Text("Start").font(.caption2).frame(width: 44, alignment: .leading)
                    Button {
                        model.moveMouthCue(
                            selection, toStart: cue.start - step)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .help("Move earlier by \(stepLabel)")
                    Text(String(format: "%.3fs", model.selectedMouthCueTimelineStart ?? 0))
                        .font(.caption.monospacedDigit())
                        .frame(maxWidth: .infinity)
                    Button {
                        model.moveMouthCue(
                            selection, toStart: cue.start + step)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .help("Move later by \(stepLabel)")
                }
                .buttonStyle(.borderless)

                HStack(spacing: 6) {
                    Text("Length").font(.caption2).frame(width: 44, alignment: .leading)
                    Button {
                        model.adjustSelectedMouthCueDuration(by: -step)
                    } label: {
                        Image(systemName: "minus")
                    }
                    .help("Shorten by \(stepLabel)")
                    Text(String(format: "%.0f ms", cue.dur * 1000))
                        .font(.caption.monospacedDigit())
                        .frame(maxWidth: .infinity)
                    Button {
                        model.adjustSelectedMouthCueDuration(by: step)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Lengthen by \(stepLabel)")
                }
                .buttonStyle(.borderless)

                HStack(spacing: 6) {
                    Text("Step").font(.caption2).frame(width: 44, alignment: .leading)
                    Picker("Step", selection: $step) {
                        Text("1 ms").tag(0.001)
                        Text("10 ms").tag(0.01)
                        Text("Frame").tag(1.0 / 30.0)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                HStack {
                    Text("← / → nudges one frame from the timeline.")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete interval", role: .destructive) {
                        model.deleteMouthCue(selection)
                    }
                    .font(.caption2)
                }
            }
            .padding(8)
            .background(EventGroup.talk.color.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(EventGroup.talk.color.opacity(0.35), lineWidth: 1))
        }
    }

    private var stepLabel: String {
        step == 1.0 / 30.0 ? "one frame" : String(format: "%.0f ms", step * 1000)
    }
}

/// Appears only when a package references bytes it no longer contains. Relink
/// preserves stable ids, so every cue/clip heals at once and undo/checkpoints
/// continue to refer to the same media.
private struct MissingMediaRecoverySection: View {
    @Bindable var model: StudioModel
    let file: ShowDocumentFile

    private enum Target {
        case audio(id: String, name: String)
        case asset(id: String, name: String, kind: Asset.Kind)
    }

    @State private var target: Target?
    @State private var importerShown = false
    @State private var error: String?

    private var missingAudio: [(id: String, name: String)] {
        let clips = model.scene.characters.flatMap(\.clips)
            + model.scene.audioTracks.flatMap(\.clips)
        var seen: Set<String> = []
        return clips.compactMap { clip in
            guard file.audio[clip.id] == nil, seen.insert(clip.id).inserted else { return nil }
            return (clip.id, clip.name)
        }
    }

    private var missingAssets: [Asset] {
        model.document.assets.filter { file.assetsMedia[$0.id] == nil }
    }

    var body: some View {
        if !missingAudio.isEmpty || !missingAssets.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Label("Missing media", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                Text("Relink in place; cues, edits, and checkpoints keep working.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ForEach(missingAudio, id: \.id) { item in
                    recoveryRow(name: item.name, detail: "audio") {
                        target = .audio(id: item.id, name: item.name)
                        importerShown = true
                    }
                }
                ForEach(missingAssets) { asset in
                    recoveryRow(name: asset.name, detail: asset.kind.rawValue) {
                        target = .asset(id: asset.id, name: asset.name, kind: asset.kind)
                        importerShown = true
                    }
                }
            }
            .padding(8)
            .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1))
            .fileImporter(isPresented: $importerShown,
                          allowedContentTypes: allowedTypes) { result in
                if case .success(let url) = result { relink(url) }
            }
            .alert("Relink failed", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } })) {
                    Button("OK") { error = nil }
                } message: {
                    Text(error ?? "")
                }
        }
    }

    private func recoveryRow(name: String, detail: String,
                             action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name.isEmpty ? "Unnamed media" : name)
                    .font(.caption2.bold())
                    .lineLimit(1)
                Text(detail).font(.system(size: 8)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Relink…", action: action).font(.caption2.bold())
        }
    }

    private var allowedTypes: [UTType] {
        switch target {
        case .audio: return [.audio, .mp3, .mpeg4Audio, .wav]
        case .asset(_, _, let kind):
            return kind == .video ? [.movie] : [.image]
        case nil:
            return [.data]
        }
    }

    private func relink(_ url: URL) {
        guard let target else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let ext = url.pathExtension.lowercased()
            guard !ext.isEmpty else {
                throw CocoaError(.fileReadUnknown)
            }
            switch target {
            case .audio(let id, _):
                let avFile = try AVAudioFile(forReading: url)
                let duration = Double(avFile.length) / avFile.processingFormat.sampleRate
                guard duration.isFinite, duration > 0 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                file.audio[id] = (data, ext)
                model.relinkAudioClipSource(id: id, sourceDuration: duration)
                model.resyncAudioIfPlaying()
            case .asset(let id, _, let expectedKind):
                let type = UTType(filenameExtension: ext)
                let matches = expectedKind == .video
                    ? type?.conforms(to: .movie) == true
                    : type?.conforms(to: .image) == true
                guard matches else { throw CocoaError(.fileReadUnsupportedScheme) }
                file.assetsMedia[id] = (data, ext)
                if let index = model.document.assets.firstIndex(where: { $0.id == id }) {
                    model.document.assets[index].file = "\(id).\(ext)"
                }
                model.backgroundRevision += 1
            }
            self.target = nil
        } catch {
            self.error = "The selected file could not replace this \(targetDescription): \(error.localizedDescription)"
        }
    }

    private var targetDescription: String {
        switch target {
        case .audio: return "audio source"
        case .asset(_, _, let kind): return kind.rawValue
        case nil: return "media"
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
    var query = ""
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MissingMediaRecoverySection(model: model, file: file)
            Text("ASSET BANK").font(.caption.bold()).foregroundStyle(.secondary)
            Button("＋ Add image/video…") { importing = true }.font(.caption)
            if model.document.assets.isEmpty {
                Text("Assets you add live with the show and can back any number of scene or visual cues.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if filteredAssets.isEmpty {
                Text("No matching project media.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(filteredAssets, id: \.element.id) { i, asset in
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

    private var filteredAssets: [(offset: Int, element: Asset)] {
        Array(model.document.assets.enumerated()).filter { _, asset in
            query.isEmpty || asset.name.localizedCaseInsensitiveContains(query)
                || asset.kind.rawValue.localizedCaseInsensitiveContains(query)
        }
    }
}

/// Natural text-to-speech for one character. Generated speech is baked into
/// the show package, so playback/export never depends on a voice still being
/// installed later.
struct VoiceSection: View {
    @Bindable var model: StudioModel
    let characterIndex: Int
    @AppStorage("studioTTSVoiceIdentifier") private var legacyVoiceID = ""
    @AppStorage("studioCustomVoiceRecipes") private var customRecipesJSON = ""
    @State private var voices = StudioSpeechVoice.installed()
    @State private var previewPlayer = VoiceRecipePreviewPlayer()
    @State private var previewTask: Task<Void, Never>?
    @State private var pickerShown = false
    @State private var fineTuneExpanded = false
    @State private var isGenerating = false
    @State private var isPreviewing = false
    @State private var lastCount: Int?
    @State private var generationError: String?
    @State private var saveRecipePrompt = false
    @State private var recipeName = ""

    private var selectedVoice: StudioSpeechVoice? {
        voices.first { $0.id == selectedVoiceID }
    }

    private var selectedVoiceID: String {
        let stored = model.scene.characters[safe: characterIndex]?
            .speechVoice.voiceIdentifier
        if let stored, voices.contains(where: { $0.id == stored }) { return stored }
        if voices.contains(where: { $0.id == legacyVoiceID }) { return legacyVoiceID }
        return StudioSpeechVoice.recommendedIdentifier(in: voices) ?? ""
    }

    private var customRecipes: [VoiceRecipe] {
        guard let data = customRecipesJSON.data(using: .utf8),
              let recipes = try? JSONDecoder().decode([VoiceRecipe].self, from: data)
        else { return [] }
        return recipes.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TEXT TO SPEECH").font(.caption.bold()).foregroundStyle(.secondary)
            if let c = model.scene.characters[safe: characterIndex] {
                if voices.isEmpty {
                    Label("No system voices are available.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Button {
                        pickerShown = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform")
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(selectedVoice?.name ?? "Choose a voice")
                                    .font(.caption.bold())
                                    .foregroundStyle(.primary)
                                if let selectedVoice {
                                    Text(Self.voiceDetail(selectedVoice))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.bold())
                                .foregroundStyle(.tertiary)
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("choose-speech-voice")

                    recipeControls(c)

                    Toggle(isOn: Binding(
                        get: { model.scene.characters[safe: characterIndex]?
                            .speechVoice.automaticMouth ?? true },
                        set: {
                            model.setAutomaticSpeechMouth(
                                characterIndex: characterIndex, enabled: $0)
                        })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Automatic mouth")
                                    .font(.caption.bold())
                                Text("Sample-aligned virtual M-key presses")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #endif
                    .disabled(c.locked)
                    .help("Uses the rendered waveform and exact word sample positions to write ordinary M-key presses. A held M key temporarily overrides it.")

                    if model.selectedMouthCue?.character == characterIndex {
                        MouthCueFineTuneSection(
                            model: model,
                            characterIndex: characterIndex)
                    }

                    HStack(spacing: 8) {
                        Button {
                            preview(character: c)
                        } label: {
                            HStack(spacing: 5) {
                                if isPreviewing {
                                    ProgressView().controlSize(.small)
                                }
                                Label(isPreviewing ? "Preparing…" : "Preview recipe",
                                      systemImage: "play.fill")
                            }
                        }
                        .font(.caption)
                        .disabled(selectedVoice == nil || isPreviewing)

                        Spacer()

                        Button {
                            generateSpeech()
                        } label: {
                            HStack(spacing: 5) {
                                if isGenerating {
                                    ProgressView().controlSize(.small)
                                }
                                Text(isGenerating ? "Rendering…" : "Render captions")
                            }
                        }
                        .font(.caption.bold())
                        .disabled(isGenerating || selectedVoice == nil
                                  || c.locked
                                  || !c.subs.contains {
                                      !$0.text.trimmingCharacters(
                                          in: .whitespacesAndNewlines).isEmpty
                                  })
                        .help("Bakes each caption, its voice recipe, and precise mouth timing. Re-running replaces only generated speech; imported files and mic takes stay untouched.")
                    }

                    if c.locked {
                        Text("Unlock this character track to generate speech.")
                            .font(.caption2).foregroundStyle(.orange)
                    } else if let lastCount {
                        Text("Created \(lastCount) speech clip\(lastCount == 1 ? "" : "s") with synchronized mouth timing.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if c.subs.isEmpty {
                        Text("Add captions first — each caption becomes a spoken clip.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("The dry voice is baked into the show; its recipe stays editable and sounds identical live and on export.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear(perform: refreshVoices)
        .onReceive(NotificationCenter.default.publisher(
            for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
                refreshVoices()
            }
        .sheet(isPresented: $pickerShown) {
            StudioVoicePicker(voices: voices, selectedVoiceID: Binding(
                get: { selectedVoiceID },
                set: { identifier in
                    legacyVoiceID = identifier
                    model.setSpeechVoiceIdentifier(
                        characterIndex: characterIndex, identifier: identifier)
                }))
        }
        .onDisappear {
            previewTask?.cancel()
            previewTask = nil
            previewPlayer.stop()
            model.stopSpeechMouthPreview(characterIndex: characterIndex)
        }
        .alert("Save Voice Recipe", isPresented: $saveRecipePrompt) {
            TextField("Recipe name", text: $recipeName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { saveCurrentRecipe() }
                .disabled(recipeName.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Saved recipes are available to every character.")
        }
        .alert("Speech generation failed", isPresented: Binding(
            get: { generationError != nil },
            set: { if !$0 { generationError = nil } })) {
                Button("OK") { generationError = nil }
            } message: {
                Text(generationError ?? "")
            }
    }

    private func refreshVoices() {
        voices = StudioSpeechVoice.installed()
        if !voices.contains(where: { $0.id == legacyVoiceID }) {
            legacyVoiceID = StudioSpeechVoice.recommendedIdentifier(in: voices) ?? ""
        }
    }

    @ViewBuilder
    private func recipeControls(_ character: Character) -> some View {
        let recipe = character.speechVoice.recipe
        Menu {
            Section("Studio recipes") {
                ForEach(VoiceRecipe.Preset.allCases.filter { $0 != .custom }) { preset in
                    Button {
                        model.setVoiceRecipe(
                            characterIndex: characterIndex,
                            recipe: VoiceRecipe.preset(preset, flavor: recipe.flavor),
                            undoLabel: "Choose Voice Recipe")
                    } label: {
                        Label(preset.displayName, systemImage: preset.symbol)
                    }
                }
            }
            if !customRecipes.isEmpty {
                Section("My recipes") {
                    ForEach(customRecipes, id: \.name) { custom in
                        Button(custom.name) {
                            model.setVoiceRecipe(
                                characterIndex: characterIndex,
                                recipe: custom,
                                undoLabel: "Choose Voice Recipe")
                        }
                    }
                }
                Menu("Delete a saved recipe") {
                    ForEach(customRecipes, id: \.name) { custom in
                        Button(custom.name, role: .destructive) {
                            deleteCustomRecipe(named: custom.name)
                        }
                    }
                }
            }
            Divider()
            Button("Save current as…") {
                recipeName = recipe.preset == .custom ? recipe.name : recipe.preset.displayName
                saveRecipePrompt = true
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: recipe.preset.symbol)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(recipe.name.isEmpty ? recipe.preset.displayName : recipe.name)
                        .font(.caption.bold())
                        .foregroundStyle(.primary)
                    Text("Voice recipe")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.bold())
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .background(Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(character.locked)

        HStack(spacing: 7) {
            Text("Flavor").font(.caption.bold())
            Slider(value: Binding(
                get: { model.scene.characters[safe: characterIndex]?
                    .speechVoice.recipe.flavor ?? 1 },
                set: { value in
                    model.updateVoiceRecipeDuringAdjustment(
                        characterIndex: characterIndex) { $0.flavor = value }
                }), in: 0...1, onEditingChanged: recipeEditingChanged)
            Text("\(Int((recipe.flavor * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .disabled(character.locked)

        DisclosureGroup(isExpanded: $fineTuneExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                recipeSlider("Pitch", keyPath: \.pitchCents, range: -1_200...1_200) {
                    String(format: "%+.0f¢", $0)
                }
                recipeSlider("Warmth", keyPath: \.low, range: -12...12) {
                    String(format: "%+.1fdB", $0)
                }
                recipeSlider("Presence", keyPath: \.mid, range: -12...12) {
                    String(format: "%+.1fdB", $0)
                }
                recipeSlider("Air", keyPath: \.high, range: -12...12) {
                    String(format: "%+.1fdB", $0)
                }
                recipeSlider("Compression", keyPath: \.compression, range: 0...1) {
                    "\(Int(($0 * 100).rounded()))%"
                }

                HStack {
                    Text("Character").font(.caption)
                    Spacer()
                    Picker("", selection: recipeBinding(\.distortion)) {
                        ForEach(VoiceRecipe.Distortion.allCases, id: \.self) {
                            Text(distortionName($0)).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 150)
                }
                recipeSlider("Character mix", keyPath: \.distortionMix, range: 0...0.75) {
                    "\(Int(($0 * 100).rounded()))%"
                }
                recipeSlider("Echo", keyPath: \.delayMix, range: 0...0.6) {
                    "\(Int(($0 * 100).rounded()))%"
                }
                recipeSlider("Echo time", keyPath: \.delayTime, range: 0.01...0.5) {
                    "\(Int(($0 * 1_000).rounded()))ms"
                }
                recipeSlider("Feedback", keyPath: \.delayFeedback, range: 0...0.8) {
                    "\(Int(($0 * 100).rounded()))%"
                }
                recipeSlider("Double", keyPath: \.doubling, range: 0...1) {
                    "\(Int(($0 * 100).rounded()))%"
                }
                HStack {
                    Text("Space").font(.caption)
                    Spacer()
                    Picker("", selection: recipeBinding(\.reverbSpace)) {
                        ForEach(VoiceRecipe.Space.allCases, id: \.self) {
                            Text(spaceName($0)).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 150)
                }
                recipeSlider("Space mix", keyPath: \.reverbMix, range: 0...0.65) {
                    "\(Int(($0 * 100).rounded()))%"
                }
                recipeSlider("Output", keyPath: \.outputGainDB, range: -12...6) {
                    String(format: "%+.1fdB", $0)
                }

                HStack {
                    Button("Save as Custom…") {
                        recipeName = recipe.preset == .custom
                            ? recipe.name : "\(recipe.preset.displayName) Custom"
                        saveRecipePrompt = true
                    }
                    Spacer()
                    Button("Reset") {
                        model.setVoiceRecipe(
                            characterIndex: characterIndex,
                            recipe: VoiceRecipe.preset(recipe.preset == .custom
                                ? .natural : recipe.preset),
                            undoLabel: "Reset Voice Recipe")
                    }
                }
                .font(.caption)
            }
            .padding(.top, 5)
        } label: {
            Text("Fine tune").font(.caption.bold()).foregroundStyle(.secondary)
        }
        .disabled(character.locked)
    }

    private func preview(character: Character) {
        guard let selectedVoice else { return }
        let caption = character.subs.map(\.text).first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let fallbackName = character.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = caption ?? "This is how \(fallbackName.isEmpty ? "this character" : fallbackName) will sound."
        previewTask?.cancel()
        previewPlayer.stop()
        model.stopSpeechMouthPreview(characterIndex: characterIndex)
        isPreviewing = true
        generationError = nil
        previewTask = Task { @MainActor in
            defer {
                isPreviewing = false
                previewTask = nil
            }
            do {
                let playback = try await previewPlayer.preview(
                    text: text,
                    voiceIdentifier: selectedVoice.id,
                    recipe: character.speechVoice.recipe)
                try Task.checkCancellation()
                model.startSpeechMouthPreview(
                    characterIndex: characterIndex,
                    playback: playback)
            } catch is CancellationError {
                // Closing the inspector or starting another preview is silent.
            } catch {
                generationError = error.localizedDescription
            }
        }
    }

    private func generateSpeech() {
        guard !isGenerating, let voiceID = selectedVoice?.id else { return }
        isGenerating = true
        lastCount = nil
        generationError = nil
        Task { @MainActor in
            defer { isGenerating = false }
            do {
                lastCount = try await model.generateSpeechCaptions(
                    characterIndex: characterIndex,
                    voiceIdentifier: voiceID)
            } catch is CancellationError {
                // A cancelled inspector task leaves the document unchanged.
            } catch {
                generationError = error.localizedDescription
            }
        }
    }

    private func recipeEditingChanged(_ editing: Bool) {
        if editing {
            model.beginVoiceRecipeAdjustment(characterIndex: characterIndex)
        } else {
            model.finishVoiceRecipeAdjustment()
        }
    }

    private func recipeSlider(
        _ label: String,
        keyPath: WritableKeyPath<VoiceRecipe, Double>,
        range: ClosedRange<Double>,
        display: @escaping (Double) -> String
    ) -> some View {
        let value = model.scene.characters[safe: characterIndex]?
            .speechVoice.recipe[keyPath: keyPath] ?? 0
        return HStack(spacing: 7) {
            Text(label).font(.caption).frame(width: 86, alignment: .leading)
            Slider(value: Binding(
                get: {
                    model.scene.characters[safe: characterIndex]?
                        .speechVoice.recipe[keyPath: keyPath] ?? 0
                },
                set: { newValue in
                    model.updateVoiceRecipeDuringAdjustment(
                        characterIndex: characterIndex) {
                            $0[keyPath: keyPath] = newValue
                            $0.preset = .custom
                            $0.name = VoiceRecipe.Preset.custom.displayName
                        }
                }), in: range, onEditingChanged: recipeEditingChanged)
            Text(display(value))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
        }
    }

    private func recipeBinding<Value>(
        _ keyPath: WritableKeyPath<VoiceRecipe, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                model.scene.characters[characterIndex]
                    .speechVoice.recipe[keyPath: keyPath]
            },
            set: { value in
                var recipe = model.scene.characters[characterIndex].speechVoice.recipe
                recipe[keyPath: keyPath] = value
                recipe.preset = .custom
                recipe.name = VoiceRecipe.Preset.custom.displayName
                model.setVoiceRecipe(characterIndex: characterIndex, recipe: recipe)
            })
    }

    private func saveCurrentRecipe() {
        let name = recipeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              var recipe = model.scene.characters[safe: characterIndex]?
                .speechVoice.recipe else { return }
        recipe.preset = .custom
        recipe.name = name
        var recipes = customRecipes
        recipes.removeAll {
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }
        recipes.append(recipe)
        persistCustomRecipes(recipes)
        model.setVoiceRecipe(
            characterIndex: characterIndex,
            recipe: recipe,
            undoLabel: "Save Voice Recipe")
    }

    private func deleteCustomRecipe(named name: String) {
        persistCustomRecipes(customRecipes.filter { $0.name != name })
    }

    private func persistCustomRecipes(_ recipes: [VoiceRecipe]) {
        guard let data = try? JSONEncoder().encode(recipes),
              let value = String(data: data, encoding: .utf8) else { return }
        customRecipesJSON = value
    }

    private func distortionName(_ distortion: VoiceRecipe.Distortion) -> String {
        switch distortion {
        case .none: "None"
        case .alienChatter: "Alien"
        case .cosmicInterference: "Cosmic"
        case .goldenPi: "Golden"
        case .radioTower: "Radio"
        case .speechWaves: "Waves"
        }
    }

    private func spaceName(_ space: VoiceRecipe.Space) -> String {
        switch space {
        case .smallRoom: "Small Room"
        case .mediumRoom: "Medium Room"
        case .largeRoom: "Large Room"
        case .mediumHall: "Medium Hall"
        case .largeHall: "Large Hall"
        case .plate: "Plate"
        case .chamber: "Chamber"
        case .cathedral: "Cathedral"
        }
    }

    fileprivate static func voiceDetail(_ voice: StudioSpeechVoice) -> String {
        let language = Locale.current.localizedString(forIdentifier: voice.language)
            ?? voice.language
        return [language, voice.quality, voice.gender]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// Search, auditioning, and voice metadata stay in an on-demand sheet so the
/// production inspector remains compact.
private struct StudioVoicePicker: View {
    let voices: [StudioSpeechVoice]
    @Binding var selectedVoiceID: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var previewSynthesizer = AVSpeechSynthesizer()

    private var filteredVoices: [StudioSpeechVoice] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return voices }
        return voices.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || $0.language.localizedCaseInsensitiveContains(needle)
                || VoiceSection.voiceDetail($0).localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose a Voice").font(.headline)
                    Text("\(voices.count) installed")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()

            TextField("Search names or languages", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 10)

            Divider()

            if filteredVoices.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredVoices) { voice in
                            HStack(spacing: 8) {
                                Button {
                                    selectedVoiceID = voice.id
                                } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: selectedVoiceID == voice.id
                                              ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selectedVoiceID == voice.id
                                                             ? Color.accentColor : Color.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 5) {
                                                Text(voice.name).font(.callout.bold())
                                                if voice.isPersonal {
                                                    voiceBadge("Personal")
                                                } else if voice.isNovelty {
                                                    voiceBadge("Novelty")
                                                }
                                            }
                                            Text(VoiceSection.voiceDetail(voice))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    preview(voice)
                                } label: {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .frame(width: 28, height: 28)
                                }
                                .buttonStyle(.borderless)
                                .help("Preview \(voice.name)")
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 9)
                            Divider().padding(.leading, 48)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 390, idealWidth: 430, minHeight: 420, idealHeight: 520)
        .accessibilityIdentifier("speech-voice-picker")
    }

    private func voiceBadge(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.08), in: Capsule())
    }

    private func preview(_ studioVoice: StudioSpeechVoice) {
        guard let voice = AVSpeechSynthesisVoice(identifier: studioVoice.id) else { return }
        previewSynthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(
            string: "The quick brown fox jumps over the lazy dog.")
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        previewSynthesizer.speak(utterance)
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
                Text("Drag on the stage to place it. During REC, grab and perform the asset directly—or use the keyboard for precise motion.")
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
            let active = model.scene.lightTracks[ti].cues.firstIndex {
                model.time >= $0.start && model.time < $0.start + $0.dur
            }
            return (ti, active ?? 0)
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
                Text("Drag the yellow source point to move this cue’s path. During REC, grab it and draw timed movement.")
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
                .accessibilityIdentifier("script-editor")
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
    @State private var pivotExpanded = false

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
                                                speed: StudioModel.speed(fromUI: ($0 * 10).rounded() / 10),
                                                registerUndo: false) }),
                    in: 1...10,
                    onEditingChanged: registerMotionUndo)
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
                        rotationSpeed: StudioModel.rotationSpeed(fromUI: ($0 * 10).rounded() / 10),
                        registerUndo: false) }),
                    in: 1...100,
                    onEditingChanged: registerMotionUndo)
                Text(String(format: "%.1f", StudioModel.uiRotationSpeed(m.rotationSpeed)))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            rotationPivotControls
            HStack {
                Text("wobble").font(.caption2).frame(width: 80, alignment: .leading)
                Slider(value: Binding(
                    get: { StudioModel.uiWobble(m.wobble) },
                    set: { model.setMotionParam(characterIndex: characterIndex, at: model.time,
                                                wobble: StudioModel.wobble(fromUI: ($0 * 10).rounded() / 10),
                                                registerUndo: false) }),
                    in: 1...10,
                    onEditingChanged: registerMotionUndo)
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

    private func registerMotionUndo(_ editing: Bool) {
        if editing { model.registerUndoSnapshot(label: "Adjust Motion") }
    }

    @ViewBuilder
    private var rotationPivotControls: some View {
        let pivot = model.scene.characters[safe: characterIndex]?.rotationPivot
        HStack(spacing: 6) {
            Text("rotation pivot").font(.caption2)
                .frame(width: 80, alignment: .leading)
            Menu {
                Button("Auto") {
                    model.setRotationPivot(characterIndex: characterIndex, pivot: nil)
                }
                Divider()
                Button("Feet") {
                    model.setRotationPivot(
                        characterIndex: characterIndex, pivot: .characterFeet)
                }
                Button("Center") {
                    model.setRotationPivot(
                        characterIndex: characterIndex, pivot: .center)
                }
                Button("Head") {
                    model.setRotationPivot(
                        characterIndex: characterIndex, pivot: .characterHead)
                }
            } label: {
                Text(pivotName(pivot))
                    .font(.caption2.bold())
                    .frame(minWidth: 48)
            }
            Spacer()
            Button {
                pivotExpanded.toggle()
            } label: {
                Image(systemName: "scope")
                    .font(.caption2.bold())
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.bordered)
            .help(pivotExpanded ? "Hide precise pivot controls"
                  : "Fine-tune the pivot point")
        }

        if pivotExpanded {
            Text(pivot == nil
                 ? "Auto keeps ordinary rotation at the feet and flips around the center."
                 : "Normalized position inside the character artwork.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            pivotSlider("x", keyPath: \.x)
            pivotSlider("y", keyPath: \.y)
        }
    }

    private func pivotSlider(
        _ label: String,
        keyPath: WritableKeyPath<MediaPivot, Double>
    ) -> some View {
        let value = (model.scene.characters[safe: characterIndex]?.rotationPivot
                     ?? .center)[keyPath: keyPath]
        return HStack(spacing: 7) {
            Text(label).font(.caption2).frame(width: 18, alignment: .leading)
            Slider(value: Binding(
                get: {
                    (model.scene.characters[safe: characterIndex]?.rotationPivot
                     ?? .center)[keyPath: keyPath]
                },
                set: { newValue in
                    var pivot = model.scene.characters[safe: characterIndex]?
                        .rotationPivot ?? .center
                    pivot[keyPath: keyPath] = newValue
                    model.setRotationPivot(
                        characterIndex: characterIndex,
                        pivot: pivot,
                        registerUndo: false)
                }), in: 0...1) { editing in
                    if editing {
                        model.registerUndoSnapshot(label: "Adjust Rotation Pivot")
                    }
                }
            Text(String(format: "%.2f", value))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.leading, 80)
    }

    private func pivotName(_ pivot: MediaPivot?) -> String {
        guard let pivot else { return "Auto" }
        if close(pivot, .characterFeet) { return "Feet" }
        if close(pivot, .center) { return "Center" }
        if close(pivot, .characterHead) { return "Head" }
        return "Custom"
    }

    private func close(_ lhs: MediaPivot, _ rhs: MediaPivot) -> Bool {
        abs(lhs.x - rhs.x) < 0.001 && abs(lhs.y - rhs.y) < 0.001
    }
}

/// Reusable composite performances. Saving replaces the selected raw marks
/// (plus outfit changes inside their time span) with one editable block.
struct ReactionLibrarySection: View {
    @Bindable var model: StudioModel
    let characterIndex: Int
    var query = ""
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
            } else if filteredReactions.isEmpty {
                Text("No matching reactions.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(filteredReactions) { reaction in
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

    private var filteredReactions: [ReactionDefinition] {
        model.scene.reactionLibrary.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
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
    @State private var analyzingMouth = false
    @State private var mouthError: String?

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
            if let clipID {
                Divider()
                Text("FADES").font(.caption2.bold()).foregroundStyle(.secondary)
                clipFadeSlider("fade in", id: clipID, leading: true)
                clipFadeSlider("fade out", id: clipID, leading: false)
                if model.selectedCrossfadeDuration != nil {
                    Button("Match overlap as crossfade") {
                        model.applyCrossfadeToSelectedClips()
                    }
                    .font(.caption)
                    .help("Sets the outgoing and incoming fades to the overlap of the two selected clips.")
                }
                if case .character(let characterIndex) = kind {
                    lipSyncControls(clipID: clipID, characterIndex: characterIndex)
                }
                Button("Reset to track mix") { resetClipOverride() }
                    .font(.caption)
            }
            Text("Changes apply from the next play.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .alert("Mouth analysis failed", isPresented: Binding(
            get: { mouthError != nil },
            set: { if !$0 { mouthError = nil } })) {
                Button("OK") { mouthError = nil }
            } message: {
                Text(mouthError ?? "")
            }
    }

    @ViewBuilder
    private func lipSyncControls(clipID: String, characterIndex: Int) -> some View {
        let clip = model.scene.characters[safe: characterIndex]?
            .clips.first { $0.id == clipID }
        Divider()
        HStack {
            Text("MOUTH TIMING").font(.caption2.bold()).foregroundStyle(.secondary)
            Spacer()
            if let count = clip?.mouthCues.count, count > 0 {
                Text("\(count) M presses")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        Text(clip?.kind == .speech
             ? "Text + waveform timing, baked as ordinary M-key presses."
             : "Waveform timing, baked as ordinary M-key presses in the Mouth lane.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        HStack {
            Button {
                analyzeMouth(clipID: clipID, characterIndex: characterIndex)
            } label: {
                HStack(spacing: 5) {
                    if analyzingMouth { ProgressView().controlSize(.small) }
                    Text((clip?.mouthCues.isEmpty ?? true) ? "Analyze dialogue" : "Re-analyze")
                }
            }
            .font(.caption)
            .disabled(analyzingMouth)
            if clip?.mouthCues.isEmpty == false {
                Button("Clear") {
                    model.clearClipMouth(
                        characterIndex: characterIndex, clipID: clipID)
                }
                .font(.caption)
            }
        }
        if model.selectedMouthCue?.character == characterIndex,
           model.selectedMouthCue?.clipID == clipID {
            MouthCueFineTuneSection(
                model: model,
                characterIndex: characterIndex,
                clipID: clipID)
        }
    }

    private func analyzeMouth(clipID: String, characterIndex: Int) {
        analyzingMouth = true
        mouthError = nil
        Task { @MainActor in
            defer { analyzingMouth = false }
            do {
                _ = try await model.analyzeClipMouth(
                    characterIndex: characterIndex, clipID: clipID)
            } catch {
                mouthError = error.localizedDescription
            }
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
        guard !model.isClipLocked(id) else { return }
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
        guard !model.isClipLocked(id) else { return }
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
            guard !model.isClipLocked(id) else { return }
            updateClip(id, transform)
            setClipOverride(id, true)
            return
        }
        guard !model.isTrackLocked(kind) else { return }
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
                   in: range) { editing in
                if editing {
                    model.registerUndoSnapshot(label: clipID == nil ? "Adjust Track Mix"
                                                                    : "Adjust Clip Mix")
                }
            }
            Text(String(format: fmt, display(get(fx))))
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func clipFadeSlider(_ label: String, id: String, leading: Bool) -> some View {
        let clip = model.audioClip(id: id)
        let value = leading ? (clip?.fadeIn ?? 0) : (clip?.fadeOut ?? 0)
        let upper = max(0.1, clip?.dur ?? 0.1)
        return HStack {
            Text(label).font(.caption2).frame(width: 60, alignment: .leading)
            Slider(value: Binding(
                get: {
                    guard let clip = model.audioClip(id: id) else { return 0 }
                    return leading ? clip.fadeIn : clip.fadeOut
                },
                set: { newValue in
                    model.setClipFades(id: id,
                                       fadeIn: leading ? newValue : nil,
                                       fadeOut: leading ? nil : newValue)
                }), in: 0...upper) { editing in
                    if editing { model.registerUndoSnapshot(label: "Adjust Clip Fade") }
                }
            Text(String(format: "%.2fs", value))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
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
