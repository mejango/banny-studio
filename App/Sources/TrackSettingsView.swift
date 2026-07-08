import SwiftUI
import BannyCore

/// Per-track gear popover: rename + delete. Type-specific controls live in the
/// right panel's inspector for the selected track.
struct TrackSettingsView: View {
    @Bindable var model: StudioModel
    let row: TrackRow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            nameField
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
        .frame(width: 210)
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
}
