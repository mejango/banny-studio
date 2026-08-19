// Live mode is macOS only. It reaches a model through a bridge script run by
// NSUserUnixTask, which does not exist on iOS, and its set editor is built on
// AppKit — there is no version of this that works on a phone.
#if os(macOS)
import SwiftUI
import BannyCore

/// Where the groups stand, drawn on the set itself.
///
/// The model's read is a first draft, not a verdict. A set is the one thing in
/// a live scene that rewards being tuned by eye — the sunset bar looked right
/// because its standing places were matched to the stools, and no glance at an
/// image will find that on its own. Each band is drawn at the height the feet
/// will actually land, from the same ground-plane maths the renderer uses, so
/// a group standing in the bar rather than in front of it is visible here
/// rather than three minutes into a render.
struct LiveSetEditor: View {
    @Binding var set: LiveSet?
    /// Raised the moment a band is moved. A reading that lands afterwards is
    /// discarded rather than allowed to undo the drag it was racing.
    @Binding var handPlaced: Bool
    let backdrop: NSImage?
    var reading: Bool
    var onReadAgain: () -> Void

    /// The zone being dragged, and what it looked like when the drag began.
    @State private var dragging: (zone: LiveZone, spot: LiveSet.Spot)?

    private let zones: [LiveZone] = [.front, .middle, .far]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("The set")
                Spacer()
                if reading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Looking at it…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button("Let it read the set", action: onReadAgain)
                        .font(.caption)
                        .help("Ask the model where people can stand in this picture")
                        .accessibilityIdentifier("live-read-again")
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    if let backdrop {
                        Image(nsImage: backdrop)
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                    ForEach(zones, id: \.self) { zone in
                        band(zone, in: geo.size)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            }
            .frame(height: 190)
            .accessibilityIdentifier("live-set-editor")

            Text("Each band is a group, drawn where their feet will land. Drag it "
                 + "sideways to move them, the grips to widen, up or down for how "
                 + "far back they stand.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - One band

    private func band(_ zone: LiveZone, in size: CGSize) -> some View {
        let spot = spot(for: zone)
        let x0 = spot.from * size.width
        let x1 = spot.to * size.width
        let y = feetY(depth: spot.depth) * size.height
        let width = max(58, x1 - x0)

        // The grips live inside the chip. Overlays applied after .position()
        // attach to the container's edges rather than the band's, which put
        // all three pairs in the same place and let one band eat every drag.
        return ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(0.26))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.accentColor.opacity(0.95), lineWidth: 1))
            Text(zone.rawValue)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(radius: 1)
            HStack(spacing: 0) {
                handle(zone, edge: .lower, in: size)
                Spacer(minLength: 0)
                handle(zone, edge: .upper, in: size)
            }
        }
        .frame(width: width, height: 26)
        .contentShape(Rectangle())
        .gesture(dragBody(zone, in: size))
        .position(x: x0 + width / 2, y: y)
    }

    private enum Edge { case lower, upper }

    private func handle(_ zone: LiveZone, edge: Edge, in size: CGSize) -> some View {
        ZStack {
            // A grip you can see and a target you can hit are different sizes.
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor)
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(.white.opacity(0.65), lineWidth: 1))
                .frame(width: 8, height: 20)
            VStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule().fill(.white.opacity(0.8)).frame(width: 3, height: 1.5)
                }
            }
        }
        .frame(width: 22)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .highPriorityGesture(DragGesture(coordinateSpace: .named("set"))
                .onChanged { value in
                    var spot = dragging?.spot ?? self.spot(for: zone)
                    if dragging == nil { dragging = (zone, spot) }
                    let x = clamp(value.location.x / size.width, 0.01, 0.99)
                    if edge == .lower { spot.from = min(x, spot.to - 0.05) }
                    else { spot.to = max(x, spot.from + 0.05) }
                    write(spot, for: zone)
                }
                .onEnded { _ in dragging = nil })
    }

    private func dragBody(_ zone: LiveZone, in size: CGSize) -> some Gesture {
        DragGesture(coordinateSpace: .named("set"))
            .onChanged { value in
                if dragging == nil { dragging = (zone, spot(for: zone)) }
                guard let start = dragging?.spot else { return }
                var spot = start
                let dx = value.translation.width / size.width
                let width = start.to - start.from
                spot.from = clamp(start.from + dx, 0.0, 1 - width)
                spot.to = spot.from + width
                // Up the picture is further away.
                let dy = value.translation.height / size.height
                spot.depth = clamp(depth(atFeetY: feetY(depth: start.depth) + dy),
                                   -0.1, 0.85)
                write(spot, for: zone)
            }
            .onEnded { _ in dragging = nil }
    }

    // MARK: - Reading and writing the set

    private func spot(for zone: LiveZone) -> LiveSet.Spot {
        if let spot = set?.zones[zone.rawValue] { return spot }
        return LiveSet.Spot(from: zone.span.lowerBound,
                            to: zone.span.upperBound, depth: zone.depth)
    }

    private func write(_ spot: LiveSet.Spot, for zone: LiveZone) {
        handPlaced = true
        var next = set ?? LiveSet()
        next.zones[zone.rawValue] = spot
        // Editing by hand is its own reading of the room.
        if next.reading == nil { next.reading = "Placed by hand." }
        set = next
    }

    // MARK: - The ground plane, as the renderer sees it

    /// Where a performer's feet land, as a fraction of frame height.
    private func feetY(depth d: Double) -> Double {
        let up = max(0, d)
        let lift = 0.09 * up + 0.33 * (up * up) * (3 - 2 * up)
        return 0.929 - lift + max(0, -d) * 0.09
    }

    /// The inverse, by search: the curve is monotonic, so a walk is enough and
    /// is far easier to trust than an inverted cubic.
    private func depth(atFeetY y: Double) -> Double {
        var best = 0.0, error = Double.infinity
        var d = -0.1
        while d <= 0.9 {
            let e = abs(feetY(depth: d) - y)
            if e < error { error = e; best = d }
            d += 0.005
        }
        return best
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, v))
    }
}

/// A set you have tuned stays tuned. Keyed by the backdrop, so the same picture
/// brings its staging back next time.
enum LiveSetStore {
    private static func key(for url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return "liveSet.\(url.lastPathComponent).\(size)"
    }

    static func load(for url: URL) -> LiveSet? {
        guard let data = UserDefaults.standard.data(forKey: key(for: url)) else { return nil }
        return try? JSONDecoder().decode(LiveSet.self, from: data)
    }

    static func save(_ set: LiveSet?, for url: URL) {
        guard let set, let data = try? JSONEncoder().encode(set) else {
            UserDefaults.standard.removeObject(forKey: key(for: url))
            return
        }
        UserDefaults.standard.set(data, forKey: key(for: url))
    }
}

#endif
