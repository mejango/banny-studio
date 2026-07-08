import SwiftUI
import BannyCore

/// Main editor layout, adaptive per platform:
/// - macOS / iPad (regular width): scene tabs / stage / timeline + side panel,
///   with a touch performance deck overlay on iPad.
/// - iPhone (compact width): one region at a time behind a mode switcher.
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

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                SceneTabsView(model: model)
                StageView(model: model, file: file)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        if showDeck {
                            PerformanceDeck(model: model)
                        }
                    }
                StudioTimelineView(model: model, file: file)
                    .frame(height: 230)
            }
            Divider()
            SidePanel(model: model, file: file)
                .frame(width: 300)
        }
    }
}

/// iPhone layout: Stage / Timeline / Wardrobe / Watch, one at a time.
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
                SceneTabsView(model: model)
                StageView(model: model, file: file)
                    .frame(height: 180)
                StudioTimelineView(model: model, file: file)
            case .wardrobe:
                SidePanel(model: model, file: file)
            }
        }
    }
}

struct SceneTabsView: View {
    @Bindable var model: StudioModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(Array(model.document.scenes.enumerated()), id: \.element.id) { i, scene in
                    HStack(spacing: 8) {
                        Text(scene.name).font(.system(size: 12, weight: .semibold))
                        if model.document.scenes.count > 1 {
                            Button("×") { model.removeScene(at: i) }
                                .buttonStyle(.plain)
                                .foregroundStyle(i == model.activeSceneIndex ? .white : .red)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(i == model.activeSceneIndex ? Color.orange : Color(white: 0.12))
                    .foregroundStyle(i == model.activeSceneIndex ? .white : Color(white: 0.75))
                    .onTapGesture { model.switchScene(to: i) }
                }
                Button("+ Scene") { model.addScene() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Color(red: 0.07, green: 0.13, blue: 0.06))
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 34)
        .background(Color(red: 0.055, green: 0.055, blue: 0.086))
    }
}

/// Right panel: cast, wardrobe, audio, background, script, physics, show playlist.
struct SidePanel: View {
    @Bindable var model: StudioModel
    var file: ShowDocumentFile? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                castSection
                if let i = model.selection.first, model.scene.characters.indices.contains(i) {
                    MotionSection(model: model, characterIndex: i)
                    ScriptSection(model: model, characterIndex: i)
                    WardrobePanel(model: model, characterIndex: i)
                }
                if let file {
                    AudioSection(model: model, file: file)
                }
                BackgroundSection(model: model)
                physicsSection
                showSection
            }
            .padding(10)
        }
        .background(Color(red: 1, green: 0.99, blue: 0.95))
        // The panel is a light surface by design (webapp cream); pin it so
        // system dark mode doesn't render white-on-white chips.
        .environment(\.colorScheme, .light)
    }

    private var castSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CAST").font(.caption.bold()).foregroundStyle(.secondary)
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
        }
    }

    private var physicsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SCENE").font(.caption.bold()).foregroundStyle(.secondary)
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

    private var showSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SHOW").font(.caption.bold()).foregroundStyle(.secondary)
            if model.document.show.isEmpty {
                Text("Drop anchors on the SHOW bar, then tap a segment to add it.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array(model.document.show.enumerated()), id: \.offset) { i, seg in
                HStack {
                    Text("\(i + 1)").font(.caption2.bold()).foregroundStyle(.purple)
                    Text(seg.name).font(.caption2).lineLimit(1)
                    Spacer()
                    Button("×") { model.document.show.remove(at: i) }
                        .buttonStyle(.plain).foregroundStyle(.red)
                }
                .padding(4)
                .background(Color(red: 1, green: 0.97, blue: 0.9))
            }
            let total = model.document.show.reduce(0) { $0 + ($1.to - $1.from) }
            if total > 0 {
                Text(String(format: "total %.1fs", total)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
