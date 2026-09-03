import Foundation
import CryptoKit
import BannyCore
import BannyMedia
import BannyRender

public struct LiveRoomParticipantSummary: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let seat: Int
    public let state: String

    public init(id: String, displayName: String, seat: Int, state: String) {
        self.id = id
        self.displayName = displayName
        self.seat = seat
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case id, seat, state
        case displayName = "display_name"
    }
}

public struct LiveRoomTranscriptEntry: Codable, Equatable, Sendable {
    public let id: String
    public let type: String
    public let speaker: String
    public let text: String
    public let sceneTimeMS: Int64

    public init(id: String, type: String = "speech", speaker: String,
                text: String, sceneTimeMS: Int64) {
        self.id = id
        self.type = type
        self.speaker = speaker
        self.text = text
        self.sceneTimeMS = sceneTimeMS
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, speaker, text
        case sceneTimeMS = "scene_time_ms"
    }
}

public struct LiveRoomPublicSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let premise: String?
    public let state: String
    public let occupancy: Int
    public let maxOccupancy: Int
    public let allowlisted: Bool
    public let sequence: Int64
    public let participants: [LiveRoomParticipantSummary]
    public let transcript: [LiveRoomTranscriptEntry]

    public init(id: String, title: String, premise: String?, state: String,
                occupancy: Int, maxOccupancy: Int, allowlisted: Bool,
                sequence: Int64, participants: [LiveRoomParticipantSummary] = [],
                transcript: [LiveRoomTranscriptEntry] = []) {
        self.id = id
        self.title = title
        self.premise = premise
        self.state = state
        self.occupancy = occupancy
        self.maxOccupancy = maxOccupancy
        self.allowlisted = allowlisted
        self.sequence = sequence
        self.participants = participants
        self.transcript = transcript
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, premise, state, occupancy, allowlisted, sequence
        case maxOccupancy = "max_occupancy"
        case participants, transcript
    }
}

public struct LiveRoomInvitation: Codable, Equatable, Sendable {
    public let identity: String
    public let invite: String

    public init(identity: String, invite: String) {
        self.identity = identity
        self.invite = invite
    }
}

public struct LiveRoomJoinAvatar: Codable, Equatable, Sendable {
    public let body: Body
    public let eyes: String
    public let mouth: String
    public let outfit: [String: String]

    public init(body: Body, eyes: String = "default", mouth: String = "default",
                outfit: [String: String] = [:]) {
        self.body = body
        self.eyes = eyes
        self.mouth = mouth
        self.outfit = outfit
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case body, eyes, mouth, outfit
    }

    public init(from decoder: Decoder) throws {
        try hostRejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        body = try c.decode(Body.self, forKey: .body)
        eyes = try c.decodeIfPresent(String.self, forKey: .eyes) ?? "default"
        mouth = try c.decodeIfPresent(String.self, forKey: .mouth) ?? "default"
        outfit = try c.decodeIfPresent([String: String].self, forKey: .outfit) ?? [:]
    }
}

public struct LiveRoomJoinRequest: Codable, Equatable, Sendable {
    public let displayName: String
    public let characterPrompt: String
    public let identity: String?
    public let invite: String?
    public let avatar: LiveRoomJoinAvatar

    public init(displayName: String, characterPrompt: String,
                identity: String? = nil, invite: String? = nil,
                avatar: LiveRoomJoinAvatar) {
        self.displayName = displayName
        self.characterPrompt = characterPrompt
        self.identity = identity
        self.invite = invite
        self.avatar = avatar
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case displayName = "display_name"
        case characterPrompt = "character_prompt"
        case identity, invite, avatar
    }

    public init(from decoder: Decoder) throws {
        try hostRejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try c.decode(String.self, forKey: .displayName)
        characterPrompt = try c.decode(String.self, forKey: .characterPrompt)
        identity = try c.decodeIfPresent(String.self, forKey: .identity)
        invite = try c.decodeIfPresent(String.self, forKey: .invite)
        avatar = try c.decode(LiveRoomJoinAvatar.self, forKey: .avatar)
    }
}

/// HTTP adapter and durable `.bs` owner for a local Banny Live process.
/// Credentials, invite digests, allowlists, and endpoints never enter the
/// editable recording.
public actor LiveRoomHostService: LiveHTTPService {
    private struct ParticipantSession: Sendable {
        let participantID: String
        let identity: String
        var lastRequestID: String?
        var lastCursor: Int64?
        var lastConstraints: AgentConstraints?
        var acceptedRequestByIntent: [String: String] = [:]
        var acceptedDecisionDigestByIntent: [String: Data] = [:]
        var acceptedIntentIDOrder: [String] = []
    }

    private struct FinalizationFlight: Sendable {
        let id: UUID
        let task: Task<ShowDocument, Error>
    }

    private struct FinalFrameFlight: Sendable {
        let id: UUID
        let task: Task<Data, Error>
    }

    private struct HostedRoom: Sendable {
        let runtime: LiveRoom
        let director: LiveRoomDirector?
        let packageURL: URL
        let backgroundURL: URL
        let musicURL: URL
        var frameRenderer: LiveFrameJPEGRenderer?
        let frameCache: LiveRoomJPEGCache
        let allowlisted: Bool
        let hostTokenDigest: Data
        var inviteDigests: [String: Data]
        var sessionsByDigest: [Data: ParticipantSession]
        var identityByParticipantID: [String: String]
        var admissionsClosed: Bool
        var revokedParticipantIDs: Set<String>
        var endedSceneTimeMS: Int64?
        var finalDocument: ShowDocument?
        var finalizationFlight: FinalizationFlight?
        var finalFrameFlight: FinalFrameFlight?
    }

    public let storageURL: URL
    private let assets: AssetCatalog
    public let limits: LiveRoomHostLimits
    public let autonomyEnabled: Bool
    public let legacyParticipantControlEnabled: Bool
    private let directorDecisionProvider: any LiveDirectorDecisionProvider
    private let clockMS: @Sendable () -> Int64
    private let creationAdmissionHook: (@Sendable () async -> Void)?
    private let submitContinuationHook: (@Sendable () async -> Void)?
    private let frameRenderHook: (@Sendable (ShowDocument, Double) async throws -> Data)?
    private let renderLimiter: LiveRoomRenderLimiter
    private var rooms: [String: HostedRoom] = [:]
    private var reservedRoomIDs: Set<String> = []
    private var pendingStorageReservations: [String: UInt64] = [:]

    public init(
        storageURL: URL,
        assets: AssetCatalog,
        directorDecisionProvider: any LiveDirectorDecisionProvider = BuiltInLiveDirectorDecisionProvider(),
        autonomyEnabled: Bool = true,
        legacyParticipantControlEnabled: Bool = false,
        limits: LiveRoomHostLimits = LiveRoomHostLimits(),
        clockMS: @escaping @Sendable () -> Int64 = {
            Int64((ProcessInfo.processInfo.systemUptime * 1_000).rounded(.down))
        }
    ) throws {
        guard storageURL.isFileURL else {
            throw LiveHTTPProblem(status: 400, code: "invalid_storage",
                                  message: "Room storage must be a local directory.")
        }
        guard !(autonomyEnabled && legacyParticipantControlEnabled) else {
            throw LiveHTTPProblem(
                status: 400,
                code: "invalid_host_configuration",
                message: "Autonomous direction and participant action control cannot run together.")
        }
        try Self.validate(limits: limits)
        try FileManager.default.createDirectory(
            at: storageURL, withIntermediateDirectories: true)
        self.storageURL = storageURL.standardizedFileURL
        self.assets = assets
        self.limits = limits
        self.autonomyEnabled = autonomyEnabled
        self.legacyParticipantControlEnabled = legacyParticipantControlEnabled
        self.directorDecisionProvider = directorDecisionProvider
        self.clockMS = clockMS
        self.creationAdmissionHook = nil
        self.submitContinuationHook = nil
        self.frameRenderHook = nil
        self.renderLimiter = liveRoomRenderLimiter
    }

    /// Deterministic suspension seam for actor-reentrancy regression tests.
    /// Production callers use the public initializer above and pay no hook
    /// dispatch on the submit path.
    init(
        storageURL: URL,
        assets: AssetCatalog,
        clockMS: @escaping @Sendable () -> Int64,
        submitContinuationHook: (@Sendable () async -> Void)?,
        directorDecisionProvider: any LiveDirectorDecisionProvider = BuiltInLiveDirectorDecisionProvider(),
        autonomyEnabled: Bool = false,
        legacyParticipantControlEnabled: Bool = true,
        frameRenderHook: (@Sendable (ShowDocument, Double) async throws -> Data)? = nil,
        renderLimiter: LiveRoomRenderLimiter = liveRoomRenderLimiter,
        limits: LiveRoomHostLimits = LiveRoomHostLimits(),
        creationAdmissionHook: (@Sendable () async -> Void)? = nil
    ) throws {
        guard storageURL.isFileURL else {
            throw LiveHTTPProblem(status: 400, code: "invalid_storage",
                                  message: "Room storage must be a local directory.")
        }
        guard !(autonomyEnabled && legacyParticipantControlEnabled) else {
            throw LiveHTTPProblem(
                status: 400,
                code: "invalid_host_configuration",
                message: "Autonomous direction and participant action control cannot run together.")
        }
        try Self.validate(limits: limits)
        try FileManager.default.createDirectory(
            at: storageURL, withIntermediateDirectories: true)
        self.storageURL = storageURL.standardizedFileURL
        self.assets = assets
        self.limits = limits
        self.autonomyEnabled = autonomyEnabled
        self.legacyParticipantControlEnabled = legacyParticipantControlEnabled
        self.directorDecisionProvider = directorDecisionProvider
        self.clockMS = clockMS
        self.creationAdmissionHook = creationAdmissionHook
        self.submitContinuationHook = submitContinuationHook
        self.frameRenderHook = frameRenderHook
        self.renderLimiter = renderLimiter
    }

    public func perform(_ operation: LiveHTTPOperation) async throws -> LiveHTTPServiceResult {
        do {
            switch operation {
            case .catalog:
                return try .json(["catalog": assets.summary()])
            case .listRooms:
                return try await listRooms()
            case .createRoom(let json):
                return try await createRoom(json)
            case .getRoom(let roomID):
                let hosted = try room(roomID)
                return try .json(RoomResponse(
                    room: try await publicSnapshot(hosted, nowMS: now())))
            case .join(let roomID, let json, let authorization):
                return try await join(
                    roomID: roomID, json: json, authorization: authorization)
            case .nextDecision(let roomID, let after, let authorization):
                return try await nextDecision(
                    roomID: roomID, after: after, authorization: authorization)
            case .submitDecision(let roomID, let requestID, let json, let authorization):
                return try await submitDecision(
                    roomID: roomID, requestID: requestID,
                    json: json, authorization: authorization)
            case .leave(let roomID, let json, let authorization):
                return try await leave(
                    roomID: roomID, json: json, authorization: authorization)
            case .music(let roomID):
                return try music(roomID: roomID)
            case .endRoom(let roomID, let authorization):
                return try await endRoom(roomID: roomID, authorization: authorization)
            case .removeParticipant(let roomID, let participantID, let authorization):
                return try await removeParticipant(
                    roomID: roomID, participantID: participantID,
                    authorization: authorization)
            }
        } catch let problem as LiveHTTPProblem {
            throw problem
        } catch let error as LiveRoomError {
            throw Self.problem(for: error)
        } catch is AgentProtocolValidationError {
            throw LiveHTTPProblem(
                status: 422,
                code: "invalid_agent_decision",
                message: "The agent decision is invalid or no longer current.")
        }
    }

    public func renderFrameJPEG(roomID: String) async throws -> Data {
        let hosted = try room(roomID)
        let runtime = hosted.runtime
        let renderer = hosted.frameRenderer
        let clockMS = self.clockMS
        let renderHook = frameRenderHook
        let limiter = renderLimiter
        for _ in 0..<3 {
            let expectedRevision = await runtime.currentVisualRevision()
            do {
                return try await hosted.frameCache.jpeg(epoch: expectedRevision) {
                    return try await limiter.withPermit {
                        // Sampling warms position timelines and can itself be
                        // expensive late in a room, so it belongs inside the
                        // same process-wide bound as drawing and JPEG encode.
                        // A mutation between the cheap key read and this atomic
                        // sample retries under the new revision.
                        let sample = try await runtime.frameSample(
                            nowMS: max(0, clockMS()))
                        guard sample.visualRevision == expectedRevision else {
                            throw LiveRoomFrameError.superseded
                        }
                        let time = Self.frameTime(sceneTimeMS: sample.sceneTimeMS)
                        if let renderHook {
                            return try await renderHook(sample.document, time)
                        }
                        guard let renderer else {
                            throw LiveRoomFrameError.rendererReleased
                        }
                        return try await renderer.render(
                            document: sample.document, at: time)
                    }
                }
            } catch LiveRoomFrameError.superseded {
                continue
            }
        }
        throw LiveRoomFrameError.superseded
    }

    /// Internal diagnostics used by focused cache/coalescing tests.
    func frameRenderStartCount(roomID: String) async throws -> Int {
        try await room(roomID).frameCache.renderStartCount()
    }

    func frameResourceState(roomID: String) async throws -> LiveRoomFrameResourceState {
        let hosted = try room(roomID)
        return LiveRoomFrameResourceState(
            rendererResident: hosted.frameRenderer != nil,
            finalFrameSealed: await hosted.frameCache.isSealed())
    }

    public func packageURL(roomID: String) throws -> URL {
        try room(roomID).packageURL
    }

    private func listRooms() async throws -> LiveHTTPServiceResult {
        var snapshots: [LiveRoomPublicSnapshot] = []
        for hosted in Array(rooms.values) {
            snapshots.append(try await publicSnapshot(hosted, nowMS: now()))
        }
        snapshots.sort { $0.id < $1.id }
        return try .json(RoomListResponse(rooms: snapshots))
    }

    private func createRoom(_ json: Data) async throws -> LiveHTTPServiceResult {
        let request: LiveRoomCreateRequest
        do {
            request = try LiveHTTPJSON.decoder.decode(LiveRoomCreateRequest.self, from: json)
        } catch {
            throw LiveHTTPProblem(status: 400, code: "invalid_room",
                                  message: "The room creation document is invalid.")
        }
        let identities = try Self.normalizedAllowlist(request.allowlist)
        let roomID = reserveRoomID(title: request.title)
        do {
            try reserveCreationStorage(roomID: roomID, animateStill: request.animateStill)
        } catch {
            reservedRoomIDs.remove(roomID)
            throw error
        }
        defer {
            pendingStorageReservations.removeValue(forKey: roomID)
            reservedRoomIDs.remove(roomID)
        }
        if let creationAdmissionHook {
            await creationAdmissionHook()
        }
        let seed: LiveRoomPackageSeed
        do {
            seed = try await LiveRoomPackageBuilder.create(
                request: request, roomID: roomID,
                storageURL: storageURL, catalog: assets)
        } catch let error as LiveRoomPackageBuilderError {
            throw LiveHTTPProblem(status: 422, code: "invalid_room_media",
                                  message: error.localizedDescription)
        } catch {
            throw LiveHTTPProblem(status: 422, code: "invalid_room_media",
                                  message: "The uploaded room media could not be decoded.")
        }

        let startedAtMS = now()
        let runtime: LiveRoom
        do {
            runtime = try LiveRoom(
                id: roomID,
                title: request.title.trimmingCharacters(in: .whitespacesAndNewlines),
                premise: request.premise,
                maxOccupancy: request.maxOccupancy,
                allowlist: identities,
                draftDocument: seed.document,
                packageURL: seed.packageURL,
                startedAtMS: startedAtMS)
        } catch {
            try? FileManager.default.removeItem(at: seed.packageURL.deletingLastPathComponent())
            throw error
        }

        let hostToken = Self.token()
        var invitations: [LiveRoomInvitation] = []
        var inviteDigests: [String: Data] = [:]
        for identity in identities.sorted() {
            let invite = Self.token()
            invitations.append(LiveRoomInvitation(identity: identity, invite: invite))
            inviteDigests[identity] = Self.digest(invite)
        }
        let hosted = HostedRoom(
            runtime: runtime,
            director: autonomyEnabled
                ? LiveRoomDirector(
                    room: runtime,
                    provider: directorDecisionProvider,
                    clock: LiveRoomHostDirectorClock(clockMS: clockMS))
                : nil,
            packageURL: seed.packageURL,
            backgroundURL: seed.backgroundURL,
            musicURL: seed.musicURL,
            frameRenderer: LiveFrameJPEGRenderer(
                documentAssets: seed.document.assets,
                assetURLs: ["room-background": seed.backgroundURL],
                catalog: assets),
            frameCache: LiveRoomJPEGCache(clockMS: clockMS),
            allowlisted: !identities.isEmpty,
            hostTokenDigest: Self.digest(hostToken),
            inviteDigests: inviteDigests,
            sessionsByDigest: [:],
            identityByParticipantID: [:],
            admissionsClosed: false,
            revokedParticipantIDs: [],
            endedSceneTimeMS: nil,
            finalDocument: nil,
            finalizationFlight: nil,
            finalFrameFlight: nil)
        rooms[roomID] = hosted
        return try .json(
            statusCode: 201,
            CreateResponse(
                room: try await publicSnapshot(hosted, nowMS: startedAtMS),
                hostToken: hostToken,
                invitations: invitations))
    }

    private func join(
        roomID: String,
        json: Data,
        authorization: LiveHTTPBearerCredential?
    ) async throws -> LiveHTTPServiceResult {
        let request: LiveRoomJoinRequest
        do {
            request = try LiveHTTPJSON.decoder.decode(LiveRoomJoinRequest.self, from: json)
        } catch {
            throw LiveHTTPProblem(status: 400, code: "invalid_join",
                                  message: "The participant join document is invalid.")
        }
        let admissionRoom = try room(roomID)
        guard !admissionRoom.admissionsClosed else {
            throw LiveHTTPProblem(
                status: 409,
                code: "room_ended",
                message: "This room has ended.")
        }
        let identity: String
        if admissionRoom.allowlisted {
            guard let suppliedIdentity = request.identity else {
                throw LiveHTTPProblem(status: 403, code: "invite_required",
                                      message: "This room requires an identity and invite.")
            }
            identity = Self.normalizedIdentity(suppliedIdentity)
            let bodyInvite = request.invite
            let bearerInvite = authorization?.token
            if let bodyInvite, let bearerInvite, bodyInvite != bearerInvite {
                throw LiveHTTPProblem(status: 401, code: "conflicting_invite",
                                      message: "The supplied invite credentials do not match.")
            }
            guard let invite = bodyInvite ?? bearerInvite,
                  let expected = admissionRoom.inviteDigests[identity],
                  Self.secureEqual(Self.digest(invite), expected)
            else {
                throw LiveHTTPProblem(status: 403, code: "identity_not_invited",
                                      message: "The identity or invite is not valid for this room.")
            }
        } else {
            identity = "guest-\(UUID().uuidString.lowercased())"
        }
        let character = try makeCharacter(from: request.avatar)
        let receipt = try await admissionRoom.runtime.join(
            identity: identity,
            displayName: request.displayName,
            character: character,
            characterPrompt: request.characterPrompt,
            nowMS: now())

        // `LiveRoom` is a separate actor, so another host request may have
        // progressed while admission was suspended. Merge into the latest
        // host record instead of publishing the pre-await copy.
        var hosted = try room(roomID)
        if hosted.admissionsClosed
            || hosted.revokedParticipantIDs.contains(receipt.participantID) {
            if hosted.revokedParticipantIDs.contains(receipt.participantID) {
                hosted.inviteDigests.removeValue(forKey: identity)
                rooms[roomID] = hosted
            }
            // A concurrent kick or room end won the admission race. Do not
            // mint a post-revocation capability; compensate if the runtime is
            // still live and the participant has not already been removed.
            try? await admissionRoom.runtime.leave(
                participantID: receipt.participantID,
                nowMS: now())
            throw LiveHTTPProblem(
                status: 409,
                code: "admission_revoked",
                message: "Admission was revoked before the session became active.")
        }
        // Build the public receipt before minting the capability. This await
        // is another reentrancy point: a kick/end may win while the snapshot
        // is being produced, so reload and recheck immediately afterward.
        let snapshot = try await publicSnapshot(hosted, nowMS: now())
        hosted = try room(roomID)
        if hosted.admissionsClosed
            || hosted.revokedParticipantIDs.contains(receipt.participantID) {
            if hosted.revokedParticipantIDs.contains(receipt.participantID) {
                hosted.inviteDigests.removeValue(forKey: identity)
                rooms[roomID] = hosted
            }
            try? await admissionRoom.runtime.leave(
                participantID: receipt.participantID,
                nowMS: now())
            throw LiveHTTPProblem(
                status: 409,
                code: "admission_revoked",
                message: "Admission was revoked before the session became active.")
        }
        // Retain the digest while the room is live so the same invited
        // identity can reconnect after an explicit leave. LiveRoom rejects a
        // second active connection for that identity atomically.
        hosted.sessionsByDigest = hosted.sessionsByDigest.filter {
            $0.value.participantID != receipt.participantID
        }
        hosted.identityByParticipantID[receipt.participantID] = identity
        let sessionToken = Self.token()
        hosted.sessionsByDigest[Self.digest(sessionToken)] = ParticipantSession(
            participantID: receipt.participantID,
            identity: identity,
            lastRequestID: nil,
            lastCursor: nil,
            lastConstraints: nil)
        rooms[roomID] = hosted
        if let director = hosted.director {
            await director.start()
        }
        return try .json(
            statusCode: 201,
            JoinResponse(
                participantID: receipt.participantID,
                sessionToken: sessionToken,
                seat: receipt.seat + 1,
                room: snapshot))
    }

    private func nextDecision(
        roomID: String,
        after: Int64?,
        authorization: LiveHTTPBearerCredential
    ) async throws -> LiveHTTPServiceResult {
        try requireLegacyParticipantControl()
        if after == Int64.max {
            throw LiveHTTPProblem(status: 400, code: "invalid_cursor",
                                  message: "The decision cursor is too large.")
        }
        let pollingRoom = try room(roomID)
        let (sessionDigest, originalSession) = try authenticatedSession(
            authorization, in: pollingRoom)
        let envelope: AgentContextEnvelope
        do {
            envelope = try await pollingRoom.runtime.nextDecision(
                participantID: originalSession.participantID,
                nowMS: now(),
                timeoutMS: 3_000)
        } catch LiveRoomError.decisionNotDue {
            return LiveHTTPServiceResult(statusCode: 204)
        }
        var hosted = try room(roomID)
        guard var session = hosted.sessionsByDigest[sessionDigest] else {
            throw LiveHTTPProblem(status: 401, code: "invalid_session",
                                  message: "The participant session is not valid.")
        }
        if session.lastRequestID == envelope.requestID,
           let after, let lastCursor = session.lastCursor,
           after >= lastCursor {
            return LiveHTTPServiceResult(statusCode: 204)
        }
        // basis_seq remains the authoritative room event sequence. Submitted
        // intents (including no-ops) and expired requests advance that sequence
        // in LiveRoom; this adapter never substitutes a transport-only cursor.
        if let after {
            if after > envelope.basisSeq {
                throw LiveHTTPProblem(status: 409, code: "cursor_ahead",
                                      message: "The decision cursor is ahead of the room sequence.")
            }
            if after == envelope.basisSeq {
                return LiveHTTPServiceResult(statusCode: 204)
            }
        }
        session.lastRequestID = envelope.requestID
        session.lastCursor = envelope.basisSeq
        session.lastConstraints = envelope.context.constraints
        hosted.sessionsByDigest[sessionDigest] = session
        rooms[roomID] = hosted
        return try .json(envelope, encoder: LiveHTTPJSON.encoder)
    }

    private func submitDecision(
        roomID: String,
        requestID: String,
        json: Data,
        authorization: LiveHTTPBearerCredential
    ) async throws -> LiveHTTPServiceResult {
        try requireLegacyParticipantControl()
        let submissionRoom = try room(roomID)
        let (sessionDigest, originalSession) = try authenticatedSession(
            authorization, in: submissionRoom)
        guard json.count <= BannyAgentProtocol.maximumResponseBytes else {
            throw LiveHTTPProblem(status: 413, code: "agent_decision_too_large",
                                  message: "The agent decision exceeds 16 KiB.")
        }
        let decoded: AgentDecisionEnvelope
        do {
            decoded = try LiveHTTPJSON.decoder.decode(AgentDecisionEnvelope.self, from: json)
        } catch {
            throw LiveHTTPProblem(status: 422, code: "invalid_agent_decision",
                                  message: "The agent decision is not strict banny.agent.v1 JSON.")
        }
        guard decoded.requestID == requestID else {
            throw LiveHTTPProblem(status: 409, code: "request_mismatch",
                                  message: "The decision does not match the request URL.")
        }
        if originalSession.acceptedRequestByIntent[decoded.intentID] == requestID,
           let expectedDigest = originalSession.acceptedDecisionDigestByIntent[decoded.intentID],
           Self.secureEqual(Self.digest(json), expectedDigest) {
            let snapshot = try await submissionRoom.runtime.snapshot(nowMS: now())
            return try .json(LiveRoomSubmitResult(disposition: .duplicate, seq: snapshot.seq))
        }
        guard originalSession.lastRequestID == requestID,
              let constraints = originalSession.lastConstraints else {
            throw LiveHTTPProblem(status: 409, code: "no_outstanding_decision",
                                  message: "No matching decision request is outstanding.")
        }
        let decision = try AgentProtocolCodec.decodeDecision(
            json, expectedRequestID: requestID, constraints: constraints)
        let result = try await submissionRoom.runtime.submit(
            decision,
            participantID: originalSession.participantID,
            nowMS: now())
        if let submitContinuationHook {
            await submitContinuationHook()
        }
        var hosted = try room(roomID)
        guard var session = hosted.sessionsByDigest[sessionDigest] else {
            throw LiveHTTPProblem(status: 401, code: "invalid_session",
                                  message: "The participant session is not valid.")
        }
        if result.disposition == .accepted {
            // A newer poll may have installed another outstanding request
            // while the runtime actor was committing this one. Clear only the
            // request this continuation actually completed.
            if session.lastRequestID == requestID {
                session.lastRequestID = nil
                session.lastConstraints = nil
            }
            let isNewReceipt = session.acceptedRequestByIntent[decision.intentID] == nil
            session.acceptedRequestByIntent[decision.intentID] = requestID
            session.acceptedDecisionDigestByIntent[decision.intentID] = Self.digest(json)
            if isNewReceipt {
                session.acceptedIntentIDOrder.append(decision.intentID)
            }
            while session.acceptedIntentIDOrder.count > 128 {
                let oldest = session.acceptedIntentIDOrder.removeFirst()
                session.acceptedRequestByIntent.removeValue(forKey: oldest)
                session.acceptedDecisionDigestByIntent.removeValue(forKey: oldest)
            }
        }
        hosted.sessionsByDigest[sessionDigest] = session
        rooms[roomID] = hosted
        return try .json(result)
    }

    private func leave(
        roomID: String,
        json: Data?,
        authorization: LiveHTTPBearerCredential
    ) async throws -> LiveHTTPServiceResult {
        if let json {
            do { _ = try LiveHTTPJSON.decoder.decode(LeaveRequest.self, from: json) }
            catch {
                throw LiveHTTPProblem(status: 400, code: "invalid_leave",
                                      message: "The leave document is invalid.")
            }
        }
        let hosted = try room(roomID)
        let (sessionDigest, session) = try authenticatedSession(authorization, in: hosted)
        let before = try await hosted.runtime.snapshot(nowMS: now())
        if before.participants.first(where: {
            $0.participantID == session.participantID
        })?.status == .disconnected {
            revokeSession(sessionDigest, participantID: session.participantID, roomID: roomID)
            return LiveHTTPServiceResult(statusCode: 204)
        }
        try await hosted.runtime.leave(participantID: session.participantID, nowMS: now())
        revokeSession(sessionDigest, participantID: session.participantID, roomID: roomID)
        return LiveHTTPServiceResult(statusCode: 204)
    }

    private func music(roomID: String) throws -> LiveHTTPServiceResult {
        let data = try Data(contentsOf: try room(roomID).musicURL, options: [.mappedIfSafe])
        return LiveHTTPServiceResult(
            headers: [
                "Content-Type": "audio/mpeg",
                "Cache-Control": "public, max-age=3600",
            ],
            body: data)
    }

    private func endRoom(
        roomID: String,
        authorization: LiveHTTPBearerCredential
    ) async throws -> LiveHTTPServiceResult {
        var endingRoom = try room(roomID)
        try authenticateHost(authorization, in: endingRoom)
        endingRoom.admissionsClosed = true
        rooms[roomID] = endingRoom
        if let director = endingRoom.director {
            await director.stop()
        }
        // LiveRoom owns the idempotent terminal transition. Concurrent end
        // requests receive the same frozen snapshot and scene time.
        let result = try await endingRoom.runtime.end(nowMS: now())
        let snapshot = result.snapshot
        var hosted = try room(roomID)
        hosted.endedSceneTimeMS = result.endedAtSceneTimeMS
        hosted.admissionsClosed = true
        hosted.inviteDigests.removeAll(keepingCapacity: false)
        hosted.sessionsByDigest.removeAll(keepingCapacity: false)
        hosted.identityByParticipantID.removeAll(keepingCapacity: false)
        rooms[roomID] = hosted

        if hosted.finalDocument == nil, hosted.finalizationFlight == nil {
            let source = await endingRoom.runtime.document()
            hosted = try room(roomID)
            if hosted.finalDocument == nil, hosted.finalizationFlight == nil {
                let flightID = UUID()
                let duration = max(
                    0.001,
                    Double(result.endedAtSceneTimeMS) / 1_000)
                let packageURL = endingRoom.packageURL
                let catalog = assets
                let task = Task.detached(priority: .utility) {
                    try Self.finalize(
                        source,
                        duration: duration,
                        packageURL: packageURL,
                        assets: catalog)
                }
                hosted.finalizationFlight = FinalizationFlight(id: flightID, task: task)
                rooms[roomID] = hosted
            }
        }
        hosted = try room(roomID)
        if let flight = hosted.finalizationFlight {
            do {
                let final = try await flight.task.value
                hosted = try room(roomID)
                if hosted.finalizationFlight?.id == flight.id {
                    hosted.finalDocument = final
                    hosted.finalizationFlight = nil
                    rooms[roomID] = hosted
                }
            } catch {
                hosted = try room(roomID)
                if hosted.finalizationFlight?.id == flight.id {
                    hosted.finalizationFlight = nil
                    rooms[roomID] = hosted
                }
                throw error
            }
        }
        try await sealFinalFrame(roomID: roomID)
        return try .json(RoomResponse(
            room: Self.publicSnapshot(snapshot, allowlisted: endingRoom.allowlisted)))
    }

    /// Final-frame production is lifecycle-owned, like package finalization:
    /// disconnecting the HTTP caller does not orphan it. Concurrent end calls
    /// share one flight, and only a successfully sealed JPEG releases the
    /// room's decoded media and sprite cache.
    private func sealFinalFrame(roomID: String) async throws {
        var hosted = try room(roomID)
        if hosted.frameRenderer == nil {
            guard await hosted.frameCache.isSealed() else {
                throw LiveRoomFrameError.rendererReleased
            }
            return
        }

        if hosted.finalFrameFlight == nil {
            let finalRevision = await hosted.runtime.currentVisualRevision()
            hosted = try room(roomID)
            if hosted.frameRenderer != nil, hosted.finalFrameFlight == nil {
                let id = UUID()
                let cache = hosted.frameCache
                let runtime = hosted.runtime
                let renderer = hosted.frameRenderer
                let renderHook = frameRenderHook
                let limiter = renderLimiter
                let clockMS = self.clockMS
                let task = Task.detached(priority: .utility) {
                    try await cache.seal(epoch: finalRevision) {
                        try await limiter.withPermit {
                            let sample = try await runtime.frameSample(
                                nowMS: max(0, clockMS()))
                            guard sample.visualRevision == finalRevision else {
                                throw LiveRoomFrameError.superseded
                            }
                            let time = Self.frameTime(
                                sceneTimeMS: sample.sceneTimeMS)
                            if let renderHook {
                                return try await renderHook(sample.document, time)
                            }
                            guard let renderer else {
                                throw LiveRoomFrameError.rendererReleased
                            }
                            return try await renderer.render(
                                document: sample.document, at: time)
                        }
                    }
                }
                hosted.finalFrameFlight = FinalFrameFlight(id: id, task: task)
                rooms[roomID] = hosted
            }
        }

        hosted = try room(roomID)
        guard let flight = hosted.finalFrameFlight else { return }
        do {
            _ = try await flight.task.value
            hosted = try room(roomID)
            if hosted.finalFrameFlight?.id == flight.id {
                hosted.finalFrameFlight = nil
                hosted.frameRenderer = nil
                rooms[roomID] = hosted
            }
        } catch {
            hosted = try room(roomID)
            if hosted.finalFrameFlight?.id == flight.id {
                hosted.finalFrameFlight = nil
                rooms[roomID] = hosted
            }
            throw error
        }
    }

    private func removeParticipant(
        roomID: String,
        participantID: String,
        authorization: LiveHTTPBearerCredential
    ) async throws -> LiveHTTPServiceResult {
        let removalRoom = try room(roomID)
        try authenticateHost(authorization, in: removalRoom)
        let before = try await removalRoom.runtime.snapshot(nowMS: now())
        guard before.participants.contains(where: {
            $0.participantID == participantID
        }) else { throw LiveRoomError.participantNotFound }

        // Revoke admission and every capability before yielding back to the
        // runtime. An already-authenticated join rechecks the revocation set
        // before minting its session, so it cannot resurrect this identity.
        var flagged = try room(roomID)
        flagged.revokedParticipantIDs.insert(participantID)
        var identities = Set(flagged.sessionsByDigest.values.compactMap {
            $0.participantID == participantID ? $0.identity : nil
        })
        if let identity = flagged.identityByParticipantID.removeValue(
            forKey: participantID) {
            identities.insert(identity)
        }
        flagged.sessionsByDigest = flagged.sessionsByDigest.filter {
            $0.value.participantID != participantID
        }
        for identity in identities {
            flagged.inviteDigests.removeValue(forKey: identity)
        }
        rooms[roomID] = flagged

        // The snapshot may become stale while the host actor is suspended.
        // Always attempt the teardown; a concurrent leave/end still yields a
        // successful, fully-cleaned host kick.
        do {
            try await removalRoom.runtime.leave(participantID: participantID, nowMS: now())
        } catch LiveRoomError.participantDisconnected {
            // A concurrent voluntary leave won the runtime race.
        } catch LiveRoomError.roomEnded {
            // Concurrent room end already performed the same teardown.
        }
        let hosted = try room(roomID)
        return try .json(RoomResponse(
            room: try await publicSnapshot(hosted, nowMS: now())))
    }

    private func publicSnapshot(
        _ hosted: HostedRoom,
        nowMS: Int64
    ) async throws -> LiveRoomPublicSnapshot {
        Self.publicSnapshot(
            try await hosted.runtime.snapshot(nowMS: nowMS),
            allowlisted: hosted.allowlisted)
    }

    /// Revokes only the exact capability that initiated an explicit leave.
    /// Reacquiring the latest room record after the runtime await preserves a
    /// newly issued reconnect token if another host request progressed first.
    private func revokeSession(
        _ digest: Data,
        participantID: String,
        roomID: String
    ) {
        guard var hosted = rooms[roomID],
              hosted.sessionsByDigest[digest]?.participantID == participantID
        else { return }
        hosted.sessionsByDigest.removeValue(forKey: digest)
        rooms[roomID] = hosted
    }

    private func requireLegacyParticipantControl() throws {
        guard legacyParticipantControlEnabled else {
            throw LiveHTTPProblem(
                status: 403,
                code: "participant_control_disabled",
                message: "Direct participant agent control is disabled for this host.")
        }
    }

    private static func publicSnapshot(
        _ snapshot: LiveRoomSnapshot,
        allowlisted: Bool
    ) -> LiveRoomPublicSnapshot {
        let names = Dictionary(uniqueKeysWithValues: snapshot.participants.map {
            ($0.participantID, $0.displayName)
        })
        let transcript = snapshot.recentEvents.compactMap { event -> LiveRoomTranscriptEntry? in
            guard event.kind == "speech", let text = event.text else { return nil }
            return LiveRoomTranscriptEntry(
                id: "event-\(event.seq)",
                speaker: event.participantID.flatMap { names[$0] } ?? "Banny",
                text: text,
                sceneTimeMS: event.sceneTimeMS)
        }
        let participants = snapshot.participants
            .filter { $0.status == .active }
            .map {
                LiveRoomParticipantSummary(
                    id: $0.participantID,
                    displayName: $0.displayName,
                    seat: $0.seat + 1,
                    state: "connected")
            }
        return LiveRoomPublicSnapshot(
            id: snapshot.roomID,
            title: snapshot.title,
            premise: snapshot.premise,
            state: snapshot.state.rawValue,
            occupancy: snapshot.occupancy,
            maxOccupancy: snapshot.maxOccupancy,
            allowlisted: allowlisted,
            sequence: snapshot.seq,
            participants: participants,
            transcript: transcript)
    }

    private func makeCharacter(from avatar: LiveRoomJoinAvatar) throws -> Character {
        let summary = assets.summary()
        guard summary.bodies.contains(avatar.body.rawValue) else {
            throw LiveHTTPProblem(status: 422, code: "invalid_avatar",
                                  message: "The selected Banny body is not in the catalog.")
        }
        guard assets.hasEyeOption(avatar.eyes), assets.hasMouthOption(avatar.mouth) else {
            throw LiveHTTPProblem(status: 422, code: "invalid_avatar",
                                  message: "The selected eyes or mouth are not in the catalog.")
        }
        let outfitsBySlot = Dictionary(uniqueKeysWithValues: summary.slots.map {
            ($0.slot, Set($0.outfits.map(\.name)))
        })
        var outfit: [Int: String] = [:]
        for (rawSlot, name) in avatar.outfit {
            guard let slot = Int(rawSlot), String(slot) == rawSlot,
                  let choices = outfitsBySlot[slot],
                  choices.contains(name) else {
                throw LiveHTTPProblem(status: 422, code: "invalid_avatar",
                                      message: "The avatar contains an unknown outfit choice.")
            }
            outfit[slot] = name
        }
        if avatar.eyes != "default" { outfit[OutfitCategory.eyes.rawValue] = avatar.eyes }
        if avatar.mouth != "default" { outfit[OutfitCategory.mouth.rawValue] = avatar.mouth }
        return Character(body: avatar.body, baseOutfit: outfit)
    }

    private func room(_ roomID: String) throws -> HostedRoom {
        guard let room = rooms[roomID] else {
            throw LiveHTTPProblem(status: 404, code: "room_not_found",
                                  message: "No room with that identifier exists.")
        }
        return room
    }

    private func authenticatedSession(
        _ credential: LiveHTTPBearerCredential,
        in room: HostedRoom
    ) throws -> (Data, ParticipantSession) {
        let supplied = Self.digest(credential.token)
        for (digest, session) in room.sessionsByDigest
        where Self.secureEqual(digest, supplied) {
            return (digest, session)
        }
        throw LiveHTTPProblem(status: 401, code: "invalid_session",
                              message: "The participant session is not valid.")
    }

    private func authenticateHost(
        _ credential: LiveHTTPBearerCredential,
        in room: HostedRoom
    ) throws {
        guard Self.secureEqual(Self.digest(credential.token), room.hostTokenDigest) else {
            throw LiveHTTPProblem(status: 403, code: "host_authorization_failed",
                                  message: "The host credential is not valid for this room.")
        }
    }

    private func reserveCreationStorage(roomID: String, animateStill: Bool) throws {
        let activeRoomIDs = Set(pendingStorageReservations.keys)
        let snapshot: LiveRoomStorageSnapshot
        do {
            snapshot = try LiveRoomStorageAccounting.snapshot(
                at: storageURL,
                excludingActiveRoomIDs: activeRoomIDs)
        } catch {
            throw LiveHTTPProblem(
                status: 507,
                code: "storage_quota_unavailable",
                message: "Room storage could not be measured safely.")
        }

        var countedRooms = snapshot.roomDirectoryNames
        countedRooms.formUnion(rooms.keys)
        countedRooms.formUnion(reservedRoomIDs)
        guard countedRooms.count <= limits.maximumRooms else {
            throw LiveHTTPProblem(
                status: 429,
                code: "room_limit_reached",
                message: "This room server has reached its room limit.")
        }

        let reservation = LiveRoomStorageAccounting.creationReservationBytes(
            animateStill: animateStill)
        var projectedBytes = snapshot.bytes
        do {
            for pending in pendingStorageReservations.values {
                projectedBytes = try LiveRoomStorageAccounting.checkedAdd(
                    projectedBytes, pending)
            }
            projectedBytes = try LiveRoomStorageAccounting.checkedAdd(
                projectedBytes, reservation)
        } catch {
            throw LiveHTTPProblem(
                status: 507,
                code: "storage_quota_exceeded",
                message: "This room server has reached its storage quota.")
        }
        guard projectedBytes <= limits.maximumStorageBytes else {
            throw LiveHTTPProblem(
                status: 507,
                code: "storage_quota_exceeded",
                message: "This room server has reached its storage quota.")
        }
        pendingStorageReservations[roomID] = reservation
    }

    private func reserveRoomID(title: String) -> String {
        let slug = title.lowercased().unicodeScalars.reduce(into: "") { partial, scalar in
            let isASCIIAlphaNumeric = (48...57).contains(scalar.value)
                || (97...122).contains(scalar.value)
            if isASCIIAlphaNumeric {
                partial.append(contentsOf: String(scalar))
            } else if partial.last != "-" {
                partial.append("-")
            }
        }.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let stem = String((slug.isEmpty ? "room" : slug).prefix(48))
        while true {
            let candidate = "\(stem)-\(UUID().uuidString.prefix(8).lowercased())"
            if rooms[candidate] == nil && !reservedRoomIDs.contains(candidate) {
                reservedRoomIDs.insert(candidate)
                return candidate
            }
        }
    }

    private func now() -> Int64 {
        max(0, clockMS())
    }

    private static func validate(limits: LiveRoomHostLimits) throws {
        guard limits.maximumRooms > 0, limits.maximumStorageBytes > 0 else {
            throw LiveHTTPProblem(
                status: 400,
                code: "invalid_host_limits",
                message: "Room and storage limits must both be greater than zero.")
        }
    }

    private static func frameTime(sceneTimeMS: Int64) -> Double {
        min(
            LiveRoomPackageBuilder.recordingHorizonSeconds - 0.001,
            max(0, Double(sceneTimeMS) / 1_000))
    }

    private static func normalizedAllowlist(_ identities: [String]) throws -> [String] {
        var seen: Set<String> = []
        var output: [String] = []
        for supplied in identities {
            let identity = normalizedIdentity(supplied)
            guard !identity.isEmpty, identity.unicodeScalars.count <= 200,
                  !identity.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else {
                throw LiveHTTPProblem(status: 422, code: "invalid_allowlist",
                                      message: "The room allowlist contains an invalid identity.")
            }
            guard seen.insert(identity).inserted else {
                throw LiveHTTPProblem(status: 422, code: "duplicate_allowlist_identity",
                                      message: "The room allowlist contains a duplicate identity.")
            }
            output.append(identity)
        }
        return output
    }

    private static func normalizedIdentity(_ identity: String) -> String {
        identity.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func token() -> String {
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func digest(_ token: String) -> Data {
        Data(SHA256.hash(data: Data(token.utf8)))
    }

    private static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private static func secureEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }

    private static func finalize(
        _ source: ShowDocument,
        duration: Double,
        packageURL: URL,
        assets: AssetCatalog
    ) throws -> ShowDocument {
        var document = source
        let end = min(LiveRoomPackageBuilder.recordingHorizonSeconds, max(0.001, duration))
        if !document.stage.backgroundTracks.isEmpty {
            var track = document.stage.backgroundTracks[0]
            track.cues = track.cues.compactMap { cue in
                guard cue.start < end else { return nil }
                var clipped = cue
                clipped.dur = min(cue.dur, end - cue.start)
                return clipped.dur > 0 ? clipped : nil
            }
            document.stage.backgroundTracks[0] = track
        }
        document.show = [ShowSegment(name: "Room recording", from: 0, to: end)]
        let roomAudioClips = document.stage.audioTracks.flatMap(\.clips)
        guard document.stage.audioTracks.count == 1,
              roomAudioClips.count == 1,
              roomAudioClips[0].id == "room-music",
              document.stage.characters.allSatisfy({
                  $0.muted && $0.clips.isEmpty
              })
        else {
            throw LiveHTTPProblem(
                status: 500,
                code: "recording_audio_policy_failed",
                message: "The room recording contains audio other than its background MP3.")
        }
        let canonical = try ShowJSONCodec.encode(document: document)
        _ = try ShowJSONCodec.decodeDocument(canonical)
        let audioIDs = Set(roomAudioClips.map(\.id))
        let assetIDs = Set(document.assets.map(\.id))
        let errors = ShowLint.check(
            document: document,
            audioIDs: audioIDs,
            assetFileIDs: assetIDs,
            catalog: assets,
            profile: .editableShow)
            .filter { $0.severity == .error }
        guard errors.isEmpty else {
            throw LiveHTTPProblem(
                status: 500,
                code: "recording_validation_failed",
                message: "The final editable room recording did not pass validation.")
        }
        try Data(canonical.utf8).write(
            to: packageURL.appendingPathComponent("show.json"),
            options: .atomic)
        return document
    }

    private static func problem(for error: LiveRoomError) -> LiveHTTPProblem {
        switch error {
        case .roomFull:
            LiveHTTPProblem(status: 409, code: "room_full", message: "This room is full.")
        case .recordingCapacityExhausted:
            LiveHTTPProblem(
                status: 409,
                code: "recording_capacity_exhausted",
                message: "This recording has used all 10 character tracks; start a new room segment.")
        case .roomEnded:
            LiveHTTPProblem(status: 409, code: "room_ended", message: "This room has ended.")
        case .identityNotInvited:
            LiveHTTPProblem(status: 403, code: "identity_not_invited",
                            message: "This identity is not invited to the room.")
        case .identityAlreadyActive:
            LiveHTTPProblem(status: 409, code: "identity_already_active",
                            message: "This identity is already active in the room.")
        case .participantNotFound:
            LiveHTTPProblem(status: 404, code: "participant_not_found",
                            message: "The participant does not belong to this room.")
        case .participantDisconnected:
            LiveHTTPProblem(status: 409, code: "participant_disconnected",
                            message: "The participant is no longer active.")
        case .decisionNotDue:
            LiveHTTPProblem(status: 429, code: "decision_not_due",
                            message: "The participant's next decision is not due yet.")
        case .noOutstandingDecision:
            LiveHTTPProblem(status: 409, code: "no_outstanding_decision",
                            message: "No decision request is outstanding.")
        case .decisionExpired:
            LiveHTTPProblem(status: 409, code: "decision_expired",
                            message: "The outstanding decision request has expired.")
        case .intentIDReused:
            LiveHTTPProblem(status: 409, code: "intent_id_reused",
                            message: "The agent reused an intent ID for another request.")
        default:
            LiveHTTPProblem(status: 422, code: "invalid_room_operation",
                            message: error.localizedDescription)
        }
    }
}

struct LiveRoomFrameResourceState: Equatable, Sendable {
    let rendererResident: Bool
    let finalFrameSealed: Bool
}

enum LiveRoomFrameError: Error, Equatable, Sendable {
    case rendererReleased
    case superseded
}

/// A lock-backed one-shot lets cancellation resume an HTTP waiter immediately
/// without waiting for the cache actor or a synchronous media decode to yield.
private final class LiveRoomOneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    @discardableResult
    func resolve(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return false
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }

    var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result != nil
    }
}

/// Cancellation-aware process-wide render bound. A released permit transfers
/// directly to the oldest live waiter; canceled queued producers never consume
/// a later slot.
actor LiveRoomRenderLimiter {
    private struct Queued {
        let id: UUID
        let signal: LiveRoomOneShot<Void>
    }

    private let limit: Int
    private var active = 0
    private var queued: [Queued] = []

    init(limit: Int = 2) {
        precondition(limit > 0)
        self.limit = limit
    }

    func withPermit<Value: Sendable>(
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire()
        do {
            try Task.checkCancellation()
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async throws {
        let id = UUID()
        let signal = LiveRoomOneShot<Void>()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if active < limit {
                active += 1
                return
            }
            queued.append(Queued(id: id, signal: signal))
            do {
                try await signal.value()
            } catch {
                removeQueued(id: id)
                throw error
            }
        } onCancel: {
            signal.resolve(.failure(CancellationError()))
        }
    }

    private func removeQueued(id: UUID) {
        queued.removeAll { $0.id == id }
    }

    private func release() {
        while !queued.isEmpty {
            let next = queued.removeFirst()
            if next.signal.resolve(.success(())) {
                return
            }
        }
        precondition(active > 0)
        active -= 1
    }

    func diagnostics() -> (active: Int, queued: Int) {
        (active, queued.count)
    }
}

private let liveRoomRenderLimiter = LiveRoomRenderLimiter(limit: 2)

/// Per-room short-lived frame cache. Each caller owns a cancellation-aware
/// waiter on one shared producer. The producer is canceled when its final
/// waiter leaves, while canceling one viewer never disrupts the others.
actor LiveRoomJPEGCache {
    private struct CachedFrame {
        let epoch: UInt64
        let sampledAtMS: Int64
        let data: Data
    }

    private struct SealedFrame {
        let data: Data
    }

    private struct Flight {
        let id: UUID
        let epoch: UInt64
        let sampledAtMS: Int64
        let task: Task<Data, Error>
        var waiters: [UUID: LiveRoomOneShot<Data>]
    }

    private static let lifetimeMS: Int64 = 125

    private let clockMS: @Sendable () -> Int64
    private var cached: CachedFrame?
    private var sealed: SealedFrame?
    private var sealingEpoch: UInt64?
    private var flight: Flight?
    private var latestEpoch: UInt64 = 0
    private var cachedGeneration: UUID?
    private var evictionTask: Task<Void, Never>?
    private var starts = 0

    init(clockMS: @escaping @Sendable () -> Int64) {
        self.clockMS = clockMS
    }

    func jpeg(
        epoch: UInt64,
        producer: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        let waiterID = UUID()
        let waiter = LiveRoomOneShot<Data>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            // Terminal sealing is absorbing. A caller which sampled the old
            // revision before end must not resurrect live rendering afterward.
            if let sealed { return sealed.data }
            if let sealingEpoch, epoch != sealingEpoch {
                throw LiveRoomFrameError.superseded
            }
            guard epoch >= latestEpoch else {
                throw LiveRoomFrameError.superseded
            }
            if epoch > latestEpoch {
                latestEpoch = epoch
                clearCached()
                if flight != nil { cancelFlight() }
            }
            let requestedAtMS = now()
            if let cached,
               cached.epoch == epoch,
               requestedAtMS >= cached.sampledAtMS,
               requestedAtMS - cached.sampledAtMS < Self.lifetimeMS {
                return cached.data
            }
            clearCached()
            try attach(
                waiter,
                waiterID: waiterID,
                epoch: epoch,
                sampledAtMS: requestedAtMS,
                producer: producer)
            do {
                return try await waiter.value()
            } catch {
                removeWaiter(waiterID)
                throw error
            }
        } onCancel: {
            waiter.resolve(.failure(CancellationError()))
        }
    }

    func seal(
        epoch: UInt64,
        producer: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        if let sealed { return sealed.data }
        if let sealingEpoch, sealingEpoch != epoch {
            throw LiveRoomFrameError.superseded
        }
        sealingEpoch = epoch
        do {
            let data = try await jpeg(epoch: epoch, producer: producer)
            sealed = SealedFrame(data: data)
            sealingEpoch = nil
            clearCached()
            return data
        } catch {
            if sealingEpoch == epoch { sealingEpoch = nil }
            throw error
        }
    }

    func renderStartCount() -> Int { starts }
    func isSealed() -> Bool { sealed != nil }
    func waiterCount() -> Int { flight?.waiters.count ?? 0 }
    func hasFlight() -> Bool { flight != nil }
    func hasCachedFrame() -> Bool { cached != nil }

    func evictExpired() {
        guard let cached, now() - cached.sampledAtMS >= Self.lifetimeMS else {
            return
        }
        clearCached()
    }

    private func attach(
        _ waiter: LiveRoomOneShot<Data>,
        waiterID: UUID,
        epoch: UInt64,
        sampledAtMS: Int64,
        producer: @escaping @Sendable () async throws -> Data
    ) throws {
        guard !waiter.isResolved else { throw CancellationError() }
        if var flight, flight.epoch == epoch {
            flight.waiters[waiterID] = waiter
            self.flight = flight
            return
        }
        if flight != nil { cancelFlight() }

        let flightID = UUID()
        let task = Task.detached(priority: .userInitiated) {
            try await producer()
        }
        flight = Flight(
            id: flightID,
            epoch: epoch,
            sampledAtMS: sampledAtMS,
            task: task,
            waiters: [waiterID: waiter])
        starts += 1
        Task { [weak self] in
            let result = await task.result
            await self?.completeFlight(id: flightID, result: result)
        }
    }

    private func completeFlight(id: UUID, result: Result<Data, Error>) {
        guard let completed = flight, completed.id == id else { return }
        flight = nil
        if case .success(let data) = result {
            let age = max(0, now() - completed.sampledAtMS)
            if completed.epoch == sealingEpoch || age < Self.lifetimeMS {
                cached = CachedFrame(
                    epoch: completed.epoch,
                    sampledAtMS: completed.sampledAtMS,
                    data: data)
                if completed.epoch != sealingEpoch {
                    scheduleEviction(afterMS: Self.lifetimeMS - age)
                }
            } else {
                clearCached()
            }
        }
        for waiter in completed.waiters.values {
            waiter.resolve(result)
        }
    }

    private func removeWaiter(_ waiterID: UUID) {
        guard var flight, flight.waiters.removeValue(forKey: waiterID) != nil else {
            return
        }
        if flight.waiters.isEmpty {
            flight.task.cancel()
            self.flight = nil
        } else {
            self.flight = flight
        }
    }

    private func cancelFlight() {
        guard let flight else { return }
        self.flight = nil
        flight.task.cancel()
        for waiter in flight.waiters.values {
            waiter.resolve(.failure(LiveRoomFrameError.superseded))
        }
    }

    private func scheduleEviction(afterMS: Int64) {
        evictionTask?.cancel()
        let generation = UUID()
        cachedGeneration = generation
        evictionTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(max(1, afterMS)) * 1_000_000)
            } catch {
                return
            }
            await self?.evictCached(generation: generation)
        }
    }

    private func evictCached(generation: UUID) {
        guard cachedGeneration == generation, sealed == nil else { return }
        cached = nil
        cachedGeneration = nil
        evictionTask = nil
    }

    private func clearCached() {
        cached = nil
        cachedGeneration = nil
        evictionTask?.cancel()
        evictionTask = nil
    }

    private func now() -> Int64 { max(0, clockMS()) }
}

private struct RoomListResponse: Encodable, Sendable {
    let rooms: [LiveRoomPublicSnapshot]
}

private struct RoomResponse: Encodable, Sendable {
    let room: LiveRoomPublicSnapshot
}

private struct CreateResponse: Encodable, Sendable {
    let room: LiveRoomPublicSnapshot
    let hostToken: String
    let invitations: [LiveRoomInvitation]

    private enum CodingKeys: String, CodingKey {
        case room, invitations
        case hostToken = "host_token"
    }
}

private struct JoinResponse: Encodable, Sendable {
    let participantID: String
    let sessionToken: String
    let seat: Int
    let room: LiveRoomPublicSnapshot

    private enum CodingKeys: String, CodingKey {
        case participantID = "participant_id"
        case sessionToken = "session_token"
        case seat, room
    }
}

private struct LeaveRequest: Decodable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case participantID = "participant_id"
    }

    init(from decoder: Decoder) throws {
        try hostRejectUnknownKeys(decoder, allowed: CodingKeys.self)
        _ = try decoder.container(keyedBy: CodingKeys.self)
    }
}

private struct HostDynamicCodingKey: CodingKey {
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

private func hostRejectUnknownKeys<Key: CodingKey & CaseIterable>(
    _ decoder: Decoder,
    allowed: Key.Type
) throws where Key.AllCases: Sequence {
    let names = Set(Key.allCases.map(\.stringValue))
    let container = try decoder.container(keyedBy: HostDynamicCodingKey.self)
    if let unknown = container.allKeys.first(where: { !names.contains($0.stringValue) }) {
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "Unknown field \(unknown.stringValue)."))
    }
}
