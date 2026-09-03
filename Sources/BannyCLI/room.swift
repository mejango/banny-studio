import Foundation
import BannyCore
import BannyLive
import BannyRender
#if canImport(Darwin)
import Darwin
#endif

private let roomServeUsage =
    "banny room serve [--storage DIR] [--bind HOST] [--port N] "
        + "[--allowed-host HOST ...] [--director built-in|ollama] "
        + "[--director-url URL] [--director-model MODEL] [--max-rooms N] "
        + "[--max-storage-bytes BYTES] [--json]"
private let roomJoinUsage =
    "banny room join <room-url> --agent URL --name NAME --character FILE "
        + "[--credentials-file FILE] [options]"

private func writeRoomJSONRecord<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(value) + Data("\n".utf8))
}

/// Turns terminal shutdown into cooperative cancellation so a bridge can send
/// `leave` and a server can stop its listener before the process exits.
private final class RoomProcessSignalWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false
    #if canImport(Darwin)
    private var sources: [DispatchSourceSignal] = []
    #endif

    init() {
        #if canImport(Darwin)
        for number in [SIGINT, SIGTERM] {
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: number,
                queue: DispatchQueue.global(qos: .userInitiated))
            source.setEventHandler { [weak self] in self?.finish() }
            sources.append(source)
            source.resume()
        }
        #endif
    }

    deinit {
        #if canImport(Darwin)
        for source in sources { source.cancel() }
        Darwin.signal(SIGINT, SIG_DFL)
        Darwin.signal(SIGTERM, SIG_DFL)
        #endif
    }

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if finished {
                    lock.unlock()
                    continuation.resume()
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            finish()
        }
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

private final class RoomRuntimeFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMessage: String?

    func record(_ message: String) {
        lock.lock()
        if storedMessage == nil { storedMessage = message }
        lock.unlock()
    }

    var message: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedMessage
    }
}

func roomCommand(_ args: [String]) async throws {
    guard let subcommand = args.first else {
        throw CLIError.usage(
            "banny room <contract|serve|join> [options]")
    }
    let tail = Array(args.dropFirst())
    switch subcommand {
    case "contract":
        try roomContractCommand(tail)
    case "serve":
        try await roomServeCommand(tail)
    case "join":
        try await roomJoinCommand(tail)
    default:
        throw CLIError.usage(
            "unknown room command \(subcommand)\n\n"
                + "banny room <contract|serve|join> [options]")
    }
}

// MARK: - Agent contract

struct RoomAgentContractReport: Codable, Equatable {
    struct Limits: Codable, Equatable {
        let requestBytes: Int
        let responseBytes: Int
        let speechCharacters: Int
        let actionsPerDecision: Int
        let actionDurationMS: ClosedRangeReport
        let timeoutMS: ClosedRangeReport
        let requestAfterMS: ClosedRangeReport
        let reactionIntensity: DecimalRangeReport

        enum CodingKeys: String, CodingKey {
            case requestBytes = "request_bytes"
            case responseBytes = "response_bytes"
            case speechCharacters = "speech_characters"
            case actionsPerDecision = "actions_per_decision"
            case actionDurationMS = "action_duration_ms"
            case timeoutMS = "timeout_ms"
            case requestAfterMS = "request_after_ms"
            case reactionIntensity = "reaction_intensity"
        }
    }

    struct ClosedRangeReport: Codable, Equatable {
        let minimum: Int
        let maximum: Int
    }

    struct DecimalRangeReport: Codable, Equatable {
        let minimum: Double
        let maximum: Double
    }

    struct Rules: Codable, Equatable {
        let invalidDecisionIsAtomic: Bool
        let duplicateActionGroupsRejected: Bool
        let responseMustEchoRequestID: Bool
        let unknownFieldsRejected: Bool

        enum CodingKeys: String, CodingKey {
            case invalidDecisionIsAtomic = "invalid_decision_is_atomic"
            case duplicateActionGroupsRejected = "duplicate_action_groups_rejected"
            case responseMustEchoRequestID = "response_must_echo_request_id"
            case unknownFieldsRejected = "unknown_fields_rejected"
        }
    }

    struct Action: Codable, Equatable {
        let op: String
        let required: [String]
        let optional: [String]
        let values: [String: [String]]
    }

    let protocolVersion: String
    let endpoint: String
    let contentType: String
    let requestFields: [String]
    let responseFields: [String]
    let contextFields: [String: [String]]
    let actionDiscriminator: String
    let strictUnknownFields: Bool
    let limits: Limits
    let rules: Rules
    let actions: [Action]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case endpoint
        case contentType = "content_type"
        case requestFields = "request_fields"
        case responseFields = "response_fields"
        case contextFields = "context_fields"
        case actionDiscriminator = "action_discriminator"
        case strictUnknownFields = "strict_unknown_fields"
        case limits, rules, actions
    }

    static let current = RoomAgentContractReport(
        protocolVersion: BannyAgentProtocol.version,
        endpoint: "POST /v1/decide",
        contentType: "application/json",
        requestFields: [
            "protocol", "request_id", "room_id", "participant_id",
            "basis_seq", "timeout_ms", "context",
        ],
        responseFields: [
            "protocol", "request_id", "intent_id", "say?", "actions",
            "request_after_ms?",
        ],
        contextFields: [
            "context": [
                "scene_time_ms", "room", "self_state", "cast",
                "recent_events", "constraints",
            ],
            "room": ["state", "title", "premise?"],
            "self_state_and_cast": [
                "participant_id", "display_name", "pose", "status", "speaking",
            ],
            "pose": ["x", "depth", "face", "spin", "zoom"],
            "recent_event": [
                "seq", "scene_time_ms", "kind", "participant_id?", "text?", "action?",
            ],
            "constraints": [
                "allowed_actions", "allowed_reaction_ids", "max_actions",
                "max_speech_chars", "max_action_ms",
            ],
        ],
        actionDiscriminator: "op",
        strictUnknownFields: true,
        limits: .init(
            requestBytes: LocalAgentClientConfiguration.hardMaximumRequestBytes,
            responseBytes: BannyAgentProtocol.maximumResponseBytes,
            speechCharacters: BannyAgentProtocol.maximumSpeechCharacters,
            actionsPerDecision: BannyAgentProtocol.maximumActions,
            actionDurationMS: .init(
                minimum: BannyAgentProtocol.minimumActionDurationMS,
                maximum: BannyAgentProtocol.maximumActionDurationMS),
            timeoutMS: .init(minimum: 100, maximum: 10_000),
            requestAfterMS: .init(minimum: 250, maximum: 10_000),
            reactionIntensity: .init(minimum: 0, maximum: 4)),
        rules: .init(
            invalidDecisionIsAtomic: true,
            duplicateActionGroupsRejected: true,
            responseMustEchoRequestID: true,
            unknownFieldsRejected: true),
        actions: [
            .init(op: "move", required: ["direction", "duration_ms"], optional: [],
                  values: ["direction": ["left", "right"]]),
            .init(op: "depth", required: ["direction", "duration_ms"], optional: [],
                  values: ["direction": ["away", "toward"]]),
            .init(op: "tilt", required: ["direction", "duration_ms"], optional: [],
                  values: ["direction": ["forward", "back"]]),
            .init(op: "expression", required: ["expression", "duration_ms"], optional: [],
                  values: ["expression": ["blink", "brow1", "brow2"]]),
            .init(op: "jump", required: [], optional: [], values: [:]),
            .init(op: "flip", required: ["direction"], optional: [],
                  values: ["direction": ["front", "back"]]),
            .init(op: "rotate", required: ["direction", "duration_ms"], optional: [],
                  values: ["direction": ["left", "right"]]),
            .init(op: "zoom", required: ["direction", "duration_ms"], optional: [],
                  values: ["direction": ["in", "out"]]),
            .init(op: "reset", required: ["target"], optional: [],
                  values: ["target": ["spin", "zoom"]]),
            .init(op: "reaction", required: ["reaction_id"],
                  optional: ["duration_ms", "intensity"], values: [:]),
        ])
}

private func roomContractCommand(_ args: [String]) throws {
    var options = CLIOptions(args)
    let json = try options.flag("--json")
    try options.finish(usage: "banny room contract [--json]")
    let contract = RoomAgentContractReport.current
    if json {
        try printJSON(contract)
        return
    }
    print("Banny deprecated legacy local-agent protocol: \(contract.protocolVersion)")
    print("endpoint: \(contract.endpoint) (\(contract.contentType), strict snake_case JSON)")
    print("actions: \(contract.actions.map(\.op).joined(separator: ", "))")
    print("limits: \(contract.limits.actionsPerDecision) actions, "
          + "\(contract.limits.speechCharacters) speech characters, "
          + "\(contract.limits.responseBytes) response bytes")
    print("This contract is for the opt-in legacy participant bridge. Browser players use the host-wide director.")
}

// MARK: - Server

struct RoomServeReadyReport: Codable, Equatable {
    let ok: Bool
    let operation: String
    let url: String
    let bind: String
    let port: UInt16
    let storage: String
    let maximumRooms: Int
    let maximumStorageBytes: UInt64
    let director: String
    let directorModel: String?

    private enum CodingKeys: String, CodingKey {
        case ok, operation, url, bind, port, storage
        case maximumRooms = "maximum_rooms"
        case maximumStorageBytes = "maximum_storage_bytes"
        case director
        case directorModel = "director_model"
    }
}

enum RoomServeDirectorConfiguration: Equatable {
    case builtIn
    case ollama(OllamaLiveDirectorConfiguration)

    var name: String {
        switch self {
        case .builtIn: "built-in"
        case .ollama: "ollama"
        }
    }

    var model: String? {
        guard case .ollama(let configuration) = self else { return nil }
        return configuration.model
    }

    func makeProvider() throws -> any LiveDirectorDecisionProvider {
        switch self {
        case .builtIn:
            return BuiltInLiveDirectorDecisionProvider()
        case .ollama(let configuration):
            return try OllamaLiveDirectorDecisionProvider(configuration: configuration)
        }
    }
}

struct RoomServeCommandOptions: Equatable {
    let storageRaw: String?
    let bind: String
    let port: UInt16
    let allowedHosts: Set<String>
    let maximumRooms: Int
    let maximumStorageBytes: UInt64
    let director: RoomServeDirectorConfiguration
    let json: Bool

    var hostLimits: LiveRoomHostLimits {
        LiveRoomHostLimits(
            maximumRooms: maximumRooms,
            maximumStorageBytes: maximumStorageBytes)
    }

    var serverConfiguration: LiveHTTPServer.Configuration {
        .init(
            bindHost: bind,
            port: port,
            hostHeaderPolicy: allowedHosts.isEmpty
                ? .automatic
                : .allowed(allowedHosts))
    }
}

func parseRoomServeCommandOptions(_ args: [String]) throws -> RoomServeCommandOptions {
    var options = CLIOptions(args)
    let storageRaw = try options.value("--storage")
    let bind = try options.value("--bind") ?? "127.0.0.1"
    let rawPort = try options.int("--port") ?? 7_330
    let allowedHosts = Set(try options.values("--allowed-host"))
    let directorName = try options.value("--director") ?? "built-in"
    let directorURLRaw = try options.value("--director-url")
    let directorModelRaw = try options.value("--director-model")
    let maximumRooms = try options.int("--max-rooms")
        ?? LiveRoomHostLimits.defaultMaximumRooms
    let maximumStorageBytes: UInt64
    if let rawBytes = try options.value("--max-storage-bytes") {
        guard !rawBytes.isEmpty,
              rawBytes.utf8.allSatisfy({ (48...57).contains($0) }),
              let parsedBytes = UInt64(rawBytes)
        else {
            throw CLIError.invalid("--max-storage-bytes requires a positive integer")
        }
        maximumStorageBytes = parsedBytes
    } else {
        maximumStorageBytes = LiveRoomHostLimits.defaultMaximumStorageBytes
    }
    let json = try options.flag("--json")
    try options.finish(usage: roomServeUsage)

    let director: RoomServeDirectorConfiguration
    switch directorName {
    case "built-in":
        guard directorURLRaw == nil, directorModelRaw == nil else {
            throw CLIError.invalid(
                "--director-url and --director-model require --director ollama")
        }
        director = .builtIn
    case "ollama":
        let endpoint: URL
        if let directorURLRaw {
            guard let parsed = URL(string: directorURLRaw) else {
                throw CLIError.invalid(
                    "--director-url must be an HTTP numeric-loopback origin")
            }
            endpoint = parsed
        } else {
            endpoint = OllamaLiveDirectorConfiguration.defaultEndpoint
        }
        let configuration = OllamaLiveDirectorConfiguration(
            endpoint: endpoint,
            model: directorModelRaw ?? OllamaLiveDirectorConfiguration.defaultModel)
        do {
            _ = try OllamaLiveDirectorDecisionProvider(configuration: configuration)
        } catch OllamaLiveDirectorError.invalidEndpoint {
            throw CLIError.invalid(
                "--director-url must be an HTTP numeric-loopback origin without a path, query, or credentials")
        } catch OllamaLiveDirectorError.invalidModel {
            throw CLIError.invalid(
                "--director-model must be a valid Ollama model name")
        } catch {
            throw CLIError.invalid("the Ollama director configuration is invalid")
        }
        director = .ollama(configuration)
    default:
        throw CLIError.invalid("--director must be built-in or ollama")
    }

    guard (0...65_535).contains(rawPort), let port = UInt16(exactly: rawPort) else {
        throw CLIError.invalid("--port must be inside 0...65535")
    }
    guard maximumRooms > 0 else {
        throw CLIError.invalid("--max-rooms must be greater than zero")
    }
    guard maximumStorageBytes > 0 else {
        throw CLIError.invalid("--max-storage-bytes must be greater than zero")
    }
    let parsed = RoomServeCommandOptions(
        storageRaw: storageRaw,
        bind: bind,
        port: port,
        allowedHosts: allowedHosts,
        maximumRooms: maximumRooms,
        maximumStorageBytes: maximumStorageBytes,
        director: director,
        json: json)
    do {
        try parsed.serverConfiguration.validate()
    } catch LiveHTTPServerError.hostHeaderPolicyRequired {
        throw CLIError.invalid(
            "--bind \(bind) requires at least one --allowed-host HOST; "
                + "put TLS in front of the listener before internet exposure")
    } catch LiveHTTPServerError.emptyAllowedHosts {
        throw CLIError.invalid("provide at least one non-empty --allowed-host HOST")
    } catch LiveHTTPServerError.invalidAllowedHost(let host) {
        throw CLIError.invalid(
            "invalid --allowed-host \(host); use an exact DNS name or IP literal "
                + "without a scheme, path, wildcard, or port")
    } catch LiveHTTPServerError.invalidBindHost {
        throw CLIError.invalid("--bind must be a valid DNS name or IP literal")
    }
    return parsed
}

private final class RoomServerStartLatch: @unchecked Sendable {
    private enum Result {
        case ready(UInt16)
        case failed(String)
    }

    private let lock = NSLock()
    private var result: Result?
    private var continuation: CheckedContinuation<UInt16, Error>?

    func wait() async throws -> UInt16 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    Self.resume(continuation, with: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            failed("startup was cancelled")
        }
    }

    func ready(_ port: UInt16) {
        finish(.ready(port))
    }

    func failed(_ message: String) {
        finish(.failed(message))
    }

    private func finish(_ result: Result) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        if let continuation {
            Self.resume(continuation, with: result)
        }
    }

    private static func resume(
        _ continuation: CheckedContinuation<UInt16, Error>,
        with result: Result
    ) {
        switch result {
        case .ready(let port): continuation.resume(returning: port)
        case .failed(let message):
            continuation.resume(throwing: RoomCLIError.serverStart(message))
        }
    }
}

func defaultRoomStorageURL() throws -> URL {
    guard let root = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask).first
    else {
        throw CLIError.invalid("could not locate the user Application Support directory")
    }
    return root
        .appendingPathComponent("Banny Studio", isDirectory: true)
        .appendingPathComponent("Live Rooms", isDirectory: true)
}

private func roomServeCommand(_ args: [String]) async throws {
    let options = try parseRoomServeCommandOptions(args)
    let bind = options.bind
    let storage: URL
    if let storageRaw = options.storageRaw {
        guard !storageRaw.isEmpty else {
            throw CLIError.invalid("--storage cannot be empty")
        }
        storage = URL(fileURLWithPath:
            (storageRaw as NSString).expandingTildeInPath,
            isDirectory: true).standardizedFileURL
    } else {
        storage = try defaultRoomStorageURL()
    }

    let assetsRoot = try locateAssetsRoot()
    let catalog = try AssetCatalog(assetsRoot: assetsRoot)
    let directorDecisionProvider = try options.director.makeProvider()
    let host = try LiveRoomHostService(
        storageURL: storage,
        assets: catalog,
        directorDecisionProvider: directorDecisionProvider,
        limits: options.hostLimits)
    let staticAssets = LiveHTTPCompositeStaticAssets(providers: [
        LiveHTTPMountedStaticAssets(
            mount: "banny-assets",
            assets: LiveHTTPDirectoryStaticAssets(rootDirectory: assetsRoot)),
        LiveHTTPBundledWebAssets(),
    ])
    let termination = RoomProcessSignalWaiter()
    let runtimeFailure = RoomRuntimeFailure()
    let server = LiveHTTPServer(
        service: host,
        configuration: options.serverConfiguration,
        staticAssets: staticAssets,
        frameRenderer: { roomID in
            try await host.renderFrameJPEG(roomID: roomID)
        })
    let latch = RoomServerStartLatch()
    server.onReady = { latch.ready($0) }
    server.onFailure = { message in
        latch.failed(message)
        runtimeFailure.record(message)
        termination.finish()
    }
    try server.start()

    let actualPort: UInt16
    do {
        actualPort = try await latch.wait()
    } catch {
        server.stop()
        throw error
    }
    let bracketedHost = bind.contains(":") ? "[\(bind)]" : bind
    let url = "http://\(bracketedHost):\(actualPort)/"
    let report = RoomServeReadyReport(
        ok: true,
        operation: "room_serve",
        url: url,
        bind: bind,
        port: actualPort,
        storage: storage.path,
        maximumRooms: options.maximumRooms,
        maximumStorageBytes: options.maximumStorageBytes,
        director: options.director.name,
        directorModel: options.director.model)
    if options.json {
        try writeRoomJSONRecord(report)
    } else {
        print("Banny Live is ready at \(url)")
        print("room packages: \(storage.path)")
        print("room quota: \(options.maximumRooms) rooms, "
              + "\(options.maximumStorageBytes) storage bytes")
        if let model = options.director.model {
            print("director: ollama (\(model))")
        } else {
            print("director: built-in")
        }
        if !options.allowedHosts.isEmpty {
            print("allowed hosts: \(options.allowedHosts.sorted().joined(separator: ", "))")
            printErr("internet mode: terminate TLS at the reverse proxy before this listener")
        }
    }

    await termination.wait()
    server.stop()
    if let message = runtimeFailure.message {
        throw RoomCLIError.serverRuntime(message)
    }
}

// MARK: - Participant bridge

struct RoomCLIEndpoint: Equatable {
    let roomID: String
    let apiRoomURL: URL

    init(_ rawValue: String, allowInsecureRemote: Bool = false) throws {
        guard var components = URLComponents(string: rawValue),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw CLIError.invalid(
                "room-url must be an HTTP(S) room URL without credentials, query, or fragment")
        }
        if scheme == "http",
           !LocalAgentClient.isNumericLoopbackHost(host),
           !allowInsecureRemote {
            throw CLIError.invalid(
                "room-url must use HTTPS unless it targets numeric loopback; "
                    + "use --allow-insecure-room only on a trusted network")
        }

        let encodedSegments = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        let segments = try encodedSegments.map { value -> String in
            guard let decoded = value.removingPercentEncoding else {
                throw CLIError.invalid("room-url contains invalid percent encoding")
            }
            return decoded
        }
        let roomID: String
        switch segments {
        case let values where values.count >= 2 && values[0] == "rooms":
            roomID = values[1]
            guard values.count == 2
                    || (values.count == 3 && ["live", "join", "control"].contains(values[2]))
            else {
                throw CLIError.invalid("room-url has an unsupported room path")
            }
        case let values where values.count == 3
            && values[0] == "v1" && values[1] == "rooms":
            roomID = values[2]
        default:
            throw CLIError.invalid(
                "room-url path must be /rooms/<id>[/live] or /v1/rooms/<id>")
        }
        guard roomCLIIsIdentifier(roomID) else {
            throw CLIError.invalid("room-url contains an invalid room identifier")
        }

        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encodedID = roomID.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw CLIError.invalid("room-url contains an invalid room identifier")
        }
        components.scheme = scheme
        components.path = ""
        components.percentEncodedPath = "/v1/rooms/\(encodedID)"
        guard let apiRoomURL = components.url else {
            throw CLIError.invalid("room-url could not be normalized")
        }
        self.roomID = roomID
        self.apiRoomURL = apiRoomURL
    }
}

private func roomCLIIsIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".." && value.utf8.count <= 200
        && value.utf8.allSatisfy { byte in
            (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || byte == 45 || byte == 46 || byte == 95 || byte == 126
        }
}

private func roomCLIIsBearerToken(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 4_096 && value.utf8.allSatisfy { byte in
        (48...57).contains(byte)
            || (65...90).contains(byte)
            || (97...122).contains(byte)
            || [43, 45, 46, 47, 61, 95, 126].contains(byte)
    }
}

private func roomCLIIsPublicMessage(_ value: String, maximum: Int) -> Bool {
    !value.isEmpty && value.unicodeScalars.count <= maximum
        && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
}

struct RoomCLIAvatar: Codable, Equatable {
    let body: Body
    let eyes: String
    let mouth: String
    let outfit: [Int: String]
}

struct RoomCLIJoinCredentials: Codable, Equatable {
    let identity: String?
    let invite: String?
    let agentToken: String?

    init(identity: String? = nil, invite: String? = nil, agentToken: String? = nil) {
        self.identity = identity
        self.invite = invite
        self.agentToken = agentToken
    }

    enum CodingKeys: String, CodingKey {
        case identity, invite
        case agentToken = "agent_token"
    }
}

func loadRoomCLIJoinCredentials(at url: URL) throws -> RoomCLIJoinCredentials {
    let resourceValues = try url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard resourceValues.isSymbolicLink != true,
          resourceValues.isRegularFile == true else {
        throw CLIError.invalid("--credentials-file must name a regular, non-symlink file")
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    if let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
       permissions & 0o077 != 0 {
        throw CLIError.invalid(
            "--credentials-file must not be accessible by group or other users; "
                + "run chmod 600 on the file")
    }
    #if canImport(Darwin)
    if let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
       owner != getuid() {
        throw CLIError.invalid("--credentials-file must be owned by the current user")
    }
    #endif

    let maximumBytes = 16 * 1_024
    if let size = resourceValues.fileSize, size > maximumBytes {
        throw CLIError.invalid("--credentials-file exceeds the 16384-byte limit")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    guard data.count <= maximumBytes else {
        throw CLIError.invalid("--credentials-file exceeds the 16384-byte limit")
    }
    guard !data.isEmpty else {
        throw CLIError.invalid("--credentials-file cannot be empty")
    }
    guard String(data: data, encoding: .utf8) != nil else {
        throw CLIError.invalid("--credentials-file must use UTF-8 encoding")
    }
    let object: Any
    do {
        object = try JSONSerialization.jsonObject(with: data)
    } catch {
        throw CLIError.invalid("--credentials-file must contain valid UTF-8 JSON")
    }
    guard let dictionary = object as? [String: Any] else {
        throw CLIError.invalid("--credentials-file JSON must be an object")
    }
    let allowed = Set(["identity", "invite", "agent_token"])
    let unknown = Set(dictionary.keys).subtracting(allowed).sorted()
    guard unknown.isEmpty else {
        throw CLIError.invalid(
            "--credentials-file contains unsupported field"
                + (unknown.count == 1 ? ": " : "s: ")
                + unknown.joined(separator: ", "))
    }
    do {
        return try JSONDecoder().decode(RoomCLIJoinCredentials.self, from: data)
    } catch {
        throw CLIError.invalid(
            "--credentials-file fields must be strings or null")
    }
}

func mergeRoomCLIJoinCredentials(
    file: RoomCLIJoinCredentials?,
    identity: String?,
    invite: String?,
    agentToken: String?
) throws -> RoomCLIJoinCredentials {
    if identity != nil && file?.identity != nil {
        throw CLIError.invalid(
            "choose only one identity source: --identity or --credentials-file")
    }
    if invite != nil && file?.invite != nil {
        throw CLIError.invalid(
            "choose only one invite source: --invite or --credentials-file")
    }
    if agentToken != nil && file?.agentToken != nil {
        throw CLIError.invalid(
            "choose only one local-agent token source: --agent-token or --credentials-file")
    }
    return RoomCLIJoinCredentials(
        identity: identity ?? file?.identity,
        invite: invite ?? file?.invite,
        agentToken: agentToken ?? file?.agentToken)
}

private struct RoomJoinRequest: Codable {
    let displayName: String
    let identity: String?
    let invite: String?
    let avatar: RoomCLIAvatar

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case identity, invite, avatar
    }
}

private struct RoomJoinReceipt: Decodable {
    let participantID: String
    let sessionToken: String
    let seat: Int

    enum CodingKeys: String, CodingKey {
        case participantID = "participant_id"
        case sessionToken = "session_token"
        case seat
    }
}

struct RoomJoinReadyReport: Codable, Equatable {
    let ok: Bool
    let operation: String
    let roomID: String
    let participantID: String
    let seat: Int

    enum CodingKeys: String, CodingKey {
        case ok, operation, seat
        case roomID = "room_id"
        case participantID = "participant_id"
    }
}

private struct RoomHTTPProblemEnvelope: Decodable {
    struct Problem: Decodable {
        let code: String
        let message: String
    }
    let error: Problem
}

private enum RoomCLIError: Error, CustomStringConvertible {
    case serverStart(String)
    case serverRuntime(String)
    case invalidHTTPResponse
    case redirected
    case responseTooLarge(Int64)
    case timedOut
    case server(status: Int, code: String, message: String)
    case malformedJoinReceipt

    var description: String {
        switch self {
        case .serverStart(let message):
            "the room server could not start: \(message)"
        case .serverRuntime(let message):
            "the room server stopped unexpectedly: \(message)"
        case .invalidHTTPResponse:
            "the room returned an invalid HTTP response"
        case .redirected:
            "the room attempted to redirect an admission request"
        case .responseTooLarge(let size):
            "the room admission response exceeded 65536 bytes (received \(size))"
        case .timedOut:
            "the room admission request timed out"
        case .server(let status, let code, let message):
            "room admission failed (HTTP \(status), \(code)): \(message)"
        case .malformedJoinReceipt:
            "the room returned a malformed admission receipt"
        }
    }
}

func loadRoomCLIAvatar(
    at url: URL,
    catalog: AssetCatalog
) throws -> RoomCLIAvatar {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else {
        throw CLIError.invalid("--character must name a regular file")
    }
    let maximumBytes = url.pathExtension.lowercased() == "bannytrack"
        ? 64 * 1_024 * 1_024 : 64 * 1_024
    if let size = values.fileSize, size > maximumBytes {
        throw CLIError.invalid("--character file is too large")
    }
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard data.count <= maximumBytes else {
        throw CLIError.invalid("--character file is too large")
    }

    let avatar: RoomCLIAvatar
    switch url.pathExtension.lowercased() {
    case "json":
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw CLIError.invalid("avatar JSON must be an object")
        }
        let allowed = Set(["body", "eyes", "mouth", "outfit"])
        let unknown = Set(dictionary.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else {
            throw CLIError.invalid(
                "avatar JSON contains unsupported field\(unknown.count == 1 ? "" : "s"): "
                    + unknown.joined(separator: ", "))
        }
        do {
            avatar = try JSONDecoder().decode(RoomCLIAvatar.self, from: data)
        } catch {
            throw CLIError.invalid("avatar JSON is malformed: \(error)")
        }
    case "bannytrack":
        let track: PortableTrack
        do {
            track = try PortableTrack(data: data)
        } catch {
            throw CLIError.invalid("could not decode character .bannytrack: \(error)")
        }
        guard case .character(let character) = track.payload else {
            throw CLIError.invalid("--character .bannytrack must contain a character track")
        }
        avatar = RoomCLIAvatar(
            body: character.body,
            eyes: character.baseOutfit[OutfitCategory.eyes.rawValue] ?? "default",
            mouth: character.baseOutfit[OutfitCategory.mouth.rawValue] ?? "default",
            outfit: character.baseOutfit.filter { slot, _ in
                slot != OutfitCategory.eyes.rawValue
                    && slot != OutfitCategory.mouth.rawValue
            })
    default:
        throw CLIError.invalid("--character must end in .json or .bannytrack")
    }

    try validateRoomCLIAvatar(avatar, catalog: catalog)
    return avatar
}

private func validateRoomCLIAvatar(
    _ avatar: RoomCLIAvatar,
    catalog: AssetCatalog
) throws {
    guard !avatar.eyes.isEmpty, avatar.eyes.utf8.count <= 200,
          catalog.hasEyeOption(avatar.eyes)
    else {
        throw CLIError.invalid("avatar eyes is not in the Banny catalog")
    }
    guard !avatar.mouth.isEmpty, avatar.mouth.utf8.count <= 200,
          catalog.hasMouthOption(avatar.mouth)
    else {
        throw CLIError.invalid("avatar mouth is not in the Banny catalog")
    }
    let validSlots = Set(OutfitCategory.allCases.map(\.rawValue))
    for (slot, name) in avatar.outfit.sorted(by: { $0.key < $1.key }) {
        guard validSlots.contains(slot),
              slot != OutfitCategory.eyes.rawValue,
              slot != OutfitCategory.mouth.rawValue
        else {
            throw CLIError.invalid(
                "avatar outfit slot \(slot) is invalid or belongs in eyes/mouth")
        }
        guard !name.isEmpty, name.utf8.count <= 200,
              catalog.outfitSlot(name) == slot
        else {
            throw CLIError.invalid(
                "avatar outfit \(name) is not a catalog item for slot \(slot)")
        }
    }
}

private func roomJoinCommand(_ args: [String]) async throws {
    guard let rawRoomURL = args.first else {
        throw CLIError.usage(roomJoinUsage)
    }
    var options = CLIOptions(Array(args.dropFirst()))
    let agentRaw = try options.requiredValue("--agent")
    let agentTokenArgument = try options.value("--agent-token")
    let displayName = try options.requiredValue("--name")
    let characterPath = try options.requiredValue("--character")
    let identityArgument = try options.value("--identity")
    let inviteArgument = try options.value("--invite")
    let credentialsPath = try options.value("--credentials-file")
    let allowRemoteAgent = try options.flag("--allow-remote-agent")
    let allowInsecureRoom = try options.flag("--allow-insecure-room")
    let json = try options.flag("--json")
    try options.finish(usage: roomJoinUsage)
    printErr(
        "warning: banny room join is the deprecated legacy bridge; "
            + "new participants should join directly in the room browser")

    let fileCredentials: RoomCLIJoinCredentials?
    if let credentialsPath {
        guard !credentialsPath.isEmpty else {
            throw CLIError.invalid("--credentials-file cannot be empty")
        }
        fileCredentials = try loadRoomCLIJoinCredentials(
            at: URL(fileURLWithPath:
                (credentialsPath as NSString).expandingTildeInPath))
    } else {
        fileCredentials = nil
    }
    let credentials = try mergeRoomCLIJoinCredentials(
        file: fileCredentials,
        identity: identityArgument,
        invite: inviteArgument,
        agentToken: agentTokenArgument)
    let identity = credentials.identity
    let invite = credentials.invite
    let agentToken = credentials.agentToken
    if inviteArgument != nil {
        printErr("warning: --invite exposes a room secret in process arguments; "
                 + "it is deprecated, use --credentials-file")
    }
    if agentTokenArgument != nil {
        printErr("warning: --agent-token exposes a local-agent secret in process arguments; "
                 + "it is deprecated, use --credentials-file")
    }

    let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedDisplayName.isEmpty,
          normalizedDisplayName.unicodeScalars.count <= 60,
          !normalizedDisplayName.unicodeScalars.contains(where: {
              CharacterSet.controlCharacters.contains($0)
          })
    else {
        throw CLIError.invalid("--name must be 1...60 characters without control characters")
    }
    if let identity {
        guard !identity.isEmpty, identity.utf8.count <= 200,
              !identity.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else { throw CLIError.invalid("--identity is invalid") }
    }
    if let invite {
        guard !invite.isEmpty,
              !invite.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else { throw CLIError.invalid("--invite is invalid") }
    }

    let endpoint = try RoomCLIEndpoint(
        rawRoomURL,
        allowInsecureRemote: allowInsecureRoom)
    guard let agentURL = URL(string: agentRaw) else {
        throw CLIError.invalid("--agent must be an HTTP(S) URL")
    }
    let agent = try LocalAgentClient(
        endpoint: agentURL,
        bearerToken: agentToken,
        configuration: .init(allowRemoteEndpoint: allowRemoteAgent))
    let catalog = try AssetCatalog(assetsRoot: locateAssetsRoot())
    let avatar = try loadRoomCLIAvatar(
        at: URL(fileURLWithPath:
            (characterPath as NSString).expandingTildeInPath),
        catalog: catalog)
    let receipt = try await joinRoom(
        endpoint: endpoint,
        request: RoomJoinRequest(
            displayName: normalizedDisplayName,
            identity: identity,
            invite: invite,
            avatar: avatar))

    let transport = try URLSessionRoomTransport(
        roomURL: endpoint.apiRoomURL,
        bearerToken: receipt.sessionToken,
        configuration: .init(allowInsecureRemoteHTTP: allowInsecureRoom))
    let ready = RoomJoinReadyReport(
        ok: true,
        operation: "room_join",
        roomID: endpoint.roomID,
        participantID: receipt.participantID,
        seat: receipt.seat)
    if json {
        try writeRoomJSONRecord(ready)
    } else {
        print("joined room \(endpoint.roomID) as \(normalizedDisplayName) "
              + "(seat \(receipt.seat), participant \(receipt.participantID))")
        print("bridge ready — room and local AI connections are outbound")
    }

    let loop = RoomPollingLoop(transport: transport, agent: agent)
    let termination = RoomProcessSignalWaiter()
    do {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await loop.run { step in
                    guard case .skipped(let cursor, let requestID, let reason) = step else {
                        return
                    }
                    if json {
                        let record = RoomBridgeProgress(
                            event: "decision_skipped",
                            cursor: cursor,
                            requestID: requestID,
                            message: reason)
                        if let data = try? LiveHTTPJSON.encoder.encode(record) {
                            FileHandle.standardError.write(data + Data("\n".utf8))
                        }
                    } else {
                        let safeReason = reason.unicodeScalars.map {
                            CharacterSet.controlCharacters.contains($0) ? "�" : String($0)
                        }.joined()
                        printErr("local AI skipped request \(requestID): "
                                 + String(safeReason.prefix(512)))
                    }
                }
            }
            group.addTask {
                await termination.wait()
                throw CancellationError()
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
        try? await transport.leave()
    } catch is CancellationError {
        try? await transport.leave()
    } catch let error as URLSessionRoomTransportError
        where roomBridgeWasClosed(error)
    {
        // A participant session is deliberately revoked when the host ends or
        // removes it. Treat that terminal 401 as a clean bridge shutdown; the
        // token can no longer authorize a useful leave request.
        if !json { print("room bridge closed") }
    } catch {
        try? await transport.leave()
        throw error
    }
}

func roomBridgeWasClosed(_ error: URLSessionRoomTransportError) -> Bool {
    error == .httpStatus(401)
}

private struct RoomBridgeProgress: Codable {
    let event: String
    let cursor: Int64
    let requestID: String
    let message: String

    enum CodingKeys: String, CodingKey {
        case event, cursor, message
        case requestID = "request_id"
    }
}

private func joinRoom(
    endpoint: RoomCLIEndpoint,
    request joinRequest: RoomJoinRequest
) async throws -> RoomJoinReceipt {
    let body = try LiveHTTPJSON.encoder.encode(joinRequest)
    let joinURL = endpoint.apiRoomURL.appendingPathComponent("join", isDirectory: false)
    var request = URLRequest(
        url: joinURL,
        cachePolicy: .reloadIgnoringLocalCacheData,
        timeoutInterval: 15)
    request.httpMethod = "POST"
    request.httpBody = body
    request.httpShouldHandleCookies = false
    request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }
    let payload: BannyLiveURLLoader.Payload
    do {
        payload = try await BannyLiveURLLoader.data(
            for: request,
            session: session,
            timeout: 15,
            maximumResponseBytes: 64 * 1_024)
    } catch BannyLiveURLLoader.Error.timedOut {
        throw RoomCLIError.timedOut
    } catch let BannyLiveURLLoader.Error.responseTooLarge(actual, _) {
        throw RoomCLIError.responseTooLarge(actual)
    }
    let data = payload.data
    guard let response = payload.response as? HTTPURLResponse else {
        throw RoomCLIError.invalidHTTPResponse
    }
    guard response.url == joinURL else {
        throw RoomCLIError.redirected
    }
    guard (200..<300).contains(response.statusCode) else {
        if let problem = try? LiveHTTPJSON.decoder.decode(
            RoomHTTPProblemEnvelope.self,
            from: data).error,
           roomCLIIsIdentifier(problem.code),
           roomCLIIsPublicMessage(problem.message, maximum: 512) {
            throw RoomCLIError.server(
                status: response.statusCode,
                code: problem.code,
                message: problem.message)
        }
        throw RoomCLIError.server(
            status: response.statusCode,
            code: "http_error",
            message: "The room rejected admission.")
    }
    guard let receipt = try? LiveHTTPJSON.decoder.decode(RoomJoinReceipt.self, from: data),
          roomCLIIsIdentifier(receipt.participantID),
          roomCLIIsBearerToken(receipt.sessionToken),
          (1...10).contains(receipt.seat)
    else {
        throw RoomCLIError.malformedJoinReceipt
    }
    return receipt
}
