import SwiftUI
import BannyCore
import BannyRender

/// Outfit picker showing the actual part art (like the webapp, but compact).
/// Changing something mid-timeline records a timed wardrobe change.
struct WardrobePanel: View {
    @Bindable var model: StudioModel
    let characterIndex: Int
    /// Edit the base (t=0) outfit instead of recording timed changes.
    var baseOnly = false

    private static let outfitSlots = [2, 3, 4, 6, 8, 9, 10, 11, 12, 13]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 3)

    /// Mannequin crop per slot, in the 400-box (webapp full thumb = 115,34,170,306).
    static func cropRegion(forSlot slot: Int) -> CGRect {
        switch slot {
        case 4:               // Head → head with the full antenna
            return CGRect(x: 118, y: 26, width: 168, height: 172)
        case 5, 6, 7:         // Eyes, Glasses, Mouth → head only
            return CGRect(x: 122, y: 60, width: 160, height: 130)
        case 8:               // Legs → full legs
            return CGRect(x: 115, y: 150, width: 170, height: 204)
        case 3:               // Necklace → torso up
            return CGRect(x: 115, y: 30, width: 170, height: 190)
        case 12:              // Head top → torso up, centered on the head
            return CGRect(x: 118, y: 26, width: 150, height: 196)
        default:              // Backside, Suit, Suit top/bottom, Hand → full body
            return CGRect(x: 115, y: 30, width: 170, height: 324)
        }
    }

    var body: some View {
        let outfit = currentOutfit
        let body_ = model.scene.characters[safe: characterIndex]?.body ?? .orange
        VStack(alignment: .leading, spacing: 10) {
            Text("WARDROBE").font(.caption.bold()).foregroundStyle(.secondary)

            slotGrid(title: "Eyes", selected: outfit[5] ?? "default", allowNone: false,
                     crop: Self.cropRegion(forSlot: 5),
                     items: ["default", "eyeliner", "fierce", "glassy", "surprised", "introspective"].map {
                         ($0, $0, SharedAssets.catalog.eyesImage(option: $0, expression: .open, body: body_))
                     }) { name in
                apply(slot: 5, name: name == "default" ? nil : name)
            }
            slotGrid(title: "Mouth", selected: outfit[7] ?? "default", allowNone: false,
                     crop: Self.cropRegion(forSlot: 7),
                     items: ["default", "lipstick", "gapteeth", "open"].map {
                         ($0, $0, SharedAssets.catalog.mouthImage(option: $0, state: .closed, body: body_))
                     }) { name in
                apply(slot: 7, name: name == "default" ? nil : name)
            }
            ForEach(Self.outfitSlots, id: \.self) { slot in
                let items = SharedAssets.catalog.outfits(inSlot: slot)
                if !items.isEmpty {
                    slotGrid(title: slotName(slot), selected: outfit[slot] ?? "",
                             allowNone: true, crop: Self.cropRegion(forSlot: slot),
                             items: items.map {
                                 ($0.name, $0.label, SharedAssets.catalog.outfitImage($0.name, body: body_))
                             }) { name in
                        apply(slot: slot, name: name.isEmpty ? nil : name)
                    }
                }
            }
        }
    }

    private var currentOutfit: [Int: String] {
        baseOnly ? (model.scene.characters[safe: characterIndex]?.baseOutfit ?? [:])
                 : model.simulator.pose(characterIndex: characterIndex, at: model.time).outfit
    }

    private func apply(slot: Int, name: String?) {
        if baseOnly {
            model.setBaseOutfit(characterIndex: characterIndex, slot: slot, name: name)
        } else {
            model.setOutfit(characterIndex: characterIndex, slot: slot, name: name)
        }
    }

    private func slotName(_ slot: Int) -> String {
        SharedAssets.catalog.slotName(slot) ?? "Slot \(slot)"
    }

    private func slotGrid(title: String, selected: String, allowNone: Bool, crop: CGRect,
                          items: [(name: String, label: String, image: CGImage?)],
                          choose: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.bold()).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(items, id: \.name) { item in
                    thumbCell(name: item.name, label: item.label, image: item.image, crop: crop,
                              selected: item.name == selected, allowNone: allowNone, choose: choose)
                }
            }
        }
    }

    private func thumbCell(name: String, label: String, image: CGImage?, crop: CGRect,
                           selected: Bool, allowNone: Bool,
                           choose: @escaping (String) -> Void) -> some View {
        let body_ = model.scene.characters[safe: characterIndex]?.body ?? .orange
        return Button {
            // Tapping the worn item takes it off (when the slot can be empty);
            // tapping anything else swaps to it.
            choose(selected && allowNone ? "" : name)
        } label: {
            VStack(spacing: 3) {
                Group {
                    if let image {
                        MannequinThumb(part: image,
                                       body: SharedAssets.catalog.bodyImage(body_),
                                       crop: crop)
                    } else {
                        Image(systemName: "slash.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(crop.width / crop.height, contentMode: .fit)
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
    let crop: CGRect

    init(part: CGImage, body: CGImage?, crop: CGRect) {
        self.part = part
        self.body_ = body
        self.crop = crop
    }

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            // Fixed light paper behind the mannequin so dark mode reads identically.
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(Color(red: 0.96, green: 0.95, blue: 0.91)))
            let s = size.width / crop.width
            let box = CGRect(x: -crop.minX * s, y: -crop.minY * s,
                             width: 400 * s, height: 400 * s)
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

/// The character's full starting outfit on a mini mannequin (renderer slot order).
struct OutfitCard: View {
    let character: BannyCore.Character

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(Color(red: 0.96, green: 0.95, blue: 0.91)))
            let crop = WardrobePanel.cropRegion(forSlot: 0) // full body
            let s = size.height / crop.height
            let box = CGRect(x: -crop.minX * s + (size.width - crop.width * s) / 2,
                             y: -crop.minY * s, width: 400 * s, height: 400 * s)
            let cat = SharedAssets.catalog
            let o = character.baseOutfit
            let headWorn = o[4] != nil
            var hidden = Set<Int>()
            if headWorn { hidden.formUnion([6, 12]) }
            if o[9] != nil { hidden.formUnion([10, 11]) }
            func draw(_ img: CGImage?) {
                if let img {
                    ctx.draw(Image(decorative: img, scale: 1).interpolation(.none), in: box)
                }
            }
            // FrameRenderer slot order, flat (no pose).
            draw(o[2].flatMap { cat.outfitImage($0, body: character.body) })
            draw(cat.bodyImage(character.body))
            if let n = o[3] { draw(cat.outfitImage(n, body: character.body)) }
            else { draw(cat.necklaceImage(body: character.body)) }
            draw(o[4].flatMap { cat.outfitImage($0, body: character.body) })
            if !headWorn {
                draw(cat.eyesImage(option: o[5] ?? "default", expression: .open, body: character.body))
                if !hidden.contains(6) { draw(o[6].flatMap { cat.outfitImage($0, body: character.body) }) }
                draw(cat.mouthImage(option: o[7] ?? "default", state: .closed, body: character.body))
            }
            for slot in [8, 9, 10, 11, 12, 13] where !hidden.contains(slot) {
                draw(o[slot].flatMap { cat.outfitImage($0, body: character.body) })
            }
        }
        .clipped()
    }
}

/// Gutter card: the starting outfit, click to edit it (always edits base).
struct OutfitCardButton: View {
    @Bindable var model: StudioModel
    let characterIndex: Int
    @State private var editing = false

    var body: some View {
        if let c = model.scene.characters[safe: characterIndex] {
            Button { editing = true } label: {
                OutfitCard(character: c)
                    .frame(width: 30, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.primary.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Starting outfit — click to edit")
            .popover(isPresented: $editing) {
                ScrollView {
                    WardrobePanel(model: model, characterIndex: characterIndex, baseOnly: true)
                        .padding(10)
                }
                .frame(width: 300, height: 430)
            }
        }
    }
}
