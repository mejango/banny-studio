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
    @State private var dividerDragBase: Double?

    var body: some View {
        GeometryReader { geo in
            // Stage never letterboxes vertically: it takes exactly its 16:9 height
            // for the available width, and the timeline absorbs all remaining space.
            let stageWidth = Double(max(200, geo.size.width - 300))
            let requestedTL = min(max(120, timelineHeight), Double(geo.size.height) - 140)
            let stageH = min(stageWidth * 9.0 / 16.0, Double(geo.size.height) - 6 - requestedTL)
            let tlH = max(120, Double(geo.size.height) - 6 - stageH)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    StageView(model: model, file: file)
                        .frame(width: CGFloat(stageWidth), height: CGFloat(stageH))
                        .overlay(alignment: .bottom) {
                            if showDeck {
                                PerformanceDeck(model: model)
                            }
                        }
                    divider(maxHeight: Double(geo.size.height) - 140)
                    StudioTimelineView(model: model, file: file)
                        .frame(height: CGFloat(tlH))
                }
                Divider()
                SidePanel(model: model, file: file)
                    .frame(width: 300)
            }
        }
    }

    /// Drag up to grow the timeline (shrinking the stage), down to shrink it.
    /// Global coordinates: the divider itself moves during the drag, so local
    /// translation would feed back and oscillate.
    private func divider(maxHeight: Double) -> some View {
        Rectangle()
            .fill(Color(red: 0.16, green: 0.16, blue: 0.22))
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
