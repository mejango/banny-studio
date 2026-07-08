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
            let stageWidth = Double(max(200, geo.size.width - 300))
            let requestedTL = min(max(120, timelineHeight), availH - 140)
            let stageH = min(stageWidth * 9.0 / 16.0, availH - 6 - requestedTL)
            let tlH = max(120, availH - 6 - stageH)
            VStack(spacing: 0) {
                header
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        StageView(model: model, file: file)
                            .frame(width: CGFloat(stageWidth), height: CGFloat(stageH))
                            .overlay(alignment: .bottom) {
                                if showDeck {
                                    PerformanceDeck(model: model)
                                }
                            }
                        divider(maxHeight: availH - 140)
                        StudioTimelineView(model: model, file: file, showShip: false)
                            .frame(height: CGFloat(tlH))
                    }
                    Divider()
                    SidePanel(model: model, file: file)
                        .frame(width: 300)
                }
            }
            .background(theme.surface)
            // Drive SwiftUI's semantic colors (.primary on buttons/menus) from the
            // studio theme, not the system appearance.
            .environment(\.colorScheme, lightMode ? .light : .dark)
        }
    }

    private var header: some View {
        HStack {
            Image(lightMode ? "HeaderLogo" : "HeaderLogoDark")
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(height: 18)
            Text("BANNY STUDIO")
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .kerning(2)
                // Match the logo art: black in light mode, off-white in dark.
                .foregroundStyle(lightMode ? Color.black
                                           : Color(red: 0.92, green: 0.92, blue: 0.92))
            ThemeToggle()
                .padding(.leading, 6)
            Spacer()
            ShipButton(model: model, file: file)
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
            .frame(height: 6)
            .overlay(Capsule().fill(Color(white: 0.4)).frame(width: 48, height: 3))
            #if os(macOS)
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            #endif
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let base = dividerDragBase ?? timelineHeight
                    dividerDragBase = base
                    timelineHeight = min(max(200, maxHeight), max(120, base - Double(value.translation.height)))
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

/// Right panel: tracks, wardrobe, asset bank, script, physics, show playlist.
struct SidePanel: View {
    @Bindable var model: StudioModel
    var file: ShowDocumentFile? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                tracksSection
                if let i = model.selection.first, model.scene.characters.indices.contains(i) {
                    MotionSection(model: model, characterIndex: i)
                    ScriptSection(model: model, characterIndex: i)
                    WardrobePanel(model: model, characterIndex: i)
                }
                if model.selectedImageCuePath != nil {
                    ImageCueInspector(model: model)
                }
                if model.selectedLightCuePath != nil {
                    LightCueInspector(model: model)
                }
                if let file {
                    AssetBankSection(model: model, file: file)
                    AudioSection(model: model, file: file)
                }
                physicsSection
            }
            .padding(10)
        }
        .background(Color(red: 1, green: 0.99, blue: 0.95))
        // The panel is a light surface by design (webapp cream); pin it so
        // system dark mode doesn't render white-on-white chips.
        .environment(\.colorScheme, .light)
    }

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TRACKS").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(Array(model.scene.characters.enumerated()), id: \.offset) { i, c in
                HStack {
                    Text("\((i + 1) % 10)").font(.system(.caption, design: .monospaced).bold())
                        .foregroundStyle(.purple)
                    TextField("name", text: Binding(
                        get: { model.scene.characters[safe: i]?.name ?? "" },
                        set: { if model.scene.characters.indices.contains(i) { model.scene.characters[i].name = $0 } }))
                        .textFieldStyle(.plain).font(.caption)
                    Text(c.body.rawValue).font(.caption2).foregroundStyle(.secondary)
                    Button("×") { model.removeCharacter(at: i) }
                        .buttonStyle(.plain).foregroundStyle(.red)
                }
                .padding(4)
                .background(model.selection.contains(i) ? Color.orange.opacity(0.15) : .clear)
                .onTapGesture { model.selection = [i] }
            }
            HStack {
                ForEach(BannyCore.Body.allCases, id: \.self) { body in
                    Button("+ \(body.rawValue)") { model.addCharacter(body: body) }
                        .font(.caption2)
                }
                Button("+ light") { model.addLightTrack() }
                    .font(.caption2)
            }
            Text("audio / image / background tracks are added from AUDIO and the ASSET BANK; hide/show any track with the eye on its timeline lane")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var physicsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("STAGE").font(.caption.bold()).foregroundStyle(.secondary)
            slider("size", value: Binding(get: { model.scene.gSize }, set: { model.scene.gSize = $0 }),
                   range: 0.3...2.5)
            slider("depth scale", value: Binding(get: { model.scene.gScale }, set: { model.scene.gScale = $0 }),
                   range: 0...1.2)
            slider("gravity", value: Binding(get: { model.scene.gravity }, set: { model.scene.gravity = $0 }),
                   range: 0.3...2.5)
        }
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).font(.caption2).frame(width: 80, alignment: .leading)
            Slider(value: value, in: range)
        }
    }

}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
