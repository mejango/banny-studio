import Foundation
import SwiftUI
import BannyCore

/// The wide editor has one auxiliary surface. Browsing and inspecting replace
/// each other instead of shrinking the stage with several permanent panels.
enum WorkspaceDrawerMode: String, CaseIterable, Identifiable {
    case browse = "Browse"
    case inspect = "Inspect"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .browse: return "square.grid.2x2"
        case .inspect: return "slider.horizontal.3"
        }
    }
}

extension StudioModel {
    /// The track selected by the timeline, resolved to the model-facing kind.
    var selectedTrackKind: TrackRowKind? {
        guard let key = selectedTrackKey else { return nil }
        for i in scene.characters.indices where "c-\(i)" == key { return .character(i) }
        for (i, track) in scene.audioTracks.enumerated() where track.id == key { return .audio(i) }
        for (i, track) in scene.imageTracks.enumerated() where track.id == key { return .image(i) }
        for (i, track) in scene.lightTracks.enumerated() where track.id == key { return .light(i) }
        for (i, track) in scene.backgroundTracks.enumerated() where track.id == key { return .background(i) }
        return nil
    }

    var selectedTrackDisplayName: String {
        guard let kind = selectedTrackKind else { return "Nothing selected" }
        switch kind {
        case .character(let i):
            let name = scene.characters[safe: i]?.name ?? ""
            return name.isEmpty ? "Banny \((i + 1) % 10)" : name
        case .audio(let i): return scene.audioTracks[safe: i]?.name ?? "Media"
        case .image(let i): return scene.imageTracks[safe: i]?.name ?? "Visual"
        case .light(let i): return scene.lightTracks[safe: i]?.name ?? "Light"
        case .background(let i): return scene.backgroundTracks[safe: i]?.name ?? "Scenes"
        }
    }

    /// Human-readable answer to “what will Record capture?” used throughout
    /// the quiet workspace and its focused recording HUD.
    var recordingTargetLabel: String {
        if isImageRecording || selectedVisualCueOnSelectedTrack { return "Visual motion" }
        if let key = selectedTrackKey,
           let track = scene.lightTracks.first(where: { $0.id == key }) {
            return track.name.isEmpty ? "Light" : track.name
        }
        if let key = selectedTrackKey,
           scene.backgroundTracks.contains(where: { $0.id == key }) {
            return "Camera"
        }
        let indices = (recording ? Array(recTargets) : Array(selection))
            .filter { scene.characters[safe: $0]?.locked != true }
            .sorted()
        let names = indices.compactMap { index -> String? in
            guard let character = scene.characters[safe: index] else { return nil }
            return character.name.isEmpty ? "Banny \((index + 1) % 10)" : character.name
        }
        return names.isEmpty ? "Select a track" : names.joined(separator: ", ")
    }

    var canRecordSelection: Bool {
        guard let kind = selectedTrackKind else { return false }
        if isTrackLocked(kind) { return false }
        if selectedVisualCueOnSelectedTrack { return true }
        switch kind {
        case .character:
            return selection.contains { scene.characters[safe: $0]?.locked == false }
        case .light, .background: return true
        case .audio, .image: return false
        }
    }

    /// Record is an action, not a transport mode: pressing it while playing
    /// starts a take at the current playhead instead of requiring two clicks.
    func performRecordAction() {
        if recording {
            pause()
            return
        }
        if playing { pause() }
        record()
    }
}

struct WorkspaceUndoButtons: View {
    let undoManager: UndoManager?

    var body: some View {
        HStack(spacing: 2) {
            Button { undoManager?.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 24, height: 24)
            }
            .help(undoManager?.undoActionName.isEmpty == false
                  ? "Undo \(undoManager?.undoActionName ?? "")" : "Undo")
            .accessibilityLabel("Undo")
            .disabled(!(undoManager?.canUndo ?? false))

            Button { undoManager?.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
                    .frame(width: 24, height: 24)
            }
            .help(undoManager?.redoActionName.isEmpty == false
                  ? "Redo \(undoManager?.redoActionName ?? "")" : "Redo")
            .accessibilityLabel("Redo")
            .disabled(!(undoManager?.canRedo ?? false))
        }
        .font(.system(size: 11, weight: .semibold))
        .buttonStyle(.plain)
    }
}

struct WorkspacePanelButton: View {
    let title: String
    let systemImage: String
    let active: Bool
    let accessibilityID: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ViewThatFits(in: .horizontal) {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(active ? Color.orange : Color.primary.opacity(0.78))
            .padding(.horizontal, 7)
            .frame(height: 26)
            .background(active ? Color.orange.opacity(0.16) : Color.primary.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(active ? Color.orange.opacity(0.6) : Color.primary.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(active ? "Close \(title.lowercased())" : "Open \(title.lowercased())")
        .accessibilityIdentifier(accessibilityID)
    }
}

/// Small permanent transport: the only production controls that remain in
/// view while the user is concentrating on the stage.
struct WorkspaceTransport: View {
    @Bindable var model: StudioModel
    @State private var showingPerformanceKeys = false

    var body: some View {
        HStack(spacing: 3) {
            rewindButton
            playbackButton
            timecodeLabel
            performanceKeysButton
            recordButton
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }

    private var rewindButton: some View {
        Button(action: model.rewind) {
            Image(systemName: "backward.end.fill").frame(width: 24, height: 24)
        }
        .help("Return to the beginning")
    }

    private var playbackButton: some View {
        Button(action: model.play) {
            Image(systemName: model.playing && !model.recording ? "pause.fill" : "play.fill")
                .frame(width: 26, height: 24)
        }
        .help("Play/Pause (Space)")
        .accessibilityIdentifier("workspace-play")
    }

    private var timecodeLabel: some View {
        Text(timecode)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .frame(width: 58)
            .accessibilityLabel("Playhead \(timecode)")
    }

    private var performanceKeysButton: some View {
        Button {
            showingPerformanceKeys.toggle()
        } label: {
            Image(systemName: "keyboard")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 24)
        }
        .help("Performance keys and recording channels")
        .accessibilityLabel("Performance keys and recording channels")
        .accessibilityIdentifier("workspace-performance-keys")
        .popover(isPresented: $showingPerformanceKeys, arrowEdge: .top) {
            PerformanceKeyGuide(model: model)
                .padding(14)
                .frame(width: 360)
        }
    }

    private var recordButton: some View {
        Button(action: model.performRecordAction) {
            HStack(spacing: 5) {
                Circle()
                    .fill(model.recording ? Color.white : Color.red)
                    .frame(width: 8, height: 8)
                Text(model.recording ? "STOP" : "REC")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(model.recording ? Color.white : Color.primary.opacity(0.82))
            .padding(.horizontal, 7)
            .frame(minWidth: 48)
            .frame(height: 26)
            .background(model.recording ? Color.red : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(model.recording ? Color.clear : Color.red.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!model.recording && !model.canRecordSelection)
        .help("Record \(model.recordingTargetLabel)")
        .accessibilityLabel(model.recording
                            ? "Stop recording" : "Record \(model.recordingTargetLabel)")
        .accessibilityIdentifier("workspace-record")
    }

    private var timecode: String {
        let tenths = max(0, Int((model.time * 10).rounded()))
        let minutes = tenths / 600
        let seconds = (tenths / 10) % 60
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths % 10)
    }
}

/// Complete performance vocabulary on demand. Character rows are also the
/// record-arm controls; other recordable track types show their contextual map.
private struct PerformanceKeyGuide: View {
    @Bindable var model: StudioModel

    private enum Target {
        case characters, visual, light, camera, unavailable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "keyboard").foregroundStyle(.orange)
                Text("PERFORMANCE KEYS").font(.caption.bold())
                Spacer()
                Text(model.recordingTargetLabel)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            switch target {
            case .characters:
                Text("Click a channel to choose what REC writes. Keys still preview disarmed channels.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(EventGroup.allCases, id: \.self) { group in
                    characterRow(group)
                }
            case .visual:
                Text("You can also grab the visual directly on the stage during REC.")
                    .font(.caption2).foregroundStyle(.secondary)
                mappingRow("Move left / right", keys: ["←", "→"], tint: EventGroup.move.color)
                mappingRow("Move forward / back", keys: ["↑", "↓"], tint: EventGroup.depth.color)
                mappingRow("Rotate", keys: ["⇧", "sep:+", "←", "→"], tint: EventGroup.spin.color)
                mappingRow("Scale", keys: ["−", "+"], tint: EventGroup.zoom.color)
            case .light:
                Text("Paused: grab the source handle to move its cue path. REC: grab it to record a new path.")
                    .font(.caption2).foregroundStyle(.secondary)
                mappingRow("Move", keys: ["←", "→", "↑", "↓"], tint: EventGroup.move.color)
                mappingRow("Intensity", keys: ["−", "+"], tint: Color.yellow)
                mappingRow("Size", keys: ["1", "2"], tint: EventGroup.jump.color)
            case .camera:
                Text("You can also drag the stage to aim the camera during REC.")
                    .font(.caption2).foregroundStyle(.secondary)
                mappingRow("Pan", keys: ["←", "→", "↑", "↓"], tint: EventGroup.move.color)
                mappingRow("Zoom", keys: ["−", "+"], tint: EventGroup.zoom.color)
            case .unavailable:
                ContentUnavailableView(
                    "No performance target",
                    systemImage: "cursorarrow.click",
                    description: Text("Select a character, visual cue, light, or Scenes track."))
                    .frame(maxWidth: .infinity)
            }

            Divider()
            HStack(spacing: 8) {
                keycaps(["⇧", "sep:+", "Space"], tint: .red)
                Text("start / stop REC")
                Spacer()
                keycaps(["Space"], tint: .secondary)
                Text("play / pause")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("performance-key-guide")
    }

    private var target: Target {
        if model.isImageRecording || model.selectedVisualCueOnSelectedTrack { return .visual }
        if let key = model.selectedTrackKey,
           model.scene.lightTracks.contains(where: { $0.id == key }) { return .light }
        if let key = model.selectedTrackKey,
           model.scene.backgroundTracks.contains(where: { $0.id == key }) { return .camera }
        if !characterIndices.isEmpty { return .characters }
        return .unavailable
    }

    private var characterIndices: [Int] {
        let selected = model.selection
            .filter { model.scene.characters.indices.contains($0) }
            .filter { !model.scene.characters[$0].locked }
            .sorted()
        if !selected.isEmpty { return selected }
        if case .character(let index) = model.selectedTrackKind,
           model.scene.characters.indices.contains(index),
           !model.scene.characters[index].locked {
            return [index]
        }
        return []
    }

    private func characterRow(_ group: EventGroup) -> some View {
        let indices = characterIndices
        let armedCount = indices.filter {
            model.scene.characters[$0].armedGroups.contains(group)
        }.count
        let armed = !indices.isEmpty && armedCount == indices.count
        let mixed = armedCount > 0 && !armed
        let tint = group.color

        return Button {
            let shouldArm = !armed
            model.registerUndoSnapshot(label: shouldArm
                                       ? "Arm \(group.performanceTitle)"
                                       : "Disarm \(group.performanceTitle)")
            for index in indices {
                if shouldArm {
                    model.scene.characters[index].armedGroups.insert(group)
                } else {
                    model.scene.characters[index].armedGroups.remove(group)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: armed ? "checkmark.circle.fill"
                      : mixed ? "minus.circle.fill" : "circle")
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(group.performanceTitle)
                    .font(.caption.bold())
                Spacer()
                keycaps(group.performanceKeys, tint: tint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(indices.isEmpty)
        .help(armed ? "Armed: this channel will be recorded" : "Disarmed: preview only")
    }

    private func mappingRow(_ title: String, keys: [String], tint: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(title).font(.caption.bold())
            Spacer()
            keycaps(keys, tint: tint)
        }
    }

    private func keycaps(_ keys: [String], tint: Color) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                if key.hasPrefix("sep:") {
                    Text(String(key.dropFirst(4)))
                        .font(.system(size: 8, weight: .bold))
                } else {
                    Text(key)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .padding(.horizontal, key.count > 1 ? 5 : 3)
                        .frame(minWidth: 18, minHeight: 17)
                        .background(tint.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(tint.opacity(0.45), lineWidth: 0.7))
                }
            }
        }
    }
}

/// During a take, configuration disappears and the editor answers only the
/// three questions that matter: are we recording, what, and where in time?
struct RecordingHUD: View {
    @Bindable var model: StudioModel

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(Color.white).frame(width: 8, height: 8)
            Text("RECORDING")
                .font(.system(size: 10, weight: .heavy))
            Text(model.recordingTargetLabel)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            Text(timecode)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .monospacedDigit()
            Button("Stop") { model.pause() }
                .font(.system(size: 10, weight: .bold))
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.red)
                .controlSize(.small)
        }
        .foregroundStyle(.white)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.94), in: Capsule())
        .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
        .accessibilityIdentifier("recording-hud")
    }

    private var timecode: String {
        let seconds = max(0, model.time)
        return String(format: "%02d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}

/// Selection-driven high-value controls. It is intentionally not a second
/// inspector: common adjustments are inline; everything else opens Inspect.
struct ContextSmartBar: View {
    @Bindable var model: StudioModel
    @Binding var drawer: WorkspaceDrawerMode?
    let onDismiss: () -> Void

    var body: some View {
        if let kind = model.selectedTrackKind {
            Group {
                switch kind {
                case .character(let index): characterControls(index)
                case .audio(let index): audioControls(index)
                case .image: visualControls()
                case .light:
                    performanceControls(
                        symbol: "sun.max.fill",
                        hint: "Grab the source point; REC writes its path. Keys adjust position, intensity, and size.",
                        action: "Record light")
                case .background:
                    performanceControls(
                        symbol: "viewfinder",
                        hint: "Drag to preview framing; REC writes camera aim. Keys pan and zoom.",
                        action: "Record camera")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 14, y: 5)
            .accessibilityIdentifier("context-smart-bar")
        }
    }

    private func characterControls(_ index: Int) -> some View {
        let motion = model.resolvedMotion(characterIndex: index, at: model.time)
        return HStack(spacing: 10) {
            selectionLabel(symbol: "person.fill")
            MiniWorkspaceSlider(
                label: "Speed",
                value: Binding(
                    get: { StudioModel.uiSpeed(model.resolvedMotion(characterIndex: index, at: model.time).speed) },
                    set: { model.setMotionParam(characterIndex: index, at: model.time,
                                                speed: StudioModel.speed(fromUI: $0),
                                                registerUndo: false) }),
                range: 1...10, valueText: String(format: "%.1f", StudioModel.uiSpeed(motion.speed)),
                onBegin: { model.registerUndoSnapshot(label: "Speed") })
            MiniWorkspaceSlider(
                label: "Wobble",
                value: Binding(
                    get: { StudioModel.uiWobble(model.resolvedMotion(characterIndex: index, at: model.time).wobble) },
                    set: { model.setMotionParam(characterIndex: index, at: model.time,
                                                wobble: StudioModel.wobble(fromUI: $0),
                                                registerUndo: false) }),
                range: 1...10, valueText: String(format: "%.1f", StudioModel.uiWobble(motion.wobble)),
                onBegin: { model.registerUndoSnapshot(label: "Wobble") })
            Menu {
                Button("Normal") { setSize(1, character: index) }
                Button("Small") { setSize(0.62, character: index) }
                Button("Baby") { setSize(0.38, character: index) }
            } label: {
                Label(sizeName(motion.size), systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            smartButton("Dialogue", symbol: "text.bubble") { openInspector() }
            recordButton("Perform")
            moreButton
            dismissButton
        }
    }

    @ViewBuilder
    private func visualControls() -> some View {
        if let cue = model.selectedImageCueValue {
            HStack(spacing: 10) {
                selectionLabel(symbol: "photo.fill")
                MiniWorkspaceSlider(
                    label: "Scale",
                    value: Binding(
                        get: { model.selectedImageCueValue?.from.scale ?? cue.from.scale },
                        set: { value in
                            model.updateSelectedImageCue {
                                $0.from.scale = value
                                if $0.to != nil { $0.to?.scale = value }
                            }
                        }),
                    range: 0.05...1.2, valueText: String(format: "%.2f", cue.from.scale),
                    onBegin: { model.registerUndoSnapshot(label: "Scale Visual") })
                MiniWorkspaceSlider(
                    label: "Rotate",
                    value: Binding(
                        get: { model.selectedImageCueValue?.from.rotation ?? cue.from.rotation },
                        set: { value in
                            model.updateSelectedImageCue {
                                $0.from.rotation = value
                                if $0.to != nil { $0.to?.rotation = value }
                            }
                        }),
                    range: -180...180, valueText: String(format: "%.0f°", cue.from.rotation),
                    onBegin: { model.registerUndoSnapshot(label: "Rotate Visual") })
                recordButton("Record motion")
                moreButton
                dismissButton
            }
        } else {
            HStack(spacing: 10) {
                selectionLabel(symbol: "photo")
                Text("Select a visual cue, or add media at the playhead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                smartButton("Browse media", symbol: "square.grid.2x2") { openBrowser() }
                moreButton
                dismissButton
            }
        }
    }

    private func audioControls(_ index: Int) -> some View {
        let gain = model.scene.audioTracks[safe: index]?.fx.gain ?? 1
        return HStack(spacing: 10) {
            selectionLabel(symbol: "waveform")
            MiniWorkspaceSlider(
                label: "Gain",
                value: Binding(
                    get: { model.scene.audioTracks[safe: index]?.fx.gain ?? 1 },
                    set: { value in
                        if model.scene.audioTracks.indices.contains(index) {
                            model.scene.audioTracks[index].fx.gain = value
                        }
                    }),
                range: 0...2, valueText: String(format: "%.2f", gain),
                onBegin: { model.registerUndoSnapshot(label: "Track Gain") })
            smartButton("Add media", symbol: "plus") { openBrowser() }
            if model.selectedVisualCueOnSelectedTrack { recordButton("Record motion") }
            moreButton
            dismissButton
        }
    }

    private func performanceControls(symbol: String, hint: String,
                                     action: String) -> some View {
        HStack(spacing: 10) {
            selectionLabel(symbol: symbol)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            recordButton(action)
            moreButton
            dismissButton
        }
    }

    private func selectionLabel(symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.orange)
            Text(model.selectedTrackDisplayName)
                .font(.system(size: 11, weight: .bold))
                .lineLimit(1)
        }
        .padding(.trailing, 2)
    }

    private func smartButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.borderless)
    }

    private func recordButton(_ title: String) -> some View {
        Button(action: model.performRecordAction) {
            Label(title, systemImage: "record.circle")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.red)
        }
        .buttonStyle(.borderless)
        .disabled(!model.canRecordSelection)
    }

    private var moreButton: some View {
        Button(action: openInspector) {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help("More settings")
        .accessibilityLabel("More settings")
        .accessibilityIdentifier("smart-bar-more")
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Hide quick controls")
        .accessibilityLabel("Hide quick controls")
        .accessibilityIdentifier("smart-bar-close")
    }

    private func setSize(_ size: Double, character index: Int) {
        model.registerUndoSnapshot(label: "Body Size")
        model.setMotionParam(characterIndex: index, at: model.time, size: size,
                             registerUndo: false)
    }

    private func sizeName(_ size: Double) -> String {
        if abs(size - 0.38) < 0.02 { return "Baby" }
        if abs(size - 0.62) < 0.02 { return "Small" }
        return "Normal"
    }

    private func openBrowser() {
        withAnimation(.easeInOut(duration: 0.18)) { drawer = .browse }
    }

    private func openInspector() {
        withAnimation(.easeInOut(duration: 0.18)) { drawer = .inspect }
    }
}

private struct MiniWorkspaceSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let valueText: String
    let onBegin: () -> Void

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 4) {
                Text(label)
                Spacer(minLength: 2)
                Text(valueText).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.system(size: 8, weight: .semibold))
            Slider(value: $value, in: range) { editing in
                if editing { onBegin() }
            }
            .frame(width: 88)
            .controlSize(.mini)
            .tint(.orange)
        }
        .frame(width: 88)
    }
}

struct WorkspaceDrawer: View {
    @Bindable var model: StudioModel
    let file: ShowDocumentFile
    @Binding var mode: WorkspaceDrawerMode?
    @AppStorage("studioLightMode") private var lightMode = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Workspace panel", selection: activeMode) {
                    ForEach(WorkspaceDrawerMode.allCases) { item in
                        Label(item.rawValue, systemImage: item.symbol).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button { close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Close panel")
                .accessibilityLabel("Close panel")
            }
            .padding(10)
            .background(Color.primary.opacity(0.04))

            Divider()

            switch mode ?? .browse {
            case .browse:
                WorkspaceBrowser(model: model, file: file)
            case .inspect:
                ScrollView {
                    if let kind = model.selectedTrackKind {
                        TrackInspector(model: model, file: file, kind: kind)
                            .padding(12)
                    } else {
                        ContentUnavailableView("Nothing selected",
                                               systemImage: "slider.horizontal.3",
                                               description: Text("Select a track or item to edit it."))
                            .padding(.top, 60)
                    }
                }
            }
        }
        // Opaque by design: otherwise stationary stage/timeline guides show
        // through while inspector content scrolls and look like stuck dividers.
        .background(lightMode ? Color(red: 1, green: 0.99, blue: 0.96)
                              : Color(red: 0.09, green: 0.09, blue: 0.125))
        .overlay(alignment: .leading) { Divider() }
        .shadow(color: .black.opacity(0.34), radius: 18, x: -5)
        .environment(\.colorScheme, lightMode ? .light : .dark)
        .accessibilityIdentifier("workspace-drawer")
        #if os(macOS)
        .onExitCommand(perform: close)
        #endif
    }

    private var activeMode: Binding<WorkspaceDrawerMode> {
        Binding(get: { mode ?? .browse }, set: { mode = $0 })
    }

    private func close() {
        withAnimation(.easeInOut(duration: 0.18)) { mode = nil }
    }
}

private enum WorkspaceBrowserSection: String, CaseIterable, Identifiable {
    case cast = "Cast"
    case reactions = "Reactions"
    case media = "Media"
    case sets = "Sets"
    case outline = "Outline"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .cast: return "person.2"
        case .reactions: return "sparkles"
        case .media: return "photo.on.rectangle.angled"
        case .sets: return "rectangle.inset.filled"
        case .outline: return "list.bullet.indent"
        }
    }
}

private struct WorkspaceBrowser: View {
    @Bindable var model: StudioModel
    let file: ShowDocumentFile
    @State private var section = WorkspaceBrowserSection.cast
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("Library", selection: $section) {
                ForEach(WorkspaceBrowserSection.allCases) { item in
                    Label(item.rawValue, systemImage: item.symbol).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .accessibilityIdentifier("browser-sections")

            TextField(searchPrompt, text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .padding(10)
                .accessibilityIdentifier("browser-search")

            ScrollView {
                switch section {
                case .cast:
                    CastBrowser(model: model, query: query)
                case .reactions:
                    if let index = model.selection.first,
                       model.scene.characters.indices.contains(index) {
                        ReactionLibrarySection(model: model, characterIndex: index, query: query)
                    } else {
                        browserEmpty("Select a character", symbol: "person.crop.circle")
                    }
                case .media:
                    AssetBankSection(model: model, file: file, query: query)
                case .sets:
                    BackdropGallerySection(model: model, query: query, expandedByDefault: true)
                case .outline:
                    TimelineOutlineSection(model: model, query: query)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .accessibilityIdentifier("browser-\(section.rawValue.lowercased())")
        }
        .onChange(of: section) { _, _ in query = "" }
    }

    private var searchPrompt: String {
        switch section {
        case .cast: return "Search cast"
        case .reactions: return "Search reactions"
        case .media: return "Search project media"
        case .sets: return "Search backdrops"
        case .outline: return "Search markers and sections"
        }
    }

    private func browserEmpty(_ title: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

private struct TimelineOutlineSection: View {
    @Bindable var model: StudioModel
    let query: String

    private var markers: [TimelineMarker] {
        model.scene.markers
            .filter {
                query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                    || $0.kind.rawValue.localizedCaseInsensitiveContains(query)
            }
            .sorted { $0.start < $1.start }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SHOW OUTLINE").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Marker at playhead") {
                        model.addTimelineMarker(kind: .marker)
                    }
                    Button("Section at playhead") {
                        model.addTimelineMarker(kind: .section)
                    }
                } label: {
                    Label("Add", systemImage: "plus").font(.caption.bold())
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
            }

            if markers.isEmpty {
                Text(query.isEmpty
                     ? "Name important moments and sections without adding another permanent timeline lane."
                     : "No matching markers or sections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            }

            ForEach(markers) { marker in
                TimelineMarkerRow(model: model, marker: marker)
            }
        }
    }
}

private struct TimelineMarkerRow: View {
    @Bindable var model: StudioModel
    let marker: TimelineMarker

    private enum Field: Hashable { case name, start, duration }
    @FocusState private var focused: Field?
    @State private var nameDraft: String
    @State private var startDraft: String
    @State private var durationDraft: String

    init(model: StudioModel, marker: TimelineMarker) {
        self.model = model
        self.marker = marker
        _nameDraft = State(initialValue: marker.name)
        _startDraft = State(initialValue: String(format: "%.2f", marker.start))
        _durationDraft = State(initialValue: String(format: "%.2f", marker.duration))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Button {
                    model.seek(to: marker.start)
                } label: {
                    Image(systemName: marker.kind == .section ? "rectangle.split.3x1" : "bookmark.fill")
                        .foregroundStyle(color(marker.color))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Go to \(marker.name)")

                TextField(marker.kind == .section ? "Section name" : "Marker name",
                          text: $nameDraft)
                    .textFieldStyle(.plain)
                    .font(.caption.bold())
                    .focused($focused, equals: .name)
                    .onSubmit(commitName)

                Menu {
                    ForEach(TimelineMarker.Color.allCases, id: \.self) { choice in
                        Button {
                            model.registerUndoSnapshot(label: "Change Marker Color")
                            model.updateTimelineMarker(id: marker.id) { $0.color = choice }
                        } label: {
                            Label(choice.rawValue.capitalized,
                                  systemImage: choice == marker.color ? "checkmark.circle.fill" : "circle.fill")
                        }
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        model.deleteTimelineMarker(id: marker.id)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
            }

            HStack(spacing: 6) {
                Text("at").foregroundStyle(.secondary)
                TextField("seconds", text: $startDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                    .focused($focused, equals: .start)
                    .onSubmit(commitStart)
                Text("s").foregroundStyle(.secondary)
                if marker.kind == .section {
                    Text("for").foregroundStyle(.secondary)
                    TextField("duration", text: $durationDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 58)
                        .focused($focused, equals: .duration)
                        .onSubmit(commitDuration)
                    Text("s").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .font(.caption2.monospacedDigit())
        }
        .padding(7)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(color(marker.color).opacity(0.35), lineWidth: 1))
        .onChange(of: focused) { old, _ in
            if old == .name { commitName() }
            if old == .start { commitStart() }
            if old == .duration { commitDuration() }
        }
        .onChange(of: marker) { _, current in
            guard focused == nil else { return }
            nameDraft = current.name
            startDraft = String(format: "%.2f", current.start)
            durationDraft = String(format: "%.2f", current.duration)
        }
    }

    private func commitName() {
        let value = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != marker.name else {
            nameDraft = marker.name
            return
        }
        model.registerUndoSnapshot(label: "Rename Marker")
        model.updateTimelineMarker(id: marker.id) { $0.name = value }
    }

    private func commitStart() {
        guard let value = Double(startDraft.replacingOccurrences(of: ",", with: ".")),
              value.isFinite else {
            startDraft = String(format: "%.2f", marker.start)
            return
        }
        let clamped = max(0, value)
        guard abs(clamped - marker.start) > 0.0001 else { return }
        model.registerUndoSnapshot(label: "Move Marker")
        model.updateTimelineMarker(id: marker.id) { $0.start = clamped }
        model.seek(to: clamped)
    }

    private func commitDuration() {
        guard marker.kind == .section,
              let value = Double(durationDraft.replacingOccurrences(of: ",", with: ".")),
              value.isFinite else {
            durationDraft = String(format: "%.2f", marker.duration)
            return
        }
        let clamped = max(0.1, value)
        guard abs(clamped - marker.duration) > 0.0001 else { return }
        model.registerUndoSnapshot(label: "Resize Section")
        model.updateTimelineMarker(id: marker.id) { $0.duration = clamped }
    }

    private func color(_ value: TimelineMarker.Color) -> Color {
        switch value {
        case .orange: return .orange
        case .blue: return .blue
        case .green: return .green
        case .purple: return .purple
        case .red: return .red
        case .gray: return .gray
        }
    }
}

private struct CastBrowser: View {
    @Bindable var model: StudioModel
    let query: String

    private var indices: [Int] {
        model.scene.characters.indices.filter { index in
            let character = model.scene.characters[index]
            let name = character.name.isEmpty ? "Banny \((index + 1) % 10)" : character.name
            return query.isEmpty || name.localizedCaseInsensitiveContains(query)
                || character.body.rawValue.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CAST").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(BannyCore.Body.allCases, id: \.self) { body in
                        Button(body.rawValue.capitalized) { addCharacter(body) }
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.caption.bold())
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .disabled(model.scene.characters.count >= 10)
            }

            if indices.isEmpty {
                Text(query.isEmpty ? "Add a character to start performing." : "No matching characters.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            }

            ForEach(indices, id: \.self) { index in
                let character = model.scene.characters[index]
                Button { select(index) } label: {
                    HStack(spacing: 10) {
                        OutfitCard(character: character)
                            .frame(width: 30, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(character.name.isEmpty ? "Banny \((index + 1) % 10)" : character.name)
                                .font(.caption.bold())
                            Text(character.body.rawValue.capitalized
                                 + " · \(character.reactions.count) reaction\(character.reactions.count == 1 ? "" : "s")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.selection.contains(index) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.orange)
                        }
                    }
                    .padding(7)
                    .background(model.selection.contains(index) ? Color.orange.opacity(0.12)
                                                                 : Color.primary.opacity(0.045),
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(model.selection.contains(index) ? Color.orange.opacity(0.55)
                                                               : Color.primary.opacity(0.1), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func select(_ index: Int) {
        model.selection = [index]
        model.selectedTrackKey = "c-\(index)"
    }

    private func addCharacter(_ body: BannyCore.Body) {
        model.addCharacter(body: body)
        if let index = model.selection.first { model.selectedTrackKey = "c-\(index)" }
    }
}
