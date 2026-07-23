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
    @AppStorage("contextSmartBarVisible") private var contextSmartBarVisible = false
    @Environment(\.undoManager) private var undoManager
    private var theme: Theme { lightMode ? .light : .dark }
    @State private var dividerDragBase: Double?
    @State private var drawer: WorkspaceDrawerMode? = {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "debugWorkspaceDrawer")
            .flatMap(WorkspaceDrawerMode.init(rawValue:))
        #else
        return nil
        #endif
    }()

    private let headerH = 44.0

    var body: some View {
        GeometryReader { geo in
            // Stage never letterboxes vertically: it takes exactly its aspect
            // height for the available width, and the timeline absorbs all
            // remaining space.
            let availH = Double(geo.size.height) - headerH
            let stageWidth = Double(max(200, geo.size.width))
            let requestedTL = min(max(0, timelineHeight), availH - 9)
            // Below ~24pt the timeline snaps away entirely and the stage keeps
            // the whole area (letterboxed once it hits its aspect width limit).
            let wantTL = requestedTL < 24 ? 0.0 : requestedTL
            let rawStage = min(stageWidth / model.frameAspect, availH - 9 - wantTL)
            // Below ~44pt the stage snaps away too — timeline-only editing.
            let stageH = rawStage < 44 ? 0.0 : rawStage
            let tlH = wantTL == 0 ? 0.0 : max(0, availH - 9 - stageH)
            let stageBoxH = availH - 9 - tlH
            VStack(spacing: 0) {
                header
                ZStack(alignment: .trailing) {
                    StageView(model: model, file: file)
                        .frame(width: CGFloat(stageWidth), height: CGFloat(stageBoxH))
                        .background(Color.black)
                        .overlay(alignment: .bottom) {
                            if showDeck {
                                PerformanceDeck(model: model)
                            } else if !model.recording {
                                if contextSmartBarVisible {
                                    ContextSmartBar(
                                        model: model,
                                        drawer: $drawer,
                                        onDismiss: hideQuickControls)
                                        .padding(.bottom, 12)
                                        .transition(.move(edge: .bottom).combined(with: .opacity))
                                } else if model.selectedTrackKind != nil {
                                    Button(action: showQuickControls) {
                                        Image(systemName: "slider.horizontal.3")
                                            .font(.system(size: 11, weight: .semibold))
                                            .frame(width: 28, height: 26)
                                            .background(.ultraThinMaterial, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Show quick controls")
                                    .accessibilityLabel("Show quick controls")
                                    .accessibilityIdentifier("smart-bar-show")
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .padding(.trailing, 12)
                                    .padding(.bottom, 12)
                                    .transition(.opacity)
                                }
                            }
                        }
                        .overlay(alignment: .top) {
                            if model.recording {
                                RecordingHUD(model: model)
                                    .padding(.top, 12)
                            }
                        }

                    if drawer != nil {
                        WorkspaceDrawer(model: model, file: file, mode: $drawer)
                            .frame(width: min(350, max(300, geo.size.width * 0.32)),
                                   height: CGFloat(stageBoxH))
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(width: CGFloat(stageWidth), height: CGFloat(stageBoxH))
                .clipped()
                divider(maxHeight: availH - 9)
                StudioTimelineView(model: model, file: file, showShip: false,
                                   showTransport: false,
                                   onInspectTrack: { row in openInspector(for: row) })
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
        HStack(spacing: 10) {
            Image(lightMode ? "HeaderLogo" : "HeaderLogoDark")
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                // Dark variant carries a 7px outline outside the glyphs; scale
                // so the BLACK eyes render at the same size in both themes.
                .frame(height: lightMode ? 17 : 19)
            Text("BANNY STUDIO")
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .kerning(1.2)
                // Match the logo art: black in light mode, off-white in dark.
                .foregroundStyle(lightMode ? Color.black
                                           : Color(red: 0.92, green: 0.92, blue: 0.92))
            Divider().frame(height: 18)
            ProjectMenu(model: model, file: file)
            Spacer(minLength: 8)
            WorkspaceUndoButtons(undoManager: undoManager)
            WorkspaceTransport(model: model)
            Spacer(minLength: 8)
            SaveBadge(indicator: file.saveIndicator, lightMode: lightMode)
            WorkspacePanelButton(title: "Browse", systemImage: "square.grid.2x2",
                                 active: drawer == .browse,
                                 accessibilityID: "workspace-browse") {
                toggleDrawer(.browse)
            }
            WorkspacePanelButton(title: "Inspect", systemImage: "slider.horizontal.3",
                                 active: drawer == .inspect,
                                 accessibilityID: "workspace-inspect") {
                toggleDrawer(.inspect)
            }
            ShipButton(model: model, file: file, compact: true)
            ThemeToggle()
        }
        .padding(.horizontal, 12)
        .frame(height: CGFloat(headerH))
        .background(theme.header)
    }

    private func toggleDrawer(_ requested: WorkspaceDrawerMode) {
        withAnimation(.easeInOut(duration: 0.18)) {
            drawer = drawer == requested ? nil : requested
        }
    }

    private func hideQuickControls() {
        withAnimation(.easeInOut(duration: 0.18)) {
            contextSmartBarVisible = false
        }
    }

    private func showQuickControls() {
        withAnimation(.easeInOut(duration: 0.18)) {
            contextSmartBarVisible = true
        }
    }

    private func openInspector(for row: TrackRow) {
        model.selectedTrackKey = row.key(in: model.scene)
        if case .character(let index) = row { model.selection = [index] }
        withAnimation(.easeInOut(duration: 0.18)) { drawer = .inspect }
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
        case inspect = "Inspect"
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
            case .inspect:
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

/// Complete per-track inspector. The wide workspace hosts it in the shared
/// on-demand drawer; compact layouts and legacy callers can still present it.
struct TrackInspector: View {
    @Bindable var model: StudioModel
    var file: ShowDocumentFile? = nil
    let kind: TrackRowKind

    @State private var confirmDelete = false
    @State private var exportFile: BannyTrackFile?
    @State private var exportFilename = "track.bannytrack"
    @State private var exporting = false
    @State private var exportError: String?
    @State private var dialogueExpanded = true
    @State private var reactionsExpanded = false
    @State private var mixExpanded = false
    @State private var advancedExpanded = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField(namePrompt, text: nameBinding)
                .textFieldStyle(.plain)
                .font(.headline)
                .focused($nameFocused)
                .accessibilityLabel("Track name")
                .disabled(isLocked)
            trackSafetyControls
            Group {
                switch kind {
            case .character(let i):
                MotionSection(model: model, characterIndex: i)
                Divider()
                DisclosureGroup(isExpanded: $dialogueExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        ScriptSection(model: model, characterIndex: i)
                        Divider()
                        VoiceSection(model: model, characterIndex: i)
                        if let file {
                            Divider()
                            AudioSection(model: model, file: file, characterIndex: i)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Label("DIALOGUE & VOICE", systemImage: "text.bubble")
                        .font(.caption.bold()).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("dialogue-disclosure")

                // The card's wardrobe edits the character's START state; timed
                // mid-show changes remain as recorded outfit events (white dots).
                WardrobePanel(model: model, characterIndex: i, baseOnly: true)
                Divider()
                DisclosureGroup(isExpanded: $reactionsExpanded) {
                    ReactionLibrarySection(model: model, characterIndex: i)
                        .padding(.top, 8)
                } label: {
                    Label("REACTIONS", systemImage: "sparkles")
                        .font(.caption.bold()).foregroundStyle(.secondary)
                }
                Divider()
                DisclosureGroup(isExpanded: $mixExpanded) {
                    MixSection(model: model, kind: kind)
                        .padding(.top, 8)
                } label: {
                    Label("AUDIO MIX", systemImage: "dial.medium")
                        .font(.caption.bold()).foregroundStyle(.secondary)
                }
                Divider()
                DisclosureGroup(isExpanded: $advancedExpanded) {
                    AdvancedJSONSection(model: model, file: file, characterIndex: i)
                        .padding(.top, 8)
                } label: {
                    Label("ADVANCED", systemImage: "curlybraces")
                        .font(.caption.bold()).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("advanced-disclosure")
            case .audio(let i):
                MixSection(model: model, kind: kind)
                if let file {
                    AudioSection(model: model, file: file, audioTrackIndex: i)
                    VisualMediaSection(model: model, trackIndex: i)
                }
                if model.selectedImageCueOwner?.trackID == model.scene.audioTracks[safe: i]?.id {
                    ImageCueInspector(model: model)
                }
                Text("Drop audio, image, GIF, or video onto this media track, or click an empty spot to import.")
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
                FrameSection(model: model)
                CameraSection(model: model)
                stageSection
                BackdropGallerySection(model: model)
                if let file {
                    AssetBankSection(model: model, file: file)
                }
            }
            }
            .disabled(isLocked)

            if file != nil {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Button {
                        prepareTrackExport()
                    } label: {
                        Label(exportTitle, systemImage: "square.and.arrow.up")
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(Color.primary.opacity(0.07),
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    Text("Includes its settings, timeline content, and linked media.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
                .disabled(isLocked || file?.isMicRecording == true)
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
        .fileExporter(isPresented: $exporting, document: exportFile,
                      contentType: .bannyTrack, defaultFilename: exportFilename) { result in
            if case .failure(let error) = result,
               (error as NSError).code != NSUserCancelledError {
                exportError = error.localizedDescription
            }
            exportFile = nil
        }
        .alert("Export failed", isPresented: .init(get: { exportError != nil },
                                                    set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var isLocked: Bool { model.isTrackLocked(kind) }

    @ViewBuilder
    private var trackSafetyControls: some View {
        HStack(spacing: 8) {
            Button {
                model.toggleTrackLock(kind)
            } label: {
                Label(isLocked ? "Unlock" : "Lock",
                      systemImage: isLocked ? "lock.fill" : "lock.open")
                    .font(.caption.bold())
            }
            .buttonStyle(.bordered)
            .tint(isLocked ? .orange : nil)
            .disabled(model.recording || file?.micRecorder.isRecording == true)

            switch kind {
            case .character, .audio:
                Button {
                    model.toggleTrackSolo(kind)
                } label: {
                    Label(model.isTrackSoloed(kind) ? "Soloed" : "Solo",
                          systemImage: model.isTrackSoloed(kind)
                            ? "speaker.wave.2.circle.fill" : "speaker.wave.2.circle")
                        .font(.caption.bold())
                }
                .buttonStyle(.bordered)
                .tint(model.isTrackSoloed(kind) ? .yellow : nil)
            default:
                EmptyView()
            }
            Spacer()
        }
        if isLocked {
            Text("Protected from timeline, stage, inspector, and recording edits.")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    private var exportTitle: String {
        if case .character = kind { return "Export character…" }
        return "Export track…"
    }

    private func prepareTrackExport() {
        do {
            let track = try model.portableTrack(for: kind)
            let unsafe = track.payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = String((unsafe.isEmpty ? track.payload.kind.rawValue : unsafe).map { character in
                "/:\n\r".contains(character) ? "-" : character
            })
            exportFilename = base + ".bannytrack"
            exportFile = BannyTrackFile(track: track)
            exporting = true
        } catch {
            exportError = error.localizedDescription
        }
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

    private var namePrompt: String {
        switch kind {
        case .character(let index): return "Banny \((index + 1) % 10)"
        case .audio: return "Media"
        case .image: return "Visual"
        case .light: return "Light"
        case .background: return "Scenes"
        }
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
    var onInspect: ((TrackRow) -> Void)?
    @AppStorage("studioLightMode") private var lightMode = false
    @State private var open = false

    var body: some View {
        Button {
            model.selectedTrackKey = row.key(in: model.scene)
            if case .character(let i) = row { model.selection = [i] }
            if let onInspect { onInspect(row) } else { open = true }
        } label: {
            face
        }
        .buttonStyle(.plain)
        .help("Track settings")
        .accessibilityIdentifier("track-card-\(row.key(in: model.scene))")
        .onChange(of: model.inspectorRequest) { _, req in
            if req == row.key(in: model.scene) {
                if let onInspect { onInspect(row) } else { open = true }
                model.inspectorRequest = nil
            }
        }
        .popover(isPresented: Binding(
            get: { onInspect == nil && open },
            set: { open = $0 })) {
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
        case .character: return 640
        case .background: return 560
        case .image: return 380
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

    var body: some View {
        ScrollView {
            if let kind = model.selectedTrackKind {
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
