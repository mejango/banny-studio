import SwiftUI
import BannyCore
#if os(macOS)
import AppKit
#endif

/// Group colors from the web perfColor palette.
extension EventGroup {
    var color: Color {
        switch self {
        case .move: return Color(red: 0.29, green: 0.62, blue: 1)      // #4a9eff
        case .depth: return Color(red: 1, green: 0.35, blue: 0.35)     // #ff5a5a
        case .tilt: return Color(red: 0.27, green: 0.85, blue: 0.27)   // #46d846
        case .talk: return Color(red: 1, green: 0.88, blue: 0.29)      // #ffe14a
        case .blink: return Color(red: 1, green: 0.60, blue: 0.24)     // #ff9a3c
        case .jump: return Color(red: 0.71, green: 0.49, blue: 1)      // #b57cff
        }
    }

    var laneIndex: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// Deeper variants that stay visible on the light theme's surfaces.
    func color(light: Bool) -> Color {
        guard light else { return color }
        switch self {
        case .move: return Color(red: 0.13, green: 0.4, blue: 0.85)
        case .depth: return Color(red: 0.8, green: 0.2, blue: 0.2)
        case .tilt: return Color(red: 0.1, green: 0.58, blue: 0.22)
        case .talk: return Color(red: 0.85, green: 0.64, blue: 0.07)
        case .blink: return Color(red: 0.82, green: 0.45, blue: 0.08)
        case .jump: return Color(red: 0.63, green: 0.47, blue: 0.93)
        }
    }
}

/// A held segment of one code on the timeline, derived from down/up event pairs.
struct PerfMark: Identifiable, Equatable, Hashable {
    var id: String { "\(character)-\(code.rawValue)-\(start)" }
    var character: Int
    var code: EventCode
    var start: Double
    var end: Double
}

enum TimelineMath {
    /// Pair down/up events into drawable held segments (web perfMarks).
    static func marks(for events: [PerfEvent], character: Int, duration: Double) -> [PerfMark] {
        var open: [EventCode: Double] = [:]
        var out: [PerfMark] = []
        for ev in events {
            guard case .key(let t, let code, let down) = ev else { continue }
            if down {
                if open[code] == nil { open[code] = t }
            } else if let s = open.removeValue(forKey: code) {
                out.append(PerfMark(character: character, code: code, start: s, end: max(t, s + 0.04)))
            }
        }
        for (code, s) in open {
            out.append(PerfMark(character: character, code: code, start: s, end: duration))
        }
        return out.sorted { $0.start < $1.start }
    }

    static func removeMarks(_ marks: Set<PerfMark>, from events: [PerfEvent]) -> [PerfEvent] {
        events.filter { ev in
            guard case .key(let t, let code, _) = ev else { return true }
            return !marks.contains { m in
                m.code == code && t >= m.start - 1e-6 && t <= m.end + 1e-6
            }
        }
    }

    /// Resize one mark edge: move its down (leading) or up (trailing) event to newT.
    static func resizeMark(_ mark: PerfMark, leading: Bool, to newT: Double,
                           in events: [PerfEvent]) -> [PerfEvent] {
        var out = events
        for (i, ev) in out.enumerated() {
            guard case .key(let t, let code, let down) = ev, code == mark.code else { continue }
            if leading, down, abs(t - mark.start) < 1e-6 {
                out[i] = .key(t: min(max(0, newT), mark.end - 0.04), code: code, down: true)
            } else if !leading, !down, abs(t - mark.end) < 1e-6 {
                out[i] = .key(t: max(newT, mark.start + 0.04), code: code, down: false)
            }
        }
        out.sort { $0.t < $1.t }
        return out
    }

    static func shiftMarks(_ marks: Set<PerfMark>, in events: [PerfEvent], by dt: Double) -> [PerfEvent] {
        var shifted = events.map { ev -> PerfEvent in
            guard case .key(let t, let code, let down) = ev else { return ev }
            let hit = marks.contains { m in
                m.code == code && t >= m.start - 1e-6 && t <= m.end + 1e-6
            }
            guard hit else { return ev }
            return .key(t: max(0, ((t + dt) * 1000).rounded() / 1000), code: code, down: down)
        }
        shifted.sort { $0.t < $1.t }
        return shifted
    }
}

/// One timeline row = one track (character / image / audio / background).
enum TrackRow: Equatable {
    case character(Int)
    case image(Int)
    case audio(Int)
    case light(Int)
    case background(Int)

    /// Stable identity for per-track height storage.
    func key(in scene: SceneState) -> String {
        switch self {
        case .character(let i): return "c-\(i)"
        case .image(let i): return scene.imageTracks[safe: i]?.id ?? "i-\(i)"
        case .audio(let i): return scene.audioTracks[safe: i]?.id ?? "a-\(i)"
        case .light(let i): return scene.lightTracks[safe: i]?.id ?? "l-\(i)"
        case .background(let i): return scene.backgroundTracks[safe: i]?.id ?? "b-\(i)"
        }
    }
}

/// The timeline panel: ruler + scrub, SHOW crop bar, one resizable lane per track.
/// Lane bottom edges (in the label column) drag to resize a single track.
struct StudioTimelineView: View {
    @Bindable var model: StudioModel
    var file: ShowDocumentFile? = nil
    var showShip = true
    @AppStorage("studioLightMode") private var lightMode = false
    private var theme: Theme { lightMode ? .light : .dark }
    @State private var zoom: Double = 1
    @State private var dragStartMarks: [Int: [PerfEvent]]?
    @State private var resizing: (mark: PerfMark, leading: Bool, baseEvents: [PerfEvent])?
    @State private var draggingClip: (id: String, baseStart: Double, baseDur: Double,
                                      baseOffset: Double, srcDur: Double, edge: Int)?
    @State private var draggingCue: (row: TrackRow, cueID: String, baseStart: Double, baseDur: Double, edge: Int)?
    @State private var draggingSub: (char: Int, index: Int, baseStart: Double, baseDur: Double, edge: Int)?
    /// Export-range drag: edge -1/1 = a marker, 0 = slide the range, 2 = drag out a new one.
    @State private var draggingExport: (edge: Int, baseFrom: Double, baseTo: Double)?
    @State private var exportRangeSelected = false
    @State private var draggingPresence: (row: TrackRow, index: Int)?
    @State private var selectedPresence: (rowKey: String, index: Int)?
    @State private var lastTap: (location: CGPoint, at: Date)?
    @State private var resizingTrack: (key: String, baseHeight: CGFloat, minHeight: CGFloat)?
    @State private var draggingRow: (row: TrackRow, currentY: CGFloat)?
    /// Preview slot (within the dragged row's group) while a row drag is live.
    @State private var dragPreviewIndex: Int?
    /// Which track's settings popover is open (row key).
    @State private var peakCache = PeakCache()
    /// Per-track lane heights (session-scoped), keyed by TrackRow.key.
    @State private var trackHeights: [String: CGFloat] = [:]

    /// In-place label editing over the canvas.
    enum LabelKind { case clip, cue, caption }
    @State private var editingLabel: (kind: LabelKind, id: String, origin: CGPoint)?
    @State private var editingText = ""
    @FocusState private var labelFocused: Bool
    @State private var cueThumbs = CueThumbCache()

    /// Label gutter width — draggable at its right edge.
    @AppStorage("laneLabelWidth") private var laneLabelWidthStore: Double = 110
    private var laneLabelWidth: CGFloat { CGFloat(laneLabelWidthStore) }
    @State private var resizingGutter = false
    @State private var scrubZoomBase: Double?
    @State private var pinchZoomBase: Double?
    /// Locked once at pinch start: anchored time, its view-x, and the vertical
    /// scroll fraction. Recomputing these per tick from lagging preference
    /// values fed an oscillation (the "shake" while zooming).
    @State private var pinchAnchor: (t: Double, vx: CGFloat, fy: CGFloat)?
    @State private var lastGutterTap: (key: String, at: Date)?
    @State private var renamingRow: TrackRow?
    @State private var hoverGutterRow: TrackRow?
    /// Double-clicked audio clip: per-clip mix override editor.
    @State private var clipMix: (kind: TrackRowKind, clipID: String, x: CGFloat, y: CGFloat)?
    /// Rubber-band selection over empty lane space.
    @State private var marquee: (start: CGPoint, current: CGPoint)?
    /// Edge auto-scroll while dragging: px past the viewport edge (sign = side).
    @State private var dragOvershootX: CGFloat = 0
    @State private var autoScrollTimer: Timer?
    /// Anchor a drag is currently snapped to (draws a guide line).
    @State private var snapGuide: Double?
    /// Group-drag base positions for selected clips.
    @State private var dragStartClips: [String: Double]?
    /// Pointer position over the lanes (content coords) for context menus.
    @State private var hoverLanePoint: CGPoint?
    /// Click/double-click on an empty audio-track spot → import a file there.
    @State private var audioImportAt: (trackIndex: Int, t: Double)?
    /// Wardrobe-strip click: add a timed outfit change here.
    @State private var outfitPopover: (char: Int, t: Double, x: CGFloat, y: CGFloat)?
    @State private var renamingText = ""
    @FocusState private var renameFocused: Bool
    @State private var editorOpenedAt = Date.distantPast
    /// Lanes viewport scroll offset. An observable holder (not view @State) so
    /// scrolling re-renders ONLY the pinned overlays that read it — the heavy
    /// lanes canvas is untouched by scroll ticks.
    @State private var offsets = TLOffsets()
    @State private var tlProxy: ScrollViewProxy?
    @State private var tlViewport: CGSize = .zero
    private var scrollOffset: CGPoint { CGPoint(x: offsets.x, y: offsets.y) }
    private let rulerHeight: CGFloat = 30
    private let scrubHeight: CGFloat = 0
    private let defaultLaneHeight: CGFloat = 52

    var body: some View {
        VStack(spacing: 0) {
            TransportBar(model: model, file: showShip ? file : nil)
            VStack(spacing: 0) {
            HStack(spacing: 0) {
                cornerCell
                headerBand
            }
            .frame(height: lanesTop)
            ZStack(alignment: .topLeading) {
            ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        GeometryReader { geo in
                            Color.clear.preference(key: TLOffsetKey.self,
                                                   value: geo.frame(in: .named("tlScroll")).origin)
                        }
                        timelineCanvas
                        popoverAnchors
                        if let editing = editingLabel, editing.kind != .caption {
                            TextField("", text: $editingText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3)
                                .frame(width: 110)
                                .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                                .focused($labelFocused)
                                .onSubmit { commitLabelEdit() }
                                #if os(macOS)
                                .onExitCommand { editingLabel = nil }
                                #endif
                                .offset(x: editing.origin.x, y: editing.origin.y)
                                .onAppear { labelFocused = true }
                                .onChange(of: labelFocused) { _, focused in
                                    if !focused { commitLabelEdit() }
                                }
                        }
                    }
                    .padding(.leading, laneLabelWidth)
                }
                .frame(width: laneLabelWidth + max(600, contentWidth + 40),
                       height: totalLaneHeight + 34, alignment: .topLeading)
                .id("tlContent")
                // On the outer frame, NOT the canvas: dropDestination inside the
                // measured ZStack corrupts the scroll-offset GeometryReader
                // preference (band/gutter stop tracking native scrolls).
                .dropDestination(for: URL.self) { urls, location in
                    handleFileDrop(urls: urls,
                                   location: CGPoint(x: location.x - laneLabelWidth, y: location.y))
                }
            }
            .contentMargins(.leading, laneLabelWidth, for: .scrollIndicators)
            .coordinateSpace(name: "tlScroll")
            .onPreferenceChange(TLOffsetKey.self) { [offsets] origin in
                // origin.x includes the leading gutter padding at rest.
                offsets.x = laneLabelWidth - origin.x
                offsets.y = -origin.y
            }
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { tlViewport = g.size; tlProxy = proxy }
                    .onChange(of: g.size) { _, s in tlViewport = s }
            })
            }
            // Pinned gutter: never moves horizontally; tracks vertical scroll.
            ZStack(alignment: .topLeading) {
                GutterWheelRedirect(gutterWidth: laneLabelWidth)
                gutterCanvas
                // Every track's card: face + popover inspector (the old right panel).
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let isCharacter: Bool = { if case .character = row { return true }; return false }()
                    let mismatch: Bool = {
                        if case .character(let ci) = row {
                            return model.startPoseMismatch(characterIndex: ci)
                        }
                        return false
                    }()
                    // The button's reserved strip doesn't feed the card's size.
                    let available = height(of: row) - presenceStripH - 16 - (mismatch ? 26 : 0)
                    let cardH = isCharacter ? min(available, 160) : min(26, available)
                    if isCharacter ? available >= 26 : available >= 14 {
                        TrackCardButton(model: model, file: file, row: row, cardHeight: cardH)
                            .offset(x: 10, y: laneTop(of: row) + presenceStripH + 4 - scrollOffset.y)
                    }
                    if case .character(let ci) = row, mismatch,
                       let c = model.scene.characters[safe: ci] {
                        let lines = CGFloat(3 + mixReadout(c.trackFx).count)
                        Button("Set start position") { model.commitStartPose(characterIndex: ci) }
                            .buttonStyle(.plain)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                            .overlay(Capsule().stroke(Color.orange.opacity(0.55), lineWidth: 1))
                            .help("The character isn't at its saved start — save where it stands now")
                            .offset(x: 12 + (cardH * 30 / 54).rounded() + 10,
                                    y: laneTop(of: row) + presenceStripH + 13 + 13 * lines + 2
                                        - scrollOffset.y)
                    }
                }
                if let row = renamingRow {
                    TextField("name", text: $renamingText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .frame(width: laneLabelWidth - 44)
                        .background(theme.gutterBase, in: RoundedRectangle(cornerRadius: 3))
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.orange.opacity(0.7), lineWidth: 1))
                        .focused($renameFocused)
                        .onSubmit { commitRename() }
                        .onAppear { renameFocused = true }
                        .onChange(of: renameFocused) { _, f in if !f { commitRename() } }
                        .offset(x: 8, y: laneTop(of: row) + 1 - scrollOffset.y)
                }
                newTrackRow
                    .offset(y: totalLaneHeight - scrollOffset.y)
            }
            .frame(width: laneLabelWidth)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            }
            }
            // ONE playhead line across the band and the lanes — a single view,
            // so it cannot misalign with itself.
            .overlay(alignment: .topLeading) {
                let px = laneLabelWidth + x(forTime: model.time) - scrollOffset.x
                Rectangle()
                    .fill(theme.playhead)
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
                    .offset(x: px - 0.75)
                    .opacity(px >= laneLabelWidth ? 1 : 0)
                    .allowsHitTesting(false)
            }
        }
        .background(theme.surface)
        .onChange(of: neededGutterWidth) { _, needed in
            if needed > laneLabelWidthStore {
                laneLabelWidthStore = min(300, needed)
            }
        }
        .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { g in
                        let base = pinchZoomBase ?? zoom
                        pinchZoomBase = base
                        if pinchAnchor == nil {
                            // The time under the pointer stays put while zooming.
                            let vx = g.startLocation.x
                            let contentH = totalLaneHeight + 34
                            let fy = min(1, max(0, offsets.y / max(1, contentH - tlViewport.height)))
                            pinchAnchor = (time(forX: vx - laneLabelWidth + scrollOffset.x), vx, fy)
                        }
                        var tr = Transaction()
                        tr.disablesAnimations = true
                        withTransaction(tr) {
                            zoom = min(16, max(0.25, base * g.magnification))
                            if let p = pinchAnchor { keepTime(p.t, atViewX: p.vx, fy: p.fy) }
                        }
                    }
                    .onEnded { _ in
                        pinchZoomBase = nil
                        pinchAnchor = nil
                    })
        .fileImporter(isPresented: Binding(get: { audioImportAt != nil },
                                           set: { if !$0 { audioImportAt = nil } }),
                      allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav]) { result in
            if case .success(let url) = result, let target = audioImportAt {
                model.addAudioClip(from: url, characterIndex: nil,
                                   audioTrackIndex: target.trackIndex, at: target.t)
            }
            audioImportAt = nil
        }
        .onChange(of: model.timelineDeleteRequest) { _, _ in deleteSelection() }
        #if os(macOS)
        .onDeleteCommand { deleteSelection() }
        #else
        .toolbar {
            if !model.selectedMarks.isEmpty || !model.selectedClips.isEmpty {
                Button("Delete", role: .destructive) { deleteSelection() }
            }
        }
        #endif
    }

    // MARK: - Layout

    private var baseRows: [TrackRow] {
        let typed = model.scene.characters.indices.map(TrackRow.character)
            + model.scene.imageTracks.indices.map(TrackRow.image)
            + model.scene.audioTracks.indices.map(TrackRow.audio)
            + model.scene.lightTracks.indices.map(TrackRow.light)
            + model.scene.backgroundTracks.indices.map(TrackRow.background)
        guard !model.scene.rowOrder.isEmpty else { return typed }
        let keyed = Dictionary(typed.map { ($0.key(in: model.scene), $0) },
                               uniquingKeysWith: { a, _ in a })
        var out = model.scene.rowOrder.compactMap { keyed[$0] }
        for r in typed where !out.contains(r) { out.append(r) }
        return out
    }

    /// Rows in display order; while dragging, the dragged row previews at its slot.
    private var rows: [TrackRow] {
        guard let dragging = draggingRow, let preview = dragPreviewIndex else { return baseRows }
        var out = baseRows
        guard let from = out.firstIndex(of: dragging.row) else { return out }
        out.remove(at: from)
        out.insert(dragging.row, at: min(max(preview, 0), out.count))
        return out
    }

    /// The preview slot (across ALL rows) under the cursor's content y.
    private func previewSlot(for dragging: (row: TrackRow, currentY: CGFloat)) -> Int {
        var yCursor: CGFloat = 0
        for (slot, r) in rows.enumerated() {
            let h = height(of: r)
            if dragging.currentY < yCursor + h { return slot }
            yCursor += h
        }
        return max(0, rows.count - 1)
    }

    private var headerHeight: CGFloat { rulerHeight + scrubHeight }
    /// Export range row: bracket markers bound what ships.
    private let exportRowH: CGFloat = 18
    private var captionsTop: CGFloat { exportRowH }
    /// Global closed-caption strip: right under the export row.
    private let captionsRowH: CGFloat = 22
    private var rulerTop: CGFloat { exportRowH + captionsRowH }
    private var lanesTop: CGFloat { rulerTop + rulerHeight }

    private func minHeight(of row: TrackRow) -> CGFloat {
        if case .character = row { return 64 }   // presence + audio + 7 event rows
        return 44
    }

    private func height(of row: TrackRow) -> CGFloat {
        var h = baseHeight(of: row) + rowStretch
        // Room for the "Set start position" button when it's showing — grow
        // enough that every readout line stays visible above it.
        if case .character(let ci) = row, model.startPoseMismatch(characterIndex: ci),
           let c = model.scene.characters[safe: ci] {
            let lineCount = CGFloat(3 + mixReadout(c.trackFx).count)
            let needed = presenceStripH + 13 + 13 * lineCount + 32 + wardrobeStripH
            h = max(h + 26, needed)
        }
        return h
    }

    private func baseHeight(of row: TrackRow) -> CGFloat {
        let base: CGFloat
        if case .character = row { base = 72 } else { base = defaultLaneHeight }
        return max(minHeight(of: row), trackHeights[row.key(in: model.scene)] ?? base)
    }

    /// Extra per-row height when the lanes viewport is taller than the tracks:
    /// rows stretch to fill instead of leaving dead space below New track.
    private var rowStretch: CGFloat {
        guard tlViewport.height > 0, !rows.isEmpty else { return 0 }
        let base = rows.reduce(0) { $0 + baseHeight(of: $1) }
        return max(0, (tlViewport.height - 34 - base) / CGFloat(rows.count))
    }

    private var totalLaneHeight: CGFloat {
        rows.reduce(0) { $0 + height(of: $1) }
    }

    /// Gutter width needed so the outfit card plus its readouts fit; the
    /// gutter auto-expands (never shrinks) to this when rows grow tall.
    private var neededGutterWidth: Double {
        var need = 0.0
        for row in rows {
            guard case .character = row else { continue }
            let available = height(of: row) - presenceStripH - 16
            guard available >= 26 else { continue }
            let cardW = (min(available, 160) * 30 / 54).rounded()
            need = max(need, Double(12 + cardW + 10 + 74))
        }
        return need
    }

    private func laneTop(of row: TrackRow) -> CGFloat {
        var y: CGFloat = 0
        for r in rows {
            if r == row { return y }
            y += height(of: r)
        }
        return y
    }

    /// Finder file dropped on the lanes: import to the bank, cue it where it
    /// landed — image tracks get an image cue, the Background row (or a video
    /// anywhere) gets a background cue, an image anywhere else gets a new track.
    private func handleFileDrop(urls: [URL], location: CGPoint) -> Bool {
        guard let url = urls.first else { return false }
        let t = max(0, (time(forX: location.x) * 10).rounded() / 10)
        // Audio files land as clips, not bank assets.
        if ["mp3", "m4a", "wav", "aac", "aif", "aiff", "caf"].contains(url.pathExtension.lowercased()) {
            switch row(at: location.y) {
            case .audio(let i):
                model.addAudioClip(from: url, characterIndex: nil, audioTrackIndex: i, at: t)
            case .character(let i):
                model.addAudioClip(from: url, characterIndex: i, audioTrackIndex: nil, at: t)
            default:
                return false
            }
            return true
        }
        guard let asset = model.addAsset(from: url) else { return false }
        switch row(at: location.y) {
        case .image(let i) where asset.kind == .image:
            model.addImageCue(trackIndex: i, assetID: asset.id, at: t)
        case .background, .some where asset.kind == .video, nil where asset.kind == .video:
            model.addBackgroundCue(assetID: asset.id, assetName: asset.name, at: t)
        default:
            model.addImageTrack(assetID: asset.id, assetName: asset.name)
        }
        return true
    }

    /// An empty spot on a character lane's wardrobe strip (bottom band).
    private func wardrobeSlot(at point: CGPoint) -> (char: Int, t: Double, x: CGFloat, y: CGFloat)? {
        guard let row = row(at: point.y), case .character(let ci) = row,
              model.scene.characters.indices.contains(ci) else { return nil }
        let bandTop = laneTop(of: row) + height(of: row) - wardrobeStripH
        guard point.y >= bandTop - 2 else { return nil }
        let t = (time(forX: point.x) * 10).rounded() / 10
        return (ci, t, point.x, bandTop + wardrobeStripH / 2)
    }

    /// The outfit-change dot near a click, if any.
    private func outfitEvent(at point: CGPoint) -> (char: Int, index: Int)? {
        guard let row = row(at: point.y), case .character(let ci) = row,
              model.scene.characters.indices.contains(ci) else { return nil }
        let cy = laneTop(of: row) + height(of: row) - wardrobeStripH / 2
        guard abs(point.y - cy) < 9 else { return nil }
        for (i, ev) in model.scene.characters[ci].events.enumerated() {
            guard case .outfit(let t, _, _) = ev else { continue }
            if abs(x(forTime: t) - point.x) < 7 { return (ci, i) }
        }
        return nil
    }

    private func row(at y: CGFloat) -> TrackRow? {
        var top: CGFloat = 0
        for r in rows {
            let h = height(of: r)
            if y >= top && y < top + h { return r }
            top += h
        }
        return nil
    }

    private var pxPerSecond: CGFloat { 30 * zoom }
    private var contentWidth: CGFloat { CGFloat(model.duration) * pxPerSecond }
    private func x(forTime t: Double) -> CGFloat { 1 + CGFloat(t) * pxPerSecond }
    private func time(forX x: CGFloat) -> Double { max(0, Double((x - 1) / pxPerSecond)) }

    /// Programmatic scroll so `t` lands at view-x `vx` (zoom anchoring). Goes
    /// through ScrollViewProxy — writing the NSScrollView's bounds directly
    /// desyncs SwiftUI's own scroll bookkeeping (band/gutter stop tracking).
    private func keepTime(_ t: Double, atViewX vx: CGFloat, fy: CGFloat) {
        guard let proxy = tlProxy, tlViewport.width > 0 else { return }
        let contentW = laneLabelWidth + max(600, contentWidth + 40)
        let maxScroll = max(0, contentW - tlViewport.width)
        // Whole device pixels: subpixel scroll positions shimmer the canvas.
        // Clamp to what the scroll view can actually reach — recording an
        // unreachable target desyncs the pinned band until the next scroll.
        let target = min(maxScroll, (max(0, x(forTime: t) - (vx - laneLabelWidth)) * 2).rounded() / 2)
        let fx = maxScroll > 0 ? target / maxScroll : 0
        proxy.scrollTo("tlContent", anchor: UnitPoint(x: fx, y: fy))
        offsets.x = target
    }

    /// Fixed top-left corner of the pinned band.
    private var cornerCell: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(theme.gutterBase))
            // Same band colors as the rows to the right — the column boundary
            // reads from color continuity, not a drawn line.
            ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: exportRowH)),
                     with: .color(theme.ccRow.opacity(0.6)))
            ctx.fill(Path(CGRect(x: 0, y: rulerTop, width: size.width, height: rulerHeight)),
                     with: .color(theme.ruler))
            ctx.fill(Path(CGRect(x: 0, y: captionsTop, width: size.width, height: captionsRowH)),
                     with: .color(theme.ccRow))
            ctx.draw(Text(String(format: "%.1f / %.0fs", model.time, model.duration))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(lightMode ? Color(red: 0, green: 0.45, blue: 0.1) : .green),
                     at: CGPoint(x: size.width - 10, y: rulerTop + rulerHeight / 2 + 2),
                     anchor: .trailing)
            ctx.draw(Text("Captions").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.mutedText),
                     at: CGPoint(x: size.width - 10, y: captionsTop + captionsRowH / 2),
                     anchor: .trailing)
        }
        .overlay(alignment: .topTrailing) {
            // The Export action lives on its row, sticky to the divider.
            if let file {
                ShipButton(model: model, file: file, compact: true)
                    .padding(.trailing, 8)
                    .frame(height: exportRowH)
            }
        }
        .frame(width: laneLabelWidth, height: lanesTop)
    }

    /// Pinned ruler/scrub/CC band, shifted by the horizontal scroll offset.
    private var headerBand: some View {
        Canvas { ctx0, size in
            let fullW = max(size.width + scrollOffset.x, contentWidth + 40)
            var ctx = ctx0
            ctx.translateBy(x: -scrollOffset.x, y: 0)
            drawRuler(ctx: ctx, size: CGSize(width: fullW, height: size.height))
            drawExportRow(ctx: ctx, size: CGSize(width: fullW, height: size.height))
            drawCaptionsRow(ctx: ctx, size: CGSize(width: fullW, height: size.height))
        }
        .clipped()
        .overlay(alignment: .topLeading) {
            if let editing = editingLabel, editing.kind == .caption {
                TextField("caption", text: $editingText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .frame(width: 150)
                    .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 3))
                    .focused($labelFocused)
                    .onSubmit { commitLabelEdit() }
                    #if os(macOS)
                    .onExitCommand { editingLabel = nil }
                    #endif
                    .offset(x: max(4, editing.origin.x - scrollOffset.x), y: captionsTop + 3)
                    .onAppear { labelFocused = true }
                    .onChange(of: labelFocused) { _, focused in
                        if !focused { commitLabelEdit() }
                    }
            }
        }
        .gesture(headerInteraction)
    }

    private var headerInteraction: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if editingLabel != nil {
                    // The second click of a double-click must not commit-and-
                    // reopen (the chips resort and the strip appears to jump).
                    if Date().timeIntervalSince(editorOpenedAt) > 0.5 { commitLabelEdit() }
                    return
                }
                let cx = value.location.x + scrollOffset.x
                if let ds = draggingSub {
                    applySubDrag(ds, translation: Double(value.translation.width / pxPerSecond))
                    return
                }
                if let de = draggingExport {
                    applyExportDrag(de, value: value)
                    return
                }
                if value.startLocation.y < exportRowH {
                    // Export row: grab a marker, slide the range, or drag out a new one.
                    let sx = value.startLocation.x + scrollOffset.x
                    let t0 = time(forX: sx)
                    if let r = model.exportRange {
                        let grab: CGFloat = 6
                        if abs(sx - x(forTime: r.from)) < grab { draggingExport = (-1, r.from, r.to) }
                        else if abs(sx - x(forTime: r.to)) < grab { draggingExport = (1, r.from, r.to) }
                        else if t0 > r.from, t0 < r.to { draggingExport = (0, r.from, r.to) }
                        else { draggingExport = (2, t0, t0) }
                    } else {
                        draggingExport = (2, t0, t0)
                    }
                    if let de = draggingExport { applyExportDrag(de, value: value) }
                    return
                }
                if value.startLocation.y < captionsTop + captionsRowH {
                    let sx = value.startLocation.x + scrollOffset.x
                    if let st = subtitleAt(contentX: sx) {
                        let edge = 4.0
                        let startX = x(forTime: st.sub.start)
                        let endX = x(forTime: st.sub.start + st.sub.dur)
                        let e = abs(sx - startX) < edge ? -1 : abs(sx - endX) < edge ? 1 : 0
                        draggingSub = (st.char, st.index, st.sub.start, st.sub.dur, e)
                    }
                    return
                }
                model.seek(to: time(forX: cx))
                let base = scrubZoomBase ?? zoom
                scrubZoomBase = base
                let dy = Double(value.translation.height)
                if abs(dy) > 8 {
                    // Anchored like pinch: the time under the pointer stays put.
                    if pinchAnchor == nil {
                        let contentH = totalLaneHeight + 34
                        let fy = min(1, max(0, offsets.y / max(1, contentH - tlViewport.height)))
                        pinchAnchor = (time(forX: value.startLocation.x + scrollOffset.x),
                                       value.startLocation.x + laneLabelWidth, fy)
                    }
                    var tr = Transaction()
                    tr.disablesAnimations = true
                    withTransaction(tr) {
                        zoom = min(16, max(0.25, base * pow(2, dy / 90)))
                        if let p = pinchAnchor { keepTime(p.t, atViewX: p.vx, fy: p.fy) }
                    }
                }
            }
            .onEnded { value in
                if let de = draggingExport {
                    if value.translation.width.magnitude < 3 {
                        // A plain click: on the range selects it (Delete removes),
                        // on the empty row deselects.
                        exportRangeSelected = de.edge != 2
                    }
                    model.registerUndoSnapshot(label: "Export Range")
                    draggingExport = nil
                    return
                }
                if value.translation.width.magnitude < 3, value.translation.height.magnitude < 3,
                   value.location.y >= captionsTop, value.location.y < captionsTop + captionsRowH {
                    let cx = value.location.x + scrollOffset.x
                    if let st = subtitleAt(contentX: cx) {
                        // Click a caption → edit its text in place.
                        editingText = st.sub.text
                        editorOpenedAt = Date()
                        editingLabel = (.caption, "\(st.char)-\(st.index)",
                                        CGPoint(x: x(forTime: st.sub.start), y: 0))
                    } else if model.selectedOutfitEvent != nil || exportRangeSelected || selectedPresence != nil {
                        // Click-away from a selection only deselects.
                        model.selectedOutfitEvent = nil
                        exportRangeSelected = false
                        selectedPresence = nil
                    } else if !model.scene.characters.isEmpty {
                        // Click empty strip → new caption for the selected character.
                        let ci = model.selection.first ?? 0
                        model.registerUndoSnapshot(label: "Add Caption")
                        let t = (time(forX: cx) * 10).rounded() / 10
                        model.scene.characters[ci].subs.append(Subtitle(text: "", start: t, dur: 2))
                        model.scene.characters[ci].subs.sort { $0.start < $1.start }
                        if let si = model.scene.characters[ci].subs.firstIndex(where: { $0.start == t }) {
                            editingText = ""
                            editorOpenedAt = Date()
                            editingLabel = (.caption, "\(ci)-\(si)", CGPoint(x: x(forTime: t), y: 0))
                        }
                    }
                }
                if draggingSub != nil {
                    model.registerUndoSnapshot(label: "Edit Captions")
                }
                draggingSub = nil
                scrubZoomBase = nil
                pinchAnchor = nil
            }
    }

    private func applyExportDrag(_ de: (edge: Int, baseFrom: Double, baseTo: Double),
                                 value: DragGesture.Value) {
        let dt = Double(value.translation.width / pxPerSecond)
        switch de.edge {
        case -1:
            model.exportRange = (max(0, min(de.baseFrom + dt, de.baseTo - 0.1)), de.baseTo)
        case 1:
            model.exportRange = (de.baseFrom, min(model.duration, max(de.baseFrom + 0.1, de.baseTo + dt)))
        case 0:
            let len = de.baseTo - de.baseFrom
            let f = max(0, min(de.baseFrom + dt, model.duration - len))
            model.exportRange = (f, f + len)
        default:
            let t1 = time(forX: value.location.x + scrollOffset.x)
            let lo = min(de.baseFrom, t1)
            let hi = max(de.baseFrom, t1)
            if hi - lo >= 0.1 { model.exportRange = (lo, hi) }
        }
    }

    private func applySubDrag(_ ds: (char: Int, index: Int, baseStart: Double, baseDur: Double, edge: Int),
                              translation dt: Double) {
        var subs = model.scene.characters[ds.char].subs
        guard subs.indices.contains(ds.index) else { return }
        switch ds.edge {
        case -1:
            let newStart = max(0, min(ds.baseStart + dt, ds.baseStart + ds.baseDur - 0.2))
            subs[ds.index].dur = ds.baseDur + (ds.baseStart - newStart)
            subs[ds.index].start = newStart
        case 1:
            subs[ds.index].dur = max(0.2, ds.baseDur + dt)
        default:
            subs[ds.index].start = max(0, ds.baseStart + dt)
        }
        model.scene.characters[ds.char].subs = subs
    }

    private func subtitleAt(contentX: CGFloat) -> (char: Int, index: Int, sub: Subtitle)? {
        for (ci, character) in model.scene.characters.enumerated().reversed() {
            for (si, sub) in character.subs.enumerated() {
                let minX = x(forTime: sub.start)
                let maxX = minX + max(8, CGFloat(sub.dur) * pxPerSecond)
                if contentX >= minX - 2, contentX <= maxX + 2 { return (ci, si, sub) }
            }
        }
        return nil
    }

    /// Always the last row: create any track type in place.
    private var newTrackRow: some View {
        // No wrapper HStack/Spacer: their implicit widths overflow laneLabelWidth
        // and the outer frame centers the overflow, shifting the gutter left.
        Menu {
                Menu("Character") {
                    ForEach(BannyCore.Body.allCases, id: \.self) { body in
                        Button(body.rawValue) { model.addCharacter(body: body) }
                    }
                }
                Button("Audio") { model.addAudioTrack() }
                Button("Light") { model.addLightTrack() }
                Button("Image") { model.addEmptyImageTrack() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                    Text("New track")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.labelText)
                }
                .padding(.leading, 12)
                .frame(width: laneLabelWidth, height: 34, alignment: .leading)
                .contentShape(Rectangle())
            }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .background(theme.gutterCell)
        .frame(height: 34)
    }

    /// Pinned label gutter: names, eye toggles, track-height pills, width handle.
    private var gutterCanvas: some View {
        Canvas { ctx0, size in
            ctx0.fill(Path(CGRect(origin: .zero, size: size)),
                      with: .color(theme.gutterBase))
            var ctx = ctx0
            ctx.translateBy(x: 0, y: -scrollOffset.y)
            for row in rows {
                let y = laneTop(of: row)
                let h = height(of: row)
                let hidden = isHidden(row)
                // Lighter cell over the base, bounded by strong dark separators.
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: h - 2)),
                         with: .color(theme.gutterCell))
                if isSelectedRow(row) {
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: h - 2)),
                             with: .color(Color.orange.opacity(lightMode ? 0.08 : 0.1)))
                }
                if draggingRow?.row == row {
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: h)),
                             with: .color(Color.white.opacity(0.08)))
                }
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: 0, y: y + h - 1))
                    p.addLine(to: CGPoint(x: size.width, y: y + h - 1))
                }, with: .color(lightMode ? Color.black.opacity(0.22) : .black), lineWidth: lightMode ? 1 : 2)
                let pillActive = resizingTrack?.key == row.key(in: model.scene)
                ctx.fill(Path(roundedRect: CGRect(x: size.width / 2 - 12, y: y + h - 8,
                                                  width: 24, height: 2), cornerRadius: 1),
                         with: .color(pillActive
                                      ? Color(white: lightMode ? 0.3 : 0.8)
                                      : theme.mutedText.opacity(0.35)))
                // Name + whole-track eye sit on the presence-strip line, so the
                // eye reads as the label of that show/hide row.
                var labelCtx = ctx
                if hidden { labelCtx.opacity = 0.65 }
                labelCtx.draw(Text(label(for: row)).font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(labelColor(for: row)),
                              at: CGPoint(x: 12, y: y + presenceStripH / 2), anchor: .leading)
                if case .background = row {} else {
                    ctx.draw(Text(Image(systemName: hidden ? "eye.slash" : "eye"))
                                .font(.system(size: 10))
                                .foregroundStyle(hidden ? Color.gray : theme.mutedText),
                             at: CGPoint(x: size.width - 18, y: y + presenceStripH / 2))
                }
                if case .character = row {
                    ctx.draw(Text(Image(systemName: "tshirt"))
                                .font(.system(size: 9))
                                .foregroundStyle(theme.mutedText),
                             at: CGPoint(x: size.width - 18, y: y + h - wardrobeStripH / 2 - 1))
                }
                // Motion + mix readouts beside the card / type icon.
                var readouts: [String] = []
                var readoutX: CGFloat = 12
                var readoutBottomPad: CGFloat = 6
                if case .character(let ci) = row, let c = model.scene.characters[safe: ci] {
                    let mismatch = model.startPoseMismatch(characterIndex: ci)
                    if mismatch { readoutBottomPad = 30 } // the button's line
                    let available = h - presenceStripH - 16 - (mismatch ? 26 : 0)
                    if available >= 26, size.width >= 120 {
                        readoutX = 12 + (min(available, 160) * 30 / 54).rounded() + 10
                        let sizeName = abs(c.size - 1) < 0.01 ? "Normal"
                            : abs(c.size - 0.62) < 0.01 ? "Small"
                            : abs(c.size - 0.38) < 0.01 ? "Baby"
                            : String(format: "%.2f", c.size)
                        readouts = ["Speed: \(String(format: "%.1f", StudioModel.uiSpeed(c.speed)))",
                                    "Wobble: \(String(format: "%.1f", StudioModel.uiWobble(c.wobble)))",
                                    "Size: \(sizeName)"]
                        readouts += mixReadout(c.trackFx)
                    }
                } else if case .audio(let ai) = row, let track = model.scene.audioTracks[safe: ai],
                          size.width >= 120 {
                    readoutX = 12 + 28 + 10
                    readouts = mixReadout(track.fx)
                } else if case .light(let li) = row, let track = model.scene.lightTracks[safe: li],
                          size.width >= 120, !track.cues.isEmpty {
                    readoutX = 12 + 28 + 10
                    let cue = track.cues.first { model.time >= $0.start && model.time < $0.start + $0.dur }
                        ?? track.cues[0]
                    let state = cue.state(at: model.time)
                    readouts = ["Intensity: \(Int((state.intensity * 100).rounded()))%"]
                }
                for (li, line) in readouts.enumerated() {
                    let ly = y + presenceStripH + 13 + CGFloat(li) * 13
                    if ly < y + h - wardrobeStripH - readoutBottomPad {
                        ctx.draw(Text(line).font(.system(size: 8.5, weight: .medium))
                                    .foregroundStyle(theme.mutedText),
                                 at: CGPoint(x: readoutX, y: ly), anchor: .leading)
                    }
                }
            }
        }
        .gesture(gutterInteraction)
        .contextMenu {
            if let row = hoverGutterRow {
                Button("Duplicate \(label(for: row))") { model.duplicateTrack(kind(of: row)) }
                Button("Rename") {
                    renamingText = label(for: row)
                    renamingRow = row
                }
                Button("Settings…") { model.inspectorRequest = row.key(in: model.scene) }
            }
        }
        #if os(macOS)
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                hoverGutterRow = row(at: p.y + scrollOffset.y)
                if abs(p.x - laneLabelWidth) < 6 {
                    NSCursor.resizeLeftRight.set()
                } else if rowNearBottomEdge(of: p.y + scrollOffset.y) != nil {
                    NSCursor.resizeUpDown.set()
                } else {
                    NSCursor.arrow.set()
                }
            case .ended:
                NSCursor.arrow.set()
            }
        }
        #endif
    }

    /// Rows of the same group as `row` (reordering stays within a type group).
    private var gutterInteraction: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if editingLabel != nil {
                    // The second click of a double-click must not commit-and-
                    // reopen (the chips resort and the strip appears to jump).
                    if Date().timeIntervalSince(editorOpenedAt) > 0.5 { commitLabelEdit() }
                    return
                }
                if resizingGutter {
                    laneLabelWidthStore = min(300, max(max(60, neededGutterWidth), Double(value.location.x)))
                    return
                }
                if let tr = resizingTrack {
                    let delta = value.location.y - value.startLocation.y
                    trackHeights[tr.key] = min(320, max(tr.minHeight, tr.baseHeight + delta))
                    return
                }
                if let dragging = draggingRow {
                    let updated = (dragging.row, value.location.y + scrollOffset.y)
                    draggingRow = updated
                    dragPreviewIndex = previewSlot(for: updated)
                    return
                }
                if abs(value.startLocation.x - laneLabelWidth) < 6 {
                    resizingGutter = true
                    return
                }
                if let row = rowNearBottomEdge(of: value.startLocation.y + scrollOffset.y) {
                    resizingTrack = (row.key(in: model.scene), height(of: row), minHeight(of: row))
                    return
                }
                // Vertical pull on a row label lifts the row for reordering.
                if abs(value.translation.height) > 8,
                   let row = row(at: value.startLocation.y + scrollOffset.y) {
                    draggingRow = (row, value.location.y + scrollOffset.y)
                    dragPreviewIndex = baseRows.firstIndex(of: row)
                }
            }
            .onEnded { value in
                if let dragging = draggingRow {
                    commitRowMove(dragging)
                    draggingRow = nil
                    dragPreviewIndex = nil
                    resizingTrack = nil
                    resizingGutter = false
                    return
                }
                if value.translation.width.magnitude < 3, value.translation.height.magnitude < 3,
                   let row = row(at: value.location.y + scrollOffset.y) {
                    if value.location.x > laneLabelWidth - 24,
                       !{ if case .background = row { return true }; return false }() {
                        toggleHidden(row)
                    } else if value.location.y + scrollOffset.y - laneTop(of: row) < presenceStripH,
                              value.location.x < min(110, CGFloat(label(for: row).count) * 6.5 + 16) {
                        // Click on the name itself → rename in place.
                        renamingText = label(for: row)
                        renamingRow = row
                        model.selectedTrackKey = row.key(in: model.scene)
                        if case .character(let i) = row { model.selection = [i] }
                    } else {
                        let key = row.key(in: model.scene)
                        if let last = lastGutterTap, Date().timeIntervalSince(last.at) < 0.45,
                           last.key == key {
                            // Double-click anywhere in the cell → its inspector.
                            model.inspectorRequest = key
                            lastGutterTap = nil
                        } else {
                            lastGutterTap = (key, Date())
                        }
                        model.selectedTrackKey = key
                        if case .character(let i) = row {
                            model.selection = [i]
                        }
                    }
                }
                resizingTrack = nil
                resizingGutter = false
            }
    }

    private func commitRowMove(_ dragging: (row: TrackRow, currentY: CGFloat)) {
        guard dragPreviewIndex != nil else { return }
        model.registerUndoSnapshot(label: "Reorder Tracks")
        // `rows` already shows the preview arrangement — persist it as the
        // display order. Storage arrays never move, so marks/selection and
        // recorded events stay index-stable across any reorder.
        model.scene.rowOrder = rows.map { $0.key(in: model.scene) }
    }

    /// Popover anchors living in the scroll content (outfit strip + clip mix),
    /// split out of the ZStack so the type-checker copes.
    @ViewBuilder private var popoverAnchors: some View {
                        if let op = outfitPopover {
                            Color.clear
                                .frame(width: 1, height: 1)
                                .offset(x: op.x, y: op.y)
                                .popover(isPresented: Binding(
                                    get: { outfitPopover != nil },
                                    set: { if !$0 { outfitPopover = nil } })) {
                                    ScrollView {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(String(format: "Outfit change at %.1fs", op.t))
                                                .font(.caption.bold())
                                            WardrobePanel(model: model, characterIndex: op.char,
                                                          eventTime: op.t)
                                        }
                                        .padding(12)
                                    }
                                    .frame(width: 300, height: 430)
                                    .background(lightMode ? Color(red: 1, green: 0.99, blue: 0.95)
                                                          : Color(red: 0.13, green: 0.13, blue: 0.16))
                                    .presentationBackground(lightMode ? Color(red: 1, green: 0.99, blue: 0.95)
                                                                      : Color(red: 0.13, green: 0.13, blue: 0.16))
                                    .environment(\.colorScheme, lightMode ? .light : .dark)
                                }
                        }
                        if let cm = clipMix {
                            Color.clear
                                .frame(width: 1, height: 1)
                                .offset(x: cm.x, y: cm.y)
                                .popover(isPresented: Binding(
                                    get: { clipMix != nil },
                                    set: { if !$0 { clipMix = nil } })) {
                                    ScrollView {
                                        MixSection(model: model, kind: cm.kind, clipID: cm.clipID)
                                            .padding(12)
                                    }
                                    .frame(width: 300, height: 360)
                                    .background(lightMode ? Color(red: 1, green: 0.99, blue: 0.95)
                                                          : Color(red: 0.13, green: 0.13, blue: 0.16))
                                    .presentationBackground(lightMode ? Color(red: 1, green: 0.99, blue: 0.95)
                                                                      : Color(red: 0.13, green: 0.13, blue: 0.16))
                                    .environment(\.colorScheme, lightMode ? .light : .dark)
                                }
                        }
    }

    private var timelineCanvas: some View {
        Canvas { ctx, size in
            for row in rows { drawLane(row, ctx: ctx, size: size) }
            if let m = marquee {
                let r = CGRect(x: min(m.start.x, m.current.x), y: min(m.start.y, m.current.y),
                               width: abs(m.start.x - m.current.x),
                               height: abs(m.start.y - m.current.y))
                ctx.fill(Path(r), with: .color(Color.orange.opacity(0.1)))
                ctx.stroke(Path(r), with: .color(Color.orange.opacity(0.7)), lineWidth: 1)
            }
            if let g = snapGuide {
                let gx = x(forTime: g)
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: gx, y: 0))
                    p.addLine(to: CGPoint(x: gx, y: size.height))
                }, with: .color(Color.cyan.opacity(0.8)),
                   style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .gesture(interaction)
        #if os(macOS)
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                hoverLanePoint = p
                if resizeEdgeHit(at: p) {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            case .ended:
                NSCursor.arrow.set()
            }
        }
        #endif
        .contextMenu {
            if let p = hoverLanePoint, case .background = row(at: p.y) {
                let t = (time(forX: p.x) * 10).rounded() / 10
                if model.document.assets.isEmpty {
                    Text("Add images/videos to the Asset Bank first")
                } else {
                    Text(String(format: "Background from %.1fs:", t))
                    ForEach(model.document.assets) { asset in
                        Button(asset.name) {
                            model.addBackgroundCue(assetID: asset.id, assetName: asset.name, at: t)
                        }
                    }
                }
            }
            if let p = hoverLanePoint, case .light(let li) = row(at: p.y) {
                let t = (time(forX: p.x) * 10).rounded() / 10
                Button(String(format: "Add light at %.1fs", t)) {
                    model.addLightCue(trackIndex: li, at: t)
                }
            }
            if let p = hoverLanePoint {
                Divider()
                if model.hasTimelineSelection {
                    Button("Copy") { model.copyTimelineSelection() }
                }
                Button(String(format: "Paste at %.1fs", (time(forX: p.x) * 10).rounded() / 10)) {
                    model.pasteTimeline(at: (time(forX: p.x) * 10).rounded() / 10)
                }
            }
        }
    }

    // MARK: - Drawing

    private func drawRuler(ctx: GraphicsContext, size: CGSize) {
        let top = rulerTop  // export + captions sit above the time row
        ctx.fill(Path(CGRect(x: 0, y: top, width: size.width, height: rulerHeight)),
                 with: .color(theme.ruler))
        // Labeled ticks every ~60px at any zoom, minor ticks between.
        let step = [0.5, 1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0]
            .first { CGFloat($0) * pxPerSecond >= 55 } ?? 60
        let minor = step / 5
        if CGFloat(minor) * pxPerSecond >= 7 {
            var m: Double = 0
            while m <= model.duration {
                let px = x(forTime: m)
                ctx.stroke(Path { $0.move(to: CGPoint(x: px, y: top + rulerHeight - 6))
                                  $0.addLine(to: CGPoint(x: px, y: top + rulerHeight)) },
                           with: .color(Color.gray.opacity(0.5)), lineWidth: 1)
                m += minor
            }
        }
        var t: Double = 0
        while t <= model.duration {
            let px = x(forTime: t)
            ctx.stroke(Path { $0.move(to: CGPoint(x: px, y: top + 16))
                              $0.addLine(to: CGPoint(x: px, y: top + rulerHeight)) },
                       with: .color(.gray), lineWidth: 1)
            let label = step < 1 ? String(format: "%.1fs", t) : "\(Int(t))s"
            ctx.draw(Text(label).font(.system(size: 9)).foregroundStyle(theme.mutedText),
                     at: CGPoint(x: px + 12, y: top + 10))
            t += step
        }
    }

    /// Export range row: green brackets bound what ships; empty ships everything.
    private func drawExportRow(ctx: GraphicsContext, size: CGSize) {
        let y: CGFloat = 0
        ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: exportRowH)),
                 with: .color(theme.ccRow.opacity(0.6)))
        ctx.stroke(Path { p in
            p.move(to: CGPoint(x: 0, y: y + exportRowH - 0.5))
            p.addLine(to: CGPoint(x: size.width, y: y + exportRowH - 0.5))
        }, with: .color(theme.gutterDivider), lineWidth: 1)
        if let r = model.exportRange {
            let x0 = x(forTime: r.from)
            let x1 = x(forTime: r.to)
            let green = Color(red: 0.25, green: 0.72, blue: 0.35)
            ctx.fill(Path(CGRect(x: x0, y: y + 2, width: max(2, x1 - x0), height: exportRowH - 4)),
                     with: .color(green.opacity(exportRangeSelected ? 0.5 : 0.28)))
            if exportRangeSelected {
                ctx.stroke(Path(CGRect(x: x0, y: y + 2, width: max(2, x1 - x0), height: exportRowH - 4)),
                           with: .color(green), lineWidth: 1)
            }
            for (mx, dir) in [(x0, 1.0), (x1, -1.0)] {
                var p = Path()
                p.move(to: CGPoint(x: mx + CGFloat(dir) * 4, y: y + 2))
                p.addLine(to: CGPoint(x: mx, y: y + 2))
                p.addLine(to: CGPoint(x: mx, y: y + exportRowH - 2))
                p.addLine(to: CGPoint(x: mx + CGFloat(dir) * 4, y: y + exportRowH - 2))
                ctx.stroke(p, with: .color(green), lineWidth: 2)
            }
            if x1 - x0 > 90 {
                ctx.draw(Text(String(format: "%.1f–%.1fs", r.from, r.to))
                            .font(.system(size: 8, weight: .semibold)).foregroundStyle(green),
                         at: CGPoint(x: (x0 + x1) / 2, y: y + exportRowH / 2))
            }
        } else {
            ctx.draw(Text("drag here to mark an export range — empty ships the whole show")
                        .font(.system(size: 8)).foregroundStyle(theme.mutedText.opacity(0.8)),
                     at: CGPoint(x: scrollOffset.x + 10, y: y + exportRowH / 2), anchor: .leading)
        }
    }

    private func drawLane(_ row: TrackRow, ctx: GraphicsContext, size: CGSize) {
        let y = laneTop(of: row)
        let h = height(of: row)
        let hidden = isHidden(row)

        if isSelectedRow(row) {
            ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: h)),
                     with: .color(Color.white.opacity(0.03)))
        }
        ctx.stroke(Path { p in
            p.move(to: CGPoint(x: 0, y: y + h - 1))
            p.addLine(to: CGPoint(x: size.width, y: y + h - 1))
        }, with: .color(lightMode ? Color.black.opacity(0.22) : .black), lineWidth: lightMode ? 1 : 2)

        if case .background = row {} else {
            drawPresenceStrip(row, y: y, ctx: ctx)
        }

        var content = ctx
        if hidden { content.opacity = 0.3 }
        switch row {
        case .character(let i):
            drawCharacterLane(i, y: y, h: h, ctx: content)
        case .audio(let i):
            for clip in model.scene.audioTracks[i].clips {
                drawClip(clip, top: y + presenceStripH + 2, height: h - presenceStripH - 6, ctx: content)
            }
        case .image(let i):
            for cue in model.scene.imageTracks[i].cues {
                drawCueBar(start: cue.start, dur: cue.dur, y: y, h: h,
                           color: Color(red: 0.85, green: 0.6, blue: 0.25),
                           label: cue.label ?? assetName(cue.assetID),
                           assetID: cue.assetID,
                           selected: model.selectedImageCue == cue.id,
                           animated: cue.to != nil, ctx: content)
            }
        case .light(let i):
            for cue in model.scene.lightTracks[i].cues {
                drawCueBar(start: cue.start, dur: cue.dur, y: y, h: h,
                           color: Color(red: 0.95, green: 0.78, blue: 0.25),
                           label: cue.label ?? "light",
                           assetID: "",
                           selected: model.selectedLightCue == cue.id,
                           animated: cue.to != nil, ctx: content)
            }
        case .background(let i):
            let cues = model.scene.backgroundTracks[i].cues
            for cue in cues {
                let leadButt = cues.contains { abs(($0.start + $0.dur) - cue.start) < 0.02 }
                let trailButt = cues.contains { abs($0.start - (cue.start + cue.dur)) < 0.02 }
                drawCueBar(start: cue.start, dur: cue.dur, y: y, h: h,
                           color: Color(red: 0.45, green: 0.4, blue: 0.85),
                           label: cue.label ?? assetName(cue.assetID),
                           assetID: cue.assetID,
                           selected: model.selectedBackgroundCue == cue.id,
                           animated: false,
                           squareLeading: leadButt, squareTrailing: trailButt, ctx: content)
            }
        }

        // Dim lane content across the spans where the track is not on stage.
        let visible = visibleSegments(presence(of: row))
        var edges: [Double] = [0]
        for (a, b) in visible { edges.append(a); edges.append(b) }
        edges.append(model.duration)
        var cursor = 0.0
        for (a, b) in visible.sorted(by: { $0.0 < $1.0 }) {
            if a > cursor {
                shadeHidden(from: cursor, to: a, laneY: y, laneH: h, ctx: ctx)
            }
            cursor = max(cursor, b)
        }
        if cursor < model.duration {
            shadeHidden(from: cursor, to: model.duration, laneY: y, laneH: h, ctx: ctx)
        }
    }

    private func shadeHidden(from: Double, to: Double, laneY y: CGFloat, laneH h: CGFloat,
                             ctx: GraphicsContext) {
        guard to > from else { return }
        let rect = CGRect(x: x(forTime: from), y: y + presenceStripH,
                          width: CGFloat(to - from) * pxPerSecond, height: h - presenceStripH)
        ctx.fill(Path(rect), with: .color(theme.shade))
    }

    private let captionStripH: CGFloat = 13
    /// Per-lane presence strip (eye markers) at the top of every row.
    private let presenceStripH: CGFloat = 18

    /// Character lane vertical layout: captions strip, then audio clips, then
    /// the seven event sub-lanes. Everything gets its own band — no overlap.
    /// Bottom band of every character lane: the wardrobe (outfit change) strip.
    private var wardrobeStripH: CGFloat { 16 }

    private func characterLaneZones(h fullH: CGFloat) -> (clipTop: CGFloat, clipH: CGFloat,
                                                          eventTop: CGFloat, subH: CGFloat) {
        let h = fullH - wardrobeStripH
        let clipH: CGFloat = max(14, (h - presenceStripH - 8) * 0.45)
        let clipTop = presenceStripH + 2
        let eventTop = clipTop + clipH + 2
        let subH = max(2, (h - eventTop - 4) / 6)
        return (clipTop, clipH, eventTop, subH)
    }

    /// The global CC strip: every character's captions, tinted per speaker body color.
    private func drawCaptionsRow(ctx: GraphicsContext, size: CGSize) {
        let y = captionsTop
        ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: captionsRowH)),
                 with: .color(theme.ccRow))
        ctx.stroke(Path { p in
            p.move(to: CGPoint(x: 0, y: y + captionsRowH))
            p.addLine(to: CGPoint(x: size.width, y: y + captionsRowH))
        }, with: .color(lightMode ? Color.black.opacity(0.22) : .black), lineWidth: 1)
        for (ci, character) in model.scene.characters.enumerated() {
            let tint = Color(red: 0.92, green: 0.9, blue: 0.82)
            _ = character
            for (si, sub) in character.subs.enumerated() {
                let rect = CGRect(x: x(forTime: sub.start), y: y + 2,
                                  width: max(8, CGFloat(sub.dur) * pxPerSecond), height: captionsRowH - 4)
                let selected = draggingSub?.char == ci && draggingSub?.index == si
                ctx.fill(Path(roundedRect: rect, cornerRadius: 3),
                         with: .color(tint.opacity(selected ? 0.95 : 0.7)))
                ctx.stroke(Path(roundedRect: rect, cornerRadius: 3),
                           with: .color(theme.chipStroke), lineWidth: 1)
                if rect.width > 30 {
                    var clipped = ctx
                    clipped.clip(to: Path(rect.insetBy(dx: 3, dy: 0)))
                    clipped.draw(Text(sub.text).font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(Color(red: 0.08, green: 0.08, blue: 0.04)),
                                 at: CGPoint(x: rect.minX + 4, y: rect.minY + 3.5), anchor: .topLeading)
                }
            }
        }
    }

    /// Contiguous [from, to) spans where the track is visible.
    private func visibleSegments(_ events: [VisibilityEvent]) -> [(Double, Double)] {
        var segments: [(Double, Double)] = []
        var spanStart: Double? = 0
        var cursorVisible = true
        for ev in events.sorted(by: { $0.t < $1.t }) {
            if cursorVisible, !ev.visible, let s0 = spanStart {
                segments.append((s0, ev.t))
                spanStart = nil
            } else if !cursorVisible, ev.visible {
                spanStart = ev.t
            }
            cursorVisible = ev.visible
        }
        if let s0 = spanStart { segments.append((s0, model.duration)) }
        return segments
    }

    /// Presence strip: tinted spans while visible, eye/eye-slash markers at toggles.
    private func drawPresenceStrip(_ row: TrackRow, y: CGFloat, ctx: GraphicsContext) {
        let events = presence(of: row).sorted { $0.t < $1.t }
        let stripRect = CGRect(x: 0, y: y, width: contentWidth + 40, height: presenceStripH)
        ctx.fill(Path(stripRect), with: .color(theme.stripTint))
        let rowKey = row.key(in: model.scene)
        for (i, ev) in events.enumerated() {
            let px = x(forTime: ev.t)
            if selectedPresence?.rowKey == rowKey, selectedPresence?.index == i {
                ctx.stroke(Path(ellipseIn: CGRect(x: px - 7, y: y + presenceStripH / 2 - 7,
                                                  width: 14, height: 14)),
                           with: .color(lightMode ? .black : .white), lineWidth: 1)
            }
            let show = lightMode ? Color(red: 0.05, green: 0.5, blue: 0.22)
                                 : Color(red: 0.5, green: 0.95, blue: 0.65)
            let hide = lightMode ? Color(red: 0.72, green: 0.15, blue: 0.1)
                                 : Color(red: 0.95, green: 0.5, blue: 0.45)
            ctx.draw(Text(Image(systemName: ev.visible ? "eye.fill" : "eye.slash.fill"))
                        .font(.system(size: 8))
                        .foregroundStyle(ev.visible ? show : hide),
                     at: CGPoint(x: px, y: y + presenceStripH / 2))
        }
    }

    private func drawCharacterLane(_ i: Int, y: CGFloat, h: CGFloat, ctx: GraphicsContext) {
        let character = model.scene.characters[i]
        let zones = characterLaneZones(h: h)
        for mark in TimelineMath.marks(for: character.events, character: i, duration: model.duration) {
            let my = y + zones.eventTop + CGFloat(mark.code.group.laneIndex) * zones.subH + 1
            let rect = CGRect(x: x(forTime: mark.start), y: my,
                              width: max(2, CGFloat(mark.end - mark.start) * pxPerSecond),
                              height: max(2, zones.subH - 1))
            ctx.fill(Path(rect), with: .color(mark.code.group.color(light: lightMode).opacity(
                model.selectedMarks.contains(mark) ? 1 : 0.85)))
            if model.selectedMarks.contains(mark) {
                ctx.stroke(Path(rect.insetBy(dx: -1, dy: -1)),
                           with: .color(lightMode ? .black : .white), lineWidth: 1)
            }
        }
        let stripY = y + h - wardrobeStripH
        ctx.fill(Path(CGRect(x: 0, y: stripY, width: contentWidth + 40, height: wardrobeStripH)),
                 with: .color(theme.stripTint))
        for ev in character.events {
            guard case .outfit(let t, _, _) = ev else { continue }
            let cx = x(forTime: t)
            let cy = stripY + wardrobeStripH / 2
            ctx.fill(Path(ellipseIn: CGRect(x: cx - 3, y: cy - 3, width: 6, height: 6)),
                     with: .color(lightMode ? .black : .white))
            if let sel = model.selectedOutfitEvent, sel.char == i,
               character.events.indices.contains(sel.index), character.events[sel.index] == ev,
               case .outfit(_, let slot, let name) = ev {
                ctx.stroke(Path(ellipseIn: CGRect(x: cx - 5.5, y: cy - 5.5, width: 11, height: 11)),
                           with: .color(.orange), lineWidth: 1.5)
                // What this dot changes, in a bubble above it.
                let slotTitle = SharedAssets.catalog.slotName(slot) ?? "Slot \(slot)"
                let itemTitle = name.map { n in
                    SharedAssets.catalog.outfits(inSlot: slot).first { $0.name == n }?.label ?? n
                } ?? "off"
                let resolved = ctx.resolve(Text("\(slotTitle) → \(itemTitle)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white))
                let sz = resolved.measure(in: CGSize(width: 260, height: 20))
                let bubble = CGRect(x: cx - sz.width / 2 - 6, y: cy - 27,
                                    width: sz.width + 12, height: 17)
                ctx.fill(Path(roundedRect: bubble, cornerRadius: 4),
                         with: .color(Color.black.opacity(0.85)))
                ctx.stroke(Path(roundedRect: bubble, cornerRadius: 4),
                           with: .color(.orange), lineWidth: 1)
                ctx.draw(resolved, at: CGPoint(x: cx, y: bubble.midY), anchor: .center)
            }
        }
        for clip in character.clips {
            drawClip(clip, top: y + zones.clipTop, height: zones.clipH, ctx: ctx)
        }
    }

    private func drawClip(_ clip: AudioClip, top: CGFloat, height clipH: CGFloat, ctx: GraphicsContext) {
        let rect = CGRect(x: x(forTime: clip.start), y: top,
                          width: max(4, CGFloat(clip.dur) * pxPerSecond), height: clipH)
        let selected = model.selectedClips.contains(clip.id)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 3),
                 with: .color(Color(red: 0.16, green: 0.38, blue: 0.33)))
        if let file, let peaks = peakCache.peaks(for: clip.id, file: file), !peaks.isEmpty {
            let perSec = Double(peaks.count) / max(0.001, clip.srcDur)
            let start = Int(clip.offset * perSec)
            let count = max(1, Int(clip.dur * perSec))
            var wave = Path()
            let cols = Int(rect.width)
            for px in stride(from: 0, to: cols, by: 1) {
                let idx = start + Int(Double(px) / Double(max(1, cols)) * Double(count))
                guard peaks.indices.contains(idx) else { continue }
                let wh = CGFloat(peaks[idx]) * (rect.height - 3)
                let cx = rect.minX + CGFloat(px)
                wave.move(to: CGPoint(x: cx, y: rect.midY - wh / 2))
                wave.addLine(to: CGPoint(x: cx, y: rect.midY + wh / 2))
            }
            ctx.stroke(wave, with: .color(Color(red: 0.45, green: 0.9, blue: 0.75)), lineWidth: 1)
        }
        if selected {
            ctx.stroke(Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: 3),
                       with: .color(.white), lineWidth: 1.5)
        }
        ctx.draw(Text(clip.name).font(.system(size: 8)).foregroundStyle(.white.opacity(0.8)),
                 at: CGPoint(x: rect.minX + 4, y: rect.minY + 4), anchor: .topLeading)
    }

    private func drawCueBar(start: Double, dur: Double, y: CGFloat, h: CGFloat, color: Color,
                            label: String, assetID: String, selected: Bool, animated: Bool,
                            squareLeading: Bool = false, squareTrailing: Bool = false,
                            ctx: GraphicsContext) {
        let rect = CGRect(x: x(forTime: start), y: y + presenceStripH + 2,
                          width: max(6, CGFloat(dur) * pxPerSecond), height: h - presenceStripH - 6)
        // Corners square off where the cue butts a neighbor, so adjacent
        // scenes read as one continuous strip.
        let radii = RectangleCornerRadii(topLeading: squareLeading ? 0 : 4,
                                         bottomLeading: squareLeading ? 0 : 4,
                                         bottomTrailing: squareTrailing ? 0 : 4,
                                         topTrailing: squareTrailing ? 0 : 4)
        let barPath = Path(roundedRect: rect, cornerRadii: radii)
        ctx.fill(barPath, with: .color(color.opacity(0.55)))
        // Tile the asset's image across the band.
        if let thumb = cueThumbs.thumb(assetID: assetID, file: file) {
            var tiled = ctx
            tiled.clip(to: barPath)
            tiled.opacity = 0.85
            let tileH = rect.height
            let tileW = tileH * CGFloat(thumb.width) / CGFloat(max(1, thumb.height))
            var tx = rect.minX
            while tx < rect.maxX {
                tiled.draw(Image(decorative: thumb, scale: 1),
                           in: CGRect(x: tx, y: rect.minY, width: tileW, height: tileH))
                tx += tileW
            }
        }
        ctx.stroke(barPath, with: .color(selected ? .white : color), lineWidth: selected ? 1.5 : 1)
        // Label chip stays readable over the artwork.
        let text = Text(label + (animated ? " →" : "")).font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white)
        let size = ctx.resolve(text).measure(in: CGSize(width: 200, height: 20))
        ctx.fill(Path(roundedRect: CGRect(x: rect.minX + 3, y: rect.minY + 2,
                                          width: size.width + 6, height: size.height + 2),
                      cornerRadius: 2),
                 with: .color(.black.opacity(0.45)))
        ctx.draw(text, at: CGPoint(x: rect.minX + 6, y: rect.minY + 3), anchor: .topLeading)
    }

    private func drawPlayhead(ctx: GraphicsContext, size: CGSize) {
        let px = x(forTime: model.time)
        ctx.stroke(Path { $0.move(to: CGPoint(x: px, y: 0)); $0.addLine(to: CGPoint(x: px, y: size.height)) },
                   with: .color(theme.playhead), lineWidth: 1.5)
    }

    // MARK: - Row helpers

    /// Non-neutral mix settings, compact (for the gutter readouts).
    private func mixReadout(_ fx: Fx) -> [String] {
        var out: [String] = []
        if abs(fx.gain - 1) > 0.005 { out.append("Gain: \(String(format: "%.2f", fx.gain))") }
        if abs(fx.low) > 0.5 || abs(fx.mid) > 0.5 || abs(fx.high) > 0.5 {
            out.append(String(format: "EQ: %+.0f/%+.0f/%+.0f", fx.low, fx.mid, fx.high))
        }
        switch fx.pan {
        case .follow: out.append("Pan: Follow")
        case .wide: out.append("Pan: Wide")
        case .narrow, .value: break
        }
        if fx.reverb > 0.005 { out.append("Reverb: \(Int(fx.reverb * 100))%") }
        return out
    }

    private func kind(of row: TrackRow) -> TrackRowKind {
        switch row {
        case .character(let i): return .character(i)
        case .image(let i): return .image(i)
        case .audio(let i): return .audio(i)
        case .light(let i): return .light(i)
        case .background(let i): return .background(i)
        }
    }

    private func commitRename() {
        guard let row = renamingRow else { return }
        let name = renamingText.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, name != label(for: row) {
            model.registerUndoSnapshot(label: "Rename Track")
            switch row {
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
        }
        renamingRow = nil
    }

    private func label(for row: TrackRow) -> String {
        switch row {
        case .character(let i):
            let n = model.scene.characters[i].name
            return n.isEmpty ? "banny \((i + 1) % 10)" : n
        case .audio(let i): return model.scene.audioTracks[i].name
        case .image(let i): return model.scene.imageTracks[i].name
        case .light(let i): return model.scene.lightTracks[i].name
        case .background(let i): return model.scene.backgroundTracks[i].name
        }
    }

    private func labelColor(for row: TrackRow) -> Color {
        switch row {
        case .character(let i):
            return model.selection.contains(i) ? (lightMode ? .black : .orange) : theme.labelText
        case .audio: return lightMode ? Color(red: 0, green: 0.48, blue: 0.34)
                                      : Color(red: 0.45, green: 0.9, blue: 0.75)
        case .image: return lightMode ? Color(red: 0.62, green: 0.4, blue: 0.05)
                                      : Color(red: 0.9, green: 0.7, blue: 0.4)
        case .light: return lightMode ? Color(red: 0.62, green: 0.47, blue: 0)
                                      : Color(red: 1, green: 0.85, blue: 0.35)
        case .background: return lightMode ? Color(red: 0.38, green: 0.32, blue: 0.72)
                                           : Color(red: 0.65, green: 0.6, blue: 0.95)
        }
    }

    private func isSelectedRow(_ row: TrackRow) -> Bool {
        row.key(in: model.scene) == model.selectedTrackKey
    }

    private func presence(of row: TrackRow) -> [VisibilityEvent] {
        switch row {
        case .character(let i): return model.scene.characters[i].presence
        case .audio(let i): return model.scene.audioTracks[i].presence
        case .image(let i): return model.scene.imageTracks[i].presence
        case .light(let i): return model.scene.lightTracks[i].presence
        case .background(let i): return model.scene.backgroundTracks[i].presence
        }
    }

    private func setPresence(_ row: TrackRow, _ events: [VisibilityEvent]) {
        let sorted = events.sorted { $0.t < $1.t }
        switch row {
        case .character(let i): model.scene.characters[i].presence = sorted
        case .audio(let i): model.scene.audioTracks[i].presence = sorted
        case .image(let i): model.scene.imageTracks[i].presence = sorted
        case .light(let i): model.scene.lightTracks[i].presence = sorted
        case .background(let i): model.scene.backgroundTracks[i].presence = sorted
        }
    }

    private func isHidden(_ row: TrackRow) -> Bool {
        switch row {
        case .character(let i): return model.scene.characters[i].hidden
        case .audio(let i): return model.scene.audioTracks[i].hidden
        case .image(let i): return model.scene.imageTracks[i].hidden
        case .light(let i): return model.scene.lightTracks[i].hidden
        case .background(let i): return model.scene.backgroundTracks[i].hidden
        }
    }

    private func toggleHidden(_ row: TrackRow) {
        model.registerUndoSnapshot(label: "Show/Hide Track")
        switch row {
        case .character(let i): model.scene.characters[i].hidden.toggle()
        case .audio(let i): model.scene.audioTracks[i].hidden.toggle()
        case .image(let i): model.scene.imageTracks[i].hidden.toggle()
        case .light(let i): model.scene.lightTracks[i].hidden.toggle()
        case .background(let i): model.scene.backgroundTracks[i].hidden.toggle()
        }
        // Muting/unmuting audio takes effect immediately during playback.
        model.resyncAudioIfPlaying()
    }

    private func assetName(_ id: String) -> String {
        model.document.assets.first { $0.id == id }?.name ?? "asset"
    }

    // MARK: - Interaction

    private var interaction: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // A click anywhere on the timeline while renaming commits the edit.
                if editingLabel != nil {
                    commitLabelEdit()
                    return
                }
                handleLaneDrag(value)
            }
            .onEnded { value in
                if value.translation.width.magnitude < 3, value.translation.height.magnitude < 3 {
                    handleTap(at: value.location)
                }
                if dragStartMarks != nil || resizing != nil || draggingClip != nil
                    || draggingCue != nil || draggingSub != nil || draggingPresence != nil {
                    model.registerUndoSnapshot(label: "Edit Timeline")
                }
                stopAutoScroll()
                snapGuide = nil
                if let m = marquee {
                    applyMarquee(m.start, m.current)
                    marquee = nil
                }
                if dragStartMarks != nil || dragStartClips != nil {
                    model.registerUndoSnapshot(label: "Move Selection")
                }
                dragStartClips = nil
                dragStartMarks = nil
                resizing = nil
                draggingClip = nil
                draggingCue = nil
                draggingSub = nil
                draggingPresence = nil
                scrubZoomBase = nil
            }
    }

    /// The row whose bottom edge is within 8px of y (for track-height resizing).
    private func rowNearBottomEdge(of y: CGFloat) -> TrackRow? {
        for r in rows {
            let bottom = laneTop(of: r) + height(of: r)
            if abs(bottom - y) < 8 { return r }
        }
        return nil
    }

    private func dlog(_ msg: String) {
        guard UserDefaults.standard.bool(forKey: "debugDrag") else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dragtest.log")
        let line = msg + "\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func handleLaneDrag(_ value: DragGesture.Value) {

        if let d = draggingClip {
            let dt = Double(value.translation.width / pxPerSecond)
            switch d.edge {
            case -1, 1:
                model.trimClip(id: d.id, leading: d.edge == -1, baseStart: d.baseStart,
                               baseDur: d.baseDur, baseOffset: d.baseOffset,
                               srcDur: d.srcDur, dt: dt)
            default:
                model.moveClip(id: d.id, toStart: max(0, d.baseStart + dt))
            }
            return
        }
        if let r = resizing {
            let t = time(forX: value.location.x)
            model.scene.characters[r.mark.character].events =
                TimelineMath.resizeMark(r.mark, leading: r.leading, to: t, in: r.baseEvents)
            return
        }
        updateAutoScroll(pointerContentX: value.location.x)
        if marquee != nil {
            marquee = (marquee!.start, value.location)
            return
        }
        if let dc = draggingCue {
            applyCueDrag(dc, translation: Double(value.translation.width / pxPerSecond))
            return
        }
        if let ds = draggingSub {
            let dt = Double(value.translation.width / pxPerSecond)
            var subs = model.scene.characters[ds.char].subs
            guard subs.indices.contains(ds.index) else { return }
            switch ds.edge {
            case -1:
                let newStart = max(0, min(ds.baseStart + dt, ds.baseStart + ds.baseDur - 0.2))
                subs[ds.index].dur = ds.baseDur + (ds.baseStart - newStart)
                subs[ds.index].start = newStart
            case 1:
                subs[ds.index].dur = max(0.2, ds.baseDur + dt)
            default:
                subs[ds.index].start = max(0, ds.baseStart + dt)
            }
            model.scene.characters[ds.char].subs = subs
            return
        }
        if let dp = draggingPresence {
            let t = max(0, snapped(time(forX: value.location.x)))
            var events = presence(of: dp.row)
            guard events.indices.contains(dp.index) else { return }
            events[dp.index].t = (t * 1000).rounded() / 1000
            setPresence(dp.row, events)
            return
        }
        if dragStartMarks == nil {
            if let row = row(at: value.startLocation.y),
               value.startLocation.y - laneTop(of: row) < presenceStripH {
                // Grab an existing marker if close; the tap handler adds new ones.
                let events = presence(of: row)
                if let idx = events.indices.min(by: {
                    abs(x(forTime: events[$0].t) - value.startLocation.x)
                        < abs(x(forTime: events[$1].t) - value.startLocation.x)
                }), abs(x(forTime: events[idx].t) - value.startLocation.x) < 8 {
                    draggingPresence = (row, idx)
                }
                return
            }
            if let hit = mark(at: value.startLocation) {
                let edge = 4.0
                let startX = x(forTime: hit.start)
                let endX = x(forTime: hit.end)
                if abs(value.startLocation.x - startX) < edge || abs(value.startLocation.x - endX) < edge {
                    resizing = (hit, abs(value.startLocation.x - startX) < edge,
                                model.scene.characters[hit.character].events)
                    return
                }
                if model.selectedMarks.contains(hit) {
                    #if os(macOS)
                    // ⌘-drag duplicates the selection and drags the copies.
                    if NSEvent.modifierFlags.contains(.command) {
                        model.duplicateSelectedMarksInPlace()
                    }
                    #endif
                    dragStartMarks = Dictionary(uniqueKeysWithValues:
                        Set(model.selectedMarks.map(\.character)).map { ($0, model.scene.characters[$0].events) })
                    dragStartClips = Dictionary(uniqueKeysWithValues:
                        model.selectedClips.compactMap { id in clipStart(id: id).map { (id, $0) } })
                }
            } else if let c = clip(at: value.startLocation)
                        ?? clip(at: CGPoint(x: value.startLocation.x - 6, y: value.startLocation.y))
                        ?? clip(at: CGPoint(x: value.startLocation.x + 6, y: value.startLocation.y)) {
                let edge = 7.0
                let e = abs(value.startLocation.x - x(forTime: c.start)) < edge ? -1
                    : abs(value.startLocation.x - x(forTime: c.start + c.dur)) < edge ? 1 : 0
                if e == 0, model.selectedClips.contains(c.id),
                   model.selectedClips.count + model.selectedMarks.count > 1 {
                    // Part of a marquee selection — drag the whole group.
                    dragStartMarks = Dictionary(uniqueKeysWithValues:
                        Set(model.selectedMarks.map(\.character)).map { ($0, model.scene.characters[$0].events) })
                    dragStartClips = Dictionary(uniqueKeysWithValues:
                        model.selectedClips.compactMap { id in clipStart(id: id).map { (id, $0) } })
                } else {
                    var clipID = c.id
                    #if os(macOS)
                    // ⌘-drag duplicates the clip and drags the copy.
                    if e == 0, NSEvent.modifierFlags.contains(.command),
                       let nid = model.duplicateClip(id: c.id) {
                        clipID = nid
                    }
                    #endif
                    draggingClip = (clipID, c.start, c.dur, c.offset, c.srcDur, e)
                    model.selectedClips = [clipID]
                }
                return
            } else if let (row, cue) = cue(at: value.startLocation)
                        ?? cue(at: CGPoint(x: value.startLocation.x - 6, y: value.startLocation.y))
                        ?? cue(at: CGPoint(x: value.startLocation.x + 6, y: value.startLocation.y)) {
                let edge = 7.0
                let startX = x(forTime: cue.start)
                let endX = x(forTime: cue.start + cue.dur)
                let e = abs(value.startLocation.x - startX) < edge ? -1
                    : abs(value.startLocation.x - endX) < edge ? 1 : 0
                dlog("grab cue row=\(row) id=\(cue.id.prefix(5)) e=\(abs(value.startLocation.x - startX) < edge ? -1 : abs(value.startLocation.x - endX) < edge ? 1 : 0) sx=\(Int(value.startLocation.x)) startX=\(Int(startX)) endX=\(Int(endX))")
                var cueID = cue.id
                #if os(macOS)
                // ⌘-drag duplicates the cue and drags the copy.
                if e == 0, NSEvent.modifierFlags.contains(.command),
                   let nid = model.duplicateCue(kind: kind(of: row), id: cue.id) {
                    cueID = nid
                }
                #endif
                draggingCue = (row, cueID, cue.start, cue.dur, e)
                selectCue(row: row, id: cueID)
                return
            } else {
                // Empty space: rubber-band select a region.
                dlog("grab marquee sx=\(Int(value.startLocation.x)) sy=\(Int(value.startLocation.y))")
                marquee = (value.startLocation, value.location)
                return
            }
        }
        guard dragStartMarks != nil || dragStartClips != nil else { return }
        let dt = Double(value.translation.width / pxPerSecond)
        if let base = dragStartMarks {
            for (charIndex, events) in base {
                let charMarks = Set(model.selectedMarks.filter { $0.character == charIndex })
                model.scene.characters[charIndex].events =
                    TimelineMath.shiftMarks(charMarks, in: events, by: dt)
            }
        }
        if let clips = dragStartClips {
            for (id, s) in clips {
                model.moveClip(id: id, toStart: max(0, s + dt))
            }
        }
    }

    /// Dragging past the viewport edge scoots the timeline — the further out,
    /// the faster (30Hz timer; drags self-correct because gesture coordinates
    /// live in content space).
    private func updateAutoScroll(pointerContentX px: CGFloat) {
        let visW = tlViewport.width - laneLabelWidth
        guard visW > 0 else { return }
        let left = offsets.x + 8
        let right = offsets.x + visW - 8
        if px > right { dragOvershootX = px - right }
        else if px < left { dragOvershootX = px - left }
        else { dragOvershootX = 0 }
        if dragOvershootX != 0, autoScrollTimer == nil {
            autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
                MainActor.assumeIsolated { autoScrollTick() }
            }
        }
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        dragOvershootX = 0
    }

    private func autoScrollTick() {
        guard let proxy = tlProxy, dragOvershootX != 0 else { return }
        let contentW = laneLabelWidth + max(600, contentWidth + 40)
        let maxScroll = max(0, contentW - tlViewport.width)
        guard maxScroll > 0 else { return }
        let step = max(-60, min(60, dragOvershootX * 0.25))
        let target = min(maxScroll, max(0, offsets.x + step))
        let contentH = totalLaneHeight + 34
        let fy = min(1, max(0, offsets.y / max(1, contentH - tlViewport.height)))
        var tr = Transaction()
        tr.disablesAnimations = true
        withTransaction(tr) {
            proxy.scrollTo("tlContent", anchor: UnitPoint(x: target / maxScroll, y: fy))
        }
        offsets.x = target
    }

    /// Pointer within grabbing distance of a clip/cue/mark edge?
    private func resizeEdgeHit(at p: CGPoint) -> Bool {
        let edge: CGFloat = 7
        if let c = clip(at: p)
            ?? clip(at: CGPoint(x: p.x - 6, y: p.y))
            ?? clip(at: CGPoint(x: p.x + 6, y: p.y)),
           abs(p.x - x(forTime: c.start)) < edge || abs(p.x - x(forTime: c.start + c.dur)) < edge {
            return true
        }
        if let (_, cue) = cue(at: p)
            ?? cue(at: CGPoint(x: p.x - 6, y: p.y))
            ?? cue(at: CGPoint(x: p.x + 6, y: p.y)),
           abs(p.x - x(forTime: cue.start)) < edge || abs(p.x - x(forTime: cue.start + cue.dur)) < edge {
            return true
        }
        if let m = mark(at: p),
           abs(p.x - x(forTime: m.start)) < 4 || abs(p.x - x(forTime: m.end)) < 4 {
            return true
        }
        return false
    }

    private func clipStart(id: String) -> Double? {
        for c in model.scene.characters {
            if let clip = c.clips.first(where: { $0.id == id }) { return clip.start }
        }
        for t in model.scene.audioTracks {
            if let clip = t.clips.first(where: { $0.id == id }) { return clip.start }
        }
        return nil
    }

    /// Marquee release: select every mark and clip inside the dragged region.
    private func applyMarquee(_ a: CGPoint, _ b: CGPoint) {
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(a.x - b.x), height: abs(a.y - b.y))
        guard rect.width > 4 || rect.height > 4 else { return }
        let t0 = time(forX: rect.minX)
        let t1 = time(forX: rect.maxX)
        var marks: Set<PerfMark> = []
        var clips: Set<String> = []
        for row in rows {
            let top = laneTop(of: row)
            let h = height(of: row)
            guard rect.maxY > top, rect.minY < top + h else { continue }
            switch row {
            case .character(let i):
                let zones = characterLaneZones(h: h)
                if rect.maxY > top + zones.clipTop, rect.minY < top + zones.clipTop + zones.clipH {
                    for clip in model.scene.characters[i].clips
                        where clip.start < t1 && clip.start + clip.dur > t0 {
                        clips.insert(clip.id)
                    }
                }
                for mark in TimelineMath.marks(for: model.scene.characters[i].events,
                                               character: i, duration: model.duration)
                    where mark.end > t0 && mark.start < t1 {
                    let my = top + zones.eventTop + CGFloat(mark.code.group.laneIndex) * zones.subH
                    if rect.maxY > my, rect.minY < my + zones.subH {
                        marks.insert(mark)
                    }
                }
            case .audio(let i):
                if rect.maxY > top + presenceStripH {
                    for clip in model.scene.audioTracks[i].clips
                        where clip.start < t1 && clip.start + clip.dur > t0 {
                        clips.insert(clip.id)
                    }
                }
            default:
                break
            }
        }
        model.selectedMarks = marks
        model.selectedClips = clips
    }

    /// Background cue boundaries: the show's scene-change anchor points.
    /// `excluding` skips a cue's own edges while dragging it.
    private func snapAnchors(excluding cueID: String? = nil) -> [Double] {
        // NOT contentEnd: it's derived from the longest cue, so it would chase
        // (and re-capture) the very edge being dragged.
        var ts: [Double] = [0]
        for track in model.scene.backgroundTracks {
            for cue in track.cues where cue.id != cueID {
                ts.append(cue.start)
                ts.append(cue.start + cue.dur)
            }
        }
        return ts
    }

    /// Snaps t to the nearest anchor within ~14px at the current zoom, and
    /// remembers the engaged anchor so the canvas can flash a guide line.
    private func snapped(_ t: Double, excluding cueID: String? = nil) -> Double {
        let tol = Double(14 / pxPerSecond)
        var best = t
        var bestD = tol
        for a in snapAnchors(excluding: cueID) {
            let d = abs(a - t)
            if d < bestD {
                bestD = d
                best = a
            }
        }
        snapGuide = best == t ? nil : best
        return best
    }

    private func applyCueDrag(_ dc: (row: TrackRow, cueID: String, baseStart: Double, baseDur: Double, edge: Int),
                              translation dt: Double) {
        // ONE value computed, ONE assignment per field. (Passing start+dur as
        // two inout refs into the computed `scene` clobbered the dur writeback.)
        let newStart: Double
        let newDur: Double
        switch dc.edge {
        case -1:
            let snappedStart = snapped(dc.baseStart + dt, excluding: dc.cueID)
            newStart = max(0, min(snappedStart, dc.baseStart + dc.baseDur - 0.2))
            newDur = dc.baseDur + (dc.baseStart - newStart)
        case 1:
            let end = snapped(dc.baseStart + dc.baseDur + dt, excluding: dc.cueID)
            newStart = dc.baseStart
            newDur = max(0.2, end - dc.baseStart)
        default:
            // Whole-cue move: snap whichever edge actually found an anchor.
            let sCand = dc.baseStart + dt
            let dS = snapped(sCand, excluding: dc.cueID) - sCand
            let dE = snapped(sCand + dc.baseDur, excluding: dc.cueID) - (sCand + dc.baseDur)
            let shift: Double
            if dS != 0, dE != 0 { shift = abs(dS) <= abs(dE) ? dS : dE }
            else if dS != 0 { shift = dS }
            else { shift = dE }
            newStart = max(0, sCand + shift)
            newDur = dc.baseDur
        }
        switch dc.row {
        case .image(let i):
            guard let ci = model.scene.imageTracks[i].cues.firstIndex(where: { $0.id == dc.cueID }) else { return }
            model.scene.imageTracks[i].cues[ci].start = newStart
            model.scene.imageTracks[i].cues[ci].dur = newDur
        case .light(let i):
            guard let ci = model.scene.lightTracks[i].cues.firstIndex(where: { $0.id == dc.cueID }) else { return }
            model.scene.lightTracks[i].cues[ci].start = newStart
            model.scene.lightTracks[i].cues[ci].dur = newDur
        case .background(let i):
            guard let ci = model.scene.backgroundTracks[i].cues.firstIndex(where: { $0.id == dc.cueID }) else { return }
            model.scene.backgroundTracks[i].cues[ci].start = newStart
            model.scene.backgroundTracks[i].cues[ci].dur = newDur
        default: break
        }
    }

    private func selectCue(row: TrackRow, id: String) {
        model.selectedTrackKey = row.key(in: model.scene)
        switch row {
        case .image: model.selectedImageCue = id
        case .light: model.selectedLightCue = id
        case .background: model.selectedBackgroundCue = id
        default: break
        }
    }

    private func handleTap(at point: CGPoint) {
        let y = point.y
        if let row = row(at: y), y - laneTop(of: row) < presenceStripH,
           !{ if case .background = row { return true }; return false }() {
            var events = presence(of: row)
            let t = (time(forX: point.x) * 10).rounded() / 10
            let isDoubleClick = lastTap.map {
                Date().timeIntervalSince($0.at) < 0.45 && abs($0.location.x - point.x) < 6
                    && abs($0.location.y - point.y) < 6
            } ?? false
            lastTap = (point, Date())
            if let idx = events.indices.first(where: { abs(x(forTime: events[$0].t) - point.x) < 8 }) {
                let rowKey = row.key(in: model.scene)
                let alreadySelected = selectedPresence?.rowKey == rowKey && selectedPresence?.index == idx
                if isCommandDown() || (isDoubleClick && alreadySelected) {
                    model.registerUndoSnapshot(label: "Delete Presence Marker")
                    events.remove(at: idx)
                    setPresence(row, events)
                    selectedPresence = nil
                } else {
                    selectedPresence = (rowKey, idx)
                }
                return
            }
            if selectedPresence != nil || model.selectedOutfitEvent != nil {
                // Click-away from a selection only deselects.
                selectedPresence = nil
                model.selectedOutfitEvent = nil
                return
            }
            if isHidden(row) {
                // Whole track is hidden — the next possible state is SHOW:
                // un-hide it and reveal from this point on.
                model.registerUndoSnapshot(label: "Show From Here")
                toggleHidden(row)
                if events.isEmpty {
                    events.append(VisibilityEvent(t: 0, visible: false))
                }
                events.append(VisibilityEvent(t: t, visible: true))
                setPresence(row, events)
                return
            }
            model.registerUndoSnapshot(label: "Toggle Presence")
            let visibleNow = events.isPresent(at: t)
            events.append(VisibilityEvent(t: t, visible: !visibleNow))
            setPresence(row, events)
            return
        }
        lastTap = (point, Date())
        // Click on a clip/cue label → rename in place.
        if let c = clip(at: point), labelZone(forClipStart: c.start, at: point) {
            editingText = c.name
            editorOpenedAt = Date()
            editingLabel = (.clip, c.id, labelOrigin(forStart: c.start, at: point))
            return
        }
        if let (row, cueHit) = cue(at: point), labelZone(forClipStart: cueHit.start, at: point) {
            editingText = currentCueLabel(row: row, id: cueHit.id)
            editorOpenedAt = Date()
            editingLabel = (.cue, cueHit.id, labelOrigin(forStart: cueHit.start, at: point))
            selectCue(row: row, id: cueHit.id)
            return
        }
        // Outfit-change dots: click selects (Delete removes); ⌘-click removes.
        if let dot = outfitEvent(at: point) {
            if isCommandDown() {
                model.selectedOutfitEvent = dot
                model.deleteTimelineSelection()
            } else if model.selectedOutfitEvent?.char == dot.char,
                      model.selectedOutfitEvent?.index == dot.index {
                model.selectedOutfitEvent = nil
            } else {
                model.selectedOutfitEvent = dot
            }
            return
        }
        if let slot = wardrobeSlot(at: point) {
            if model.selectedOutfitEvent != nil || selectedPresence != nil {
                model.selectedOutfitEvent = nil
                selectedPresence = nil
                return
            }
            outfitPopover = slot
            return
        }
        if model.selectedOutfitEvent != nil { model.selectedOutfitEvent = nil }
        let splitting = isCommandDown()
        if let hit = mark(at: point) {
            if splitting {
                splitMark(hit, at: time(forX: point.x))
            } else if model.selectedMarks.contains(hit) {
                model.selectedMarks.remove(hit)
            } else {
                model.selectedMarks.insert(hit)
            }
        } else if let c = clip(at: point) {
            let isDoubleClick = lastTap.map {
                Date().timeIntervalSince($0.at) < 0.45 && abs($0.location.x - point.x) < 6
                    && abs($0.location.y - point.y) < 6
            } ?? false
            if isDoubleClick, let row = row(at: point.y) {
                clipMix = (kind(of: row), c.id, point.x, point.y)
                return
            }
            if splitting {
                model.splitClip(id: c.id, at: time(forX: point.x))
            } else if model.selectedClips.contains(c.id) {
                model.selectedClips.remove(c.id)
            } else {
                model.selectedClips = [c.id]
            }
        } else if let (row, cue) = cue(at: point) {
            if splitting {
                switch row {
                case .background: model.splitBackgroundCue(id: cue.id, at: time(forX: point.x))
                case .light: model.splitLightCue(id: cue.id, at: time(forX: point.x))
                case .image: model.splitImageCue(id: cue.id, at: time(forX: point.x))
                default: selectCue(row: row, id: cue.id)
                }
            } else {
                selectCue(row: row, id: cue.id)
            }
        } else if case .audio(let ai) = row(at: y), !model.hasTimelineSelection {
            // Empty audio-lane click: bring in a file right here.
            audioImportAt = (ai, max(0, (time(forX: point.x) * 10).rounded() / 10))
        } else {
            model.selectedMarks = []
            model.selectedClips = []
            model.selectedImageCue = nil
            model.selectedBackgroundCue = nil
            if case .character(let i) = row(at: y) {
                model.selection = [i]
            }
        }
    }

    private func splitMark(_ mark: PerfMark, at t: Double) {
        guard t > mark.start + 0.05, t < mark.end - 0.05 else { return }
        model.registerUndoSnapshot(label: "Split Mark")
        var events = model.scene.characters[mark.character].events
        events.append(.key(t: ((t - 0.02) * 1000).rounded() / 1000, code: mark.code, down: false))
        events.append(.key(t: ((t + 0.02) * 1000).rounded() / 1000, code: mark.code, down: true))
        events.sort { $0.t < $1.t }
        model.scene.characters[mark.character].events = events
    }

    /// The top-left strip of a clip/cue where its name is drawn.
    private func labelZone(forClipStart start: Double, at point: CGPoint) -> Bool {
        let lx = x(forTime: start)
        guard point.x >= lx, point.x <= lx + 76 else { return false }
        guard let row = row(at: point.y) else { return false }
        let rowY = laneTop(of: row)
        switch row {
        case .image, .background, .light:
            return point.y >= rowY + presenceStripH && point.y <= rowY + presenceStripH + 16
        case .character:
            let zones = characterLaneZones(h: height(of: row))
            let clipTop = rowY + zones.clipTop
            return point.y >= clipTop && point.y <= clipTop + 14
        default:
            return point.y >= rowY + presenceStripH + 2 && point.y <= rowY + presenceStripH + 16
        }
    }

    private func labelOrigin(forStart start: Double, at point: CGPoint) -> CGPoint {
        guard let row = row(at: point.y) else { return point }
        let rowY = laneTop(of: row)
        switch row {
        case .image, .background, .light:
            return CGPoint(x: x(forTime: start) + 3, y: rowY + presenceStripH + 3)
        case .character:
            let zones = characterLaneZones(h: height(of: row))
            return CGPoint(x: x(forTime: start) + 3, y: rowY + zones.clipTop + 1)
        default:
            return CGPoint(x: x(forTime: start) + 3, y: rowY + presenceStripH + 3)
        }
    }

    private func currentCueLabel(row: TrackRow, id: String) -> String {
        switch row {
        case .image(let i):
            if let cue = model.scene.imageTracks[i].cues.first(where: { $0.id == id }) {
                return cue.label ?? assetName(cue.assetID)
            }
        case .light(let i):
            if let cue = model.scene.lightTracks[i].cues.first(where: { $0.id == id }) {
                return cue.label ?? "light"
            }
        case .background(let i):
            if let cue = model.scene.backgroundTracks[i].cues.first(where: { $0.id == id }) {
                return cue.label ?? assetName(cue.assetID)
            }
        default: break
        }
        return ""
    }

    private func isCommandDown() -> Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.command)
        #else
        false
        #endif
    }

    // MARK: - Hit tests

    private func mark(at point: CGPoint) -> PerfMark? {
        guard case .character(let i) = row(at: point.y) else { return nil }
        let rowY = laneTop(of: .character(i))
        let h = height(of: .character(i))
        let zones = characterLaneZones(h: h)
        for m in TimelineMath.marks(for: model.scene.characters[i].events, character: i,
                                    duration: model.duration) {
            let my = rowY + zones.eventTop + CGFloat(m.code.group.laneIndex) * zones.subH + 1
            let rect = CGRect(x: x(forTime: m.start), y: my,
                              width: max(6, CGFloat(m.end - m.start) * pxPerSecond),
                              height: max(4, zones.subH - 1))
            if rect.insetBy(dx: -2, dy: -2).contains(point) { return m }
        }
        return nil
    }

    private func clip(at point: CGPoint) -> AudioClip? {
        guard let row = row(at: point.y) else { return nil }
        let rowY = laneTop(of: row)
        let h = height(of: row)
        let clips: [AudioClip]
        let top: CGFloat
        let clipH: CGFloat
        switch row {
        case .character(let i):
            clips = model.scene.characters[i].clips
            let zones = characterLaneZones(h: h)
            top = rowY + zones.clipTop
            clipH = zones.clipH
        case .audio(let i):
            clips = model.scene.audioTracks[i].clips
            top = rowY + presenceStripH + 2
            clipH = h - presenceStripH - 6
        default: return nil
        }
        for clip in clips {
            let rect = CGRect(x: x(forTime: clip.start), y: top,
                              width: max(4, CGFloat(clip.dur) * pxPerSecond), height: clipH)
            if rect.contains(point) { return clip }
        }
        return nil
    }

    private func cue(at point: CGPoint) -> (TrackRow, (id: String, start: Double, dur: Double))? {
        guard let row = row(at: point.y) else { return nil }
        let rowY = laneTop(of: row)
        let h = height(of: row)
        func hit(_ start: Double, _ dur: Double) -> Bool {
            CGRect(x: x(forTime: start), y: rowY + presenceStripH + 2,
                   width: max(6, CGFloat(dur) * pxPerSecond),
                   height: h - presenceStripH - 6).contains(point)
        }
        switch row {
        case .image(let i):
            for cue in model.scene.imageTracks[i].cues where hit(cue.start, cue.dur) {
                return (row, (cue.id, cue.start, cue.dur))
            }
        case .light(let i):
            for cue in model.scene.lightTracks[i].cues where hit(cue.start, cue.dur) {
                return (row, (cue.id, cue.start, cue.dur))
            }
        case .background(let i):
            for cue in model.scene.backgroundTracks[i].cues where hit(cue.start, cue.dur) {
                return (row, (cue.id, cue.start, cue.dur))
            }
        default: break
        }
        return nil
    }

    private func commitLabelEdit() {
        guard let editing = editingLabel else { return }
        editingLabel = nil
        let name = editingText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            deleteCaptionIfEmpty(editing)
            return
        }
        switch editing.kind {
        case .clip: model.renameClip(id: editing.id, to: name)
        case .cue: model.renameCue(id: editing.id, to: name)
        case .caption:
            let parts = editing.id.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2, model.scene.characters.indices.contains(parts[0]),
                  model.scene.characters[parts[0]].subs.indices.contains(parts[1]) else { return }
            model.registerUndoSnapshot(label: "Edit Caption")
            model.scene.characters[parts[0]].subs[parts[1]].text = name
        }
    }

    /// Empty commit on a caption removes it (typing nothing = delete).
    private func deleteCaptionIfEmpty(_ editing: (kind: LabelKind, id: String, origin: CGPoint)) {
        guard editing.kind == .caption else { return }
        let parts = editing.id.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, model.scene.characters.indices.contains(parts[0]),
              model.scene.characters[parts[0]].subs.indices.contains(parts[1]) else { return }
        model.registerUndoSnapshot(label: "Delete Caption")
        model.scene.characters[parts[0]].subs.remove(at: parts[1])
    }

    private func deleteSelection() {
        if let sel = selectedPresence {
            for row in rows where row.key(in: model.scene) == sel.rowKey {
                var events = presence(of: row)
                if events.indices.contains(sel.index) {
                    model.registerUndoSnapshot(label: "Delete Presence Marker")
                    events.remove(at: sel.index)
                    setPresence(row, events)
                }
            }
            selectedPresence = nil
            return
        }
        if exportRangeSelected {
            model.registerUndoSnapshot(label: "Delete Export Range")
            model.exportRange = nil
            exportRangeSelected = false
            return
        }
        model.deleteTimelineSelection()
    }
}

struct TransportBar: View {
    @Bindable var model: StudioModel
    var file: ShowDocumentFile? = nil
    @AppStorage("studioLightMode") private var lightMode = false
    private var theme: Theme { lightMode ? .light : .dark }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: model.rewind) { Image(systemName: "backward.end.fill") }
                .help("Rewind (return playhead to 0)")
            Button(action: model.play) {
                Image(systemName: model.playing && !model.recording ? "pause.fill" : "play.fill")
            }
            .help("Play/Pause (Space)")
            // Record cluster: REC + what it records (armed event groups).
            HStack(spacing: 6) {
                Text(recTargetNames)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(model.recording ? Color.red
                                     : lightMode ? Color.black
                                     : Color.orange)
                    .lineLimit(1)
                Button(action: model.record) {
                    HStack(spacing: 4) {
                        Circle().fill(model.recording ? Color.white : Color.red.opacity(0.8))
                            .frame(width: 7, height: 7)
                        Text("REC")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(model.recording ? Color.white : theme.mutedText)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(model.recording ? Color.red : Color.primary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(model.recording ? Color.clear : Color.primary.opacity(0.22), lineWidth: 1))
                }
                .help("Record the selected characters (⇧Space)")
                if let key = model.selectedTrackKey,
                   model.scene.lightTracks.contains(where: { $0.id == key }) {
                    lightChip(title: "Move", keys: ["←", "→", "↑", "↓"])
                    lightChip(title: "Intensity", keys: ["−", "+"])
                    lightChip(title: "Size", keys: ["1", "2"])
                } else {
                    let pose = livePose
                    ForEach(EventGroup.allCases, id: \.self) { group in
                        armChip(group, pose: pose)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(theme.scrub, in: RoundedRectangle(cornerRadius: 6))
            Spacer()
            if let file {
                ShipButton(model: model, file: file)
            }
        }
        .buttonStyle(.borderless)
        .focusEffectDisabled()
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(theme.ruler)
    }

    /// The selected character's pose right now — drives the chip glow while
    /// playing back or holding keys. Nil when idle so nothing simulates.
    private var livePose: CharacterPose? {
        guard model.playing || !model.heldCodes.isEmpty,
              let i = model.selection.first,
              model.scene.characters.indices.contains(i) else { return nil }
        return model.simulator.pose(characterIndex: i, at: model.playing ? model.time : model.freeformClock)
    }

    /// Is this group's motion happening right now (held key or played-back event)?
    private func groupActive(_ group: EventGroup, pose: CharacterPose?) -> Bool {
        if model.heldCodes.contains(where: { $0.group == group }) { return true }
        guard model.playing, let pose else { return false }
        switch group {
        case .talk: return pose.talking
        case .blink: return pose.eye != .open
        case .jump: return pose.jump != nil
        case .tilt: return abs(pose.tilt) > 0.5
        case .move, .depth: return pose.moving
        }
    }

    /// Who REC will capture: the locked targets while recording, else the selection.
    private var recTargetNames: String {
        if let key = model.selectedTrackKey,
           let t = model.scene.lightTracks.first(where: { $0.id == key }) {
            return "\(t.name) — draw on stage"
        }
        let indices = model.recording ? Array(model.recTargets).sorted()
                                      : Array(model.selection).sorted()
        let names = indices.compactMap { i -> String? in
            guard let c = model.scene.characters[safe: i] else { return nil }
            return c.name.isEmpty ? "banny \((i + 1) % 10)" : c.name
        }
        return names.isEmpty ? "—" : names.joined(separator: ", ")
    }

    /// Key-hint chip for light control (matches the arm-chip look, yellow).
    private func lightChip(title: String, keys: [String]) -> some View {
        let tint = Color(red: 0.95, green: 0.78, blue: 0.25)
        return HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
            HStack(spacing: 2) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                        .frame(width: 11, height: 11)
                        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .stroke(tint.opacity(0.4), lineWidth: 0.5))
                }
            }
        }
        .foregroundStyle(tint.opacity(0.9))
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .stroke(tint.opacity(0.6), lineWidth: 1))
    }

    /// The physical keys that drive each group (web key map), one keycap each.
    private func chipKeys(_ group: EventGroup) -> [String] {
        switch group {
        case .move: return ["←", "→"]
        case .depth: return ["↑", "↓"]
        case .tilt: return ["N", "B"]
        case .talk: return ["M"]
        case .blink: return [",", ".", "/"]
        case .jump: return ["J"]
        }
    }

    private func chipTitle(_ group: EventGroup) -> String {
        switch group {
        case .move: return "Move L/R"
        case .depth: return "Move F/B"
        case .talk: return "mouth"
        default: return group.rawValue
        }
    }

    /// Labeled arm toggle: colored + filled when it records, hollow when it plays back.
    @ViewBuilder
    private func armChip(_ group: EventGroup, pose: CharacterPose?) -> some View {
        if let i = model.selection.first, model.scene.characters.indices.contains(i) {
            let armed = model.scene.characters[i].armedGroups.contains(group)
            let active = groupActive(group, pose: pose)
            let tint = group.color(light: lightMode)
            Button {
                var c = model.scene.characters[i]
                if armed { c.armedGroups.remove(group) } else { c.armedGroups.insert(group) }
                model.scene.characters[i] = c
            } label: {
                HStack(spacing: 4) {
                    Text(chipTitle(group))
                        .font(.system(size: 9, weight: .bold))
                    HStack(spacing: 2) {
                        ForEach(chipKeys(group), id: \.self) { key in
                            Text(key)
                                .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                                .frame(width: 11, height: 11)
                                .background((armed ? Color.black : tint).opacity(0.14),
                                            in: RoundedRectangle(cornerRadius: 3))
                                .overlay(RoundedRectangle(cornerRadius: 3)
                                    .stroke((armed ? Color.black : tint).opacity(0.4), lineWidth: 0.5))
                        }
                    }
                }
                .foregroundStyle(armed ? Color.black.opacity(lightMode ? 0.95 : 0.85)
                                        : tint.opacity(0.9))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(armed ? tint.opacity(lightMode ? 0.42 : 1)
                                  : tint.opacity(active ? 0.3 : 0.12),
                            in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(tint.opacity(armed ? (lightMode ? 0.8 : 0) : 0.6), lineWidth: 1))
                .shadow(color: tint.opacity(active ? 0.85 : 0), radius: active ? 5 : 0)
                .brightness(active ? 0.06 : 0)
                .animation(.easeOut(duration: 0.12), value: active)
            }
            .help("\(group.rawValue): \(armed ? "armed (records)" : "disarmed (plays back)")")
        }
    }
}

/// Scroll offset reporter for the pinned header/gutter overlays.
struct TLOffsetKey: PreferenceKey {
    static let defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {
        value = nextValue()
    }
}

#if os(macOS)
import AppKit

/// The pinned gutter sits over the timeline's scroll view, and scroll events
/// bubble up the canvas's responder chain without reaching any scroller. A
/// local event monitor catches wheel events over the gutter and hands them to
/// the scroll view just right of it.
struct GutterWheelRedirect: NSViewRepresentable {
    let gutterWidth: CGFloat

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.install(host: v)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var monitor: Any?
        private weak var host: NSView?

        func install(host: NSView) {
            self.host = host
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                guard let self, let host = self.host, let window = host.window,
                      event.window === window else { return event }
                let local = host.convert(event.locationInWindow, from: nil)
                guard host.bounds.contains(local) else { return event }
                // Forward to the scroll view immediately right of the gutter.
                if let content = window.contentView,
                   let scroll = Self.scrollView(in: content, atWindowPoint:
                        NSPoint(x: host.convert(NSPoint(x: host.bounds.maxX + 24, y: local.y), to: nil).x,
                                y: event.locationInWindow.y)) {
                    scroll.scrollWheel(with: event)
                    return nil
                }
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        static func scrollView(in root: NSView, atWindowPoint p: NSPoint) -> NSScrollView? {
            var found: NSScrollView?
            func walk(_ view: NSView) {
                if let sv = view as? NSScrollView {
                    let local = sv.superview?.convert(p, from: nil) ?? .zero
                    if sv.frame.contains(local) { found = sv }
                }
                for sub in view.subviews { walk(sub) }
            }
            walk(root)
            return found
        }
    }
}
#endif

/// Scroll offsets as a reference type: mutating it re-renders only observers.
@Observable
final class TLOffsets {
    var x: CGFloat = 0
    var y: CGFloat = 0
}
