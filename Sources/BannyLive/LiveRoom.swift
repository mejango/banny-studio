import Foundation
import BannyCore

public enum LiveRoomState: String, Codable, Equatable, Sendable {
    case live
    case ended
}

public enum LiveParticipantStatus: String, Codable, Equatable, Sendable {
    case active
    case disconnected
}

/// The portable, renderable portion of a participant's dressed character.
/// Timeline data is deliberately absent: a joining participant cannot inject
/// historical events, captions, audio, or reactions into a room recording.
public struct LiveRoomAvatar: Codable, Equatable, Sendable {
    public let body: Body
    public let baseOutfit: [String: String]

    public init(body: Body, baseOutfit: [String: String] = [:]) {
        self.body = body
        self.baseOutfit = baseOutfit
    }

    private enum CodingKeys: String, CodingKey {
        case body
        case baseOutfit = "base_outfit"
    }
}

public struct LiveRoomParticipant: Codable, Equatable, Sendable {
    public let participantID: String
    public let displayName: String
    public let seat: Int
    public let status: LiveParticipantStatus
    public let avatar: LiveRoomAvatar
    public let pose: AgentPose

    public init(
        participantID: String,
        displayName: String,
        seat: Int,
        status: LiveParticipantStatus,
        avatar: LiveRoomAvatar,
        pose: AgentPose
    ) {
        self.participantID = participantID
        self.displayName = displayName
        self.seat = seat
        self.status = status
        self.avatar = avatar
        self.pose = pose
    }

    private enum CodingKeys: String, CodingKey {
        case participantID = "participant_id"
        case displayName = "display_name"
        case seat, status, avatar, pose
    }
}

public struct LiveRoomSnapshot: Codable, Equatable, Sendable {
    public let roomID: String
    public let title: String
    public let premise: String?
    public let state: LiveRoomState
    public let maxOccupancy: Int
    public let occupancy: Int
    public let sceneTimeMS: Int64
    public let seq: Int64
    public let participants: [LiveRoomParticipant]
    public let recentEvents: [AgentRecentEvent]

    public init(
        roomID: String,
        title: String,
        premise: String?,
        state: LiveRoomState,
        maxOccupancy: Int,
        occupancy: Int,
        sceneTimeMS: Int64,
        seq: Int64,
        participants: [LiveRoomParticipant],
        recentEvents: [AgentRecentEvent]
    ) {
        self.roomID = roomID
        self.title = title
        self.premise = premise
        self.state = state
        self.maxOccupancy = maxOccupancy
        self.occupancy = occupancy
        self.sceneTimeMS = sceneTimeMS
        self.seq = seq
        self.participants = participants
        self.recentEvents = recentEvents
    }

    private enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case title, premise, state
        case maxOccupancy = "max_occupancy"
        case occupancy
        case sceneTimeMS = "scene_time_ms"
        case seq, participants
        case recentEvents = "recent_events"
    }
}

public struct LiveRoomJoinReceipt: Codable, Equatable, Sendable {
    public let roomID: String
    public let participantID: String
    public let seat: Int
    public let reconnected: Bool

    public init(roomID: String, participantID: String, seat: Int, reconnected: Bool) {
        self.roomID = roomID
        self.participantID = participantID
        self.seat = seat
        self.reconnected = reconnected
    }

    private enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case participantID = "participant_id"
        case seat, reconnected
    }
}

public struct LiveRoomSubmitResult: Codable, Equatable, Sendable {
    public enum Disposition: String, Codable, Sendable {
        case accepted
        case duplicate
    }

    public let disposition: Disposition
    public let seq: Int64

    public init(disposition: Disposition, seq: Int64) {
        self.disposition = disposition
        self.seq = seq
    }
}

/// Server-private character seed exposed only inside BannyLive so the room's
/// autonomous director can schedule active performers. The prompt deliberately
/// does not participate in Codable and never enters a public snapshot or `.bs`.
struct LiveAutonomousParticipant: Equatable, Sendable {
    let participantID: String
    let seat: Int
    let characterPrompt: String
}

/// The one authoritative terminal view of a room. The first successful
/// `end(nowMS:)` freezes this value; every later call returns it verbatim.
public struct LiveRoomEndResult: Codable, Equatable, Sendable {
    public let roomID: String
    public let endedAtSceneTimeMS: Int64
    public let snapshot: LiveRoomSnapshot

    public init(
        roomID: String,
        endedAtSceneTimeMS: Int64,
        snapshot: LiveRoomSnapshot
    ) {
        self.roomID = roomID
        self.endedAtSceneTimeMS = endedAtSceneTimeMS
        self.snapshot = snapshot
    }

    private enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case endedAtSceneTimeMS = "ended_at_scene_time_ms"
        case snapshot
    }
}

/// One atomically sampled render input. Keeping the document, scene clock, and
/// visual revision on the room actor prevents a frame from combining state
/// observed on opposite sides of a concurrent join, action, leave, or end.
struct LiveRoomFrameSample: Sendable {
    let document: ShowDocument
    let sceneTimeMS: Int64
    let visualRevision: UInt64
}

public enum LiveRoomError: Error, Equatable, Sendable, LocalizedError {
    case invalidRoomID
    case invalidTitle
    case invalidPremise
    case invalidOccupancy
    case invalidAllowlistIdentity
    case duplicateAllowlistIdentity
    case allowlistTooLarge
    case draftMustBeVersion4
    case draftMustHaveNoCharacters
    case invalidTime
    case roomEnded
    case roomFull
    case recordingCapacityExhausted
    case identityNotInvited
    case identityAlreadyActive
    case invalidDisplayName
    case invalidCharacterPrompt
    case characterSeedImmutable
    case invalidCharacter(String)
    case participantNotFound
    case participantDisconnected
    case decisionNotDue(untilSceneTimeMS: Int64)
    case noOutstandingDecision
    case decisionExpired
    case invalidInactivityTimeout
    case intentIDReused
    case reactionConflict(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRoomID: "Room IDs must contain 1...128 safe characters."
        case .invalidTitle: "Room titles must contain 1...120 visible characters."
        case .invalidPremise: "Room premises may contain at most 2,048 visible characters."
        case .invalidOccupancy: "Room occupancy must be inside 1...10."
        case .invalidAllowlistIdentity: "Allowlist identities must contain 1...200 visible characters."
        case .duplicateAllowlistIdentity: "The room allowlist contains a duplicate identity."
        case .allowlistTooLarge: "A room recording can contain at most 10 invited identities."
        case .draftMustBeVersion4: "Live recordings require a v4 Banny Studio document."
        case .draftMustHaveNoCharacters:
            "A live room draft must leave all participant seats initially absent."
        case .invalidTime: "Room operations must use monotonic milliseconds."
        case .roomEnded: "The room has ended."
        case .roomFull: "Every room seat has been reserved."
        case .recordingCapacityExhausted:
            "This recording has used all 10 immutable character tracks."
        case .identityNotInvited: "This authenticated identity is not invited to the room."
        case .identityAlreadyActive: "This identity is already active in the room."
        case .invalidDisplayName: "Display names must contain 1...80 visible characters."
        case .invalidCharacterPrompt:
            "Character prompts must contain 1...2,000 characters and only newlines as controls."
        case .characterSeedImmutable:
            "A character's initial prompt and appearance cannot change after joining."
        case .invalidCharacter(let reason): "The dressed character is invalid: \(reason)"
        case .participantNotFound: "The participant does not belong to this room."
        case .participantDisconnected: "The participant is not active in this room."
        case .decisionNotDue(let sceneTime):
            "The participant's next decision is not due until \(sceneTime) ms."
        case .noOutstandingDecision: "No decision request is outstanding for this participant."
        case .decisionExpired: "The outstanding decision request has expired."
        case .invalidInactivityTimeout: "The inactivity timeout must be greater than zero."
        case .intentIDReused: "The agent reused an intent_id for a different request."
        case .reactionConflict(let group):
            "The decision controls event group \(group) more than once."
        }
    }
}

/// A single live room and its editable v4 recording.
///
/// The actor is the room's synchronization boundary. Every mutating operation
/// receives an explicit millisecond clock value, validates the complete change,
/// writes canonical `show.json` atomically, and only then publishes runtime
/// state. It performs no networking and stores no participant endpoints.
public actor LiveRoom {
    public nonisolated let id: String
    public nonisolated let title: String
    public nonisolated let premise: String?
    public nonisolated let maxOccupancy: Int
    public nonisolated let packageURL: URL

    public nonisolated static let defaultCharacterPrompt =
        "An autonomous Banny improvising in the room."

    private struct PendingDecision: Sendable {
        let envelope: AgentContextEnvelope
        let requestedSceneTimeMS: Int64
    }

    private struct ParticipantRecord: Sendable {
        let identity: String
        let participantID: String
        let seat: Int
        let characterIndex: Int
        let displayName: String
        var characterPrompt: String
        var status: LiveParticipantStatus
        var pending: PendingDecision?
        // Deliberately retained for the room lifetime. Evicting intent IDs
        // makes an old intent replayable; a bounded replacement needs a
        // durable intent journal or an explicit room-duration contract.
        var acceptedRequestByIntentID: [String: String]
        var nextDecisionSceneTimeMS: Int64
        var lastSeenSceneTimeMS: Int64
    }

    private let allowlist: Set<String>
    private let startedAtMS: Int64
    private var lastNowMS: Int64
    private var state: LiveRoomState = .live
    private var showDocument: ShowDocument
    private var participantsByID: [String: ParticipantRecord] = [:]
    private var participantIDByIdentity: [String: String] = [:]
    private var seq: Int64 = 0
    private var requestNumber: Int64 = 0
    private var reactionInstanceNumber: Int64 = 0
    private var visualRevision: UInt64 = 0
    private var recentEvents: [AgentRecentEvent] = []
    private var endResult: LiveRoomEndResult?

    public init(
        id: String,
        title: String,
        premise: String? = nil,
        maxOccupancy: Int,
        allowlist: [String] = [],
        draftDocument: ShowDocument,
        packageURL: URL,
        startedAtMS: Int64 = 0
    ) throws {
        guard Self.isSafeID(id) else { throw LiveRoomError.invalidRoomID }
        guard Self.isVisibleText(title, maximum: 120) else { throw LiveRoomError.invalidTitle }
        if let premise, !Self.isOptionalVisibleText(premise, maximum: 2_048) {
            throw LiveRoomError.invalidPremise
        }
        guard (1...10).contains(maxOccupancy) else { throw LiveRoomError.invalidOccupancy }
        guard startedAtMS >= 0 else { throw LiveRoomError.invalidTime }
        guard draftDocument.version == 4 else { throw LiveRoomError.draftMustBeVersion4 }
        guard draftDocument.stage.characters.isEmpty else {
            throw LiveRoomError.draftMustHaveNoCharacters
        }

        var normalizedAllowlist = Set<String>()
        guard allowlist.count <= 10 else { throw LiveRoomError.allowlistTooLarge }
        for supplied in allowlist {
            let identity = Self.normalizedIdentity(supplied)
            guard Self.isVisibleText(identity, maximum: 200) else {
                throw LiveRoomError.invalidAllowlistIdentity
            }
            guard normalizedAllowlist.insert(identity).inserted else {
                throw LiveRoomError.duplicateAllowlistIdentity
            }
        }

        self.id = id
        self.title = title
        self.premise = premise
        self.maxOccupancy = maxOccupancy
        self.allowlist = normalizedAllowlist
        self.showDocument = draftDocument
        self.packageURL = packageURL
        self.startedAtMS = startedAtMS
        self.lastNowMS = startedAtMS
    }

    /// Admits one already-authenticated identity. The caller, normally a host
    /// adapter, owns authentication and never passes a user-asserted identity
    /// here as trusted without verifying its invite capability first.
    public func join(
        identity suppliedIdentity: String,
        displayName: String,
        character suppliedCharacter: Character,
        characterPrompt suppliedCharacterPrompt: String = LiveRoom.defaultCharacterPrompt,
        nowMS: Int64
    ) throws -> LiveRoomJoinReceipt {
        let sceneTimeMS = try advanceClock(nowMS)
        try requireLive()
        _ = try expireInactive(atSceneTimeMS: sceneTimeMS, timeoutMS: 45_000)
        let characterPrompt = try Self.normalizedCharacterPrompt(suppliedCharacterPrompt)
        let identity = Self.normalizedIdentity(suppliedIdentity)
        guard Self.isVisibleText(identity, maximum: 200) else {
            throw LiveRoomError.invalidAllowlistIdentity
        }
        if !allowlist.isEmpty, !allowlist.contains(identity) {
            throw LiveRoomError.identityNotInvited
        }
        guard Self.isVisibleText(displayName, maximum: 80) else {
            throw LiveRoomError.invalidDisplayName
        }

        if let participantID = participantIDByIdentity[identity],
           var record = participantsByID[participantID] {
            guard record.status == .disconnected else {
                throw LiveRoomError.identityAlreadyActive
            }
            let activeOccupancy = participantsByID.values
                .filter { $0.status == .active }.count
            guard activeOccupancy < maxOccupancy else { throw LiveRoomError.roomFull }
            var candidate = showDocument
            var character = candidate.stage.characters[record.characterIndex]
            let proposed = try Self.sanitizedCharacter(
                suppliedCharacter,
                displayName: displayName,
                seat: record.seat,
                joinedAtMS: sceneTimeMS)
            guard record.displayName == displayName,
                  record.characterPrompt == characterPrompt,
                  Self.hasSameSeedAppearance(character, proposed)
            else { throw LiveRoomError.characterSeedImmutable }
            character.presence.append(VisibilityEvent(
                t: Self.seconds(sceneTimeMS), visible: true, fade: 0.25))
            character.presence = Self.stablePresence(character.presence)
            candidate.stage.characters[record.characterIndex] = character
            try persist(candidate)

            record.status = .active
            record.pending = nil
            record.nextDecisionSceneTimeMS = sceneTimeMS
            record.lastSeenSceneTimeMS = sceneTimeMS
            participantsByID[participantID] = record
            showDocument = candidate
            visualRevision &+= 1
            appendEvent(
                sceneTimeMS: sceneTimeMS,
                kind: "joined",
                participantID: participantID)
            return LiveRoomJoinReceipt(
                roomID: id, participantID: participantID,
                seat: record.seat, reconnected: true)
        }

        let activeOccupancy = participantsByID.values.filter { $0.status == .active }.count
        guard activeOccupancy < maxOccupancy else { throw LiveRoomError.roomFull }
        guard participantsByID.count < 10 else {
            throw LiveRoomError.recordingCapacityExhausted
        }
        let seat = participantsByID.count
        let participantID = "\(id)-p\(seat + 1)"
        let character = try Self.sanitizedCharacter(
            suppliedCharacter,
            displayName: displayName,
            seat: seat,
            joinedAtMS: sceneTimeMS)
        var candidate = showDocument
        let characterIndex = candidate.stage.characters.count
        candidate.stage.characters.append(character)
        candidate.stage.rowOrder.append("c-\(characterIndex)")
        try persist(candidate)

        let record = ParticipantRecord(
            identity: identity,
            participantID: participantID,
            seat: seat,
            characterIndex: characterIndex,
            displayName: displayName,
            characterPrompt: characterPrompt,
            status: .active,
            pending: nil,
            acceptedRequestByIntentID: [:],
            nextDecisionSceneTimeMS: sceneTimeMS,
            lastSeenSceneTimeMS: sceneTimeMS)
        participantsByID[participantID] = record
        participantIDByIdentity[identity] = participantID
        showDocument = candidate
        visualRevision &+= 1
        appendEvent(sceneTimeMS: sceneTimeMS, kind: "joined", participantID: participantID)
        return LiveRoomJoinReceipt(
            roomID: id, participantID: participantID, seat: seat, reconnected: false)
    }

    public func snapshot(nowMS: Int64) throws -> LiveRoomSnapshot {
        if let endResult { return endResult.snapshot }
        let sceneTimeMS = try advanceClock(nowMS)
        return makeSnapshot(sceneTimeMS: sceneTimeMS)
    }

    /// Cheap cache-key read used before joining a shared frame flight.
    func currentVisualRevision() -> UInt64 { visualRevision }

    /// Samples and warms the exact document revision rendered by a cold frame.
    /// Read-only frame sampling clamps an out-of-order caller timestamp to the
    /// latest accepted time; mutations retain the stricter monotonic contract.
    func frameSample(nowMS: Int64) throws -> LiveRoomFrameSample {
        let sceneTimeMS: Int64
        if let endResult {
            sceneTimeMS = endResult.endedAtSceneTimeMS
        } else {
            let effectiveNowMS = max(nowMS, lastNowMS)
            sceneTimeMS = try advanceClock(effectiveNowMS)
        }
        _ = makeSnapshot(sceneTimeMS: sceneTimeMS)
        return LiveRoomFrameSample(
            document: showDocument,
            sceneTimeMS: sceneTimeMS,
            visualRevision: visualRevision)
    }

    public func document() -> ShowDocument {
        showDocument
    }

    /// The director's private cast roster. Keeping this module-internal avoids
    /// accidentally making prompts part of the public room or recording API.
    func autonomousParticipants() -> [LiveAutonomousParticipant] {
        participantsByID.values
            .filter { $0.status == .active }
            .sorted { $0.seat < $1.seat }
            .map {
                LiveAutonomousParticipant(
                    participantID: $0.participantID,
                    seat: $0.seat,
                    characterPrompt: $0.characterPrompt)
            }
    }

    /// Lets the room-owned director distinguish an empty live room from an
    /// ended room without exposing private prompts or participant state.
    func isEnded() -> Bool {
        state == .ended || endResult != nil
    }

    /// Returns the existing outstanding request idempotently until it expires
    /// or is submitted, so long-poll retries never create multiple agent calls.
    public func nextDecision(
        participantID: String,
        nowMS: Int64,
        timeoutMS: Int = 3_000
    ) throws -> AgentContextEnvelope {
        let sceneTimeMS = try advanceClock(nowMS)
        try requireLive()
        guard var record = participantsByID[participantID] else {
            throw LiveRoomError.participantNotFound
        }
        guard record.status == .active else { throw LiveRoomError.participantDisconnected }
        record.lastSeenSceneTimeMS = sceneTimeMS
        participantsByID[participantID] = record
        guard (100...10_000).contains(timeoutMS) else {
            throw AgentProtocolValidationError.invalidRequestDelay
        }
        if let pending = record.pending,
           sceneTimeMS <= pending.requestedSceneTimeMS + Int64(pending.envelope.timeoutMS) {
            return pending.envelope
        }
        if record.pending != nil {
            record.pending = nil
            appendEvent(
                sceneTimeMS: sceneTimeMS,
                kind: "decision_timeout",
                participantID: participantID)
        }
        guard sceneTimeMS >= record.nextDecisionSceneTimeMS else {
            throw LiveRoomError.decisionNotDue(untilSceneTimeMS: record.nextDecisionSceneTimeMS)
        }

        requestNumber += 1
        let requestID = "req-\(requestNumber)"
        let constraints = makeConstraints()
        let selfContext = makeParticipantContext(record, sceneTimeMS: sceneTimeMS)
        let cast = participantsByID.values
            .filter { $0.status == .active && $0.participantID != participantID }
            .sorted { $0.seat < $1.seat }
            .map { makeParticipantContext($0, sceneTimeMS: sceneTimeMS) }
        let envelope = AgentContextEnvelope(
            requestID: requestID,
            roomID: id,
            participantID: participantID,
            basisSeq: seq,
            timeoutMS: timeoutMS,
            context: AgentContext(
                sceneTimeMS: sceneTimeMS,
                room: AgentRoomContext(state: state.rawValue, title: title, premise: premise),
                selfState: selfContext,
                cast: cast,
                recentEvents: contextualRecentEvents(),
                constraints: constraints))
        record.pending = PendingDecision(
            envelope: envelope, requestedSceneTimeMS: sceneTimeMS)
        participantsByID[participantID] = record
        return envelope
    }

    /// Validates and applies an entire intent atomically. A repeated intent id
    /// is acknowledged without creating a second event or timeline mutation.
    public func submit(
        _ decision: AgentDecisionEnvelope,
        participantID: String,
        nowMS: Int64
    ) throws -> LiveRoomSubmitResult {
        let sceneTimeMS = try advanceClock(nowMS)
        try requireLive()
        guard var record = participantsByID[participantID] else {
            throw LiveRoomError.participantNotFound
        }
        guard record.status == .active else { throw LiveRoomError.participantDisconnected }
        record.lastSeenSceneTimeMS = sceneTimeMS
        participantsByID[participantID] = record
        if let acceptedRequestID = record.acceptedRequestByIntentID[decision.intentID] {
            guard acceptedRequestID == decision.requestID else {
                throw LiveRoomError.intentIDReused
            }
            return LiveRoomSubmitResult(disposition: .duplicate, seq: seq)
        }
        guard let pending = record.pending else {
            throw LiveRoomError.noOutstandingDecision
        }
        guard sceneTimeMS <= pending.requestedSceneTimeMS
                + Int64(pending.envelope.timeoutMS)
        else {
            record.pending = nil
            participantsByID[participantID] = record
            appendEvent(
                sceneTimeMS: sceneTimeMS,
                kind: "decision_timeout",
                participantID: participantID)
            throw LiveRoomError.decisionExpired
        }
        let constraints = pending.envelope.context.constraints
        try AgentProtocolCodec.validate(
            decision,
            expectedRequestID: pending.envelope.requestID,
            constraints: constraints)
        try validateReactionGroups(decision.actions)
        try Self.validateSpeech(decision.say)

        let hasSpeech = !(decision.say?.isEmpty ?? true)
        if !hasSpeech, decision.actions.isEmpty {
            record.pending = nil
            record.acceptedRequestByIntentID[decision.intentID] = decision.requestID
            record.nextDecisionSceneTimeMS = sceneTimeMS
                + Int64(decision.requestAfterMS ?? 1_000)
            participantsByID[participantID] = record
            appendEvent(
                sceneTimeMS: sceneTimeMS,
                kind: "action",
                participantID: participantID,
                action: "idle")
            return LiveRoomSubmitResult(disposition: .accepted, seq: seq)
        }

        var candidate = showDocument
        var character = candidate.stage.characters[record.characterIndex]
        let time = Self.seconds(sceneTimeMS)
        if let speech = decision.say, !speech.isEmpty {
            let duration = Self.speechDuration(speech)
            Self.preempt(
                .talk,
                in: &character,
                reactionLibrary: candidate.stage.reactionLibrary,
                at: time)
            character.subs.append(Subtitle(text: speech, start: time, dur: duration))
            character.events.append(.key(t: time, code: .keyM, down: true))
            character.events.append(.key(t: time + duration, code: .keyM, down: false))
        }
        for action in decision.actions {
            switch action {
            case .reaction(let reactionID, let requestedDurationMS, let requestedIntensity):
                guard let definition = candidate.stage.reactionLibrary.first(where: {
                    $0.id == reactionID
                }) else {
                    throw AgentProtocolValidationError.reactionNotAllowed(reactionID)
                }
                reactionInstanceNumber += 1
                let duration = requestedDurationMS.map(Self.seconds)
                    ?? definition.dur
                for group in definition.ownedGroups {
                    Self.preempt(
                        group,
                        in: &character,
                        reactionLibrary: candidate.stage.reactionLibrary,
                        at: time)
                }
                character.reactions.append(ReactionInstance(
                    id: "live-reaction-\(reactionInstanceNumber)",
                    reactionID: reactionID,
                    start: time,
                    dur: duration,
                    intensity: requestedIntensity ?? 1))
            default:
                guard let code = action.eventCode else { continue }
                let duration = Self.seconds(action.holdDurationMS)
                Self.preempt(
                    code.group,
                    in: &character,
                    reactionLibrary: candidate.stage.reactionLibrary,
                    at: time)
                character.events.append(.key(t: time, code: code, down: true))
                character.events.append(.key(t: time + duration, code: code, down: false))
            }
        }
        character.events = Self.stableEvents(character.events)
        character.subs.sort {
            $0.start == $1.start ? $0.text < $1.text : $0.start < $1.start
        }
        character.reactions.sort {
            $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
        }
        candidate.stage.characters[record.characterIndex] = character
        try persist(candidate)

        showDocument = candidate
        visualRevision &+= 1
        record.pending = nil
        record.acceptedRequestByIntentID[decision.intentID] = decision.requestID
        record.nextDecisionSceneTimeMS = sceneTimeMS
            + Int64(decision.requestAfterMS ?? 1_000)
        participantsByID[participantID] = record
        if let speech = decision.say, !speech.isEmpty {
            appendEvent(
                sceneTimeMS: sceneTimeMS,
                kind: "speech",
                participantID: participantID,
                text: speech)
        }
        for action in decision.actions {
            appendEvent(
                sceneTimeMS: sceneTimeMS,
                kind: "action",
                participantID: participantID,
                action: action.summary)
        }
        return LiveRoomSubmitResult(disposition: .accepted, seq: seq)
    }

    /// Atomically disconnects every active participant whose authenticated
    /// bridge has been silent for longer than `timeoutMS`. The actor owns both
    /// the lease timestamps and the teardown, so admission cannot race a late
    /// heartbeat and overbook the room.
    @discardableResult
    public func expireInactive(
        nowMS: Int64,
        timeoutMS: Int64 = 45_000
    ) throws -> [String] {
        let sceneTimeMS = try advanceClock(nowMS)
        try requireLive()
        return try expireInactive(atSceneTimeMS: sceneTimeMS, timeoutMS: timeoutMS)
    }

    public func leave(participantID: String, nowMS: Int64) throws {
        let sceneTimeMS = try advanceClock(nowMS)
        try requireLive()
        guard var record = participantsByID[participantID] else {
            throw LiveRoomError.participantNotFound
        }
        guard record.status == .active else { throw LiveRoomError.participantDisconnected }

        var candidate = showDocument
        var character = candidate.stage.characters[record.characterIndex]
        Self.releaseHeldKeys(in: &character, at: Self.seconds(sceneTimeMS))
        character.presence.append(VisibilityEvent(
            t: Self.seconds(sceneTimeMS), visible: false, fade: 0.25))
        character.presence = Self.stablePresence(character.presence)
        candidate.stage.characters[record.characterIndex] = character
        try persist(candidate)

        showDocument = candidate
        visualRevision &+= 1
        record.status = .disconnected
        record.pending = nil
        participantsByID[participantID] = record
        appendEvent(sceneTimeMS: sceneTimeMS, kind: "left", participantID: participantID)
    }

    @discardableResult
    public func end(nowMS: Int64) throws -> LiveRoomEndResult {
        if let endResult { return endResult }
        let sceneTimeMS = try advanceClock(nowMS)
        var candidate = showDocument
        var changedRecords: [String: ParticipantRecord] = participantsByID
        let activeParticipantIDs = changedRecords.values
            .filter { $0.status == .active }
            .map(\.participantID)
        for participantID in activeParticipantIDs {
            guard var record = changedRecords[participantID] else { continue }
            var character = candidate.stage.characters[record.characterIndex]
            Self.releaseHeldKeys(in: &character, at: Self.seconds(sceneTimeMS))
            character.presence.append(VisibilityEvent(
                t: Self.seconds(sceneTimeMS), visible: false, fade: 0.25))
            character.presence = Self.stablePresence(character.presence)
            candidate.stage.characters[record.characterIndex] = character
            record.status = .disconnected
            record.pending = nil
            changedRecords[participantID] = record
        }
        // Character prompts shape the live performance but are deliberately
        // not part of the recording. The director has already stopped before
        // host finalization, so erase every prompt from room memory as the
        // terminal transition is published.
        for participantID in changedRecords.keys {
            guard var record = changedRecords[participantID] else { continue }
            record.characterPrompt.removeAll(keepingCapacity: false)
            changedRecords[participantID] = record
        }
        try persist(candidate)
        showDocument = candidate
        visualRevision &+= 1
        participantsByID = changedRecords
        state = .ended
        appendEvent(sceneTimeMS: sceneTimeMS, kind: "room_state", text: state.rawValue)
        let result = LiveRoomEndResult(
            roomID: id,
            endedAtSceneTimeMS: sceneTimeMS,
            snapshot: makeSnapshot(sceneTimeMS: sceneTimeMS))
        endResult = result
        return result
    }

    /// Rewrites the current canonical v4 document without changing room state.
    public func flush() throws {
        try persist(showDocument)
    }

    private func makeSnapshot(sceneTimeMS: Int64) -> LiveRoomSnapshot {
        let participants = participantsByID.values
            .sorted { $0.seat < $1.seat }
            .map { record -> LiveRoomParticipant in
                let character = showDocument.stage.characters[record.characterIndex]
                return LiveRoomParticipant(
                    participantID: record.participantID,
                    displayName: record.displayName,
                    seat: record.seat,
                    status: record.status,
                    avatar: Self.avatar(character),
                    pose: makePose(record, sceneTimeMS: sceneTimeMS))
            }
        return LiveRoomSnapshot(
            roomID: id,
            title: title,
            premise: premise,
            state: state,
            maxOccupancy: maxOccupancy,
            occupancy: participantsByID.values.filter { $0.status == .active }.count,
            sceneTimeMS: sceneTimeMS,
            seq: seq,
            participants: participants,
            recentEvents: contextualRecentEvents())
    }

    private func makeParticipantContext(
        _ record: ParticipantRecord,
        sceneTimeMS: Int64
    ) -> AgentParticipantContext {
        let pose = makePose(record, sceneTimeMS: sceneTimeMS)
        let rendered = SceneSimulator(state: showDocument.stage).pose(
            characterIndex: record.characterIndex,
            at: Self.seconds(sceneTimeMS))
        return AgentParticipantContext(
            participantID: record.participantID,
            displayName: record.displayName,
            pose: pose,
            status: record.status.rawValue,
            speaking: rendered.talking || rendered.activeSubtitle != nil)
    }

    private func makePose(_ record: ParticipantRecord, sceneTimeMS: Int64) -> AgentPose {
        let rendered = SceneSimulator(state: showDocument.stage).pose(
            characterIndex: record.characterIndex,
            at: Self.seconds(sceneTimeMS))
        return AgentPose(
            x: rendered.x,
            depth: rendered.depth,
            face: rendered.face < 0 ? .left : .right,
            spin: rendered.spin,
            zoom: rendered.zoom)
    }

    private func makeConstraints() -> AgentConstraints {
        AgentConstraints(
            allowedReactionIDs: showDocument.stage.reactionLibrary.map(\.id).sorted())
    }

    private func validateReactionGroups(_ actions: [AgentAction]) throws {
        let definitions = Dictionary(
            uniqueKeysWithValues: showDocument.stage.reactionLibrary.map { ($0.id, $0) })
        var groups = Set<EventGroup>()
        for action in actions {
            if let group = action.eventGroup {
                guard groups.insert(group).inserted else {
                    throw LiveRoomError.reactionConflict(group.rawValue)
                }
            }
            if case .reaction(let reactionID, _, _) = action {
                guard let definition = definitions[reactionID] else {
                    throw AgentProtocolValidationError.reactionNotAllowed(reactionID)
                }
                for group in definition.ownedGroups {
                    guard groups.insert(group).inserted else {
                        throw LiveRoomError.reactionConflict(group.rawValue)
                    }
                }
            }
        }
    }

    private func advanceClock(_ nowMS: Int64) throws -> Int64 {
        guard nowMS >= startedAtMS, nowMS >= lastNowMS else {
            throw LiveRoomError.invalidTime
        }
        lastNowMS = nowMS
        return nowMS - startedAtMS
    }

    private func requireLive() throws {
        guard state == .live else { throw LiveRoomError.roomEnded }
    }

    private func expireInactive(
        atSceneTimeMS sceneTimeMS: Int64,
        timeoutMS: Int64
    ) throws -> [String] {
        guard timeoutMS > 0 else { throw LiveRoomError.invalidInactivityTimeout }
        let expired = participantsByID.values
            .filter {
                $0.status == .active
                    && sceneTimeMS - $0.lastSeenSceneTimeMS > timeoutMS
            }
            .sorted { $0.seat < $1.seat }
        guard !expired.isEmpty else { return [] }

        var candidate = showDocument
        var changedRecords = participantsByID
        let time = Self.seconds(sceneTimeMS)
        for expiredRecord in expired {
            var character = candidate.stage.characters[expiredRecord.characterIndex]
            Self.releaseHeldKeys(in: &character, at: time)
            character.presence.append(VisibilityEvent(
                t: time, visible: false, fade: 0.25))
            character.presence = Self.stablePresence(character.presence)
            candidate.stage.characters[expiredRecord.characterIndex] = character

            var record = expiredRecord
            record.status = .disconnected
            record.pending = nil
            changedRecords[record.participantID] = record
        }
        try persist(candidate)

        showDocument = candidate
        visualRevision &+= 1
        participantsByID = changedRecords
        for record in expired {
            appendEvent(
                sceneTimeMS: sceneTimeMS,
                kind: "session_expired",
                participantID: record.participantID)
        }
        return expired.map(\.participantID)
    }

    private func appendEvent(
        sceneTimeMS: Int64,
        kind: String,
        participantID: String? = nil,
        text: String? = nil,
        action: String? = nil
    ) {
        seq += 1
        recentEvents.append(AgentRecentEvent(
            seq: seq,
            sceneTimeMS: sceneTimeMS,
            kind: kind,
            participantID: participantID,
            text: text,
            action: action))
        if recentEvents.count > 64 {
            recentEvents.removeFirst(recentEvents.count - 64)
        }
    }

    /// Listener business can generate many action events between lines. Keep
    /// the newest dialogue beats in the bounded model/public context instead
    /// of letting a busy cast evict the conversation it should react to.
    private func contextualRecentEvents(limit: Int = 32) -> [AgentRecentEvent] {
        let speech = Array(recentEvents.lazy.filter { $0.kind == "speech" }.suffix(8))
        let speechSequences = Set(speech.map(\.seq))
        let otherBudget = max(0, limit - speech.count)
        let others = recentEvents.reversed().lazy
            .filter { !speechSequences.contains($0.seq) }
            .prefix(otherBudget)
        return (speech + Array(others)).sorted { $0.seq < $1.seq }
    }

    private func persist(_ document: ShowDocument) throws {
        let canonical = try ShowJSONCodec.encode(document: document)
        _ = try ShowJSONCodec.decodeDocument(canonical)
        try FileManager.default.createDirectory(
            at: packageURL, withIntermediateDirectories: true)
        try Data(canonical.utf8).write(
            to: packageURL.appendingPathComponent("show.json"),
            options: .atomic)
    }

    private static func sanitizedCharacter(
        _ source: Character,
        displayName: String,
        seat: Int,
        joinedAtMS: Int64
    ) throws -> Character {
        guard source.size.isFinite, (0.1...3).contains(source.size) else {
            throw LiveRoomError.invalidCharacter("numeric appearance values are out of range")
        }
        for (slot, name) in source.baseOutfit {
            guard (0...64).contains(slot), isSafeOutfitName(name) else {
                throw LiveRoomError.invalidCharacter("base_outfit contains invalid syntax")
            }
        }
        // Character indices are immutable recording identities, while active
        // capacity can be released and reused. Give all ten possible lifetime
        // tracks a stable, on-stage lane so churn never places a later track
        // beyond the canvas and a reconnect never collides with a reused lane.
        let seatX: [Double] = [
            0.453_333, 0.546_667, 0.36, 0.64, 0.266_667,
            0.733_333, 0.173_333, 0.826_667, 0.08, 0.92,
        ]
        guard seatX.indices.contains(seat) else {
            throw LiveRoomError.roomFull
        }
        let x = seatX[seat]
        let presence: [VisibilityEvent] = joinedAtMS == 0 ? [] : [
            VisibilityEvent(t: 0, visible: false),
            VisibilityEvent(t: seconds(joinedAtMS), visible: true, fade: 0.25),
        ]
        return Character(
            body: source.body,
            x: x,
            depth: 0,
            size: source.size,
            face: x <= 0.5 ? 1 : -1,
            baseOutfit: source.baseOutfit,
            name: displayName,
            recStart: StartPose(x: x, depth: 0, face: x <= 0.5 ? 1 : -1),
            // Live-room dialogue is caption + mouth performance only. Imported
            // character clips and voice configuration are deliberately not
            // copied, and muting is defense in depth: the creator's room MP3
            // remains the sole audio source in preview and export.
            muted: true,
            presence: presence)
    }

    private static func releaseHeldKeys(in character: inout Character, at time: Double) {
        var latest: [EventCode: Bool] = [:]
        for event in character.events where event.t <= time {
            if case .key(_, let code, let down) = event { latest[code] = down }
        }
        character.events.removeAll { event in
            guard event.t > time, case .key = event else { return false }
            return true
        }
        for code in EventCode.allCases where latest[code] == true {
            character.events.append(.key(t: time, code: code, down: false))
        }
        character.events = stableEvents(character.events)
    }

    /// Ends the prior lease on one simulator channel before scheduling a new
    /// one. Removing old future edges is essential: a stale key-up from a
    /// previous decision must not cancel the new hold early.
    private static func preempt(
        _ group: EventGroup,
        in character: inout Character,
        reactionLibrary: [ReactionDefinition],
        at time: Double
    ) {
        var latest: [EventCode: Bool] = [:]
        for event in character.events where event.t <= time {
            guard case .key(_, let code, let down) = event, code.group == group else { continue }
            latest[code] = down
        }
        character.events.removeAll { event in
            guard event.t > time,
                  case .key(_, let code, _) = event,
                  code.group == group
            else { return false }
            return true
        }
        for code in EventCode.allCases where code.group == group && latest[code] == true {
            character.events.append(.key(t: time, code: code, down: false))
        }

        let definitions = Dictionary(
            reactionLibrary.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        character.reactions = character.reactions.compactMap { source in
            guard definitions[source.reactionID]?.ownedGroups.contains(group) == true else {
                return source
            }
            if source.start >= time { return nil }
            guard source.start + source.dur > time else { return source }
            var truncated = source
            truncated.dur = max(0.001, time - source.start)
            return truncated
        }
    }

    private static func stableEvents(_ events: [PerfEvent]) -> [PerfEvent] {
        events.enumerated().sorted { lhs, rhs in
            lhs.element.t == rhs.element.t ? lhs.offset < rhs.offset : lhs.element.t < rhs.element.t
        }.map(\.element)
    }

    private static func stablePresence(_ events: [VisibilityEvent]) -> [VisibilityEvent] {
        events.enumerated().sorted { lhs, rhs in
            lhs.element.t == rhs.element.t ? lhs.offset < rhs.offset : lhs.element.t < rhs.element.t
        }.map(\.element)
    }

    private static func speechDuration(_ text: String) -> Double {
        min(8, max(0.8, Double(text.unicodeScalars.count) / 13))
    }

    private static func validateSpeech(_ speech: String?) throws {
        guard let speech else { return }
        guard speech.unicodeScalars.count <= BannyAgentProtocol.maximumSpeechCharacters,
              !speech.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw AgentProtocolValidationError.speechTooLong }
    }

    private static func avatar(_ character: Character) -> LiveRoomAvatar {
        LiveRoomAvatar(
            body: character.body,
            baseOutfit: Dictionary(uniqueKeysWithValues:
                character.baseOutfit.map { (String($0.key), $0.value) }))
    }

    private static func normalizedIdentity(_ identity: String) -> String {
        identity.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedCharacterPrompt(_ prompt: String) throws -> String {
        let lineNormalized = prompt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...2_000).contains(lineNormalized.unicodeScalars.count),
              !lineNormalized.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) && $0 != "\n"
              })
        else { throw LiveRoomError.invalidCharacterPrompt }
        return lineNormalized
    }

    private static func hasSameSeedAppearance(_ lhs: Character, _ rhs: Character) -> Bool {
        lhs.body == rhs.body
            && lhs.size == rhs.size
            && lhs.baseOutfit == rhs.baseOutfit
    }

    private static func isVisibleText(_ value: String, maximum: Int) -> Bool {
        let count = value.unicodeScalars.count
        return count > 0 && count <= maximum
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func isOptionalVisibleText(_ value: String, maximum: Int) -> Bool {
        value.unicodeScalars.count <= maximum
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func isSafeID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            switch $0 {
            case 45, 48...57, 65...90, 95, 97...122: true
            default: false
            }
        }
    }

    private static func isSafeOutfitName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
            switch $0 {
            case 45, 46, 48...57, 65...90, 95, 97...122: true
            default: false
            }
        }
    }

    private static func seconds(_ milliseconds: Int64) -> Double {
        Double(milliseconds) / 1_000
    }

    private static func seconds(_ milliseconds: Int) -> Double {
        Double(milliseconds) / 1_000
    }
}

private extension AgentAction {
    var eventCode: EventCode? {
        switch self {
        case .move(let direction, _):
            direction == .left ? .arrowLeft : .arrowRight
        case .depth(let direction, _):
            direction == .away ? .arrowUp : .arrowDown
        case .tilt(let direction, _):
            direction == .forward ? .keyT : .keyB
        case .expression(let expression, _):
            switch expression {
            case .blink: .comma
            case .brow1: .slash
            case .brow2: .period
            }
        case .jump: .keyJ
        case .flip(let direction): direction == .front ? .keyF : .keyD
        case .rotate(let direction, _):
            direction == .left ? .rotateLeft : .rotateRight
        case .zoom(let direction, _): direction == .in ? .zoomIn : .zoomOut
        case .reset(let target): target == .spin ? .spinReset : .zoomReset
        case .reaction: nil
        }
    }

    var holdDurationMS: Int {
        switch self {
        case .move(_, let duration), .depth(_, let duration), .tilt(_, let duration),
             .expression(_, let duration), .rotate(_, let duration), .zoom(_, let duration):
            duration
        case .jump, .flip, .reset: BannyAgentProtocol.minimumActionDurationMS
        case .reaction(_, let duration, _):
            duration ?? BannyAgentProtocol.minimumActionDurationMS
        }
    }

    var summary: String {
        switch self {
        case .move(let direction, let duration): "move:\(direction.rawValue):\(duration)"
        case .depth(let direction, let duration): "depth:\(direction.rawValue):\(duration)"
        case .tilt(let direction, let duration): "tilt:\(direction.rawValue):\(duration)"
        case .expression(let expression, let duration):
            "expression:\(expression.rawValue):\(duration)"
        case .jump: "jump"
        case .flip(let direction): "flip:\(direction.rawValue)"
        case .rotate(let direction, let duration): "rotate:\(direction.rawValue):\(duration)"
        case .zoom(let direction, let duration): "zoom:\(direction.rawValue):\(duration)"
        case .reset(let target): "reset:\(target.rawValue)"
        case .reaction(let id, let duration, let intensity):
            "reaction:\(id):\(duration.map(String.init) ?? "native"):\(intensity ?? 1)"
        }
    }
}
