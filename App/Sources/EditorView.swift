import SwiftUI
import BannyCore

/// Main editor layout, adaptive per platform. One stage + one timeline;
/// the divider between them drags to trade stage space for track space.
struct EditorView: View {
    let file: ShowDocumentFile
    @Environment(\.undoManager) private var undoManager
    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        let model = file.model
        Group {
            #if os(macOS)
            WideEditor(model: model, file: file, showDeck: false)
                .frame(minWidth: 1000, minHeight: 700)
            #else
            if sizeClass == .regular {
                WideEditor(model: model, file: file, showDeck: true)
            } else {
                CompactEditor(model: model, file: file)
            }
            #endif
        }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { model.undoManager = $1 }
        .background(KeyCaptureView(model: model))
    }
}

/// Mac + iPad layout.
struct WideEditor: View {
    @Bindable var model: StudioModel
    let file: ShowDocumentFile
    let showDeck: Bool

    @AppStorage("timelineHeight") private var timelineHeight: Double = 230
    @AppStorage("studioLightMode") private var lightMode = false
    private var theme: Theme { lightMode ? .light : .dark }
    @State private var dividerDragBase: Double?

    private let headerH = 36.0

    var body: some View {
        GeometryReader { geo in
            // Stage never letterboxes vertically: it takes exactly its 16:9 height
            // for the available width, and the timeline absorbs all remaining space.
            let availH = Double(geo.size.height) - headerH
            let stageWidth = Double(max(200, geo.size.width))
            let requestedTL = min(max(0, timelineHeight), availH - 9)
            // Below ~24pt the timeline snaps away entirely and the stage keeps
            // the whole area (letterboxed once it hits its 16:9 width limit).
            let wantTL = requestedTL < 24 ? 0.0 : requestedTL
            let rawStage = min(stageWidth * 9.0 / 16.0, availH - 9 - wantTL)
            // Below ~44pt the stage snaps away too — timeline-only editing.
            let stageH = rawStage < 44 ? 0.0 : rawStage
            let tlH = wantTL == 0 ? 0.0 : max(0, availH - 9 - stageH)
            let stageBoxH = availH - 9 - tlH
            VStack(spacing: 0) {
                header
                StageView(model: model, file: file)
                    .frame(width: CGFloat(stageWidth), height: CGFloat(stageBoxH))
                    .background(Color.black)
                    .overlay(alignment: .bottom) {
                        if showDeck {
                            PerformanceDeck(model: model)
                        }
                    }
                divider(maxHeight: availH - 9)
                StudioTimelineView(model: model, file: file, showShip: false)
                    .frame(height: CGFloat(tlH), alignment: .top)
                    .clipped()
            }
            .background(theme.surface)
            // Drive SwiftUI's semantic colors (.primary on buttons/menus) from the
            // studio theme, not the system appearance.
            .environment(\.colorScheme, lightMode ? .light : .dark)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(lightMode ? "HeaderLogo" : "HeaderLogoDark")
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                // Dark variant carries a 7px outline outside the glyphs; scale
                // so the BLACK eyes render at the same size in both themes.
                .frame(height: lightMode ? 18 : 20.1)
            Text("BANNY STUDIO")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .kerning(2)
                // Match the logo art: black in light mode, off-white in dark.
                .foregroundStyle(lightMode ? Color.black
                                           : Color(red: 0.92, green: 0.92, blue: 0.92))
            ThemeToggle()
            Spacer()
            SaveBadge(indicator: file.saveIndicator, lightMode: lightMode)
            ProjectMenu()
        }
        .padding(.horizontal, 14)
        .frame(height: CGFloat(headerH))
        .background(theme.header)
    }

    /// Drag up to grow the timeline (shrinking the stage), down to shrink it.
    /// Global coordinates: the divider itself moves during the drag, so local
    /// translation would feed back and oscillate.
    private func divider(maxHeight: Double) -> some View {
        Rectangle()
            .fill(theme.dividerBar)
            .frame(height: 9)
            .overlay(Capsule()
                .fill(lightMode ? Color(white: 0.35) : Color(white: 0.72))
                .frame(width: 56, height: 4))
            .contentShape(Rectangle().inset(by: -4))
            #if os(macOS)
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            #endif
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let base = dividerDragBase ?? timelineHeight
                    dividerDragBase = base
                    timelineHeight = min(maxHeight, max(0, base - Double(value.translation.height)))
                }
                .onEnded { _ in dividerDragBase = nil })
    }
}

/// iPhone layout: Stage / Timeline / Cast, one at a time.
struct CompactEditor: View {
    @Bindable var model: StudioModel
    let file: ShowDocumentFile

    enum Mode: String, CaseIterable {
        case stage = "Stage"
        case timeline = "Timeline"
        case wardrobe = "Wardrobe"
    }

    @State private var mode: Mode = .stage

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .padding(8)
            switch mode {
            case .stage:
                StageView(model: model, file: file)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        PerformanceDeck(model: model)
                    }
                TransportBar(model: model, file: file)
            case .timeline:
                StageView(model: model, file: file)
                    .frame(height: 180)
                StudioTimelineView(model: model, file: file)
            case .wardrobe:
                SidePanel(model: model, file: file)
            }
        }
    }
}

/// "Saved" flash in the header whenever the document autosaves to disk.
struct SaveBadge: View {
    let indicator: SaveIndicator
    let lightMode: Bool
    @State private var visible = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.icloud")
                .font(.system(size: 11, weight: .semibold))
            Text("Saved")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(lightMode ? Color(red: 0, green: 0.45, blue: 0.1) : Color.green)
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: visible)
        .onChange(of: indicator.count) { _, _ in
            visible = true
            hideTask?.cancel()
            hideTask = Task {
                try? await Task.sleep(for: .seconds(1.4))
                if !Task.isCancelled { visible = false }
            }
        }
    }
}

/// Per-track inspector — lives in each track's gutter-card popover
/// (and the iPhone wardrobe tab via SidePanel).
struct TrackInspector: View {
    @Bindable var model: StudioModel
    var file: ShowDocumentFile? = nil
    let kind: TrackRowKind

    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("name", text: nameBinding)
                .textFieldStyle(.plain)
                .font(.headline)
                .focused($nameFocused)
            switch kind {
            case .character(let i):
                MotionSection(model: model, characterIndex: i)
                MixSection(model: model, kind: kind)
                // The card's wardrobe edits the character's START state; timed
                // mid-show changes remain as recorded outfit events (white dots).
                WardrobePanel(model: model, characterIndex: i, baseOnly: true)
            case .audio:
                MixSection(model: model, kind: kind)
                Text("Drop an audio file onto the track to add a clip at the playhead.")
                    .font(.caption2).foregroundStyle(.secondary)
            case .image:
                ImageCueInspector(model: model)
                if let file {
                    AssetBankSection(model: model, file: file)
                }
            case .light(let i):
                LightCueInspector(model: model, trackIndex: i)
            case .background:
                if let file {
                    BackgroundPreview(model: model, file: file)
                }
                stageSection
                if let file {
                    AssetBankSection(model: model, file: file)
                }
            }

            if deletable {
                Spacer(minLength: 18)
                Button {
                    confirmDelete = true
                } label: {
                    Text(deleteTitle)
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.red.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .confirmationDialog(deleteTitle + "?", isPresented: $confirmDelete,
                                    titleVisibility: .visible) {
                    Button(deleteTitle, role: .destructive) {
                        model.removeTrack(kind)
                        model.selectedTrackKey = nil
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This removes the track and everything on it. Undo (⌘Z) brings it back.")
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { nameFocused = false }
    }

    private var deletable: Bool {
        if case .background = kind { return false }
        return true
    }

    private var deleteTitle: String {
        if case .character = kind { return "Delete character" }
        return "Delete track"
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: {
                switch kind {
                case .character(let i): return model.scene.characters[safe: i]?.name ?? ""
                case .audio(let i): return model.scene.audioTracks[safe: i]?.name ?? ""
                case .image(let i): return model.scene.imageTracks[safe: i]?.name ?? ""
                case .light(let i): return model.scene.lightTracks[safe: i]?.name ?? ""
                case .background(let i): return model.scene.backgroundTracks[safe: i]?.name ?? ""
                }
            },
            set: { name in
                switch kind {
                case .character(let i):
                    if model.scene.characters.indices.contains(i) { model.scene.characters[i].name = name }
                case .audio(let i):
                    if model.scene.audioTracks.indices.contains(i) { model.scene.audioTracks[i].name = name }
                case .image(let i):
                    if model.scene.imageTracks.indices.contains(i) { model.scene.imageTracks[i].name = name }
                case .light(let i):
                    if model.scene.lightTracks.indices.contains(i) { model.scene.lightTracks[i].name = name }
                case .background(let i):
                    if model.scene.backgroundTracks.indices.contains(i) { model.scene.backgroundTracks[i].name = name }
                }
            })
    }

    private var stageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("STAGE").font(.caption.bold()).foregroundStyle(.secondary)
            valueSlider("Character size", value: Binding(get: { model.scene.gSize },
                                                         set: { model.scene.gSize = $0 }),
                        range: 0.3...2.5)
            valueSlider("Depth", value: Binding(get: { model.scene.gScale },
                                                set: { model.scene.gScale = $0 }),
                        range: 0...1.2)
            valueSlider("Gravity", value: Binding(get: { model.scene.gravity },
                                                  set: { model.scene.gravity = $0 }),
                        range: 0.3...2.5)
            Text("Gravity affects walking, wobbling, and jumping.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func valueSlider(_ label: String, value: Binding<Double>,
                             range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).font(.caption2).frame(width: 88, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
    }
}

/// Each track's gutter card: a face (outfit mannequin / type icon) that opens
/// the track's inspector in a popover. Replaces the old right panel.
struct TrackCardButton: View {
    @Bindable var model: StudioModel
    var file: ShowDocumentFile? = nil
    let row: TrackRow
    var cardHeight: CGFloat = 54
    @AppStorage("studioLightMode") private var lightMode = false
    @State private var open = false

    var body: some View {
        Button {
            model.selectedTrackKey = row.key(in: model.scene)
            if case .character(let i) = row { model.selection = [i] }
            open = true
        } label: {
            face
        }
        .buttonStyle(.plain)
        .help("Track settings")
        .onChange(of: model.inspectorRequest) { _, req in
            if req == row.key(in: model.scene) {
                open = true
                model.inspectorRequest = nil
            }
        }
        .popover(isPresented: $open) {
            ScrollView {
                TrackInspector(model: model, file: file, kind: kind)
                    .padding(12)
            }
            .frame(width: 320, height: popoverHeight)
            .background(lightMode ? Color(red: 1, green: 0.99, blue: 0.95)
                                  : Color(red: 0.13, green: 0.13, blue: 0.16))
            .presentationBackground(lightMode ? Color(red: 1, green: 0.99, blue: 0.95)
                                              : Color(red: 0.13, green: 0.13, blue: 0.16))
            .environment(\.colorScheme, lightMode ? .light : .dark)
        }
    }

    private var popoverHeight: CGFloat {
        switch row {
        case .character: return 560
        case .background, .image: return 380
        case .audio: return 480
        case .light: return 220
        }
    }

    private var kind: TrackRowKind {
        switch row {
        case .character(let i): return .character(i)
        case .image(let i): return .image(i)
        case .audio(let i): return .audio(i)
        case .light(let i): return .light(i)
        case .background(let i): return .background(i)
        }
    }

    @ViewBuilder private var face: some View {
        switch row {
        case .background(let i):
            BackgroundFace(model: model, file: file, trackIndex: i)
        case .character(let i):
            if let c = model.scene.characters[safe: i] {
                OutfitCard(character: c)
                    .frame(width: (cardHeight * 30 / 54).rounded(), height: cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.primary.opacity(0.3), lineWidth: 1))
            }
        default:
            let style = faceStyle
            let side = max(16, min(28, cardHeight))
            Image(systemName: style.symbol)
                .font(.system(size: max(9, side * 0.45), weight: .semibold))
                .foregroundStyle(style.tint)
                .frame(width: side, height: side)
                .background(style.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(style.tint.opacity(0.45), lineWidth: 1))
        }
    }

    private var faceStyle: (symbol: String, tint: Color) {
        switch row {
        case .audio: return ("waveform", Color(red: 0.45, green: 0.9, blue: 0.75))
        case .image: return ("photo", Color(red: 0.9, green: 0.7, blue: 0.4))
        case .light: return ("sun.max", Color(red: 1, green: 0.85, blue: 0.35))
        case .background: return ("photo.on.rectangle", Color(red: 0.65, green: 0.6, blue: 0.95))
        case .character: return ("person", .orange)
        }
    }
}

/// Row-card face for the background track: the backdrops actually in use.
struct BackgroundFace: View {
    @Bindable var model: StudioModel
    var file: ShowDocumentFile?
    let trackIndex: Int
    @State private var thumbs = CueThumbCache()

    var body: some View {
        let ids = usedAssetIDs
        HStack(spacing: 2) {
            if ids.isEmpty {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.65, green: 0.6, blue: 0.95))
                    .frame(width: 28, height: 24)
            }
            ForEach(ids, id: \.self) { id in
                Group {
                    if let file, let img = thumbs.thumb(assetID: id, file: file) {
                        Image(decorative: img, scale: 1).resizable().scaledToFill()
                    } else {
                        Color.primary.opacity(0.15)
                    }
                }
                .frame(width: 26, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .stroke(Color(red: 0.65, green: 0.6, blue: 0.95).opacity(0.5), lineWidth: 1))
            }
        }
    }

    private var usedAssetIDs: [String] {
        guard let track = model.scene.backgroundTracks[safe: trackIndex] else { return [] }
        var seen: [String] = []
        for cue in track.cues where !seen.contains(cue.assetID) {
            seen.append(cue.assetID)
            if seen.count == 4 { break }
        }
        return seen
    }
}

/// iPhone wardrobe tab: the same inspector, panel-style.
struct SidePanel: View {
    @Bindable var model: StudioModel
    var file: ShowDocumentFile? = nil
    @AppStorage("studioLightMode") private var lightMode = false

    private var kind: TrackRowKind? {
        guard let key = model.selectedTrackKey else { return nil }
        for i in model.scene.characters.indices where "c-\(i)" == key { return .character(i) }
        for (i, t) in model.scene.audioTracks.enumerated() where t.id == key { return .audio(i) }
        for (i, t) in model.scene.imageTracks.enumerated() where t.id == key { return .image(i) }
        for (i, t) in model.scene.lightTracks.enumerated() where t.id == key { return .light(i) }
        for (i, t) in model.scene.backgroundTracks.enumerated() where t.id == key { return .background(i) }
        return nil
    }

    var body: some View {
        ScrollView {
            if let kind {
                TrackInspector(model: model, file: file, kind: kind)
                    .padding(10)
            } else {
                Text("Select a track to edit it here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(10)
            }
        }
        .background(lightMode ? Color(red: 1, green: 0.99, blue: 0.95)
                              : Color(red: 0.1, green: 0.1, blue: 0.13))
        .environment(\.colorScheme, lightMode ? .light : .dark)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
