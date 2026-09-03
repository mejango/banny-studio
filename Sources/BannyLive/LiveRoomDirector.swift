import Foundation

/// The only model seam used by an autonomous room. A provider receives one
/// character's immutable private prompt separately from the public scene
/// context and can return only the same bounded, typed decision that
/// `LiveRoom.submit` already validates and records.
public protocol LiveDirectorDecisionProvider: Sendable {
    func decide(
        characterPrompt: String,
        context: AgentContextEnvelope
    ) async throws -> AgentDecisionEnvelope
}

public protocol LiveRoomDirectorClock: Sendable {
    func nowMS() -> Int64
}

public struct LiveRoomSystemDirectorClock: LiveRoomDirectorClock {
    public init() {}

    public func nowMS() -> Int64 {
        Int64((ProcessInfo.processInfo.systemUptime * 1_000).rounded(.down))
    }
}

/// Adapts the host's single monotonic clock closure so HTTP mutations and
/// autonomous turns share one time domain.
struct LiveRoomHostDirectorClock: LiveRoomDirectorClock {
    let clockMS: @Sendable () -> Int64

    func nowMS() -> Int64 { max(0, clockMS()) }
}

public protocol LiveRoomDirectorSleeper: Sendable {
    func sleep(milliseconds: UInt64) async throws
}

public struct LiveRoomTaskDirectorSleeper: LiveRoomDirectorSleeper {
    public init() {}

    public func sleep(milliseconds: UInt64) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
}

public enum LiveRoomDirectorStep: Equatable, Sendable {
    case idle
    case submitted(participantID: String, seq: Int64, usedFallback: Bool)
}

/// One sequential, room-owned turn scheduler.
///
/// Refreshing context after every accepted turn gives later performers the
/// prior line/action to react to and prevents the independent-agent race that
/// made several characters talk at once. The provider never receives another
/// character's prompt, and every result still passes through `LiveRoom`'s
/// atomic validation and canonical `.bs` persistence path.
public actor LiveRoomDirector {
    private let room: LiveRoom
    private let provider: any LiveDirectorDecisionProvider
    private let fallback: any LiveDirectorDecisionProvider
    private let clock: any LiveRoomDirectorClock
    private let sleeper: any LiveRoomDirectorSleeper
    private let emptyRoundDelayMS: UInt64
    private let decisionTimeoutMS: Int

    private var loopTask: Task<Void, Never>?
    private var nextSeat = 0

    public init(
        room: LiveRoom,
        provider: any LiveDirectorDecisionProvider,
        fallback: any LiveDirectorDecisionProvider = BuiltInLiveDirectorDecisionProvider(),
        clock: any LiveRoomDirectorClock = LiveRoomSystemDirectorClock(),
        sleeper: any LiveRoomDirectorSleeper = LiveRoomTaskDirectorSleeper(),
        emptyRoundDelayMS: UInt64 = 150,
        decisionTimeoutMS: Int = 10_000
    ) {
        precondition(emptyRoundDelayMS > 0)
        precondition((100...10_000).contains(decisionTimeoutMS))
        self.room = room
        self.provider = provider
        self.fallback = fallback
        self.clock = clock
        self.sleeper = sleeper
        self.emptyRoundDelayMS = emptyRoundDelayMS
        self.decisionTimeoutMS = decisionTimeoutMS
    }

    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() async {
        guard let task = loopTask else { return }
        loopTask = nil
        task.cancel()
        await task.value
    }

    /// Performs at most one accepted character turn. Exposed for deterministic
    /// tests and for future schedulers; production uses `start()`.
    @discardableResult
    public func step() async throws -> LiveRoomDirectorStep {
        try Task.checkCancellation()
        if await room.isEnded() {
            throw LiveRoomError.roomEnded
        }
        let cast = await room.autonomousParticipants()
        guard !cast.isEmpty else { return .idle }

        let split = cast.partitioningIndex { $0.seat >= nextSeat }
        let ordered = Array(cast[split...]) + Array(cast[..<split])
        for performer in ordered {
            try Task.checkCancellation()
            let context: AgentContextEnvelope
            do {
                context = try await room.nextDecision(
                    participantID: performer.participantID,
                    nowMS: clock.nowMS(),
                    timeoutMS: decisionTimeoutMS)
            } catch LiveRoomError.decisionNotDue {
                continue
            } catch LiveRoomError.participantDisconnected {
                continue
            }

            nextSeat = (performer.seat + 1) % 10
            let primary: AgentDecisionEnvelope?
            do {
                primary = try await provider.decide(
                    characterPrompt: performer.characterPrompt,
                    context: context)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                primary = nil
            }

            if let primary,
               let result = try await submitIfValid(
                   primary,
                   context: context,
                   participantID: performer.participantID) {
                return .submitted(
                    participantID: performer.participantID,
                    seq: result.seq,
                    usedFallback: false)
            }

            let fallbackDecision: AgentDecisionEnvelope
            do {
                fallbackDecision = try await fallback.decide(
                    characterPrompt: performer.characterPrompt,
                    context: context)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                fallbackDecision = AgentDecisionEnvelope(
                    requestID: context.requestID,
                    intentID: "director-skip-\(context.requestID)",
                    requestAfterMS: 1_000)
            }
            if let result = try await submitIfValid(
                fallbackDecision,
                context: context,
                participantID: performer.participantID
            ) {
                return .submitted(
                    participantID: performer.participantID,
                    seq: result.seq,
                    usedFallback: true)
            }
            // Even a broken fallback must consume the correlated request.
            // Otherwise the director would repeatedly ask providers to decide
            // against the same stale context until its deadline elapsed.
            let noOp = AgentDecisionEnvelope(
                requestID: context.requestID,
                intentID: "director-skip-\(context.requestID)",
                requestAfterMS: 1_000)
            if let result = try await submitIfValid(
                noOp,
                context: context,
                participantID: performer.participantID
            ) {
                return .submitted(
                    participantID: performer.participantID,
                    seq: result.seq,
                    usedFallback: true)
            }
            return .idle
        }
        return .idle
    }

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                let result = try await step()
                if result == .idle {
                    try await sleeper.sleep(milliseconds: emptyRoundDelayMS)
                }
            } catch is CancellationError {
                return
            } catch LiveRoomError.roomEnded {
                return
            } catch {
                do {
                    try await sleeper.sleep(milliseconds: emptyRoundDelayMS)
                } catch {
                    return
                }
            }
        }
    }

    private func submitIfValid(
        _ supplied: AgentDecisionEnvelope,
        context: AgentContextEnvelope,
        participantID: String
    ) async throws -> LiveRoomSubmitResult? {
        try Task.checkCancellation()
        // One visible speaker at a time is a host-owned staging invariant. A
        // model may still return movement/reaction while another caption is up.
        let someoneSpeaking = context.context.selfState.speaking
            || context.context.cast.contains(where: \.speaking)
        let decision = AgentDecisionEnvelope(
            protocolVersion: supplied.protocolVersion,
            requestID: supplied.requestID,
            intentID: supplied.intentID,
            say: someoneSpeaking ? nil : supplied.say,
            actions: supplied.actions,
            requestAfterMS: supplied.requestAfterMS)
        do {
            return try await room.submit(
                decision,
                participantID: participantID,
                nowMS: clock.nowMS())
        } catch is AgentProtocolValidationError {
            return nil
        } catch LiveRoomError.reactionConflict {
            return nil
        } catch LiveRoomError.intentIDReused {
            return nil
        }
    }
}

/// Zero-install fallback. It is intentionally modest: a local Ollama model can
/// supply richer lines, while this policy guarantees that a room keeps moving
/// and reacting if the model is absent, loading, or temporarily unavailable.
/// Prompt keywords shape tone and energy without ever echoing the private
/// prompt into the scene.
public struct BuiltInLiveDirectorDecisionProvider: LiveDirectorDecisionProvider {
    public init() {}

    public func decide(
        characterPrompt: String,
        context: AgentContextEnvelope
    ) async throws -> AgentDecisionEnvelope {
        let lower = characterPrompt.lowercased()
        let seed = Self.seed(characterPrompt + "\u{1f}" + context.requestID)
        let someoneSpeaking = context.context.selfState.speaking
            || context.context.cast.contains(where: \.speaking)
        let constraints = context.context.constraints
        var actions: [AgentAction] = []

        if someoneSpeaking {
            let listener = SunsetBarPerformancePreset.listenerAction(
                seed: seed,
                style: Self.listenerStyle(lower))
            if Self.isAllowed(listener, by: constraints) {
                actions.append(listener)
            }
        } else {
            if let target = context.context.cast.first,
               let facing = SunsetBarPerformancePreset.facingAction(
                   currentX: context.context.selfState.pose.x,
                   currentFace: context.context.selfState.pose.face,
                   targetX: target.pose.x),
               Self.isAllowed(facing, by: constraints) {
                actions.append(facing)
            }
            if let business = SunsetBarPerformancePreset.idleAction(seed: seed >> 7),
               Self.isAllowed(business, by: constraints) {
                actions.append(business)
            } else if constraints.allowedActions.contains("expression") {
                actions.append(.expression(expression: .blink, durationMS: 100))
            }
        }

        let say = someoneSpeaking ? nil : Self.line(for: lower, seed: seed)
        return AgentDecisionEnvelope(
            requestID: context.requestID,
            intentID: "builtin-\(context.requestID)",
            say: say,
            actions: Array(actions.prefix(constraints.maxActions)),
            requestAfterMS: 1_300 + Int(seed % 1_700))
    }

    private static func listenerStyle(
        _ prompt: String
    ) -> SunsetBarPerformancePreset.ListenerStyle {
        if containsAny(prompt, ["rowdy", "chaotic", "loud", "wild", "party"]) {
            return .rowdy
        }
        if containsAny(prompt, ["shy", "quiet", "soft", "gentle", "reserved"]) {
            return .soft
        }
        return .conversational
    }

    private static func line(for prompt: String, seed: UInt64) -> String? {
        if containsAny(prompt, ["shy", "quiet", "silent", "reserved"]), seed % 5 != 0 {
            return nil
        }
        let choices: [String]
        if containsAny(prompt, ["philosopher", "thoughtful", "reflective", "wise"]) {
            choices = [
                "Funny how a room changes when someone new walks in.",
                "Maybe the moment is the whole point.",
                "I wonder what we'll remember about tonight.",
            ]
        } else if containsAny(prompt, ["curious", "inquisitive", "question"]) {
            choices = [
                "What brought you here?",
                "What do you make of all this?",
                "Okay, I have to ask—what happens next?",
            ]
        } else if containsAny(prompt, ["grumpy", "cynical", "irritable", "sour"]) {
            choices = [
                "Hmph. I've seen stranger nights.",
                "Let's not make a whole thing of it.",
                "I was comfortable before this got interesting.",
            ]
        } else if containsAny(prompt, ["friendly", "warm", "kind", "welcoming"]) {
            choices = [
                "Good to see you. Come join us.",
                "This is better with company.",
                "You picked a good moment to arrive.",
            ]
        } else if containsAny(prompt, ["chaotic", "wild", "mischievous", "rowdy"]) {
            choices = [
                "Now this is getting interesting.",
                "I have an idea, and it is probably a bad one.",
                "Nobody panic. Or do—surprise me.",
            ]
        } else {
            choices = [
                "What a scene.",
                "I'm listening.",
                "Something tells me this night has plans.",
            ]
        }
        // Leave most turns to movement/listening so captions can breathe.
        guard seed % 3 == 0 else { return nil }
        return choices[Int((seed >> 8) % UInt64(choices.count))]
    }

    private static func isAllowed(
        _ action: AgentAction,
        by constraints: AgentConstraints
    ) -> Bool {
        guard constraints.allowedActions.contains(action.operation) else { return false }
        if case .reaction(let reactionID, _, _) = action {
            return constraints.allowedReactionIDs.contains(reactionID)
        }
        return true
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains(where: value.contains)
    }

    /// FNV-1a is stable across launches, unlike Swift's randomized `Hasher`.
    private static func seed(_ value: String) -> UInt64 {
        value.utf8.reduce(0xcbf2_9ce4_8422_2325) { partial, byte in
            (partial ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
    }
}

private extension RandomAccessCollection {
    func partitioningIndex(
        where predicate: (Element) throws -> Bool
    ) rethrows -> Index {
        var low = startIndex
        var count = self.count
        while count > 0 {
            let half = count / 2
            let mid = index(low, offsetBy: half)
            if try predicate(self[mid]) {
                count = half
            } else {
                low = index(after: mid)
                count -= half + 1
            }
        }
        return low
    }
}
