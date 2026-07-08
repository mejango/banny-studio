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
    @State private var draggingClip: (id: String, baseStart: Double)?
    @State private var draggingCue: (row: TrackRow, cueID: String, baseStart: Double, baseDur: Double, edge: Int)?
    @State private var draggingSub: (char: Int, index: Int, baseStart: Double, baseDur: Double, edge: Int)?
    @State private var draggingPresence: (row: TrackRow, index: Int)?
    @State private var selectedPresence: (rowKey: String, index: Int)?
    @State private var lastTap: (location: CGPoint, at: Date)?
    @State private var resizingTrack: (key: String, baseHeight: CGFloat, minHeight: CGFloat)?
    @State private var draggingRow: (row: TrackRow, currentY: CGFloat)?
    @State private var peakCache = PeakCache()
    /// Per-track lane heights (session-scoped), keyed by TrackRow.key.
    @State private var trackHeights: [String: CGFloat] = [:]

    /// In-place label editing over the canvas.
    enum LabelKind { case clip, cue }
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
    private let rulerHeight: CGFloat = 18
    private let scrubHeight: CGFloat = 16
    private let defaultLaneHeight: CGFloat = 52

    var body: some View {
        VStack(spacing: 0) {
            TransportBar(model: model, file: showShip ? file : nil)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    gutterCanvas
                        .frame(width: laneLabelWidth, height: lanesTop + totalLaneHeight + 20)
                    ScrollView(.horizontal) {
                        ZStack(alignment: .topLeading) {
                            timelineCanvas
                            if let editing = editingLabel {
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
                        .frame(width: max(600, contentWidth + 40),
                               height: lanesTop + totalLaneHeight + 20, alignment: .topLeading)
                    }
                }
                newTrackRow
                }
            }
            .background(theme.surface)
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { g in
                        let base = pinchZoomBase ?? zoom
                        pinchZoomBase = base
                        zoom = min(16, max(1, base * g.magnification))
                    }
                    .onEnded { _ in pinchZoomBase = nil })
        }
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

    private var rows: [TrackRow] {
        model.scene.characters.indices.map(TrackRow.character)
            + model.scene.imageTracks.indices.map(TrackRow.image)
            + model.scene.audioTracks.indices.map(TrackRow.audio)
            + model.scene.lightTracks.indices.map(TrackRow.light)
            + model.scene.backgroundTracks.indices.map(TrackRow.background)
    }

    private var headerHeight: CGFloat { rulerHeight + scrubHeight }
    /// Global closed-caption strip: one row above all tracks.
    private let captionsRowH: CGFloat = 22
    private var lanesTop: CGFloat { headerHeight + captionsRowH }

    private func minHeight(of row: TrackRow) -> CGFloat {
        if case .character = row { return 64 }   // presence + audio + 7 event rows
        return 44
    }

    private func height(of row: TrackRow) -> CGFloat {
        let base: CGFloat
        if case .character = row { base = 72 } else { base = defaultLaneHeight }
        return max(minHeight(of: row), trackHeights[row.key(in: model.scene)] ?? base)
    }

    private var totalLaneHeight: CGFloat {
        rows.reduce(0) { $0 + height(of: $1) }
    }

    private func laneTop(of row: TrackRow) -> CGFloat {
        var y = lanesTop
        for r in rows {
            if r == row { return y }
            y += height(of: r)
        }
        return y
    }

    private func row(at y: CGFloat) -> TrackRow? {
        var top = lanesTop
        for r in rows {
            let h = height(of: r)
            if y >= top && y < top + h { return r }
            top += h
        }
        return nil
    }

    private var pxPerSecond: CGFloat { 30 * zoom }
    private var contentWidth: CGFloat { CGFloat(model.duration) * pxPerSecond }
    private func x(forTime t: Double) -> CGFloat { 4 + CGFloat(t) * pxPerSecond }
    private func time(forX x: CGFloat) -> Double { max(0, Double((x - 4) / pxPerSecond)) }

    /// Always the last row: create any track type in place.
    private var newTrackRow: some View {
        HStack {
            Menu {
                Menu("Character") {
                    ForEach(BannyCore.Body.allCases, id: \.self) { body in
                        Button(body.rawValue) { model.addCharacter(body: body) }
                    }
                }
                Button("Audio") { model.addAudioTrack() }
                Button("Light") { model.addLightTrack() }
                Menu("Image") {
                    let imageAssets = model.document.assets.filter { $0.kind == .image }
                    if imageAssets.isEmpty {
                        Text("add an image to the Asset Bank first")
                    }
                    ForEach(imageAssets) { asset in
                        Button(asset.name) { model.addImageTrack(assetID: asset.id, assetName: asset.name) }
                    }
                }
            } label: {
                Label("New track", systemImage: "plus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .padding(.leading, 12)
            .frame(width: laneLabelWidth, height: 30, alignment: .leading)
            .background(theme.newTrack)
            Spacer()
        }
        .frame(height: 30)
    }

    /// Pinned label gutter: names, eye toggles, track-height pills, width handle.
    private var gutterCanvas: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(theme.gutterBase))
            ctx.draw(Text("CC").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.mutedText),
                     at: CGPoint(x: 12, y: headerHeight + captionsRowH / 2), anchor: .leading)
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: 0, y: lanesTop))
                p.addLine(to: CGPoint(x: size.width, y: lanesTop))
            }, with: .color(.black), lineWidth: 1)
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: size.width - 0.5, y: 0))
                p.addLine(to: CGPoint(x: size.width - 0.5, y: size.height))
            }, with: .color(theme.gutterDivider), lineWidth: 1)
            for row in rows {
                let y = laneTop(of: row)
                let h = height(of: row)
                let hidden = isHidden(row)
                // Lighter cell over the base, bounded by strong dark separators.
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: h - 2)),
                         with: .color(theme.gutterCell))
                if draggingRow?.row == row {
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: h)),
                             with: .color(Color.white.opacity(0.08)))
                }
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: 0, y: y + h - 1))
                    p.addLine(to: CGPoint(x: size.width, y: y + h - 1))
                }, with: .color(.black), lineWidth: 2)
                let pillActive = resizingTrack?.key == row.key(in: model.scene)
                ctx.fill(Path(roundedRect: CGRect(x: size.width / 2 - 16, y: y + h - 9,
                                                  width: 32, height: 3), cornerRadius: 1.5),
                         with: .color(Color(white: pillActive ? 0.8 : 0.4)))
                // Name + whole-track eye sit on the presence-strip line, so the
                // eye reads as the label of that show/hide row.
                var labelCtx = ctx
                if hidden { labelCtx.opacity = 0.35 }
                labelCtx.draw(Text(label(for: row)).font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(labelColor(for: row)),
                              at: CGPoint(x: 12, y: y + presenceStripH / 2), anchor: .leading)
                ctx.draw(Text(Image(systemName: hidden ? "eye.slash" : "eye"))
                            .font(.system(size: 10))
                            .foregroundStyle(hidden ? Color.gray : theme.mutedText),
                         at: CGPoint(x: size.width - 18, y: y + presenceStripH / 2))
            }
            if let dragging = draggingRow,
               let targetY = insertionLineY(for: dragging) {
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: 0, y: targetY))
                    p.addLine(to: CGPoint(x: size.width, y: targetY))
                }, with: .color(.orange), lineWidth: 2)
            }
        }
        .gesture(gutterInteraction)
        #if os(macOS)
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                if abs(p.x - laneLabelWidth) < 6 {
                    NSCursor.resizeLeftRight.set()
                } else if rowNearBottomEdge(of: p.y) != nil {
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
    private func groupRows(of row: TrackRow) -> [TrackRow] {
        switch row {
        case .character: return model.scene.characters.indices.map(TrackRow.character)
        case .image: return model.scene.imageTracks.indices.map(TrackRow.image)
        case .audio: return model.scene.audioTracks.indices.map(TrackRow.audio)
        case .light: return model.scene.lightTracks.indices.map(TrackRow.light)
        case .background: return model.scene.backgroundTracks.indices.map(TrackRow.background)
        }
    }

    private func dropIndex(for dragging: (row: TrackRow, currentY: CGFloat)) -> Int? {
        let group = groupRows(of: dragging.row)
        guard group.count > 1 else { return nil }
        var best = 0
        for (i, r) in group.enumerated() {
            if dragging.currentY > laneTop(of: r) + height(of: r) / 2 { best = i + 1 }
        }
        return min(best, group.count)
    }

    private func insertionLineY(for dragging: (row: TrackRow, currentY: CGFloat)) -> CGFloat? {
        guard let idx = dropIndex(for: dragging) else { return nil }
        let group = groupRows(of: dragging.row)
        if idx < group.count { return laneTop(of: group[idx]) }
        let last = group[group.count - 1]
        return laneTop(of: last) + height(of: last)
    }

    private var gutterInteraction: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if editingLabel != nil { commitLabelEdit(); return }
                if resizingGutter {
                    laneLabelWidthStore = min(300, max(60, Double(value.location.x)))
                    return
                }
                if let tr = resizingTrack {
                    let delta = value.location.y - value.startLocation.y
                    trackHeights[tr.key] = min(320, max(tr.minHeight, tr.baseHeight + delta))
                    return
                }
                if let dragging = draggingRow {
                    draggingRow = (dragging.row, value.location.y)
                    return
                }
                if abs(value.startLocation.x - laneLabelWidth) < 6 {
                    resizingGutter = true
                    return
                }
                if let row = rowNearBottomEdge(of: value.startLocation.y) {
                    resizingTrack = (row.key(in: model.scene), height(of: row), minHeight(of: row))
                    return
                }
                // Vertical pull on a row label lifts the row for reordering.
                if abs(value.translation.height) > 8,
                   value.startLocation.y >= lanesTop,
                   let row = row(at: value.startLocation.y) {
                    draggingRow = (row, value.location.y)
                }
            }
            .onEnded { value in
                if let dragging = draggingRow {
                    commitRowMove(dragging)
                    draggingRow = nil
                    resizingTrack = nil
                    resizingGutter = false
                    return
                }
                if value.translation.width.magnitude < 3, value.translation.height.magnitude < 3,
                   let row = row(at: value.location.y) {
                    if value.location.x > laneLabelWidth - 24 {
                        toggleHidden(row)
                    } else if case .character(let i) = row {
                        model.selection = [i]
                    }
                }
                resizingTrack = nil
                resizingGutter = false
            }
    }

    private func commitRowMove(_ dragging: (row: TrackRow, currentY: CGFloat)) {
        guard let target = dropIndex(for: dragging) else { return }
        model.registerUndoSnapshot(label: "Reorder Tracks")
        func move<T>(_ items: inout [T], from: Int, to rawTo: Int) {
            let item = items.remove(at: from)
            let to = rawTo > from ? rawTo - 1 : rawTo
            items.insert(item, at: min(max(0, to), items.count))
        }
        switch dragging.row {
        case .character(let i):
            move(&model.scene.characters, from: i, to: target)
            // Indices shifted: selection follows the moved row; marks reset.
            let newIndex = target > i ? target - 1 : target
            model.selection = [newIndex]
            model.selectedMarks = []
        case .image(let i):
            move(&model.scene.imageTracks, from: i, to: target)
        case .audio(let i):
            move(&model.scene.audioTracks, from: i, to: target)
        case .light(let i):
            move(&model.scene.lightTracks, from: i, to: target)
        case .background(let i):
            move(&model.scene.backgroundTracks, from: i, to: target)
        }
    }

    private var timelineCanvas: some View {
        Canvas { ctx, size in
            drawRuler(ctx: ctx, size: size)
            drawCaptionsRow(ctx: ctx, size: size)
            for row in rows { drawLane(row, ctx: ctx, size: size) }
            drawPlayhead(ctx: ctx, size: size)
        }
        .gesture(interaction)
    }

    // MARK: - Drawing

    private func drawRuler(ctx: GraphicsContext, size: CGSize) {
        ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: rulerHeight)),
                 with: .color(theme.ruler))
        let step: Double = zoom >= 8 ? 1 : zoom >= 3 ? 5 : 10
        var t: Double = 0
        while t <= model.duration {
            let px = x(forTime: t)
            ctx.stroke(Path { $0.move(to: CGPoint(x: px, y: 10)); $0.addLine(to: CGPoint(x: px, y: rulerHeight)) },
                       with: .color(.gray), lineWidth: 1)
            ctx.draw(Text("\(Int(t))s").font(.system(size: 9)).foregroundStyle(theme.mutedText),
                     at: CGPoint(x: px + 12, y: 7))
            t += step
        }
        ctx.fill(Path(CGRect(x: 0, y: rulerHeight, width: size.width, height: scrubHeight)),
                 with: .color(theme.scrub))
    }

    private func drawLane(_ row: TrackRow, ctx: GraphicsContext, size: CGSize) {
        let y = laneTop(of: row)
        let h = height(of: row)
        let hidden = isHidden(row)

        if isSelectedRow(row) {
            ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: h)),
                     with: .color(Color.white.opacity(0.03)))
        }
        ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y + h)); $0.addLine(to: CGPoint(x: size.width, y: y + h)) },
                   with: .color(.black), lineWidth: 1)

        drawPresenceStrip(row, y: y, ctx: ctx)

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
                           label: (cue.label ?? "light") + String(format: " %.0f%%", cue.from.intensity * 100),
                           assetID: "",
                           selected: model.selectedLightCue == cue.id,
                           animated: cue.to != nil, ctx: content)
            }
        case .background(let i):
            for cue in model.scene.backgroundTracks[i].cues {
                drawCueBar(start: cue.start, dur: cue.dur, y: y, h: h,
                           color: Color(red: 0.45, green: 0.4, blue: 0.85),
                           label: cue.label ?? assetName(cue.assetID),
                           assetID: cue.assetID,
                           selected: model.selectedBackgroundCue == cue.id,
                           animated: false, ctx: content)
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
    private func characterLaneZones(h: CGFloat) -> (clipTop: CGFloat, clipH: CGFloat,
                                                    eventTop: CGFloat, subH: CGFloat) {
        let clipH: CGFloat = max(14, (h - presenceStripH - 8) * 0.45)
        let clipTop = presenceStripH + 2
        let eventTop = clipTop + clipH + 2
        let subH = max(2, (h - eventTop - 4) / 7)
        return (clipTop, clipH, eventTop, subH)
    }

    /// The global CC strip: every character's captions, tinted per speaker body color.
    private func drawCaptionsRow(ctx: GraphicsContext, size: CGSize) {
        let y = headerHeight
        ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: captionsRowH)),
                 with: .color(theme.ccRow))
        ctx.stroke(Path { p in
            p.move(to: CGPoint(x: 0, y: y + captionsRowH))
            p.addLine(to: CGPoint(x: size.width, y: y + captionsRowH))
        }, with: .color(.black), lineWidth: 1)
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
                           with: .color(.white), lineWidth: 1)
            }
            ctx.draw(Text(Image(systemName: ev.visible ? "eye.fill" : "eye.slash.fill"))
                        .font(.system(size: 8))
                        .foregroundStyle(ev.visible ? Color(red: 0.5, green: 0.95, blue: 0.65)
                                                    : Color(red: 0.95, green: 0.5, blue: 0.45)),
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
            ctx.fill(Path(rect), with: .color(mark.code.group.color.opacity(
                model.selectedMarks.contains(mark) ? 1 : 0.75)))
            if model.selectedMarks.contains(mark) {
                ctx.stroke(Path(rect.insetBy(dx: -1, dy: -1)), with: .color(.white), lineWidth: 1)
            }
        }
        for ev in character.events {
            guard case .outfit(let t, _, _) = ev else { continue }
            let cx = x(forTime: t)
            let cy = y + zones.eventTop + 6 * zones.subH + zones.subH / 2
            ctx.fill(Path(ellipseIn: CGRect(x: cx - 3, y: cy - 3, width: 6, height: 6)),
                     with: .color(.white))
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
                            ctx: GraphicsContext) {
        let rect = CGRect(x: x(forTime: start), y: y + presenceStripH + 2,
                          width: max(6, CGFloat(dur) * pxPerSecond), height: h - presenceStripH - 6)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(color.opacity(0.55)))
        // Tile the asset's image across the band.
        if let thumb = cueThumbs.thumb(assetID: assetID, file: file) {
            var tiled = ctx
            tiled.clip(to: Path(roundedRect: rect, cornerRadius: 4))
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
        ctx.stroke(Path(roundedRect: rect, cornerRadius: 4),
                   with: .color(selected ? .white : color), lineWidth: selected ? 1.5 : 1)
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
                   with: .color(Color(red: 0.6, green: 1, blue: 0.6)), lineWidth: 1)
    }

    // MARK: - Row helpers

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
            return model.selection.contains(i) ? .orange : theme.labelText
        case .audio: return Color(red: 0.45, green: 0.9, blue: 0.75)
        case .image: return Color(red: 0.9, green: 0.7, blue: 0.4)
        case .light: return Color(red: 1, green: 0.85, blue: 0.35)
        case .background: return Color(red: 0.65, green: 0.6, blue: 0.95)
        }
    }

    private func isSelectedRow(_ row: TrackRow) -> Bool {
        if case .character(let i) = row { return model.selection.contains(i) }
        return false
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
                let y = value.startLocation.y
                if y < headerHeight {
                    // Horizontal scrubs; vertical zooms (down = in, up = out, web-style).
                    model.seek(to: time(forX: value.location.x))
                    let base = scrubZoomBase ?? zoom
                    scrubZoomBase = base
                    let dy = Double(value.translation.height)
                    if abs(dy) > 8 {
                        zoom = min(16, max(1, base * pow(2, dy / 90)))
                    }
                } else {
                    handleLaneDrag(value)
                }
            }
            .onEnded { value in
                if value.translation.width.magnitude < 3, value.translation.height.magnitude < 3 {
                    handleTap(at: value.location)
                }
                if dragStartMarks != nil || resizing != nil || draggingClip != nil
                    || draggingCue != nil || draggingSub != nil || draggingPresence != nil {
                    model.registerUndoSnapshot(label: "Edit Timeline")
                }
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

    private func handleLaneDrag(_ value: DragGesture.Value) {
        guard value.startLocation.y >= headerHeight else { return }

        if let dragging = draggingClip {
            let dt = Double(value.translation.width / pxPerSecond)
            model.moveClip(id: dragging.id, toStart: dragging.baseStart + dt)
            return
        }
        if let r = resizing {
            let t = time(forX: value.location.x)
            model.scene.characters[r.mark.character].events =
                TimelineMath.resizeMark(r.mark, leading: r.leading, to: t, in: r.baseEvents)
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
            let t = max(0, time(forX: value.location.x))
            var events = presence(of: dp.row)
            guard events.indices.contains(dp.index) else { return }
            events[dp.index].t = (t * 10).rounded() / 10
            setPresence(dp.row, events)
            return
        }
        if dragStartMarks == nil {
            if value.startLocation.y >= lanesTop,
               let row = row(at: value.startLocation.y),
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
            if let st = subtitle(at: value.startLocation) {
                let edge = 4.0
                let startX = x(forTime: st.sub.start)
                let endX = x(forTime: st.sub.start + st.sub.dur)
                let e = abs(value.startLocation.x - startX) < edge ? -1
                    : abs(value.startLocation.x - endX) < edge ? 1 : 0
                draggingSub = (st.char, st.index, st.sub.start, st.sub.dur, e)
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
                    dragStartMarks = Dictionary(uniqueKeysWithValues:
                        Set(model.selectedMarks.map(\.character)).map { ($0, model.scene.characters[$0].events) })
                }
            } else if let c = clip(at: value.startLocation) {
                draggingClip = (c.id, c.start)
                model.selectedClips = [c.id]
                return
            } else if let (row, cue) = cue(at: value.startLocation) {
                let edge = 5.0
                let startX = x(forTime: cue.start)
                let endX = x(forTime: cue.start + cue.dur)
                let e = abs(value.startLocation.x - startX) < edge ? -1
                    : abs(value.startLocation.x - endX) < edge ? 1 : 0
                draggingCue = (row, cue.id, cue.start, cue.dur, e)
                selectCue(row: row, id: cue.id)
                return
            }
        }
        guard let base = dragStartMarks else { return }
        let dt = Double(value.translation.width / pxPerSecond)
        for (charIndex, events) in base {
            let charMarks = Set(model.selectedMarks.filter { $0.character == charIndex })
            model.scene.characters[charIndex].events =
                TimelineMath.shiftMarks(charMarks, in: events, by: dt)
        }
    }

    private func applyCueDrag(_ dc: (row: TrackRow, cueID: String, baseStart: Double, baseDur: Double, edge: Int),
                              translation dt: Double) {
        func update(start: inout Double, dur: inout Double) {
            switch dc.edge {
            case -1:
                let newStart = max(0, min(dc.baseStart + dt, dc.baseStart + dc.baseDur - 0.2))
                dur = dc.baseDur + (dc.baseStart - newStart)
                start = newStart
            case 1:
                dur = max(0.2, dc.baseDur + dt)
            default:
                start = max(0, dc.baseStart + dt)
            }
        }
        switch dc.row {
        case .image(let i):
            guard let ci = model.scene.imageTracks[i].cues.firstIndex(where: { $0.id == dc.cueID }) else { return }
            update(start: &model.scene.imageTracks[i].cues[ci].start,
                   dur: &model.scene.imageTracks[i].cues[ci].dur)
        case .light(let i):
            guard let ci = model.scene.lightTracks[i].cues.firstIndex(where: { $0.id == dc.cueID }) else { return }
            update(start: &model.scene.lightTracks[i].cues[ci].start,
                   dur: &model.scene.lightTracks[i].cues[ci].dur)
        case .background(let i):
            guard let ci = model.scene.backgroundTracks[i].cues.firstIndex(where: { $0.id == dc.cueID }) else { return }
            update(start: &model.scene.backgroundTracks[i].cues[ci].start,
                   dur: &model.scene.backgroundTracks[i].cues[ci].dur)
        default: break
        }
    }

    private func selectCue(row: TrackRow, id: String) {
        switch row {
        case .image: model.selectedImageCue = id
        case .light: model.selectedLightCue = id
        case .background: model.selectedBackgroundCue = id
        default: break
        }
    }

    private func handleTap(at point: CGPoint) {
        let y = point.y
        if let row = row(at: y), y - laneTop(of: row) < presenceStripH, y >= lanesTop {
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
            selectedPresence = nil
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
            editingLabel = (.clip, c.id, labelOrigin(forStart: c.start, at: point))
            return
        }
        if let (row, cueHit) = cue(at: point), labelZone(forClipStart: cueHit.start, at: point) {
            editingText = currentCueLabel(row: row, id: cueHit.id)
            editingLabel = (.cue, cueHit.id, labelOrigin(forStart: cueHit.start, at: point))
            selectCue(row: row, id: cueHit.id)
            return
        }
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
            if splitting {
                model.splitClip(id: c.id, at: time(forX: point.x))
            } else if model.selectedClips.contains(c.id) {
                model.selectedClips.remove(c.id)
            } else {
                model.selectedClips = [c.id]
            }
        } else if let (row, cue) = cue(at: point) {
            selectCue(row: row, id: cue.id)
        } else if y >= headerHeight {
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

    /// Caption bar under the pointer (the global CC strip above the lanes).
    private func subtitle(at point: CGPoint) -> (char: Int, index: Int, sub: Subtitle)? {
        guard point.y >= headerHeight, point.y < lanesTop else { return nil }
        for (ci, character) in model.scene.characters.enumerated().reversed() {
            for (si, sub) in character.subs.enumerated() {
                let rect = CGRect(x: x(forTime: sub.start), y: headerHeight + 2,
                                  width: max(8, CGFloat(sub.dur) * pxPerSecond), height: captionsRowH - 4)
                if rect.insetBy(dx: -2, dy: 0).contains(point) { return (ci, si, sub) }
            }
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
        guard !name.isEmpty else { return }
        switch editing.kind {
        case .clip: model.renameClip(id: editing.id, to: name)
        case .cue: model.renameCue(id: editing.id, to: name)
        }
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
        model.deleteTimelineSelection()
    }
}

struct TransportBar: View {
    @Bindable var model: StudioModel
    var file: ShowDocumentFile? = nil

    var body: some View {
        HStack(spacing: 12) {
            Button(action: model.rewind) { Image(systemName: "backward.end.fill") }
                .help("Rewind (return playhead to 0)")
            Button(action: model.play) {
                Image(systemName: model.playing && !model.recording ? "pause.fill" : "play.fill")
            }
            .help("Play/Pause (Space)")
            Button(action: model.record) {
                Text("● REC")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(model.recording ? .white : .red)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(model.recording ? Color.red : Color.clear)
            }
            .help("Record the selected characters (⇧Space)")
            Text(String(format: "%.1f / %.0fs", model.time, model.duration))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.green)
            Spacer()
            ForEach(EventGroup.allCases, id: \.self) { group in
                armDot(group)
            }
            if let file {
                ShipButton(model: model, file: file)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(red: 0.055, green: 0.055, blue: 0.086))
        // Transport stays dark in both themes: its colored dots/labels are tuned for it.
    }

    @ViewBuilder
    private func armDot(_ group: EventGroup) -> some View {
        if let i = model.selection.first, model.scene.characters.indices.contains(i) {
            let armed = model.scene.characters[i].armedGroups.contains(group)
            Button {
                var c = model.scene.characters[i]
                if armed { c.armedGroups.remove(group) } else { c.armedGroups.insert(group) }
                model.scene.characters[i] = c
            } label: {
                Circle().fill(group.color.opacity(armed ? 1 : 0.2))
                    .frame(width: 10, height: 10)
            }
            .help("\(group.rawValue): \(armed ? "armed (records)" : "disarmed (plays back)")")
        }
    }
}
