import SwiftUI
import BannyCore
import BannyRender

/// Outfit picker for one character: eyes, mouth, and the 12 outfit slots.
/// Changing something mid-timeline records a timed wardrobe change.
struct WardrobePanel: View {
    @Bindable var model: StudioModel
    let characterIndex: Int

    /// Picker slots in web PICKER_CATS order, minus eyes(5)/mouth(7) which get option rows.
    private static let outfitSlots = [2, 3, 4, 6, 8, 9, 10, 11, 12, 13]

    var body: some View {
        let outfit = currentOutfit
        VStack(alignment: .leading, spacing: 8) {
            Text("WARDROBE").font(.caption.bold()).foregroundStyle(.secondary)

            optionRow(title: "Eyes",
                      options: ["default", "eyeliner", "fierce", "glassy", "surprised", "introspective"],
                      selected: outfit[5] ?? "default") { name in
                model.setOutfit(characterIndex: characterIndex, slot: 5,
                                name: name == "default" ? nil : name)
            }
            optionRow(title: "Mouth",
                      options: ["default", "lipstick", "gapteeth", "open"],
                      selected: outfit[7] ?? "default") { name in
                model.setOutfit(characterIndex: characterIndex, slot: 7,
                                name: name == "default" ? nil : name)
            }

            ForEach(Self.outfitSlots, id: \.self) { slot in
                let items = SharedAssets.catalog.outfits(inSlot: slot)
                if !items.isEmpty {
                    slotRow(slot: slot, items: items, selected: outfit[slot])
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

    private func optionRow(title: String, options: [String], selected: String,
                           choose: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2.bold()).foregroundStyle(.secondary)
            FlowChips(items: options.map { ($0, $0) }, selected: selected, allowNone: false, choose: choose)
        }
    }

    private func slotRow(slot: Int, items: [(name: String, label: String)], selected: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(slotName(slot)).font(.caption2.bold()).foregroundStyle(.secondary)
            FlowChips(items: [("", "none")] + items.map { ($0.name, $0.label) },
                      selected: selected ?? "", allowNone: true) { name in
                model.setOutfit(characterIndex: characterIndex, slot: slot,
                                name: name.isEmpty ? nil : name)
            }
        }
    }
}

/// Wrapping chip row.
struct FlowChips: View {
    let items: [(name: String, label: String)]
    let selected: String
    let allowNone: Bool
    let choose: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(items, id: \.name) { item in
                Button(item.label) { choose(item.name) }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(item.name == selected ? Color.orange : Color(white: 0.93))
                    .foregroundStyle(item.name == selected ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
    }
}

/// Minimal flow layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = layout(proposal: proposal, subviews: subviews).positions
        for (subview, position) in zip(subviews, positions) {
            subview.place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                          proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews)
        -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? 280
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}
