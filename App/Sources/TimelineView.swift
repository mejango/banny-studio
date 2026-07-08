import SwiftUI
import BannyCore

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

    /// Sub-lane order inside a track row (7th lane = outfit changes).
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

    /// Remove the events backing a set of marks (delete selection).
    static func removeMarks(_ marks: Set<PerfMark>, from events: [PerfEvent]) -> [PerfEvent] {
        events.filter { ev in
            guard case .key(let t, let code, _) = ev else { return true }
            return !marks.contains { m in
                m.code == code && t >= m.start - 1e-6 && t <= m.end + 1e-6
            }
        }
    }

    /// Shift the events backing a set of marks by dt (drag-move selection).
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

/// The timeline panel: ruler + scrub bar, crop bar, one lane per character with
/// performance marks / clips / captions. Custom-drawn like the web timeline.
struct StudioTimelineView: View {
    @Bindable var model: StudioModel
    var file: ShowDocumentFile? = nil
    @State private var zoom: Double = 1
    @State private var selectedMarks: Set<PerfMark> = []
    @State private var selectedAnchor: Int?
    @State private var dragStartMarks: [Int: [PerfEvent]]?

    private let laneLabelWidth: CGFloat = 96
    private let rulerHeight: CGFloat = 18
    private let scrubHeight: CGFloat = 16
    private let cropHeight: CGFloat = 18
    private let laneHeight: CGFloat = 52

    var body: some View {
        VStack(spacing: 0) {
            TransportBar(model: model, file: file)
            ScrollView([.horizontal, .vertical]) {
                timelineCanvas
                    .frame(width: max(600, laneLabelWidth + contentWidth),
                           height: rulerHeight + scrubHeight + cropHeight
                                 + laneHeight * CGFloat(max(1, model.scene.characters.count)))
            }
            .background(Color(red: 0.078, green: 0.078, blue: 0.11))
        }
        .onDeleteCommand {
            deleteSelection()
        }
    }

    private var pxPerSecond: CGFloat {
        30 * zoom
    }

    private var contentWidth: CGFloat {
        CGFloat(model.duration) * pxPerSecond
    }

    private func x(forTime t: Double) -> CGFloat {
        laneLabelWidth + CGFloat(t) * pxPerSecond
    }

    private func time(forX x: CGFloat) -> Double {
        max(0, Double((x - laneLabelWidth) / pxPerSecond))
    }

    private var timelineCanvas: some View {
        Canvas { ctx, size in
            drawRuler(ctx: ctx, size: size)
            drawCropBar(ctx: ctx)
            drawLanes(ctx: ctx, size: size)
            drawPlayhead(ctx: ctx, size: size)
        }
        .gesture(interaction)
        .simultaneousGesture(MagnifyGesture().onChanged { g in
            zoom = min(16, max(1, zoom * g.velocity / 60 + zoom))
        })
    }

    // MARK: - Drawing

    private func drawRuler(ctx: GraphicsContext, size: CGSize) {
        ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: rulerHeight)),
                 with: .color(Color(red: 0.055, green: 0.055, blue: 0.086)))
        let step: Double = zoom >= 8 ? 1 : zoom >= 3 ? 5 : 10
        var t: Double = 0
        while t <= model.duration {
            let px = x(forTime: t)
            ctx.stroke(Path { $0.move(to: CGPoint(x: px, y: 10)); $0.addLine(to: CGPoint(x: px, y: rulerHeight)) },
                       with: .color(.gray), lineWidth: 1)
            ctx.draw(Text("\(Int(t))s").font(.system(size: 9)).foregroundStyle(.gray),
                     at: CGPoint(x: px + 12, y: 7))
            t += step
        }
        // Scrub strip.
        ctx.fill(Path(CGRect(x: 0, y: rulerHeight, width: size.width, height: scrubHeight)),
                 with: .color(Color(red: 0.09, green: 0.09, blue: 0.15)))
    }

    private func drawCropBar(ctx: GraphicsContext) {
        let y = rulerHeight + scrubHeight
        ctx.fill(Path(CGRect(x: 0, y: y, width: laneLabelWidth + contentWidth, height: cropHeight)),
                 with: .color(Color(red: 0.078, green: 0.063, blue: 0.13)))
        ctx.draw(Text("SHOW").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.purple),
                 at: CGPoint(x: 30, y: y + cropHeight / 2))
        let anchors = model.scene.cropAnchors.sorted()
        // Segments between adjacent anchors are clickable (handled in interaction).
        for (i, a) in anchors.enumerated() {
            let px = x(forTime: a)
            let isSel = selectedAnchor == i
            ctx.fill(Path(CGRect(x: px - 1, y: y, width: isSel ? 3 : 2, height: cropHeight)),
                     with: .color(isSel ? .white : Color(red: 0.8, green: 0.69, blue: 1)))
        }
        for pair in zip(anchors, anchors.dropFirst()) {
            let a = x(forTime: pair.0), b = x(forTime: pair.1)
            ctx.fill(Path(CGRect(x: a + 2, y: y + 2, width: b - a - 4, height: cropHeight - 4)),
                     with: .color(Color(red: 0.59, green: 0.47, blue: 1).opacity(0.14)))
        }
    }

    private func drawLanes(ctx: GraphicsContext, size: CGSize) {
        let top = rulerHeight + scrubHeight + cropHeight
        for (i, character) in model.scene.characters.enumerated() {
            let y = top + CGFloat(i) * laneHeight
            let rowRect = CGRect(x: 0, y: y, width: size.width, height: laneHeight)
            if model.selection.contains(i) {
                ctx.fill(Path(rowRect), with: .color(Color.white.opacity(0.03)))
            }
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y + laneHeight))
                              $0.addLine(to: CGPoint(x: size.width, y: y + laneHeight)) },
                       with: .color(.black), lineWidth: 1)
            // Label.
            ctx.draw(Text(character.name.isEmpty ? "\(i + 1)" : character.name)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(model.selection.contains(i) ? Color.orange : Color(white: 0.7)),
                     at: CGPoint(x: laneLabelWidth / 2, y: y + 12))
            // Performance marks in 6 sub-lanes.
            let subH = (laneHeight - 14) / 7
            for mark in TimelineMath.marks(for: character.events, character: i, duration: model.duration) {
                let my = y + 12 + CGFloat(mark.code.group.laneIndex) * subH + 2
                let rect = CGRect(x: x(forTime: mark.start), y: my,
                                  width: max(2, CGFloat(mark.end - mark.start) * pxPerSecond),
                                  height: subH - 1)
                ctx.fill(Path(rect), with: .color(mark.code.group.color.opacity(
                    selectedMarks.contains(mark) ? 1 : 0.75)))
                if selectedMarks.contains(mark) {
                    ctx.stroke(Path(rect.insetBy(dx: -1, dy: -1)), with: .color(.white), lineWidth: 1)
                }
            }
            // Outfit change diamonds (7th sub-lane).
            for ev in character.events {
                guard case .outfit(let t, _, _) = ev else { continue }
                let cx = x(forTime: t)
                let cy = y + 12 + 6 * subH + subH / 2
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 3, y: cy - 3, width: 6, height: 6)),
                         with: .color(.white))
            }
            // Audio clips (thin bars until phase 4 waveforms).
            for clip in character.clips {
                let rect = CGRect(x: x(forTime: clip.start), y: y + laneHeight - 10,
                                  width: CGFloat(clip.dur) * pxPerSecond, height: 8)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 2),
                         with: .color(Color(red: 0.3, green: 0.65, blue: 0.55).opacity(0.8)))
            }
            // Captions.
            for sub in character.subs {
                let rect = CGRect(x: x(forTime: sub.start), y: y + 2,
                                  width: CGFloat(sub.dur) * pxPerSecond, height: 8)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 2),
                         with: .color(Color(red: 1, green: 0.97, blue: 0.9).opacity(0.35)))
            }
        }
    }

    private func drawPlayhead(ctx: GraphicsContext, size: CGSize) {
        let px = x(forTime: model.time)
        ctx.stroke(Path { $0.move(to: CGPoint(x: px, y: 0)); $0.addLine(to: CGPoint(x: px, y: size.height)) },
                   with: .color(Color(red: 0.6, green: 1, blue: 0.6)), lineWidth: 1)
    }

    // MARK: - Interaction

    private var interaction: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let y = value.location.y
                if y < rulerHeight + scrubHeight {
                    model.seek(to: time(forX: value.location.x))
                } else if y < rulerHeight + scrubHeight + cropHeight {
                    handleCropDrag(value)
                } else {
                    handleLaneDrag(value)
                }
            }
            .onEnded { value in
                let y = value.location.y
                if value.translation.width.magnitude < 3, value.translation.height.magnitude < 3 {
                    handleTap(at: value.location)
                }
                if y >= rulerHeight + scrubHeight + cropHeight, dragStartMarks != nil {
                    model.registerUndoSnapshot(label: "Move Marks")
                }
                dragStartMarks = nil
                draggingAnchor = nil
            }
    }

    @State private var draggingAnchor: Int?

    private func handleCropDrag(_ value: DragGesture.Value) {
        let t = time(forX: value.location.x)
        let anchors = model.scene.cropAnchors.sorted()
        if draggingAnchor == nil {
            // Grab an existing anchor if within 6px.
            draggingAnchor = anchors.firstIndex {
                abs(x(forTime: $0) - value.startLocation.x) < 6
            } ?? -1
            model.scene.cropAnchors = anchors
        }
        if let i = draggingAnchor, i >= 0 {
            model.scene.cropAnchors[i] = t
            selectedAnchor = i
        }
    }

    private func handleLaneDrag(_ value: DragGesture.Value) {
        guard !selectedMarks.isEmpty else { return }
        let laneTop = rulerHeight + scrubHeight + cropHeight
        guard value.startLocation.y >= laneTop else { return }
        // Only drag when starting on a selected mark.
        if dragStartMarks == nil {
            guard let hit = mark(at: value.startLocation), selectedMarks.contains(hit) else { return }
            dragStartMarks = Dictionary(uniqueKeysWithValues:
                Set(selectedMarks.map(\.character)).map { ($0, model.scene.characters[$0].events) })
        }
        guard let base = dragStartMarks else { return }
        let dt = Double(value.translation.width / pxPerSecond)
        for (charIndex, events) in base {
            let charMarks = Set(selectedMarks.filter { $0.character == charIndex })
            model.scene.characters[charIndex].events =
                TimelineMath.shiftMarks(charMarks, in: events, by: dt)
        }
    }

    private func handleTap(at point: CGPoint) {
        let y = point.y
        let cropTop = rulerHeight + scrubHeight
        if y >= cropTop, y < cropTop + cropHeight {
            let anchors = model.scene.cropAnchors.sorted()
            let t = time(forX: point.x)
            // Tap on an anchor → select; inside a segment → add to Show; empty → drop anchor.
            if let i = anchors.firstIndex(where: { abs(x(forTime: $0) - point.x) < 6 }) {
                selectedAnchor = i
            } else if let seg = zip(anchors, anchors.dropFirst()).first(where: { t > $0.0 && t < $0.1 }) {
                model.addShowSegment(from: seg.0, to: seg.1)
            } else {
                model.registerUndoSnapshot(label: "Add Anchor")
                model.scene.cropAnchors.append((t * 10).rounded() / 10)
                model.scene.cropAnchors.sort()
                selectedAnchor = nil
            }
            return
        }
        if let hit = mark(at: point) {
            if selectedMarks.contains(hit) { selectedMarks.remove(hit) } else { selectedMarks.insert(hit) }
        } else if y >= cropTop + cropHeight {
            selectedMarks = []
            // Row click selects the character.
            let row = Int((y - cropTop - cropHeight) / laneHeight)
            if model.scene.characters.indices.contains(row) {
                model.selection = [row]
            }
        }
    }

    private func mark(at point: CGPoint) -> PerfMark? {
        let laneTop = rulerHeight + scrubHeight + cropHeight
        let row = Int((point.y - laneTop) / laneHeight)
        guard model.scene.characters.indices.contains(row) else { return nil }
        let subH = (laneHeight - 14) / 7
        let rowY = laneTop + CGFloat(row) * laneHeight
        for m in TimelineMath.marks(for: model.scene.characters[row].events, character: row,
                                    duration: model.duration) {
            let my = rowY + 12 + CGFloat(m.code.group.laneIndex) * subH + 2
            let rect = CGRect(x: x(forTime: m.start), y: my,
                              width: max(6, CGFloat(m.end - m.start) * pxPerSecond), height: subH - 1)
            if rect.insetBy(dx: -2, dy: -2).contains(point) { return m }
        }
        return nil
    }

    private func deleteSelection() {
        if let i = selectedAnchor, model.scene.cropAnchors.indices.contains(i) {
            model.registerUndoSnapshot(label: "Delete Anchor")
            model.scene.cropAnchors.sort()
            model.scene.cropAnchors.remove(at: i)
            selectedAnchor = nil
            return
        }
        guard !selectedMarks.isEmpty else { return }
        model.registerUndoSnapshot(label: "Delete Marks")
        for charIndex in Set(selectedMarks.map(\.character)) {
            let charMarks = Set(selectedMarks.filter { $0.character == charIndex })
            model.scene.characters[charIndex].events =
                TimelineMath.removeMarks(charMarks, from: model.scene.characters[charIndex].events)
        }
        selectedMarks = []
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
    }

    /// Arm toggles for the primary selected character.
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
