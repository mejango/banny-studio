import SwiftUI
import BannyCore

/// Per-track settings popover: name, type-specific controls, delete.
/// Value rows show their current number; clicking a row opens its slider.
struct TrackSettingsView: View {
    @Bindable var model: StudioModel
    let row: TrackRow
    var initialExpanded: String? = nil

    @State private var expanded: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            nameField
            if case .character(let i) = row, model.scene.characters.indices.contains(i) {
                characterSettings(i)
            }
            if case .background = row {
                backgroundSettings
            }
            if canDelete {
                Divider()
                Button(role: .destructive) {
                    model.removeTrack(kind)
                } label: {
                    Label("Delete track", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(width: 230)
        .onAppear { expanded = initialExpanded }
    }

    private var canDelete: Bool {
        if case .background = row { return false }
        return true
    }

    private var kind: TrackRowKind {
        switch row {
        case .character(let i): return .character(i)
        case .audio(let i): return .audio(i)
        case .image(let i): return .image(i)
        case .light(let i): return .light(i)
        case .background(let i): return .background(i)
        }
    }

    private var nameField: some View {
        TextField("name", text: Binding(
            get: {
                switch row {
                case .character(let i): return model.scene.characters[safe: i]?.name ?? ""
                case .audio(let i): return model.scene.audioTracks[safe: i]?.name ?? ""
                case .image(let i): return model.scene.imageTracks[safe: i]?.name ?? ""
                case .light(let i): return model.scene.lightTracks[safe: i]?.name ?? ""
                case .background(let i): return model.scene.backgroundTracks[safe: i]?.name ?? ""
                }
            },
            set: { name in
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
            }))
            .textFieldStyle(.roundedBorder)
            .font(.caption)
    }

    @ViewBuilder
    private func characterSettings(_ i: Int) -> some View {
        valueRow(id: "speed", label: "speed",
                 value: String(format: "%.0f", model.scene.characters[i].speed)) {
            Slider(value: Binding(
                get: { model.scene.characters[safe: i]?.speed ?? 320 },
                set: { if model.scene.characters.indices.contains(i) { model.scene.characters[i].speed = $0 } }),
                in: 40...600)
        }
        valueRow(id: "wobble", label: "wobble",
                 value: String(format: "%.1f", model.scene.characters[i].wobble)) {
            Slider(value: Binding(
                get: { model.scene.characters[safe: i]?.wobble ?? 7 },
                set: { if model.scene.characters.indices.contains(i) { model.scene.characters[i].wobble = $0 } }),
                in: 0...16)
        }
        HStack {
            Text("size").font(.caption2).frame(width: 56, alignment: .leading)
            ForEach([("Normal", 1.0), ("Small", 0.62), ("Baby", 0.38)], id: \.0) { name, value in
                let current = abs((model.scene.characters[safe: i]?.size ?? 1) - value) < 0.01
                Button(name) {
                    if model.scene.characters.indices.contains(i) {
                        model.registerUndoSnapshot(label: "Size")
                        model.scene.characters[i].size = value
                    }
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .tint(current ? .orange : .gray)
            }
        }
    }

    /// Stage-wide physics live with the Background track (the webapp's top-level
    /// size / scale / gravity sliders).
    @ViewBuilder
    private var backgroundSettings: some View {
        valueRow(id: "gsize", label: "size",
                 value: String(format: "%.2f", model.scene.gSize)) {
            Slider(value: Binding(get: { model.scene.gSize },
                                  set: { model.scene.gSize = $0 }), in: 0.3...2.5)
        }
        valueRow(id: "gscale", label: "scale (depth)",
                 value: String(format: "%.2f", model.scene.gScale)) {
            Slider(value: Binding(get: { model.scene.gScale },
                                  set: { model.scene.gScale = $0 }), in: 0...1.2)
        }
        valueRow(id: "gravity", label: "gravity",
                 value: String(format: "%.2f", model.scene.gravity)) {
            Slider(value: Binding(get: { model.scene.gravity },
                                  set: { model.scene.gravity = $0 }), in: 0.3...2.5)
        }
    }

    /// A "label  value" row; clicking it opens the adjustment control beneath.
    @ViewBuilder
    private func valueRow(id: String, label: String, value: String,
                          @ViewBuilder control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded = expanded == id ? nil : id
            } label: {
                HStack {
                    Text(label).font(.caption2)
                    Spacer()
                    Text(value).font(.system(.caption2, design: .monospaced)).bold()
                    Image(systemName: expanded == id ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded == id {
                control()
            }
        }
    }
}
