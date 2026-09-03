import Foundation
import BannyCore

/// Frozen participant-AI wire contract. The participant bridge sends a context
/// to a local agent and accepts only constrained, typed intentions in return.
public enum BannyAgentProtocol {
    public static let version = "banny.agent.v1"
    public static let maximumResponseBytes = 16 * 1_024
    public static let maximumActions = 4
    public static let maximumSpeechCharacters = 280
    public static let minimumActionDurationMS = 80
    public static let maximumActionDurationMS = 3_000
}

public struct AgentContextEnvelope: Codable, Equatable, Sendable {
    public let protocolVersion: String
    public let requestID: String
    public let roomID: String
    public let participantID: String
    public let basisSeq: Int64
    public let timeoutMS: Int
    public let context: AgentContext

    public init(
        protocolVersion: String = BannyAgentProtocol.version,
        requestID: String,
        roomID: String,
        participantID: String,
        basisSeq: Int64,
        timeoutMS: Int = 3_000,
        context: AgentContext
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.roomID = roomID
        self.participantID = participantID
        self.basisSeq = basisSeq
        self.timeoutMS = timeoutMS
        self.context = context
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case protocolVersion = "protocol"
        case requestID = "request_id"
        case roomID = "room_id"
        case participantID = "participant_id"
        case basisSeq = "basis_seq"
        case timeoutMS = "timeout_ms"
        case context
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decode(String.self, forKey: .protocolVersion)
        requestID = try c.decode(String.self, forKey: .requestID)
        roomID = try c.decode(String.self, forKey: .roomID)
        participantID = try c.decode(String.self, forKey: .participantID)
        basisSeq = try c.decode(Int64.self, forKey: .basisSeq)
        timeoutMS = try c.decode(Int.self, forKey: .timeoutMS)
        context = try c.decode(AgentContext.self, forKey: .context)
    }
}

public struct AgentContext: Codable, Equatable, Sendable {
    public let sceneTimeMS: Int64
    public let room: AgentRoomContext
    public let selfState: AgentParticipantContext
    public let cast: [AgentParticipantContext]
    public let recentEvents: [AgentRecentEvent]
    public let constraints: AgentConstraints

    public init(
        sceneTimeMS: Int64,
        room: AgentRoomContext,
        selfState: AgentParticipantContext,
        cast: [AgentParticipantContext] = [],
        recentEvents: [AgentRecentEvent] = [],
        constraints: AgentConstraints = AgentConstraints()
    ) {
        self.sceneTimeMS = sceneTimeMS
        self.room = room
        self.selfState = selfState
        self.cast = cast
        self.recentEvents = recentEvents
        self.constraints = constraints
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sceneTimeMS = "scene_time_ms"
        case room
        case selfState = "self_state"
        case cast
        case recentEvents = "recent_events"
        case constraints
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sceneTimeMS = try c.decode(Int64.self, forKey: .sceneTimeMS)
        room = try c.decode(AgentRoomContext.self, forKey: .room)
        selfState = try c.decode(AgentParticipantContext.self, forKey: .selfState)
        cast = try c.decode([AgentParticipantContext].self, forKey: .cast)
        recentEvents = try c.decode([AgentRecentEvent].self, forKey: .recentEvents)
        constraints = try c.decode(AgentConstraints.self, forKey: .constraints)
    }
}

public struct AgentRoomContext: Codable, Equatable, Sendable {
    public let state: String
    public let title: String
    public let premise: String?

    public init(state: String, title: String, premise: String? = nil) {
        self.state = state
        self.title = title
        self.premise = premise
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case state, title, premise }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(String.self, forKey: .state)
        title = try c.decode(String.self, forKey: .title)
        premise = try c.decodeIfPresent(String.self, forKey: .premise)
    }
}

public struct AgentParticipantContext: Codable, Equatable, Sendable {
    public let participantID: String
    public let displayName: String
    public let pose: AgentPose
    public let status: String
    public let speaking: Bool

    public init(
        participantID: String,
        displayName: String,
        pose: AgentPose,
        status: String,
        speaking: Bool = false
    ) {
        self.participantID = participantID
        self.displayName = displayName
        self.pose = pose
        self.status = status
        self.speaking = speaking
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case participantID = "participant_id"
        case displayName = "display_name"
        case pose, status, speaking
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        participantID = try c.decode(String.self, forKey: .participantID)
        displayName = try c.decode(String.self, forKey: .displayName)
        pose = try c.decode(AgentPose.self, forKey: .pose)
        status = try c.decode(String.self, forKey: .status)
        speaking = try c.decodeIfPresent(Bool.self, forKey: .speaking) ?? false
    }
}

public struct AgentPose: Codable, Equatable, Sendable {
    public enum Face: String, Codable, Sendable { case left, right }

    public let x: Double
    public let depth: Double
    public let face: Face
    public let spin: Double
    public let zoom: Double

    public init(
        x: Double,
        depth: Double,
        face: Face,
        spin: Double = 0,
        zoom: Double = 1
    ) {
        self.x = x
        self.depth = depth
        self.face = face
        self.spin = spin
        self.zoom = zoom
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case x, depth, face, spin, zoom }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decode(Double.self, forKey: .x)
        depth = try c.decode(Double.self, forKey: .depth)
        face = try c.decode(Face.self, forKey: .face)
        spin = try c.decode(Double.self, forKey: .spin)
        zoom = try c.decode(Double.self, forKey: .zoom)
        guard x.isFinite, depth.isFinite, spin.isFinite, zoom.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .x, in: c, debugDescription: "Pose values must be finite.")
        }
    }
}

public struct AgentRecentEvent: Codable, Equatable, Sendable {
    public let seq: Int64
    public let sceneTimeMS: Int64
    public let kind: String
    public let participantID: String?
    public let text: String?
    public let action: String?

    public init(
        seq: Int64,
        sceneTimeMS: Int64,
        kind: String,
        participantID: String? = nil,
        text: String? = nil,
        action: String? = nil
    ) {
        self.seq = seq
        self.sceneTimeMS = sceneTimeMS
        self.kind = kind
        self.participantID = participantID
        self.text = text
        self.action = action
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case seq
        case sceneTimeMS = "scene_time_ms"
        case kind
        case participantID = "participant_id"
        case text, action
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int64.self, forKey: .seq)
        sceneTimeMS = try c.decode(Int64.self, forKey: .sceneTimeMS)
        kind = try c.decode(String.self, forKey: .kind)
        participantID = try c.decodeIfPresent(String.self, forKey: .participantID)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        action = try c.decodeIfPresent(String.self, forKey: .action)
    }
}

public struct AgentConstraints: Codable, Equatable, Sendable {
    public static let allOperations = [
        "move", "depth", "tilt", "expression", "jump", "flip",
        "rotate", "zoom", "reset", "reaction",
    ]

    public let allowedActions: [String]
    public let allowedReactionIDs: [String]
    public let maxActions: Int
    public let maxSpeechChars: Int
    public let maxActionMS: Int

    public init(
        allowedActions: [String] = AgentConstraints.allOperations,
        allowedReactionIDs: [String] = [],
        maxActions: Int = BannyAgentProtocol.maximumActions,
        maxSpeechChars: Int = BannyAgentProtocol.maximumSpeechCharacters,
        maxActionMS: Int = BannyAgentProtocol.maximumActionDurationMS
    ) {
        self.allowedActions = allowedActions
        self.allowedReactionIDs = allowedReactionIDs
        self.maxActions = maxActions
        self.maxSpeechChars = maxSpeechChars
        self.maxActionMS = maxActionMS
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case allowedActions = "allowed_actions"
        case allowedReactionIDs = "allowed_reaction_ids"
        case maxActions = "max_actions"
        case maxSpeechChars = "max_speech_chars"
        case maxActionMS = "max_action_ms"
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowedActions = try c.decode([String].self, forKey: .allowedActions)
        allowedReactionIDs = try c.decode([String].self, forKey: .allowedReactionIDs)
        maxActions = try c.decode(Int.self, forKey: .maxActions)
        maxSpeechChars = try c.decode(Int.self, forKey: .maxSpeechChars)
        maxActionMS = try c.decode(Int.self, forKey: .maxActionMS)
    }
}

public struct AgentDecisionEnvelope: Codable, Equatable, Sendable {
    public let protocolVersion: String
    public let requestID: String
    public let intentID: String
    public let say: String?
    public let actions: [AgentAction]
    public let requestAfterMS: Int?

    public init(
        protocolVersion: String = BannyAgentProtocol.version,
        requestID: String,
        intentID: String,
        say: String? = nil,
        actions: [AgentAction] = [],
        requestAfterMS: Int? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.intentID = intentID
        self.say = say
        self.actions = actions
        self.requestAfterMS = requestAfterMS
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case protocolVersion = "protocol"
        case requestID = "request_id"
        case intentID = "intent_id"
        case say, actions
        case requestAfterMS = "request_after_ms"
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decode(String.self, forKey: .protocolVersion)
        requestID = try c.decode(String.self, forKey: .requestID)
        intentID = try c.decode(String.self, forKey: .intentID)
        say = try c.decodeIfPresent(String.self, forKey: .say)
        actions = try c.decode([AgentAction].self, forKey: .actions)
        requestAfterMS = try c.decodeIfPresent(Int.self, forKey: .requestAfterMS)
    }
}

public enum AgentAction: Equatable, Sendable {
    public enum HorizontalDirection: String, Codable, Sendable { case left, right }
    public enum DepthDirection: String, Codable, Sendable { case away, toward }
    public enum TiltDirection: String, Codable, Sendable { case forward, back }
    public enum Expression: String, Codable, Sendable { case blink, brow1, brow2 }
    public enum FlipDirection: String, Codable, Sendable { case front, back }
    public enum ZoomDirection: String, Codable, Sendable { case `in`, out }
    public enum ResetTarget: String, Codable, Sendable { case spin, zoom }

    case move(direction: HorizontalDirection, durationMS: Int)
    case depth(direction: DepthDirection, durationMS: Int)
    case tilt(direction: TiltDirection, durationMS: Int)
    case expression(expression: Expression, durationMS: Int)
    case jump
    case flip(direction: FlipDirection)
    case rotate(direction: HorizontalDirection, durationMS: Int)
    case zoom(direction: ZoomDirection, durationMS: Int)
    case reset(target: ResetTarget)
    case reaction(reactionID: String, durationMS: Int?, intensity: Double?)

    public var operation: String {
        switch self {
        case .move: "move"
        case .depth: "depth"
        case .tilt: "tilt"
        case .expression: "expression"
        case .jump: "jump"
        case .flip: "flip"
        case .rotate: "rotate"
        case .zoom: "zoom"
        case .reset: "reset"
        case .reaction: "reaction"
        }
    }

    public var eventGroup: EventGroup? {
        switch self {
        case .move: .move
        case .depth: .depth
        case .tilt: .tilt
        case .expression: .blink
        case .jump, .flip: .jump
        case .rotate: .spin
        case .zoom: .zoom
        case .reset(let target): target == .spin ? .spin : .zoom
        case .reaction: nil
        }
    }
}

extension AgentAction: Codable {
    private enum CodingKeys: String, CodingKey {
        case op, direction, expression
        case durationMS = "duration_ms"
        case target
        case reactionID = "reaction_id"
        case intensity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let operation = try c.decode(String.self, forKey: .op)
        switch operation {
        case "move":
            try rejectUnknownKeys(decoder, allowedNames: ["op", "direction", "duration_ms"])
            self = .move(
                direction: try c.decode(HorizontalDirection.self, forKey: .direction),
                durationMS: try c.decode(Int.self, forKey: .durationMS))
        case "depth":
            try rejectUnknownKeys(decoder, allowedNames: ["op", "direction", "duration_ms"])
            self = .depth(
                direction: try c.decode(DepthDirection.self, forKey: .direction),
                durationMS: try c.decode(Int.self, forKey: .durationMS))
        case "tilt":
            try rejectUnknownKeys(decoder, allowedNames: ["op", "direction", "duration_ms"])
            self = .tilt(
                direction: try c.decode(TiltDirection.self, forKey: .direction),
                durationMS: try c.decode(Int.self, forKey: .durationMS))
        case "expression":
            try rejectUnknownKeys(decoder, allowedNames: ["op", "expression", "duration_ms"])
            self = .expression(
                expression: try c.decode(Expression.self, forKey: .expression),
                durationMS: try c.decode(Int.self, forKey: .durationMS))
        case "jump":
            try rejectUnknownKeys(decoder, allowedNames: ["op"])
            self = .jump
        case "flip":
            try rejectUnknownKeys(decoder, allowedNames: ["op", "direction"])
            self = .flip(direction: try c.decode(FlipDirection.self, forKey: .direction))
        case "rotate":
            try rejectUnknownKeys(decoder, allowedNames: ["op", "direction", "duration_ms"])
            self = .rotate(
                direction: try c.decode(HorizontalDirection.self, forKey: .direction),
                durationMS: try c.decode(Int.self, forKey: .durationMS))
        case "zoom":
            try rejectUnknownKeys(decoder, allowedNames: ["op", "direction", "duration_ms"])
            self = .zoom(
                direction: try c.decode(ZoomDirection.self, forKey: .direction),
                durationMS: try c.decode(Int.self, forKey: .durationMS))
        case "reset":
            try rejectUnknownKeys(decoder, allowedNames: ["op", "target"])
            self = .reset(target: try c.decode(ResetTarget.self, forKey: .target))
        case "reaction":
            try rejectUnknownKeys(
                decoder,
                allowedNames: ["op", "reaction_id", "duration_ms", "intensity"])
            self = .reaction(
                reactionID: try c.decode(String.self, forKey: .reactionID),
                durationMS: try c.decodeIfPresent(Int.self, forKey: .durationMS),
                intensity: try c.decodeIfPresent(Double.self, forKey: .intensity))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .op, in: c, debugDescription: "Unknown agent action operation.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(operation, forKey: .op)
        switch self {
        case .move(let direction, let durationMS):
            try c.encode(direction, forKey: .direction)
            try c.encode(durationMS, forKey: .durationMS)
        case .depth(let direction, let durationMS):
            try c.encode(direction, forKey: .direction)
            try c.encode(durationMS, forKey: .durationMS)
        case .tilt(let direction, let durationMS):
            try c.encode(direction, forKey: .direction)
            try c.encode(durationMS, forKey: .durationMS)
        case .expression(let expression, let durationMS):
            try c.encode(expression, forKey: .expression)
            try c.encode(durationMS, forKey: .durationMS)
        case .jump:
            break
        case .flip(let direction):
            try c.encode(direction, forKey: .direction)
        case .rotate(let direction, let durationMS):
            try c.encode(direction, forKey: .direction)
            try c.encode(durationMS, forKey: .durationMS)
        case .zoom(let direction, let durationMS):
            try c.encode(direction, forKey: .direction)
            try c.encode(durationMS, forKey: .durationMS)
        case .reset(let target):
            try c.encode(target, forKey: .target)
        case .reaction(let reactionID, let durationMS, let intensity):
            try c.encode(reactionID, forKey: .reactionID)
            try c.encodeIfPresent(durationMS, forKey: .durationMS)
            try c.encodeIfPresent(intensity, forKey: .intensity)
        }
    }
}

public enum AgentProtocolValidationError: Error, Equatable, Sendable, LocalizedError {
    case payloadTooLarge(actual: Int, limit: Int)
    case malformedJSON
    case wrongProtocol(String)
    case requestMismatch(String)
    case invalidIntentID
    case speechTooLong
    case tooManyActions
    case actionNotAllowed(String)
    case invalidActionDuration
    case reactionNotAllowed(String)
    case invalidReactionIntensity
    case duplicateActionGroup(String)
    case invalidRequestDelay

    public var errorDescription: String? {
        switch self {
        case .payloadTooLarge(let actual, let limit):
            "Agent response is \(actual) bytes; the limit is \(limit)."
        case .malformedJSON: "Agent response is not strict banny.agent.v1 JSON."
        case .wrongProtocol(let value): "Unsupported agent protocol: \(value)."
        case .requestMismatch: "Agent response does not match the outstanding request."
        case .invalidIntentID: "intent_id must contain 1...128 characters."
        case .speechTooLong: "Agent speech exceeds the advertised limit."
        case .tooManyActions: "Agent response contains too many actions."
        case .actionNotAllowed(let op): "Agent action is not allowed: \(op)."
        case .invalidActionDuration: "Agent action duration is outside the advertised bounds."
        case .reactionNotAllowed(let id): "Agent reaction is not allowed: \(id)."
        case .invalidReactionIntensity: "Reaction intensity must be finite and inside 0...4."
        case .duplicateActionGroup(let group): "Agent response repeats action group \(group)."
        case .invalidRequestDelay: "request_after_ms must be inside 250...10000."
        }
    }
}

public enum AgentProtocolCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try BannyAgentWireJSON.encoder.encode(value)
    }

    public static func decodeDecision(
        _ data: Data,
        expectedRequestID: String,
        constraints: AgentConstraints
    ) throws -> AgentDecisionEnvelope {
        guard data.count <= BannyAgentProtocol.maximumResponseBytes else {
            throw AgentProtocolValidationError.payloadTooLarge(
                actual: data.count, limit: BannyAgentProtocol.maximumResponseBytes)
        }
        let decision: AgentDecisionEnvelope
        do {
            decision = try BannyAgentWireJSON.decoder.decode(AgentDecisionEnvelope.self, from: data)
        } catch {
            throw AgentProtocolValidationError.malformedJSON
        }
        try validate(decision, expectedRequestID: expectedRequestID, constraints: constraints)
        return decision
    }

    public static func validate(
        _ decision: AgentDecisionEnvelope,
        expectedRequestID: String,
        constraints: AgentConstraints
    ) throws {
        guard decision.protocolVersion == BannyAgentProtocol.version else {
            throw AgentProtocolValidationError.wrongProtocol(decision.protocolVersion)
        }
        guard decision.requestID == expectedRequestID else {
            throw AgentProtocolValidationError.requestMismatch(decision.requestID)
        }
        guard !decision.intentID.isEmpty, decision.intentID.unicodeScalars.count <= 128 else {
            throw AgentProtocolValidationError.invalidIntentID
        }
        let speechLimit = min(BannyAgentProtocol.maximumSpeechCharacters, constraints.maxSpeechChars)
        if let say = decision.say, say.unicodeScalars.count > speechLimit {
            throw AgentProtocolValidationError.speechTooLong
        }
        guard decision.actions.count <= min(BannyAgentProtocol.maximumActions, constraints.maxActions) else {
            throw AgentProtocolValidationError.tooManyActions
        }
        if let delay = decision.requestAfterMS, !(250...10_000).contains(delay) {
            throw AgentProtocolValidationError.invalidRequestDelay
        }

        let allowedOperations = Set(constraints.allowedActions)
        let allowedReactions = Set(constraints.allowedReactionIDs)
        var groups: Set<EventGroup> = []
        for action in decision.actions {
            guard allowedOperations.contains(action.operation) else {
                throw AgentProtocolValidationError.actionNotAllowed(action.operation)
            }
            if let group = action.eventGroup, !groups.insert(group).inserted {
                throw AgentProtocolValidationError.duplicateActionGroup(group.rawValue)
            }
            switch action {
            case .move(_, let duration), .depth(_, let duration), .tilt(_, let duration),
                 .expression(_, let duration), .rotate(_, let duration), .zoom(_, let duration):
                try validate(duration: duration, maximum: constraints.maxActionMS)
            case .reaction(let id, let duration, let intensity):
                guard allowedReactions.contains(id) else {
                    throw AgentProtocolValidationError.reactionNotAllowed(id)
                }
                if let duration { try validate(duration: duration, maximum: constraints.maxActionMS) }
                if let intensity, !intensity.isFinite || !(0...4).contains(intensity) {
                    throw AgentProtocolValidationError.invalidReactionIntensity
                }
            case .jump, .flip, .reset:
                break
            }
        }
    }

    private static func validate(duration: Int, maximum: Int) throws {
        let upperBound = min(BannyAgentProtocol.maximumActionDurationMS, maximum)
        guard (BannyAgentProtocol.minimumActionDurationMS...upperBound).contains(duration) else {
            throw AgentProtocolValidationError.invalidActionDuration
        }
    }
}

private struct AgentDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func rejectUnknownKeys<Key: CodingKey & CaseIterable>(
    _ decoder: Decoder,
    allowed: Key.Type
) throws where Key.AllCases: Sequence {
    let names = Set(Key.allCases.map(\.stringValue))
    try rejectUnknownKeys(decoder, allowedNames: names)
}

private func rejectUnknownKeys(
    _ decoder: Decoder,
    allowedNames: Set<String>
) throws {
    let c = try decoder.container(keyedBy: AgentDynamicCodingKey.self)
    if let unknown = c.allKeys.map(\.stringValue).first(where: { !allowedNames.contains($0) }) {
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "Unknown field \(unknown)."))
    }
}
