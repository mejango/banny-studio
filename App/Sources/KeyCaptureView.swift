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
        context.coordinator.install(model: model, view: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var monitor: Any?
        /// This capture view lives in exactly one document window. The local
        /// monitor is app-global (fires for every open document's monitor), so
        /// each one must ignore events unless ITS window is key — otherwise a
        /// background document hijacks the keystrokes of the focused one.
        private weak var view: NSView?
        /// Currently-pressed key codes, for chord detection (reset gestures).
        private var downKeys: Set<UInt16> = []

        func install(model: StudioModel, view: NSView) {
            self.view = view
            guard monitor == nil else { return }
            if UserDefaults.standard.bool(forKey: "debugDeleteTest") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    guard let ci = model.scene.characters.indices.first(where: { i in
                        model.scene.characters[i].events.contains { if case .outfit = $0 { return true }; return false }
                    }), let ei = model.scene.characters[ci].events.firstIndex(where: {
                        if case .outfit = $0 { return true }; return false
                    }) else { Self.dbg("no outfit events"); return }
                    model.selectedOutfitEvent = (ci, ei)
                    Self.dbg("before: char \(ci) events \(model.scene.characters[ci].events.count) idx \(ei)")
                    let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                              timestamp: 0, windowNumber: 0, context: nil,
                                              characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
                                              isARepeat: false, keyCode: 51)!
                    NSApp.postEvent(ev, atStart: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        Self.dbg("after: events \(model.scene.characters[ci].events.count) stillSelected \(model.selectedOutfitEvent != nil)")
                    }
                }
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                MainActor.assumeIsolated {
                    // Only the capture view in the focused document acts; every
                    // other open document's monitor passes the event through.
                    guard let self, let win = self.view?.window, win.isKeyWindow else { return event }
                    return self.route(event: event, model: model) ? nil : event
                }
            }
        }

        /// Tracks pressed keys and fires reset chords (shift+←+→ resets
        /// rotation; +/− together resets animated scale), then delegates the rest.
        private func route(event: NSEvent, model: StudioModel) -> Bool {
            let plus: Set<UInt16> = [24, 69], minus: Set<UInt16> = [27, 78]
            if event.type == .keyUp {
                downKeys.remove(event.keyCode)
                return Self.handle(event: event, model: model)
            }
            let charCtx = model.selectedTrackKey?.hasPrefix("c-") ?? true
            if !event.isARepeat, charCtx, !model.playing || model.recording {
                // Rotation reset: both arrows held with shift.
                if event.modifierFlags.contains(.shift),
                   (event.keyCode == 123 && downKeys.contains(124))
                     || (event.keyCode == 124 && downKeys.contains(123)) {
                    model.liveKey(code: .spinReset, down: true)
                    model.liveKey(code: .spinReset, down: false)
                }
                // Animated-scale reset: + and − held together.
                if (plus.contains(event.keyCode) && !downKeys.isDisjoint(with: minus))
                     || (minus.contains(event.keyCode) && !downKeys.isDisjoint(with: plus)) {
                    model.liveKey(code: .zoomReset, down: true)
                    model.liveKey(code: .zoomReset, down: false)
                }
            }
            downKeys.insert(event.keyCode)
            // Let the keys also register normally — both of a pair held nets to
            // zero change, so the reset value holds until they're released.
            return Self.handle(event: event, model: model)
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        static func dbg(_ msg: String) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("deltest.log")
            let line = msg + "\n"
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
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
            // Don't steal keys from text fields — but only while one is really
            // editing. A dismissed field editor can linger as first responder
            // and would otherwise swallow every key.
            if let responder = NSApp.keyWindow?.firstResponder as? NSText,
               responder.superview != nil, !responder.isHidden { return false }

            let down = event.type == .keyDown
            if down, event.modifierFlags.contains(.command) {
                if event.keyCode == 8, model.hasTimelineSelection {        // ⌘C
                    model.copyTimelineSelection()
                    return true
                }
                if event.keyCode == 9 {                                     // ⌘V
                    if !model.pasteImageFromPasteboard() {
                        model.pasteTimeline()
                    }
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
            // A picked timeline element (marks, clips, outfit dot, scene group)
            // moves with ← / → — takes plain arrows before any pen/freeform use.
            // (Shift+arrow is reserved for character rotation, below.)
            if !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift),
               event.keyCode == 123 || event.keyCode == 124,
               model.hasArrowMovableSelection, !model.recording {
                if down { model.nudgeTimelineSelection(by: event.keyCode == 124 ? 1.0/30 : -1.0/30) }
                return true
            }
            // Visual cues keep the character performance contract for the
            // controls that apply: move L/R, move F/B, rotate, and scale.
            if model.isImageRecording || model.selectedVisualCueOnSelectedTrack {
                var visualKey: StudioModel.LightKey?
                if event.modifierFlags.contains(.shift), event.keyCode == 123 {
                    visualKey = .rotateLeft
                } else if event.modifierFlags.contains(.shift), event.keyCode == 124 {
                    visualKey = .rotateRight
                } else {
                    visualKey = [
                        123: .left, 124: .right, 126: .up, 125: .down,
                        24: .plus, 69: .plus, 27: .minus, 78: .minus,
                    ][event.keyCode]
                }
                if let visualKey {
                    if !event.isARepeat { model.lightKey(visualKey, down: down) }
                    return true
                }
                // Character-only performance keys do nothing in a visual
                // context; never leak them to a previously selected character.
                if codeMap[event.keyCode] != nil { return true }
            }
            // Light tracks, the Scenes track, and camera recording take the
            // arrows plus their track-specific pen keys.
            if model.isCameraRecording
                || (model.selectedTrackKey.map { key in
                        model.scene.lightTracks.contains(where: { $0.id == key })
                            || model.scene.backgroundTracks.contains(where: { $0.id == key })
                    } ?? false) {
                let lightMap: [UInt16: StudioModel.LightKey] = [
                    123: .left, 124: .right, 126: .up, 125: .down,
                    24: .plus, 69: .plus, 27: .minus, 78: .minus,
                    18: .sizeDown, 19: .sizeUp,
                ]
                if let lk = lightMap[event.keyCode] {
                    if !event.isARepeat { model.lightKey(lk, down: down) }
                    return true
                }
            }
            // Character rotate (shift+←/→) and scale (+/−): held keys integrated
            // like movement. Only in a character context (no light/scene/media
            // pen is claiming these — that was handled above).
            if model.selectedTrackKey?.hasPrefix("c-") ?? true {
                var rz: EventCode?
                if event.modifierFlags.contains(.shift), event.keyCode == 123 { rz = .rotateLeft }
                else if event.modifierFlags.contains(.shift), event.keyCode == 124 { rz = .rotateRight }
                else if event.keyCode == 24 || event.keyCode == 69 { rz = .zoomIn }   // = / keypad +
                else if event.keyCode == 27 || event.keyCode == 78 { rz = .zoomOut }  // - / keypad −
                if let rz {
                    if !event.isARepeat { model.liveKey(code: rz, down: down) }
                    return true
                }
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
