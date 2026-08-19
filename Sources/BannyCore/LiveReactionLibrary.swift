import Foundation

/// The gesture vocabulary a live scene starts with.
///
/// Routine listening is carried by the eyes — Comma closes them, Slash raises a
/// brow, Period narrows them. Only the emphasis set leans, because a whole room
/// tilting on every beat reads as noise rather than attention. The leaning
/// gestures carry no jump, so intensity can push a lean past its usual range
/// without also throwing the performer off the top of frame.
public enum LiveReactionLibrary {
    public static let standard: [ReactionDefinition] = [
        // --- eyes only -------------------------------------------------------
        def("glance", "Glance", 1.0, [(0.1, .comma, true), (0.2, .comma, false),
                                      (0.42, .period, true), (0.62, .period, false)]),
        def("listen", "Listen", 2.6, [(0.25, .comma, true), (0.36, .comma, false),
                                      (1.2, .slash, true), (1.75, .slash, false),
                                      (2.15, .comma, true), (2.26, .comma, false)]),
        def("blink2", "Double blink", 0.9, [(0.05, .comma, true), (0.16, .comma, false),
                                            (0.3, .comma, true), (0.42, .comma, false)]),
        def("brow", "Eyebrow", 1.4, [(0.15, .slash, true), (0.95, .slash, false)]),
        def("squint", "Squint", 1.6, [(0.1, .period, true), (1.1, .period, false)]),
        def("eyeroll", "Eye roll", 1.8, [(0.1, .period, true), (0.75, .period, false),
                                         (0.8, .comma, true), (1.0, .comma, false)]),
        def("sip", "Sip", 2.0, [(0.3, .comma, true), (0.55, .comma, false),
                                (1.1, .slash, true), (1.5, .slash, false)]),
        def("doubletake", "Double take", 1.5, [(0.0, .comma, true), (0.11, .comma, false),
                                               (0.24, .comma, true), (0.35, .comma, false),
                                               (0.5, .slash, true), (1.2, .slash, false)]),
        def("laugh", "Laugh", 1.6, [(0.0, .keyJ, true), (0.1, .keyJ, false),
                                    (0.18, .slash, true), (0.55, .slash, false),
                                    (0.7, .comma, true), (0.85, .comma, false)]),
        def("greet", "Greet", 1.4, [(0.0, .keyJ, true), (0.09, .keyJ, false),
                                    (0.3, .period, true), (0.8, .period, false)]),
        def("cheer", "Cheers", 1.8, [(0.0, .keyJ, true), (0.12, .keyJ, false),
                                     (0.4, .slash, true), (1.0, .slash, false),
                                     (1.2, .keyJ, true), (1.3, .keyJ, false)]),
        // --- the only gestures that lean -------------------------------------
        def("secret", "Lean in", 2.6, [(0.15, .keyT, true), (2.0, .keyT, false),
                                       (0.5, .period, true), (1.4, .period, false)]),
        def("bellylaugh", "Belly laugh", 2.2, [(0.1, .keyB, true), (1.6, .keyB, false),
                                               (0.25, .comma, true), (0.5, .comma, false),
                                               (0.7, .comma, true), (1.05, .comma, false)]),
        def("recoil", "Taken aback", 1.5, [(0.0, .keyB, true), (0.55, .keyB, false),
                                           (0.05, .slash, true), (0.9, .slash, false)]),
        def("nod", "Nod", 1.1, [(0.0, .keyT, true), (0.2, .keyT, false),
                                (0.45, .keyT, true), (0.63, .keyT, false)]),
        def("hesitate", "Hesitate", 2.0, [(0.35, .keyB, true), (1.05, .keyB, false),
                                          (1.5, .comma, true), (1.62, .comma, false)]),
        def("shy", "Hang back", 2.4, [(0.45, .comma, true), (0.6, .comma, false),
                                      (1.0, .period, true), (1.9, .period, false)]),
    ]

    /// Events must be sorted: a tap authored inside a longer hold is easy to
    /// write out of order, and the document rejects it.
    private static func def(_ id: String, _ name: String, _ dur: Double,
                            _ events: [(Double, EventCode, Bool)]) -> ReactionDefinition {
        ReactionDefinition(
            id: id, name: name, dur: dur,
            events: events.sorted { $0.0 == $1.0 ? ($0.2 && !$1.2) : $0.0 < $1.0 }
                .map { .key(t: $0.0, code: $0.1, down: $0.2) })
    }
}
