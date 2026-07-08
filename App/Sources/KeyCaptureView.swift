import SwiftUI
import BannyCore

#if os(macOS)
import AppKit

/// Captures keyDown/keyUp for live puppeteering — the exact web key vocabulary.
/// Hold semantics require raw down/up events, so this is an NSEvent local monitor.
struct KeyCaptureView: NSViewRepresentable {
    let model: StudioModel

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(model: model)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var monitor: Any?

        func install(model: StudioModel) {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
                MainActor.assumeIsolated {
                    Self.handle(event: event, model: model) ? nil : event
                }
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        /// macOS keyCode → web KeyboardEvent.code vocabulary.
        private static let codeMap: [UInt16: EventCode] = [
            123: .arrowLeft, 124: .arrowRight, 126: .arrowUp, 125: .arrowDown,
            43: .comma, 44: .slash, 47: .period,
            46: .keyM, 45: .keyT, 11: .keyB, 38: .keyJ, // 45 = physical N (tilt fwd)
        ]

        /// Digit keys 1..9,0 for character selection.
        private static let digitMap: [UInt16: Int] = [
            18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8, 29: 9,
        ]

        private static func handle(event: NSEvent, model: StudioModel) -> Bool {
            // Don't steal keys from text fields.
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView || responder is NSText { return false }

            let down = event.type == .keyDown
            if down, event.modifierFlags.contains(.command) {
                if event.keyCode == 8, !model.selectedMarks.isEmpty {       // ⌘C
                    model.copySelectedMarks()
                    return true
                }
                if event.keyCode == 9 {                                     // ⌘V
                    model.pasteMarks()
                    return true
                }
                if event.keyCode == 6 {                                     // ⌘Z / ⇧⌘Z
                    if event.modifierFlags.contains(.shift) {
                        model.undoManager?.redo()
                    } else {
                        model.undoManager?.undo()
                    }
                    return true
                }
                return false
            }
            if event.isARepeat { return codeMap[event.keyCode] != nil } // swallow OS repeats

            if let code = codeMap[event.keyCode] {
                model.liveKey(code: code, down: down)
                return true
            }
            if down, event.keyCode == 51 || event.keyCode == 117 { // Delete / ⌦
                model.requestTimelineDelete()
                return true
            }
            if down, event.keyCode == 49 { // Space
                if event.modifierFlags.contains(.shift) { model.record() } else { model.play() }
                return true
            }
            if down, let digit = digitMap[event.keyCode] {
                guard model.scene.characters.indices.contains(digit) else { return true }
                if event.modifierFlags.contains(.shift) {
                    if model.selection.contains(digit) { model.selection.remove(digit) }
                    else { model.selection.insert(digit) }
                } else {
                    model.selection = [digit]
                }
                return true
            }
            return false
        }
    }
}

#else

/// iOS/iPadOS: hardware keyboards arrive via UIKeyCommand in a later phase;
/// the performance deck is the primary input there.
struct KeyCaptureView: View {
    let model: StudioModel
    var body: some View { Color.clear.allowsHitTesting(false) }
}

#endif
