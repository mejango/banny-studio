import Foundation

/// Arrays copied out of an unchanged value keep their storage. Check that
/// identity first so editor-only camera/light/media edits can validate a dense
/// prepared source in O(character count), while changed arrays still receive a
/// complete semantic comparison.
private func preparedArraysEqual<Element: Equatable>(_ lhs: [Element], _ rhs: [Element]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    guard !lhs.isEmpty else { return true }
    let sharesStorage = lhs.withUnsafeBufferPointer { left in
        rhs.withUnsafeBufferPointer { right in
            left.baseAddress == right.baseAddress
        }
    }
    return sharesStorage || lhs == rhs
}

/// Immutable, derived performance data shared by interactive playback and
/// offline rendering. Building it never mutates the show document, so callers
/// can prepare a snapshot away from the main actor and swap it in atomically.
public struct PreparedScenePerformance: Sendable {
    /// The exact subset of a scene which affects prepared character state.
    /// Comparing this value lets the editor retain prepared work across camera,
    /// light, media, and other edits which do not change character simulation.
    public struct Source: Equatable, Sendable {
        struct CharacterSource: Equatable, Sendable {
            var body: Body
            var events: [PerfEvent]
            var reactions: [ReactionInstance]
            var baseOutfit: [Int: String]
            var x: Double
            var depth: Double
            var face: Int
            var size: Double
            var recStart: StartPose?
            var speed: Double
            var rotationSpeed: Double
            var wobble: Double

            init(_ character: Character) {
                body = character.body
                events = character.events
                reactions = character.reactions
                baseOutfit = character.baseOutfit
                x = character.x
                depth = character.depth
                face = character.face
                size = character.size
                recStart = character.recStart
                speed = character.speed
                rotationSpeed = character.rotationSpeed
                wobble = character.wobble
            }

            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.body == rhs.body
                    && preparedArraysEqual(lhs.events, rhs.events)
                    && preparedArraysEqual(lhs.reactions, rhs.reactions)
                    && lhs.baseOutfit == rhs.baseOutfit
                    && lhs.x == rhs.x
                    && lhs.depth == rhs.depth
                    && lhs.face == rhs.face
                    && lhs.size == rhs.size
                    && lhs.recStart == rhs.recStart
                    && lhs.speed == rhs.speed
                    && lhs.rotationSpeed == rhs.rotationSpeed
                    && lhs.wobble == rhs.wobble
            }
        }

        fileprivate var characters: [CharacterSource]
        fileprivate var reactionLibrary: [ReactionDefinition]
        fileprivate var gScale: Double
        fileprivate var through: Double
        public var horizon: Double { through }

        public init(scene: SceneState, through requestedHorizon: Double? = nil) {
            characters = scene.characters.map(CharacterSource.init)
            reactionLibrary = scene.reactionLibrary
            gScale = scene.gScale
            through = max(0, requestedHorizon ?? Self.recommendedHorizon(for: scene))
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.gScale == rhs.gScale
                && lhs.through == rhs.through
                && lhs.characters.elementsEqual(rhs.characters)
                && preparedArraysEqual(lhs.reactionLibrary, rhs.reactionLibrary)
        }

        public static func recommendedHorizon(for scene: SceneState) -> Double {
            min(3_600, max(20, (scene.contentEnd + 3).rounded(.up)))
        }
    }

    let characters: [PreparedCharacterPerformance]
    let definitions: [String: ReactionDefinition]
    public let through: Double

    public init(scene: SceneState, through requestedHorizon: Double? = nil) {
        self.init(source: Source(scene: scene, through: requestedHorizon))
    }

    public init(source: Source) {
        through = source.through
        characters = source.characters.map {
            PreparedCharacterPerformance(source: $0, gScale: source.gScale,
                                         through: source.through)
        }
        definitions = Dictionary(source.reactionLibrary.map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first })
    }

    /// Prepares characters concurrently. Work is bounded to one task per
    /// character and happens only when performance inputs change, never per
    /// playback frame.
    public static func prepare(source: Source) async throws -> PreparedScenePerformance {
        try Task.checkCancellation()
        let count = source.characters.count
        var slots = Array<PreparedCharacterPerformance?>(repeating: nil, count: count)
        try await withThrowingTaskGroup(
            of: (Int, PreparedCharacterPerformance).self
        ) { group in
            for (index, character) in source.characters.enumerated() {
                group.addTask {
                    try Task.checkCancellation()
                    return (index, PreparedCharacterPerformance(
                        source: character,
                        gScale: source.gScale,
                        through: source.through))
                }
            }
            for try await (index, prepared) in group {
                slots[index] = prepared
            }
        }
        try Task.checkCancellation()
        return PreparedScenePerformance(
            through: source.through,
            characters: slots.compactMap { $0 },
            definitions: Dictionary(source.reactionLibrary.map { ($0.id, $0) },
                                    uniquingKeysWith: { first, _ in first }))
    }

    private init(through: Double,
                 characters: [PreparedCharacterPerformance],
                 definitions: [String: ReactionDefinition]) {
        self.through = through
        self.characters = characters
        self.definitions = definitions
    }
}

struct PreparedCharacterPerformance: Sendable {
    let events: PreparedEventTimeline
    let position: PositionTimeline
    let reactions: [ReactionInstance]

    init(source: PreparedScenePerformance.Source.CharacterSource,
         gScale: Double, through: Double) {
        events = PreparedEventTimeline(source: source)
        position = PositionTimeline(
            events: source.events,
            recStart: source.recStart
                ?? StartPose(x: source.x, depth: source.depth, face: source.face),
            speed: source.speed,
            rotationSpeed: source.rotationSpeed,
            gScale: gScale,
            upTo: through,
            // Prepared playback/export is long-lived derived state. One-second
            // checkpoints trade a small, bounded amount of memory for at most
            // 60 integration steps per pose instead of 600.
            checkpointStrideSteps: 60)
        reactions = source.reactions.sorted {
            $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
        }
    }
}

struct PreparedPerformanceState: Sendable {
    struct OutfitChange: Sendable {
        var t: Double
        var previous: String?
    }

    var eye = EyeExpression.open
    var tilt = 0.0
    var tiltPrevious = 0.0
    var tiltChangeTime = -1_000.0
    var manualMouthOpen = false
    var outfit: [Int: String]
    var lastOutfitChange: [Int: OutfitChange] = [:]
    var wobble: Double
    var size: Double
    var speed: Double
    var rotationSpeed: Double
    var lastJumpDown: Double?
    var lastFlipDown: (time: Double, direction: Double)?
    var heldLeft = false
    var heldRight = false
    var heldUp = false
    var heldDown = false
}

/// Checkpoints the non-positional event state every 64 events. A pose query
/// performs one binary search and replays at most 63 events instead of scanning
/// a character's entire history on every frame.
struct PreparedEventTimeline: Sendable {
    private struct Checkpoint: Sendable {
        var processedCount: Int
        var state: PreparedPerformanceState
    }

    private static let stride = 64
    private let source: PreparedScenePerformance.Source.CharacterSource
    private let eventTimes: [Double]
    private let checkpoints: [Checkpoint]
    private let isTimeOrdered: Bool

    init(source: PreparedScenePerformance.Source.CharacterSource) {
        self.source = source
        eventTimes = source.events.map(\.t)
        isTimeOrdered = zip(eventTimes, eventTimes.dropFirst()).allSatisfy(<=)

        var state = Self.initialState(source: source)
        var built = [Checkpoint(processedCount: 0, state: state)]
        for (index, event) in source.events.enumerated() {
            Self.apply(event, to: &state)
            let processed = index + 1
            if processed.isMultiple(of: Self.stride) {
                built.append(Checkpoint(processedCount: processed, state: state))
            }
        }
        checkpoints = built
    }

    func state(at time: Double) -> PreparedPerformanceState {
        guard isTimeOrdered else {
            // Strict decoding rejects unordered events, but retaining the old
            // break-on-first-future-event behavior keeps direct API callers
            // and legacy tests semantically unchanged.
            var state = Self.initialState(source: source)
            for event in source.events {
                guard event.t < time else { break }
                Self.apply(event, to: &state)
            }
            return state
        }

        let end = lowerBound(of: time)
        let checkpoint = checkpoints[min(end / Self.stride, checkpoints.count - 1)]
        var state = checkpoint.state
        if checkpoint.processedCount < end {
            for index in checkpoint.processedCount..<end {
                Self.apply(source.events[index], to: &state)
            }
        }
        return state
    }

    /// Deterministic test/debug metric for the bounded tail replay contract.
    func replayedEventCount(at time: Double) -> Int {
        guard isTimeOrdered else { return source.events.prefix { $0.t < time }.count }
        let end = lowerBound(of: time)
        let checkpoint = checkpoints[min(end / Self.stride, checkpoints.count - 1)]
        return end - checkpoint.processedCount
    }

    static func state(for character: Character, at time: Double) -> PreparedPerformanceState {
        var state = PreparedPerformanceState(
            outfit: character.baseOutfit,
            wobble: character.wobble,
            size: character.size,
            speed: character.speed,
            rotationSpeed: character.rotationSpeed)
        for event in character.events {
            guard event.t < time else { break }
            apply(event, to: &state)
        }
        return state
    }

    private func lowerBound(of time: Double) -> Int {
        var low = 0
        var high = eventTimes.count
        while low < high {
            let middle = (low + high) / 2
            if eventTimes[middle] < time { low = middle + 1 }
            else { high = middle }
        }
        return low
    }

    private static func initialState(
        source: PreparedScenePerformance.Source.CharacterSource
    ) -> PreparedPerformanceState {
        PreparedPerformanceState(
            outfit: source.baseOutfit,
            wobble: source.wobble,
            size: source.size,
            speed: source.speed,
            rotationSpeed: source.rotationSpeed)
    }

    static func apply(_ event: PerfEvent, to state: inout PreparedPerformanceState) {
        switch event {
        case .motion(_, let speed, let rotationSpeed, let wobble, let size):
            if let speed { state.speed = speed }
            if let rotationSpeed { state.rotationSpeed = rotationSpeed }
            if let wobble { state.wobble = wobble }
            if let size { state.size = size }
        case .outfit(let time, let slot, let name):
            state.lastOutfitChange[slot] = .init(
                t: time, previous: state.outfit[slot])
            if let name { state.outfit[slot] = name }
            else { state.outfit.removeValue(forKey: slot) }
        case .key(let time, let code, let down):
            if let blink = code.blinkExpression {
                state.eye = down ? blink : .open
                return
            }
            switch code {
            case .keyM:
                state.manualMouthOpen = down
            case .keyT:
                state.tiltPrevious = state.tilt
                state.tilt = down ? 9 : 0
                state.tiltChangeTime = time
            case .keyB:
                state.tiltPrevious = state.tilt
                state.tilt = down ? -9 : 0
                state.tiltChangeTime = time
            case .keyJ:
                if down { state.lastJumpDown = time }
            case .keyF:
                if down { state.lastFlipDown = (time, 1) }
            case .keyD:
                if down { state.lastFlipDown = (time, -1) }
            case .arrowLeft:
                state.heldLeft = down
            case .arrowRight:
                state.heldRight = down
            case .arrowUp:
                state.heldUp = down
            case .arrowDown:
                state.heldDown = down
            default:
                break
            }
        }
    }
}
