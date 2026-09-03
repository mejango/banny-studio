import Foundation
import Dispatch

/// One item returned by a room's long-poll endpoint.
///
/// `cursor` is authoritative for the next poll. It is normally the context's
/// `basis_seq`, but keeping it explicit lets alternate transports resume from
/// a server-provided cursor without changing the polling loop.
public struct RoomPolledContext: Sendable {
    public let cursor: Int64
    public let context: AgentContextEnvelope

    public init(cursor: Int64, context: AgentContextEnvelope) {
        self.cursor = cursor
        self.context = context
    }
}

/// Participant-side room I/O. A CLI can inject the URLSession-backed transport,
/// while tests and embedded clients can supply a fully in-memory implementation.
public protocol RoomTransport: Sendable {
    func poll(after cursor: Int64?) async throws -> RoomPolledContext?
    func submit(_ decision: AgentDecisionEnvelope) async throws
    func leave() async throws
}

/// Optional refinement for transports which can keep a decision submission
/// inside the room context's remaining wall-clock deadline.
public protocol DeadlineAwareRoomTransport: RoomTransport {
    func submit(_ decision: AgentDecisionEnvelope, timeout: TimeInterval) async throws
}

/// Injectable monotonic time used for context deadlines and WAN retry budgets.
public protocol RoomTransportClock: Sendable {
    func nowNanoseconds() -> UInt64
}

public struct SystemRoomTransportClock: RoomTransportClock {
    public init() {}

    public func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

/// The narrow seam used by the polling loop to call a participant's local AI.
public protocol AgentDecisionProvider: Sendable {
    func decide(_ context: AgentContextEnvelope) async throws -> AgentDecisionEnvelope
}

public enum RoomPollingLoopError: Error, Equatable, Sendable {
    case negativeCursor(Int64)
    case nonAdvancingCursor(previous: Int64, received: Int64)
    case decisionDeadlineExpired(requestID: String)
}

public enum RoomPollingStep: Equatable, Sendable {
    case idle(after: Int64?)
    case submitted(after: Int64, requestID: String, intentID: String)
    /// Local-agent failures are acknowledged to the room with a bridge-minted
    /// no-op decision before this result is emitted. This consumes the
    /// outstanding request without retrying stale scene context.
    case skipped(after: Int64, requestID: String, reason: String)

    public var cursor: Int64? {
        switch self {
        case .idle(let cursor): cursor
        case .submitted(let cursor, _, _), .skipped(let cursor, _, _): cursor
        }
    }
}

public protocol RoomPollingSleeper: Sendable {
    func sleep(milliseconds: UInt64) async throws
}

public struct TaskRoomPollingSleeper: RoomPollingSleeper {
    public init() {}

    public func sleep(milliseconds: UInt64) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
}

/// A cancellation-aware, sequential polling driver suitable for a long-running
/// CLI command. At most one local decision request is active at a time.
public struct RoomPollingLoop: Sendable {
    public let transport: any RoomTransport
    public let agent: any AgentDecisionProvider
    public let emptyPollDelayMS: UInt64
    public let sleeper: any RoomPollingSleeper
    public let clock: any RoomTransportClock

    public init(
        transport: any RoomTransport,
        agent: any AgentDecisionProvider,
        emptyPollDelayMS: UInt64 = 250,
        sleeper: any RoomPollingSleeper = TaskRoomPollingSleeper(),
        clock: any RoomTransportClock = SystemRoomTransportClock()
    ) {
        self.transport = transport
        self.agent = agent
        self.emptyPollDelayMS = emptyPollDelayMS
        self.sleeper = sleeper
        self.clock = clock
    }

    /// Performs one poll/decide/submit cycle. Room transport failures are
    /// surfaced to the caller. A local-agent failure first submits a correlated
    /// no-op, then reports `.skipped`, so the room advances authoritatively and
    /// never retries stale context.
    public func step(after cursor: Int64?) async throws -> RoomPollingStep {
        try Task.checkCancellation()
        if let cursor, cursor < 0 {
            throw RoomPollingLoopError.negativeCursor(cursor)
        }
        guard let item = try await transport.poll(after: cursor) else {
            return .idle(after: cursor)
        }
        guard item.cursor >= 0 else {
            throw RoomPollingLoopError.negativeCursor(item.cursor)
        }
        if let cursor, item.cursor <= cursor {
            throw RoomPollingLoopError.nonAdvancingCursor(
                previous: cursor,
                received: item.cursor)
        }

        let decisionStartedAt = clock.nowNanoseconds()
        let decision: AgentDecisionEnvelope
        do {
            decision = try await agent.decide(item.context)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            let noOp = AgentDecisionEnvelope(
                requestID: item.context.requestID,
                intentID: "bridge-skip-\(UUID().uuidString)")
            try Task.checkCancellation()
            try await submit(
                noOp,
                for: item.context,
                decisionStartedAt: decisionStartedAt)
            return .skipped(
                after: item.cursor,
                requestID: item.context.requestID,
                reason: String(describing: error))
        }
        try Task.checkCancellation()
        try await submit(
            decision,
            for: item.context,
            decisionStartedAt: decisionStartedAt)
        return .submitted(
            after: item.cursor,
            requestID: decision.requestID,
            intentID: decision.intentID)
    }

    /// Runs until cancellation or a room transport error. The callback gives a
    /// CLI structured progress/error events without coupling this module to its
    /// output layer.
    public func run(
        startingAfter initialCursor: Int64? = nil,
        onStep: @escaping @Sendable (RoomPollingStep) async -> Void = { _ in }
    ) async throws {
        var cursor = initialCursor
        while true {
            try Task.checkCancellation()
            let result = try await step(after: cursor)
            cursor = result.cursor
            await onStep(result)
            if case .idle = result, emptyPollDelayMS > 0 {
                try await sleeper.sleep(milliseconds: emptyPollDelayMS)
            }
        }
    }

    private func submit(
        _ decision: AgentDecisionEnvelope,
        for context: AgentContextEnvelope,
        decisionStartedAt: UInt64
    ) async throws {
        try Task.checkCancellation()
        guard let deadlineTransport = transport as? any DeadlineAwareRoomTransport else {
            try await transport.submit(decision)
            return
        }

        let now = clock.nowNanoseconds()
        let elapsedNanoseconds = now >= decisionStartedAt
            ? now - decisionStartedAt
            : 0
        guard context.timeoutMS > 0 else {
            throw RoomPollingLoopError.decisionDeadlineExpired(
                requestID: context.requestID)
        }
        let (budgetNanoseconds, overflow) = UInt64(context.timeoutMS)
            .multipliedReportingOverflow(by: 1_000_000)
        guard !overflow else {
            throw RoomPollingLoopError.decisionDeadlineExpired(
                requestID: context.requestID)
        }
        guard elapsedNanoseconds < budgetNanoseconds else {
            throw RoomPollingLoopError.decisionDeadlineExpired(
                requestID: context.requestID)
        }
        let remaining = TimeInterval(budgetNanoseconds - elapsedNanoseconds)
            / 1_000_000_000
        try await deadlineTransport.submit(decision, timeout: remaining)
    }
}
