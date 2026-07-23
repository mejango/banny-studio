import SwiftUI
import BannyCore

/// Touch puppeteering: a game-controller layout that emits the same event codes
/// as the Mac keyboard. Left thumbstick = walk/depth; right cluster = hold-buttons.
struct PerformanceDeck: View {
    @Bindable var model: StudioModel

    var body: some View {
        HStack(alignment: .bottom) {
            WalkStick(model: model)
            Spacer()
            buttonCluster
        }
        .padding(14)
    }

    private var buttonCluster: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 8) {
                HoldButton(model: model, code: .comma, label: "blink", color: EventGroup.blink.color)
                HoldButton(model: model, code: .slash, label: "brow", color: EventGroup.blink.color)
                HoldButton(model: model, code: .period, label: "brow2", color: EventGroup.blink.color)
            }
            HStack(spacing: 8) {
                HoldButton(model: model, code: .keyT, label: "tilt →", color: EventGroup.tilt.color)
                HoldButton(model: model, code: .keyB, label: "← tilt", color: EventGroup.tilt.color)
                HoldButton(model: model, code: .keyJ, label: "jump", color: EventGroup.jump.color, tapOnly: true)
            }
            HStack(spacing: 8) {
                HoldButton(model: model, code: .keyF, label: "front flip",
                           color: EventGroup.jump.color, tapOnly: true)
                HoldButton(model: model, code: .keyD, label: "back flip",
                           color: EventGroup.jump.color, tapOnly: true)
            }
            HoldButton(model: model, code: .keyM, label: "TALK", color: EventGroup.talk.color, big: true)
        }
    }
}

/// A press-and-hold action button emitting down/up like a key.
struct HoldButton: View {
    let model: StudioModel
    let code: EventCode
    let label: String
    let color: Color
    var tapOnly = false
    var big = false

    @State private var held = false

    var body: some View {
        Text(label)
            .font(.system(size: big ? 17 : 12, weight: .bold, design: .rounded))
            .frame(width: big ? 150 : 64, height: big ? 64 : 44)
            .background(held ? color : color.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(held ? .black : .primary)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !held else { return }
                    held = true
                    model.liveKey(code: code, down: true)
                    if tapOnly {
                        // Jump is momentary in the web app too: down then immediate up.
                        model.liveKey(code: code, down: false)
                    }
                }
                .onEnded { _ in
                    held = false
                    if !tapOnly { model.liveKey(code: code, down: false) }
                })
    }
}

/// Thumbstick translating displacement into held arrow codes:
/// left/right = walk, up/down = depth. Emits the exact key vocabulary.
struct WalkStick: View {
    @Bindable var model: StudioModel
    @State private var offset: CGSize = .zero
    private let radius: CGFloat = 62

    var body: some View {
        ZStack {
            Circle().fill(.gray.opacity(0.15)).frame(width: radius * 2, height: radius * 2)
            Circle().fill(.gray.opacity(held.isEmpty ? 0.35 : 0.7))
                .frame(width: 54, height: 54)
                .offset(offset)
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                let len = max(1, sqrt(dx * dx + dy * dy))
                let clamped = min(len, radius - 20)
                offset = CGSize(width: dx / len * clamped, height: dy / len * clamped)
                sync(dx: dx, dy: dy)
            }
            .onEnded { _ in
                offset = .zero
                sync(dx: 0, dy: 0)
            })
    }

    private var held: Set<EventCode> { model.heldCodes }

    private func sync(dx: CGFloat, dy: CGFloat) {
        let dead: CGFloat = 18
        set(.arrowRight, dx > dead)
        set(.arrowLeft, dx < -dead)
        set(.arrowUp, dy < -dead)    // push up = walk away (farther)
        set(.arrowDown, dy > dead)
    }

    private func set(_ code: EventCode, _ active: Bool) {
        let isHeld = model.heldCodes.contains(code)
        if active != isHeld {
            model.liveKey(code: code, down: active)
        }
    }
}
