import Foundation
import BannyCore

/// The reusable physical-performance grammar developed for the Sunset Bar
/// shows. Dialogue and scene blocking remain the live director's job; these
/// definitions contain only bounded, composable character reactions.
///
/// Reactions deliberately never own locomotion, depth, or talk. A director can
/// therefore combine one of them with a safe facing tap or captioned speech
/// without a reaction moving a character, releasing a walk, or opening a mouth.
public enum SunsetBarPerformancePreset {
    public enum ListenerStyle: String, CaseIterable, Sendable {
        case conversational
        case rowdy
        case soft
    }

    /// Stable vocabulary recorded in every Banny Live room package.
    public static let reactionLibrary: [ReactionDefinition] = [
        reaction("glance", "Glance", 1.0, [
            held(.comma, 0.10, 0.20),
            held(.period, 0.42, 0.62),
        ]),
        reaction("listen", "Listen", 2.6, [
            held(.comma, 0.25, 0.36),
            held(.slash, 1.20, 1.75),
            held(.comma, 2.15, 2.26),
        ]),
        reaction("blink2", "Double blink", 0.9, [
            held(.comma, 0.05, 0.16),
            held(.comma, 0.30, 0.42),
        ]),
        reaction("brow", "Eyebrow", 1.4, [
            held(.slash, 0.15, 0.95),
        ]),
        reaction("squint", "Squint", 1.6, [
            held(.period, 0.10, 1.10),
        ]),
        reaction("eyeroll", "Eye roll", 1.8, [
            held(.period, 0.10, 0.75),
            held(.comma, 0.80, 1.00),
        ]),
        reaction("sip", "Sip", 2.0, [
            held(.comma, 0.30, 0.55),
            held(.slash, 1.10, 1.50),
        ]),
        reaction("doubletake", "Double take", 1.5, [
            held(.comma, 0.00, 0.11),
            held(.comma, 0.24, 0.35),
            held(.slash, 0.50, 1.20),
        ]),
        reaction("laugh", "Laugh", 1.6, [
            held(.keyJ, 0.00, 0.10),
            held(.slash, 0.18, 0.55),
            held(.comma, 0.70, 0.85),
        ]),
        reaction("greet", "Greet", 1.4, [
            held(.keyJ, 0.00, 0.09),
            held(.period, 0.30, 0.80),
        ]),
        reaction("cheer", "Cheers", 1.8, [
            held(.keyJ, 0.00, 0.12),
            held(.slash, 0.40, 1.00),
            held(.keyJ, 1.20, 1.30),
        ]),
        reaction("lean-in", "Lean in", 2.6, [
            held(.keyT, 0.15, 2.00),
            held(.period, 0.50, 1.40),
        ]),
        reaction("bellylaugh", "Belly laugh", 2.2, [
            held(.keyB, 0.10, 1.60),
            held(.comma, 0.25, 0.50),
            held(.comma, 0.70, 1.05),
        ]),
        reaction("recoil", "Taken aback", 1.5, [
            held(.keyB, 0.00, 0.55),
            held(.slash, 0.05, 0.90),
        ]),
        reaction("nod", "Nod", 1.1, [
            held(.keyT, 0.00, 0.20),
            held(.keyT, 0.45, 0.63),
        ]),
        reaction("hesitate", "Hesitate", 2.0, [
            held(.keyB, 0.35, 1.05),
            held(.comma, 1.50, 1.62),
        ]),
        reaction("shy", "Hang back", 2.4, [
            held(.comma, 0.45, 0.60),
            held(.period, 1.00, 1.90),
        ]),
    ]

    /// Chooses a repeatable listener gesture without process-random hashing.
    /// The caller supplies a durable seed such as a room sequence number mixed
    /// with the listener's seat. Returning one reaction action at a time keeps
    /// the action's owned channels conflict-free.
    public static func listenerAction(
        seed: UInt64,
        style: ListenerStyle = .conversational
    ) -> AgentAction {
        let choices: [String] = switch style {
        case .conversational:
            ["glance", "listen", "sip", "brow", "blink2", "nod"]
        case .rowdy:
            ["laugh", "blink2", "brow", "doubletake", "sip", "glance", "nod"]
        case .soft:
            ["listen", "glance", "squint", "blink2", "sip"]
        }
        let value = mixed(seed)
        let reactionID = choices[Int(value % UInt64(choices.count))]
        let intensities = [0.70, 0.82, 0.94, 1.0]
        let intensity = intensities[Int((value >> 8) % UInt64(intensities.count))]
        return .reaction(reactionID: reactionID, durationMS: nil, intensity: intensity)
    }

    /// Produces occasional, repeatable background business. A nil result is an
    /// intentional quiet beat; an autonomous room should not animate everyone
    /// continuously merely because no one is speaking.
    public static func idleAction(seed: UInt64) -> AgentAction? {
        let value = mixed(seed)
        guard value % 4 != 0 else { return nil }
        let choices = ["glance", "listen", "blink2", "sip", "shy"]
        let reactionID = choices[Int((value >> 4) % UInt64(choices.count))]
        let intensities = [0.55, 0.65, 0.75, 0.85]
        let intensity = intensities[Int((value >> 12) % UInt64(intensities.count))]
        return .reaction(reactionID: reactionID, durationMS: nil, intensity: intensity)
    }

    /// Returns Sunset Bar's 80 ms pivot tap when a resting character needs to
    /// face another cast member. SceneSimulator spends the first 100 ms turning
    /// when direction changes, so this reverses facing without taking a step.
    /// Callers must schedule it only while the character is not already walking.
    public static func facingAction(
        currentX: Double,
        currentFace: AgentPose.Face,
        targetX: Double
    ) -> AgentAction? {
        guard currentX.isFinite, targetX.isFinite,
              abs(targetX - currentX) > 0.000_1
        else { return nil }
        let desiredFace: AgentPose.Face = targetX < currentX ? .left : .right
        guard desiredFace != currentFace else { return nil }
        let direction: AgentAction.HorizontalDirection = desiredFace == .left ? .left : .right
        return .move(
            direction: direction,
            durationMS: BannyAgentProtocol.minimumActionDurationMS)
    }

    private static func reaction(
        _ id: String,
        _ name: String,
        _ duration: Double,
        _ groups: [[PerfEvent]]
    ) -> ReactionDefinition {
        let events = groups.flatMap { $0 }.enumerated().sorted { lhs, rhs in
            if lhs.element.t != rhs.element.t {
                return lhs.element.t < rhs.element.t
            }
            let lhsDown = if case .key(_, _, let down) = lhs.element { down } else { false }
            let rhsDown = if case .key(_, _, let down) = rhs.element { down } else { false }
            if lhsDown != rhsDown { return lhsDown && !rhsDown }
            return lhs.offset < rhs.offset
        }.map(\.element)
        return ReactionDefinition(
            id: id,
            name: name,
            dur: duration,
            events: events)
    }

    private static func held(
        _ code: EventCode,
        _ start: Double,
        _ end: Double
    ) -> [PerfEvent] {
        [
            .key(t: start, code: code, down: true),
            .key(t: end, code: code, down: false),
        ]
    }

    /// SplitMix64's finalizer gives stable diffusion without keeping mutable RNG
    /// state or relying on Swift's intentionally randomized `Hasher`.
    private static func mixed(_ seed: UInt64) -> UInt64 {
        var value = seed &+ 0x9e37_79b9_7f4a_7c15
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
        return value ^ (value >> 31)
    }
}
