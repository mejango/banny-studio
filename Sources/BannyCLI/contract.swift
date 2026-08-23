import Foundation
import BannyCore
// The room server is a separate workstream and is not part of this repository's
// build. Guarding the import is what lets a clean checkout compile: the module
// is only importable when a Package.swift that declares it is in play.
#if canImport(BannyLive)
import BannyLive
#endif

// Public machine contract for GUI-free and agent-driven production.

enum BannyCLIContract {
    static let version = "2.1.0"
    static let contractVersion = 3
    static let schemaVersion = 4
    static let patchStandard = "RFC 6902"
}

struct CommandOptionCapability: Codable {
    let name: String
    let value: String?
    let required: Bool
    let description: String
    let allowed: [String]?
    let minimum: Double?
    let maximum: Double?
    let defaultValue: String?

    init(_ name: String, value: String? = nil, required: Bool = false,
         _ description: String, allowed: [String]? = nil,
         minimum: Double? = nil, maximum: Double? = nil,
         defaultValue: String? = nil) {
        self.name = name
        self.value = value
        self.required = required
        self.description = description
        self.allowed = allowed
        self.minimum = minimum
        self.maximum = maximum
        self.defaultValue = defaultValue
    }
}

struct CommandCapability: Codable {
    let name: String
    let summary: String
    let usage: String
    let mutatesProject: Bool
    let acceptsArchive: Bool
    let jsonOutput: String?
    let progress: String?
    let options: [CommandOptionCapability]
}

private struct ProductionCapabilities: Codable {
    struct Project: Codable {
        let schemaVersion: Int
        let directoryExtension: String
        let archiveExtension: String
        let strictUnknownFields: Bool
        let mutationFormat: String
        let atomicDocumentWrites: Bool
        let optimisticConcurrency: String
    }

    struct Vocabulary: Codable {
        let bodies: [String]
        let eventCodes: [String]
        let eventGroups: [String]
        let voiceRecipes: [String]
        let mouthShapes: [String]
        let mediaMasks: [String]
        let crops: [String]
        let markerKinds: [String]
        let markerColors: [String]
        let trackKinds: [String]
    }

    struct Limits: Codable {
        let maxCharacters: Int
        let starterCharacters: String
    }

    struct Automation: Codable {
        let successOutput: String
        let errorOutput: String
        let validationOutput: String
        let progressOutput: String
        let exitCodes: [String: Int]
    }

    let contractVersion: Int
    let cliVersion: String
    let schemaSHA256: String
    let platform: String
    let limits: Limits
    let automation: Automation
    let project: Project
    let commands: [CommandCapability]
    let vocabulary: Vocabulary
}

private let jsonOption = CommandOptionCapability(
    "--json", "Emit stable JSON on stdout and structured errors on stderr.")
private let concurrencyOptions = [
    CommandOptionCapability("--dry-run", "Validate and report without writing."),
    CommandOptionCapability("--if-hash", value: "SHA256",
                            "Only mutate the exact show.json revision."),
    jsonOption,
]

private let coreCommandCapabilities: [CommandCapability] = [
    .init(name: "capabilities", summary: "Describe the complete machine contract.",
          usage: "banny capabilities [--json]", mutatesProject: false,
          acceptsArchive: true, jsonOutput: "ProductionCapabilities", progress: nil,
          options: [jsonOption]),
    .init(name: "schema", summary: "Print the canonical v4 schema or starter example.",
          usage: "banny schema [--compact|--example]", mutatesProject: false,
          acceptsArchive: true, jsonOutput: "JSON Schema or ShowDocument", progress: nil,
          options: [.init("--compact", "Minify the schema."),
                    .init("--example", "Print a canonical starter document."), jsonOption]),
    .init(name: "catalog", summary: "List exact render vocabulary.",
          usage: "banny catalog [--json]", mutatesProject: false, acceptsArchive: true,
          jsonOutput: "AssetCatalog.Summary", progress: nil, options: [jsonOption]),
    .init(name: "voices", summary: "List voices available for speech synthesis.",
          usage: "banny voices [--language PREFIX] [--json]", mutatesProject: false,
          acceptsArchive: true, jsonOutput: "Voice list", progress: nil,
          options: [.init("--language", value: "PREFIX", "Filter BCP-47 languages."), jsonOption]),
    .init(name: "new", summary: "Create a strict v4 starter project.",
          usage: "banny new <project.bs> [--characters N] [--json]", mutatesProject: true,
          acceptsArchive: false, jsonOutput: "NewProjectReport", progress: nil,
          options: [.init("--characters", value: "N", "Starter cast size.",
                          minimum: 1, maximum: 10, defaultValue: "2"), jsonOption]),
    .init(name: "migrate", summary: "Atomically upgrade an editable v2/v3 project to v4.",
          usage: "banny migrate <project.bs> [--dry-run] [--if-hash SHA256] [--json]",
          mutatesProject: true, acceptsArchive: false, jsonOutput: "MigrationReport",
          progress: nil, options: concurrencyOptions),
    .init(name: "validate", summary: "Run strict schema, package, and production preflight checks.",
          usage: "banny validate <show.bs> [--json]", mutatesProject: false,
          acceptsArchive: true, jsonOutput: "[Diagnostic]", progress: nil, options: [jsonOption]),
    .init(name: "info", summary: "Summarize project structure and current document hash.",
          usage: "banny info <show.bs> [--json]", mutatesProject: false,
          acceptsArchive: true, jsonOutput: "ProjectInfo", progress: nil, options: [jsonOption]),
    .init(name: "state", summary: "Resolve every character, light, camera, and backdrop at a time.",
          usage: "banny state <show.bs> --at SECONDS [--json]", mutatesProject: false,
          acceptsArchive: true, jsonOutput: "StateReport", progress: nil,
          options: [.init("--at", value: "SECONDS", required: true,
                          "Timeline time.", minimum: 0), jsonOption]),
    .init(name: "character set-start", summary: "Set or clear one character's coherent start state.",
          usage: "banny character set-start <project.bs> --character N [start options] [mutation options]",
          mutatesProject: true, acceptsArchive: false, jsonOutput: "StartPoseReport", progress: nil,
          options: [.init("--character", value: "N", required: true, "One-based character index.", minimum: 1, maximum: 10),
                    .init("--x", value: "N",
                          "Stage position; may sit outside 0...1 when the scene has wings.",
                          minimum: -1, maximum: 2),
                    .init("--depth", value: "N", "Stage depth.", minimum: -12, maximum: 1),
                    .init("--face", value: "SIDE", "Facing direction.", allowed: ["left", "right", "-1", "1"]),
                    .init("--spin", value: "DEGREES", "Initial free rotation."),
                    .init("--zoom", value: "N", "Initial scale multiplier.", minimum: 0.000001),
                    .init("--size", value: "N", "Character size multiplier.", minimum: 0.000001),
                    .init("--clear", "Clear the recorded start pose."),
                   ] + concurrencyOptions),
    .init(name: "performance add", summary: "Add an idempotent typed key interval.",
          usage: "banny performance add <project.bs> --character N --code CODE --at SECONDS [options]",
          mutatesProject: true, acceptsArchive: false, jsonOutput: "PerformanceAddReport", progress: nil,
          options: [.init("--character", value: "N", required: true, "One-based character index.", minimum: 1, maximum: 10),
                    .init("--code", value: "CODE", required: true, "Exact EventCode.", allowed: EventCode.allCases.map(\.rawValue)),
                    .init("--at", value: "SECONDS", required: true, "Press time.", minimum: 0),
                    .init("--duration", value: "SECONDS", "Held duration.", minimum: 0.000001, defaultValue: "0.1"),
                   ] + concurrencyOptions),
    .init(name: "preview", summary: "Render one deterministic frame or a contact sheet.",
          usage: "banny preview <show.bs> <out.png> [--t SEC|--times CSV] [--columns N] [--json]",
          mutatesProject: false, acceptsArchive: true, jsonOutput: "PreviewReport", progress: nil,
          options: [.init("--t", value: "SECONDS", "Single frame time.", minimum: 0, defaultValue: "0"),
                    .init("--times", value: "CSV", "Comma-separated contact-sheet times."),
                    .init("--columns", value: "N", "Contact-sheet columns.", minimum: 1), jsonOption]),
    .init(name: "ship", summary: "Plan or render a deterministic MP4.",
          usage: "banny ship <show.bs> [out.mp4] [--plan] [tier/range/options]",
          mutatesProject: false, acceptsArchive: true, jsonOutput: "ShipPlan or ShipReport",
          progress: "--progress-json writes JSONL progress records to stderr.",
          options: [.init("--plan", "Preflight and report the render without writing."),
                    .init("--480", "Render 480p."), .init("--720", "Render 720p."),
                    .init("--1080", "Render 1080p (default)."), .init("--4k", "Render 2160p."),
                    .init("--range", value: "FROM TO", "Render an explicit time range."),
                    .init("--overwrite", "Replace an existing output."),
                    .init("--progress-json", "Write JSONL progress to stderr."), jsonOption]),
    .init(name: "apply", summary: "Atomically apply RFC 6902 JSON Patch.",
          usage: "banny apply <project.bs> <patch.json|-> [--dry-run] [--if-hash SHA256] [--json]",
          mutatesProject: true, acceptsArchive: false, jsonOutput: "PatchReport", progress: nil,
          options: concurrencyOptions),
    .init(name: "tts", summary: "Synthesize portable character speech clips.",
          usage: "banny tts <project.bs> --character N [--text TEXT|--text-file FILE|--captions] [options]",
          mutatesProject: true, acceptsArchive: false, jsonOutput: "TTS report", progress: nil,
          options: [.init("--character", value: "N", required: true, "One-based character index."),
                    .init("--text", value: "TEXT", "Speech text."),
                    .init("--text-file", value: "FILE", "Read speech text from UTF-8 file."),
                    .init("--captions", "Synthesize every nonempty character caption."),
                    .init("--at", value: "SECONDS", "Single-line start time.", minimum: 0, defaultValue: "0"),
                    .init("--voice", value: "ID", "Installed voice identifier."),
                    .init("--preset", value: "NAME", "Portable voice recipe.", allowed: VoiceRecipe.Preset.allCases.map(\.rawValue)),
                    .init("--flavor", value: "N", "Recipe wet/dry blend.", minimum: 0, maximum: 1),
                    .init("--rate", value: "N", "Source synthesis rate.", minimum: 0, maximum: 1, defaultValue: "0.5"),
                    .init("--pitch", value: "N", "Source pitch multiplier.", minimum: 0.5, maximum: 2, defaultValue: "1"),
                    .init("--name", value: "NAME", "Generated clip name."),
                    .init("--fade-in", value: "SECONDS", "Clip fade in.", minimum: 0, defaultValue: "0.04"),
                    .init("--fade-out", value: "SECONDS", "Clip fade out.", minimum: 0, defaultValue: "0.06"),
                    .init("--no-caption", "Do not add a caption for single-line speech."),
                    .init("--no-lipsync", "Do not derive automatic mouth timing."),
                    .init("--replace-generated", "Replace prior CLI-generated speech clips."),
                    jsonOption]),
    .init(name: "lipsync", summary: "Analyze or clear precise mouth timing.",
          usage: "banny lipsync <project.bs> --character N --clip ID [--clear] [--json]",
          mutatesProject: true, acceptsArchive: false, jsonOutput: "Lip-sync report", progress: nil,
          options: [.init("--character", value: "N", required: true, "One-based character index."),
                    .init("--clip", value: "ID", required: true, "Character clip ID."),
                    .init("--clear", "Remove mouth cues."), jsonOption]),
    .init(name: "media probe", summary: "Inspect media type, duration, and dimensions.",
          usage: "banny media probe <file> [--json]", mutatesProject: false,
          acceptsArchive: true, jsonOutput: "MediaProbe", progress: nil, options: [jsonOption]),
    .init(name: "media import", summary: "Copy media into a package and place it safely.",
          usage: "banny media import <project.bs> <file> [target/options] [--json]",
          mutatesProject: true, acceptsArchive: false, jsonOutput: "Media import report",
          progress: nil,
          options: [.init("--id", value: "ID", "Portable asset/clip ID."),
                    .init("--name", value: "NAME", "Display name."),
                    .init("--at", value: "SECONDS", "Cue/clip start.", minimum: 0, defaultValue: "0"),
                    .init("--duration", value: "SECONDS", "Placed duration.", minimum: 0.000001),
                    .init("--character", value: "N", "Place audio on a character.", minimum: 1, maximum: 10),
                    .init("--track", value: "ID", "Place on an existing media/image track."),
                    .init("--background", "Place visual media on the Scenes track."),
                    .init("--kind", value: "KIND", "Audio clip kind.", allowed: ["imported", "microphone", "speech"]),
                    .init("--lipsync", "Analyze imported character audio for mouth timing."),
                    .init("--crop", value: "MODE", "Background crop.", allowed: ["cover", "fit", "stretch", "tile"]),
                    .init("--x", value: "N", "Visual cue x position.", defaultValue: "0.5"),
                    .init("--y", value: "N", "Visual cue y position.", defaultValue: "0.5"),
                    .init("--scale", value: "N", "Visual cue scale.", minimum: 0.000001, defaultValue: "0.3"),
                    .init("--rotation", value: "DEGREES", "Visual cue rotation.", defaultValue: "0"),
                    jsonOption]),
    .init(name: "pack", summary: "Create a portable Studio archive.",
          usage: "banny pack <project.bs> <out.bs.zip> [--json]", mutatesProject: false,
          acceptsArchive: false, jsonOutput: "PackageReport", progress: nil, options: [jsonOption]),
    .init(name: "unpack", summary: "Extract an archive for typed editing.",
          usage: "banny unpack <in.bs.zip> <project.bs> [--json]", mutatesProject: true,
          acceptsArchive: true, jsonOutput: "PackageReport", progress: nil, options: [jsonOption]),
    .init(name: "import", summary: "Convert a web v1 production to native v4.",
          usage: "banny import <v1.json> <out.bs> [--json]", mutatesProject: true,
          acceptsArchive: false, jsonOutput: "ImportReport", progress: nil, options: [jsonOption]),
    .init(name: "stylize", summary: "Convert an image to Banny pixel art.",
          usage: "banny stylize <in.png> <out.png> [gridWidth] [dither] [--json]",
          mutatesProject: false, acceptsArchive: true, jsonOutput: "StylizeReport", progress: nil,
          options: [jsonOption]),
    .init(name: "shimmer", summary: "Turn sparse point lights in a still into a subtle looping GIF.",
          usage: "banny shimmer <in.png> <out.gif> [--frames N] [--delay S] [--scale N] [--json]",
          mutatesProject: false, acceptsArchive: true, jsonOutput: "ShimmerEncoder.Report",
          progress: nil,
          options: [.init("--frames", value: "N", "Animation frame count.",
                          minimum: 2, maximum: 24, defaultValue: "8"),
                    .init("--delay", value: "SECONDS", "Delay per frame.",
                          minimum: 0.04, maximum: 2, defaultValue: "0.14"),
                    .init("--scale", value: "N", "Point-light detection scale.",
                          minimum: 1, maximum: 8, defaultValue: "2"),
                    jsonOption]),
    .init(name: "skill", summary: "Print or install the current AI production skill.",
          usage: "banny skill [print|install] [--target codex|claude|all] [--json]",
          mutatesProject: true, acceptsArchive: true, jsonOutput: "SkillInstallReport", progress: nil,
          options: [.init("--target", value: "TARGET", "Install target.", allowed: ["codex", "claude", "all"]), jsonOption]),
]

/// The `room` commands, which only exist when the room server is in the build.
///
/// These were committed by accident: their `LiveRoomHostLimits` default came in
/// with an unrelated feature while the Package.swift that declares BannyLive
/// stayed deliberately uncommitted, so a clean clone of this repository could
/// not build the CLI at all. Guarding them keeps the room workstream working
/// wherever it is checked out, without its absence breaking everyone else.
#if canImport(BannyLive)
private let roomCommandCapabilities: [CommandCapability] = [
    .init(name: "room contract", summary: "Describe the deprecated participant-local AI protocol.",
          usage: "banny room contract [--json]", mutatesProject: false,
          acceptsArchive: false, jsonOutput: "RoomAgentContractReport", progress: nil,
          options: [jsonOption]),
    .init(name: "room serve", summary: "Host live rooms and the bundled room site.",
          usage: "banny room serve [--storage DIR] [--bind HOST] [--port N] [--allowed-host HOST ...] [--director built-in|ollama] [--director-url URL] [--director-model MODEL] [--max-rooms N] [--max-storage-bytes BYTES] [--json]",
          mutatesProject: true, acceptsArchive: false,
          jsonOutput: "RoomServeReadyReport",
          progress: "Prints one ready record, then serves until the process stops.",
          options: [
            .init("--storage", value: "DIR", "Persistent room/package directory.",
                  defaultValue: "~/Library/Application Support/Banny Studio/Live Rooms"),
            .init("--bind", value: "HOST", "Listener address; use a TLS reverse proxy when exposed.",
                  defaultValue: "127.0.0.1"),
            .init("--allowed-host", value: "HOST",
                  "Repeatable exact Host authority accepted from browsers/proxies; required for non-loopback binds."),
            .init("--director", value: "PROVIDER",
                  "Host-wide browser-character director.",
                  allowed: ["built-in", "ollama"], defaultValue: "built-in"),
            .init("--director-url", value: "URL",
                  "Ollama HTTP numeric-loopback origin; valid only with --director ollama.",
                  defaultValue: "http://127.0.0.1:11434"),
            .init("--director-model", value: "MODEL",
                  "Installed Ollama model; valid only with --director ollama.",
                  defaultValue: "llama3.2:3b"),
            .init("--max-rooms", value: "N",
                  "Maximum persisted or currently hosted rooms; reaching it rejects creation without deleting recordings.",
                  minimum: 1,
                  defaultValue: String(LiveRoomHostLimits.defaultMaximumRooms)),
            .init("--max-storage-bytes", value: "BYTES",
                  "Maximum logical bytes admitted under room storage; symlink targets are never counted or followed.",
                  minimum: 1,
                  defaultValue: String(LiveRoomHostLimits.defaultMaximumStorageBytes)),
            .init("--port", value: "N", "Listener port (0 asks the system to choose).",
                  minimum: 0, maximum: 65535, defaultValue: "7330"),
            jsonOption,
          ]),
    .init(name: "room join", summary: "Deprecated legacy bridge for a participant-local AI; prefer browser join.",
          usage: "banny room join <room-url> --agent URL --name NAME --character FILE [--credentials-file FILE] [options]",
          mutatesProject: false, acceptsArchive: false,
          jsonOutput: "RoomJoinReadyReport",
          progress: "Skipped local-agent decisions are written as JSONL to stderr with --json.",
          options: [
            .init("--agent", value: "URL", required: true,
                  "Local AI origin; numeric loopback is required by default."),
            .init("--credentials-file", value: "FILE",
                  "Private 0600 JSON containing identity, invite, and/or agent_token."),
            .init("--agent-token", value: "TOKEN",
                  "Deprecated inline local-AI bearer; prefer --credentials-file."),
            .init("--name", value: "NAME", required: true, "Participant display name."),
            .init("--character", value: "FILE", required: true,
                  "avatar.json or a sanitized character .bannytrack."),
            .init("--identity", value: "ID", "Identity used by an allowlisted room."),
            .init("--invite", value: "TOKEN",
                  "Deprecated inline invitation; prefer --credentials-file."),
            .init("--allow-remote-agent",
                  "Explicitly allow a non-loopback HTTPS AI endpoint."),
            .init("--allow-insecure-room",
                  "Explicitly allow plaintext HTTP to a non-loopback room host."),
            jsonOption,
          ]),
]
#else
private let roomCommandCapabilities: [CommandCapability] = []
#endif

let commandCapabilities: [CommandCapability] =
    coreCommandCapabilities + roomCommandCapabilities

func helpCommand(_ args: [String]) throws {
    var options = CLIOptions(args)
    let json = try options.flag("--json")
    let name = options.tokens.joined(separator: " ")
    guard !name.isEmpty else {
        try options.finish(usage: "banny help [command] [--json]")
        if json { try printJSON(commandCapabilities) } else { print(cliUsage) }
        return
    }
    guard let command = commandCapabilities.first(where: { $0.name == name }) else {
        throw CLIError.invalid("unknown command for help: \(name)")
    }
    if json {
        try printJSON(command)
    } else {
        print("\(command.summary)\n\nusage: \(command.usage)")
        if !command.options.isEmpty {
            print("\noptions:")
            for option in command.options {
                let spelling = option.value.map { "\(option.name) \($0)" } ?? option.name
                print("  \(spelling) — \(option.description)")
            }
        }
    }
}

func capabilitiesCommand(_ args: [String]) throws {
    var options = CLIOptions(args)
    _ = try options.flag("--json")
    try options.finish(usage: "banny capabilities [--json]")
    let value = ProductionCapabilities(
        contractVersion: BannyCLIContract.contractVersion,
        cliVersion: BannyCLIContract.version,
        schemaSHA256: sha256Hex(Data(showSchemaJSON.utf8)),
        platform: "macOS",
        limits: .init(maxCharacters: 10, starterCharacters: "1...10"),
        automation: .init(
            successOutput: "--json writes one JSON value to stdout",
            errorOutput: "argument and operation failures write an error envelope to stderr",
            validationOutput: "validation diagnostics are a JSON array on stdout and use a nonzero status when errors exist",
            progressOutput: "--progress-json writes JSON Lines to stderr",
            exitCodes: [
                "success": 0,
                "operation_failed": 1,
                "invalid_argument_or_usage": 2,
                "validation_failed": 3,
                "not_a_package": 4,
            ]),
        project: .init(
            schemaVersion: BannyCLIContract.schemaVersion,
            directoryExtension: ".bs",
            archiveExtension: ".bs.zip",
            strictUnknownFields: true,
            mutationFormat: BannyCLIContract.patchStandard,
            atomicDocumentWrites: true,
            optimisticConcurrency: "SHA-256 of the current show.json via --if-hash"),
        commands: commandCapabilities,
        vocabulary: .init(
            bodies: Body.allCases.map(\.rawValue),
            eventCodes: EventCode.allCases.map(\.rawValue),
            eventGroups: EventGroup.allCases.map(\.rawValue),
            voiceRecipes: VoiceRecipe.Preset.allCases.map(\.rawValue),
            mouthShapes: MouthShape.allCases.map(\.rawValue),
            mediaMasks: MediaMask.allCases.map(\.rawValue),
            crops: ["cover", "fit", "stretch", "tile"],
            markerKinds: TimelineMarker.Kind.allCases.map(\.rawValue),
            markerColors: TimelineMarker.Color.allCases.map(\.rawValue),
            trackKinds: PortableTrack.Kind.allCases.map(\.rawValue)))
    try printJSON(value)
}

func schemaCommand(_ args: [String]) throws {
    let usage = "banny schema [--compact|--example]"
    var options = CLIOptions(args)
    let example = try options.flag("--example")
    let compact = try options.flag("--compact")
    _ = try options.flag("--json")
    try options.finish(usage: usage)
    guard !(example && compact) else {
        throw CLIError.invalid("choose only one of --compact or --example")
    }
    if example {
        print(try ShowJSONCodec.encode(document: .starter(characterCount: 2)))
        return
    }
    let data = Data(showSchemaJSON.utf8)
    // Parse before printing so a malformed embedded schema can never become
    // part of the public machine contract.
    let object = try JSONSerialization.jsonObject(with: data)
    let writingOptions: JSONSerialization.WritingOptions = compact
        ? [.sortedKeys]
        : [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try JSONSerialization.data(
        withJSONObject: object,
        options: writingOptions),
                 as: UTF8.self))
}

/// JSON Schema Draft 2020-12 for the canonical v4 document. Semantic rules
/// involving package files and cross-reference uniqueness remain the job of
/// `banny validate`; object keys and value shapes are fully described here.
let showSchemaJSON = #"""
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://banny.studio/schema/show-v4.json",
  "title": "Banny Studio Show",
  "description": "Canonical show.json schema. Unknown fields are rejected by the CLI and Studio advanced editor.",
  "type": "object",
  "additionalProperties": false,
  "required": ["version", "stage"],
  "properties": {
    "version": {"const": 4},
    "stage": {"$ref": "#/$defs/stage"},
    "assets": {"type": "array", "items": {"$ref": "#/$defs/asset"}, "default": []},
    "show": {"type": "array", "items": {"$ref": "#/$defs/showSegment"}, "default": []},
    "settings": {"$ref": "#/$defs/settings"}
  },
  "$defs": {
    "nonnegative": {"type": "number", "minimum": 0},
    "normalized": {"type": "number", "minimum": 0, "maximum": 1},
    "nullableNumber": {"type": ["number", "null"]},
    "nullableString": {"type": ["string", "null"]},
    "presence": {
      "type": "object",
      "additionalProperties": false,
      "required": ["t", "visible"],
      "properties": {
        "t": {"$ref": "#/$defs/nonnegative"},
        "visible": {"type": "boolean"},
        "fade": {"type": "number", "minimum": 0, "maximum": 10}
      }
    },
    "pivot": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "x": {"$ref": "#/$defs/normalized"},
        "y": {"$ref": "#/$defs/normalized"}
      }
    },
    "placement": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "x": {"type": "number"},
        "y": {"type": "number"},
        "scale": {"type": "number", "exclusiveMinimum": 0},
        "rotation": {"type": "number"}
      }
    },
    "camera": {
      "type": "object",
      "additionalProperties": false,
      "required": ["x", "y", "zoom"],
      "properties": {
        "x": {"type": "number"},
        "y": {"type": "number"},
        "zoom": {"type": "number", "exclusiveMinimum": 0}
      }
    },
    "mediaColor": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "red": {"type": "number"},
        "green": {"type": "number"},
        "blue": {"type": "number"}
      }
    },
    "appearance": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "tint": {"$ref": "#/$defs/mediaColor"},
        "tintAmount": {"$ref": "#/$defs/normalized"},
        "brightness": {"type": "number"},
        "contrast": {"type": "number"},
        "saturation": {"type": "number"},
        "outline": {"type": "number", "minimum": 0},
        "shadow": {"$ref": "#/$defs/normalized"},
        "cleanup": {"$ref": "#/$defs/normalized"}
      }
    },
    "playback": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "trimStart": {"$ref": "#/$defs/nonnegative"},
        "trimEnd": {"$ref": "#/$defs/nullableNumber"},
        "rate": {"type": "number", "exclusiveMinimum": 0},
        "reverse": {"type": "boolean"},
        "loop": {"type": "boolean"},
        "freezeAt": {"$ref": "#/$defs/nullableNumber"},
        "phaseOffset": {"$ref": "#/$defs/nonnegative"}
      }
    },
    "imageCue": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id", "assetID", "start", "dur", "from"],
      "properties": {
        "id": {"type": "string", "minLength": 1},
        "assetID": {"type": "string", "minLength": 1},
        "start": {"$ref": "#/$defs/nonnegative"},
        "dur": {"type": "number", "exclusiveMinimum": 0},
        "from": {"$ref": "#/$defs/placement"},
        "to": {"anyOf": [{"$ref": "#/$defs/placement"}, {"type": "null"}]},
        "speed": {"type": "number"},
        "rotationSpeed": {"type": "number"},
        "playback": {"$ref": "#/$defs/playback"},
        "appearance": {"$ref": "#/$defs/appearance"},
        "mask": {"enum": ["none", "rectangle", "roundedRectangle", "circle"]},
        "maskRadius": {"type": "number", "minimum": 0, "maximum": 0.5},
        "pivot": {"$ref": "#/$defs/pivot"},
        "label": {"$ref": "#/$defs/nullableString"}
      }
    },
    "fx": {
      "type": "object",
      "additionalProperties": false,
      "required": ["gain", "low", "mid", "high", "reverb", "pan"],
      "properties": {
        "gain": {"type": "number", "minimum": 0},
        "low": {"type": "number"},
        "mid": {"type": "number"},
        "high": {"type": "number"},
        "reverb": {"$ref": "#/$defs/normalized"},
        "pan": {
          "anyOf": [
            {"enum": ["follow", "narrow", "wide"]},
            {"type": "number", "minimum": -1, "maximum": 1}
          ]
        }
      }
    },
    "mouthCue": {
      "type": "object",
      "additionalProperties": false,
      "required": ["start", "dur", "shape"],
      "properties": {
        "start": {"$ref": "#/$defs/nonnegative"},
        "dur": {"type": "number", "exclusiveMinimum": 0},
        "shape": {"enum": ["closed", "tight", "open"]}
      }
    },
    "audioClip": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id", "start", "dur", "srcDur"],
      "properties": {
        "id": {"type": "string", "minLength": 1},
        "name": {"type": "string"},
        "kind": {"enum": ["imported", "microphone", "speech"]},
        "start": {"$ref": "#/$defs/nonnegative"},
        "dur": {"type": "number", "exclusiveMinimum": 0},
        "offset": {"$ref": "#/$defs/nonnegative"},
        "srcDur": {"type": "number", "exclusiveMinimum": 0},
        "fx": {"$ref": "#/$defs/fx"},
        "fxOverride": {"type": ["boolean", "null"]},
        "fadeIn": {"$ref": "#/$defs/nonnegative"},
        "fadeOut": {"$ref": "#/$defs/nonnegative"},
        "mouthCues": {"type": "array", "items": {"$ref": "#/$defs/mouthCue"}}
      }
    },
    "voiceRecipe": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "preset": {"enum": ["natural", "warmNarrator", "tinyHero", "deepVillain", "radio", "robot", "dream", "ghost", "alien", "double", "arcade", "custom"]},
        "name": {"type": "string"},
        "flavor": {"$ref": "#/$defs/normalized"},
        "pitchCents": {"type": "number", "minimum": -2400, "maximum": 2400},
        "low": {"type": "number", "minimum": -24, "maximum": 24},
        "mid": {"type": "number", "minimum": -24, "maximum": 24},
        "high": {"type": "number", "minimum": -24, "maximum": 24},
        "compression": {"$ref": "#/$defs/normalized"},
        "distortion": {"enum": ["none", "alienChatter", "cosmicInterference", "goldenPi", "radioTower", "speechWaves"]},
        "distortionMix": {"$ref": "#/$defs/normalized"},
        "delayTime": {"type": "number", "minimum": 0.001, "maximum": 0.5},
        "delayFeedback": {"type": "number", "minimum": 0, "maximum": 0.8},
        "delayMix": {"$ref": "#/$defs/normalized"},
        "reverbSpace": {"enum": ["smallRoom", "mediumRoom", "largeRoom", "mediumHall", "largeHall", "plate", "chamber", "cathedral"]},
        "reverbMix": {"$ref": "#/$defs/normalized"},
        "doubling": {"$ref": "#/$defs/normalized"},
        "outputGainDB": {"type": "number", "minimum": -24, "maximum": 12}
      }
    },
    "speechVoice": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "voiceIdentifier": {"$ref": "#/$defs/nullableString"},
        "recipe": {"$ref": "#/$defs/voiceRecipe"},
        "automaticMouth": {"type": "boolean"}
      }
    },
    "subtitle": {
      "type": "object",
      "additionalProperties": false,
      "required": ["text", "start", "dur"],
      "properties": {
        "text": {"type": "string"},
        "start": {"$ref": "#/$defs/nonnegative"},
        "dur": {"type": "number", "exclusiveMinimum": 0},
        "x": {"$ref": "#/$defs/normalized"},
        "y": {"$ref": "#/$defs/normalized"},
        "size": {"type": "number", "minimum": 0.2, "maximum": 4},
        "width": {"type": "number", "minimum": 0.08, "maximum": 1},
        "follow": {"type": "boolean"}
      }
    },
    "performanceEvent": {
      "oneOf": [
        {
          "type": "object",
          "additionalProperties": false,
          "required": ["t", "code", "down"],
          "properties": {
            "t": {"$ref": "#/$defs/nonnegative"},
            "code": {"enum": ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Comma", "Slash", "Period", "KeyM", "KeyT", "KeyB", "KeyJ", "KeyF", "KeyD", "RotateLeft", "RotateRight", "ZoomIn", "ZoomOut", "SpinReset", "ZoomReset"]},
            "down": {"type": "boolean"}
          }
        },
        {
          "type": "object",
          "additionalProperties": false,
          "required": ["t", "outfit"],
          "properties": {
            "t": {"$ref": "#/$defs/nonnegative"},
            "outfit": {
              "type": "object",
              "additionalProperties": false,
              "required": ["slot"],
              "properties": {
                "slot": {"type": "integer"},
                "name": {"$ref": "#/$defs/nullableString"}
              }
            }
          }
        },
        {
          "type": "object",
          "additionalProperties": false,
          "required": ["t", "motion"],
          "properties": {
            "t": {"$ref": "#/$defs/nonnegative"},
            "motion": {
              "type": "object",
              "additionalProperties": false,
              "properties": {
                "speed": {"$ref": "#/$defs/nullableNumber"},
                "rotationSpeed": {"$ref": "#/$defs/nullableNumber"},
                "wobble": {"$ref": "#/$defs/nullableNumber"},
                "size": {"$ref": "#/$defs/nullableNumber"}
              }
            }
          }
        }
      ]
    },
    "reactionDefinition": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id", "name", "dur", "events"],
      "properties": {
        "id": {"type": "string", "minLength": 1},
        "name": {"type": "string"},
        "dur": {"type": "number", "exclusiveMinimum": 0},
        "events": {"type": "array", "items": {"$ref": "#/$defs/performanceEvent"}}
      }
    },
    "reactionInstance": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id", "reactionID", "start", "dur"],
      "properties": {
        "id": {"type": "string", "minLength": 1},
        "reactionID": {"type": "string", "minLength": 1},
        "start": {"$ref": "#/$defs/nonnegative"},
        "dur": {"type": "number", "exclusiveMinimum": 0},
        "intensity": {"type": "number", "minimum": 0, "maximum": 4}
      }
    },
    "startPose": {
      "type": "object",
      "additionalProperties": false,
      "required": ["x"],
      "properties": {
        "x": {"type": "number"},
        "depth": {"type": "number"},
        "face": {"enum": [-1, 1]},
        "spin": {"type": "number"},
        "zoom": {"type": "number", "exclusiveMinimum": 0}
      }
    },
    "character": {
      "type": "object",
      "additionalProperties": false,
      "required": ["body"],
      "properties": {
        "body": {"enum": ["orange", "original", "pink", "alien"]},
        "x": {"type": "number"},
        "depth": {"type": "number"},
        "size": {"type": "number", "exclusiveMinimum": 0},
        "face": {"enum": [-1, 1]},
        "baseOutfit": {"type": "object", "additionalProperties": {"type": "string"}},
        "subs": {"type": "array", "items": {"$ref": "#/$defs/subtitle"}},
        "voicePitch": {"type": "number"},
        "voiceSpeed": {"type": "number", "exclusiveMinimum": 0},
        "speechVoice": {"$ref": "#/$defs/speechVoice"},
        "clips": {"type": "array", "items": {"$ref": "#/$defs/audioClip"}},
        "events": {"type": "array", "items": {"$ref": "#/$defs/performanceEvent"}},
        "reactions": {"type": "array", "items": {"$ref": "#/$defs/reactionInstance"}},
        "armedGroups": {"type": "array", "uniqueItems": true, "items": {"enum": ["move", "depth", "tilt", "talk", "blink", "jump", "spin", "zoom"]}},
        "name": {"type": "string"},
        "trackFx": {"$ref": "#/$defs/fx"},
        "recStart": {"anyOf": [{"$ref": "#/$defs/startPose"}, {"type": "null"}]},
        "speed": {"type": "number"},
        "rotationSpeed": {"type": "number"},
        "rotationPivot": {"anyOf": [{"$ref": "#/$defs/pivot"}, {"type": "null"}]},
        "wobble": {"type": "number"},
        "hidden": {"type": "boolean"},
        "locked": {"type": "boolean"},
        "muted": {"type": "boolean"},
        "solo": {"type": "boolean"},
        "presence": {"type": "array", "items": {"$ref": "#/$defs/presence"}}
      }
    },
    "audioTrack": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id"],
      "properties": {
        "id": {"type": "string", "minLength": 1},
        "name": {"type": "string"},
        "fx": {"$ref": "#/$defs/fx"},
        "clips": {"type": "array", "items": {"$ref": "#/$defs/audioClip"}},
        "cues": {"type": "array", "items": {"$ref": "#/$defs/imageCue"}},
        "hidden": {"type": "boolean"},
        "locked": {"type": "boolean"},
        "visualLayer": {"enum": ["behindCast", "inFrontOfCast"]},
        "muted": {"type": "boolean"},
        "solo": {"type": "boolean"},
        "presence": {"type": "array", "items": {"$ref": "#/$defs/presence"}}
      }
    },
    "imageTrack": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id", "name"],
      "properties": {
        "id": {"type": "string", "minLength": 1},
        "name": {"type": "string"},
        "hidden": {"type": "boolean"},
        "locked": {"type": "boolean"},
        "visualLayer": {"enum": ["behindCast", "inFrontOfCast"]},
        "cues": {"type": "array", "items": {"$ref": "#/$defs/imageCue"}},
        "presence": {"type": "array", "items": {"$ref": "#/$defs/presence"}}
      }
    },
    "backgroundCue": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id", "assetID", "start", "dur", "crop"],
      "properties": {
        "id": {"type": "string", "minLength": 1},
        "assetID": {"type": "string", "minLength": 1},
        "start": {"$ref": "#/$defs/nonnegative"},
        "dur": {"type": "number", "exclusiveMinimum": 0},
        "crop": {"enum": ["cover", "fit", "stretch", "tile"]},
        "label": {"$ref": "#/$defs/nullableString"},
        "camFrom": {"anyOf": [{"$ref": "#/$defs/camera"}, {"type": "null"}]},
        "camTo": {"anyOf": [{"$ref": "#/$defs/camera"}, {"type": "null"}]}
      }
    },
    "backgroundTrack": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id", "name"],
      "properties": {
        "id": {"type": "string", "minLength": 1},
        "name": {"type": "string"},
        "hidden": {"type": "boolean"},
        "locked": {"type": "boolean"},
        "cues": {"type": "array", "items": {"$ref": "#/$defs/backgroundCue"}},
        "presence": {"type": "array", "items": {"$ref": "#/$defs/presence"}}
      }
    },
    "lightState": {
      "type": "object",
      "additionalProperties": false,
      "required": ["x", "y"],
      "properties": {
        "x": {"type": "number"},
        "y": {"type": "number"},
        "intensity": {"$ref": "#/$defs/normalized"},
        "size": {"type": "number", "exclusiveMinimum": 0}
      }
    },
    "legacyLight": {
      "type": "object",
      "additionalProperties": false,
      "required": ["x", "y"],
      "properties": {
        "x": {"type": "number"},
        "y": {"type": "number"}
      }
    },
    "lightCue": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id", "start", "dur", "from"],
      "properties": {
        "id": {"type": "string", "minLength": 1},
        "start": {"$ref": "#/$defs/nonnegative"},
        "dur": {"type": "number", "exclusiveMinimum": 0},
        "from": {"$ref": "#/$defs/lightState"},
        "to": {"anyOf": [{"$ref": "#/$defs/lightState"}, {"type": "null"}]},
        "label": {"$ref": "#/$defs/nullableString"}
      }
    },
    "lightTrack": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id", "name"],
      "properties": {
        "id": {"type": "string", "minLength": 1},
        "name": {"type": "string"},
        "hidden": {"type": "boolean"},
        "locked": {"type": "boolean"},
        "cues": {"type": "array", "items": {"$ref": "#/$defs/lightCue"}},
        "presence": {"type": "array", "items": {"$ref": "#/$defs/presence"}}
      }
    },
    "marker": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id"],
      "properties": {
        "id": {"type": "string", "minLength": 1},
        "name": {"type": "string"},
        "start": {"$ref": "#/$defs/nonnegative"},
        "kind": {"enum": ["marker", "section"]},
        "duration": {"$ref": "#/$defs/nonnegative"},
        "color": {"enum": ["orange", "blue", "green", "purple", "red", "gray"]}
      }
    },
    "legacyBackground": {
      "type": "object",
      "additionalProperties": false,
      "required": ["type", "file", "crop"],
      "properties": {
        "type": {"enum": ["image", "video"]},
        "file": {"type": "string"},
        "crop": {"enum": ["cover", "fit", "stretch", "tile"]}
      }
    },
    "stage": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "characters": {"type": "array", "items": {"$ref": "#/$defs/character"}},
        "reactionLibrary": {"type": "array", "items": {"$ref": "#/$defs/reactionDefinition"}},
        "audioTracks": {"type": "array", "items": {"$ref": "#/$defs/audioTrack"}},
        "imageTracks": {"type": "array", "items": {"$ref": "#/$defs/imageTrack"}},
        "backgroundTracks": {"type": "array", "minItems": 1, "maxItems": 1, "items": {"$ref": "#/$defs/backgroundTrack"}},
        "lightTracks": {"type": "array", "items": {"$ref": "#/$defs/lightTrack"}},
        "lights": {"type": "array", "items": {"$ref": "#/$defs/legacyLight"}},
        "cropAnchors": {"type": "array", "items": {"$ref": "#/$defs/nonnegative"}},
        "markers": {"type": "array", "items": {"$ref": "#/$defs/marker"}},
        "gScale": {"type": "number"},
        "gravity": {"type": "number", "exclusiveMinimum": 0},
        "gSize": {"type": "number", "exclusiveMinimum": 0},
        "wings": {"type": "number", "minimum": 0, "maximum": 1},
        "background": {"anyOf": [{"$ref": "#/$defs/legacyBackground"}, {"type": "null"}]},
        "rowOrder": {"type": "array", "items": {"type": "string"}}
      }
    },
    "asset": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id", "name", "kind", "file"],
      "properties": {
        "id": {"type": "string", "minLength": 1},
        "name": {"type": "string"},
        "kind": {"enum": ["image", "video"]},
        "file": {"type": "string", "minLength": 1}
      }
    },
    "showSegment": {
      "type": "object",
      "additionalProperties": false,
      "required": ["from", "to"],
      "properties": {
        "sceneID": {"type": "string"},
        "name": {"type": "string"},
        "from": {"$ref": "#/$defs/nonnegative"},
        "to": {"type": "number", "exclusiveMinimum": 0}
      }
    },
    "settings": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "activeScene": {"type": "integer", "minimum": 0},
        "lightSize": {"type": "number"},
        "frameW": {"type": "number", "exclusiveMinimum": 0},
        "frameH": {"type": "number", "exclusiveMinimum": 0}
      }
    }
  }
}
"""#
