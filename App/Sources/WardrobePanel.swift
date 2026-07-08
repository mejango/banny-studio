import SwiftUI
import BannyCore
import BannyRender

/// Outfit picker showing the actual part art (like the webapp, but compact).
/// Changing something mid-timeline records a timed wardrobe change.
struct WardrobePanel: View {
    @Bindable var model: StudioModel
    let characterIndex: Int

    private static let outfitSlots = [2, 3, 4, 6, 8, 9, 10, 11, 12, 13]
    private let columns = [GridItem(.adaptive(minimum: 64), spacing: 0)]

    var body: some View {
        let outfit = currentOutfit
        let body_ = model.scene.characters[safe: characterIndex]?.body ?? .orange
        VStack(alignment: .leading, spacing: 10) {
            Text("WARDROBE").font(.caption.bold()).foregroundStyle(.secondary)

            slotGrid(title: "Eyes", selected: outfit[5] ?? "default", allowNone: false,
                     items: ["default", "eyeliner", "fierce", "glassy", "surprised", "introspective"].map {
                         ($0, $0, SharedAssets.catalog.eyesImage(option: $0, expression: .open, body: body_))
                     }) { name in
                model.setOutfit(characterIndex: characterIndex, slot: 5,
                                name: name == "default" ? nil : name)
            }
            slotGrid(title: "Mouth", selected: outfit[7] ?? "default", allowNone: false,
                     items: ["default", "lipstick", "gapteeth", "open"].map {
                         ($0, $0, SharedAssets.catalog.mouthImage(option: $0, state: .closed, body: body_))
                     }) { name in
                model.setOutfit(characterIndex: characterIndex, slot: 7,
                                name: name == "default" ? nil : name)
            }
            ForEach(Self.outfitSlots, id: \.self) { slot in
                let items = SharedAssets.catalog.outfits(inSlot: slot)
                if !items.isEmpty {
                    slotGrid(title: slotName(slot), selected: outfit[slot] ?? "",
                             allowNone: true,
                             items: items.map {
                                 ($0.name, $0.label, SharedAssets.catalog.outfitImage($0.name, body: body_))
                             }) { name in
                        model.setOutfit(characterIndex: characterIndex, slot: slot,
                                        name: name.isEmpty ? nil : name)
                    }
                }
            }
        }
    }

    private var currentOutfit: [Int: String] {
        model.simulator.pose(characterIndex: characterIndex, at: model.time).outfit
    }

    private func slotName(_ slot: Int) -> String {
        SharedAssets.catalog.slotName(slot) ?? "Slot \(slot)"
    }

    private func slotGrid(title: String, selected: String, allowNone: Bool,
                          items: [(name: String, label: String, image: CGImage?)],
                          choose: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.bold()).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 0) {
                if allowNone {
                    thumbCell(name: "", label: "none", image: nil,
                              selected: selected.isEmpty, choose: choose)
                }
                ForEach(items, id: \.name) { item in
                    thumbCell(name: item.name, label: item.label, image: item.image,
                              selected: item.name == selected, choose: choose)
                }
            }
        }
    }

    private func thumbCell(name: String, label: String, image: CGImage?,
                           selected: Bool, choose: @escaping (String) -> Void) -> some View {
        let body_ = model.scene.characters[safe: characterIndex]?.body ?? .orange
        return Button {
            choose(name)
        } label: {
            VStack(spacing: 3) {
                Group {
                    if let image {
                        MannequinThumb(part: image,
                                       body: SharedAssets.catalog.bodyImage(body_))
                    } else {
                        Image(systemName: "slash.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(170.0 / 250.0, contentMode: .fit)
                Text(label)
                    .font(.system(size: 8))
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.orange : .secondary)
            }
            .padding(5)
            .background(Color.primary.opacity(selected ? 0.09 : 0.04))
            .overlay(Rectangle()
                .stroke(selected ? Color.orange : Color.primary.opacity(0.12),
                        lineWidth: selected ? 2 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The webapp's picker framing: a ghosted banny mannequin wearing the part
/// (thumb viewBox 115 34 170 306, body at 16% opacity).
struct MannequinThumb: View {
    let part: CGImage
    let body_: CGImage?

    init(part: CGImage, body: CGImage?) {
        self.part = part
        self.body_ = body
    }

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            let s = size.width / 170.0
            let box = CGRect(x: -115 * s, y: -44 * s, width: 400 * s, height: 400 * s)
            var ghost = ctx
            ghost.opacity = 0.16
            if let body_ {
                ghost.draw(Image(decorative: body_, scale: 1)
                    .interpolation(.none), in: box)
            }
            ctx.draw(Image(decorative: part, scale: 1)
                .interpolation(.none), in: box)
        }
        .clipped()
    }
}
