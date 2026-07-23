import Foundation
import BannyCore

// Public machine contract for GUI-free and agent-driven production.

enum BannyCLIContract {
    static let version = "1.4.0"
    static let schemaVersion = 4
    static let patchStandard = "RFC 6902"
}

private struct CommandCapability: Codable {
    let name: String
    let mutatesProject: Bool
    let acceptsArchive: Bool
    let synopsis: String
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

    let cliVersion: String
    let platform: String
    let project: Project
    let commands: [CommandCapability]
    let vocabulary: Vocabulary
}

func capabilitiesCommand(_ args: [String]) throws {
    var options = CLIOptions(args)
    _ = try options.flag("--json")
    try options.finish(usage: "banny capabilities [--json]")
    let commands = [
        CommandCapability(name: "capabilities", mutatesProject: false, acceptsArchive: true,
                          synopsis: "banny capabilities --json"),
        CommandCapability(name: "schema", mutatesProject: false, acceptsArchive: true,
                          synopsis: "banny schema [--compact|--example]"),
        CommandCapability(name: "catalog", mutatesProject: false, acceptsArchive: true,
                          synopsis: "banny catalog [--json]"),
        CommandCapability(name: "voices", mutatesProject: false, acceptsArchive: true,
                          synopsis: "banny voices [--language PREFIX] [--json]"),
        CommandCapability(name: "new", mutatesProject: true, acceptsArchive: false,
                          synopsis: "banny new <folder.bs> [--characters N]"),
        CommandCapability(name: "migrate", mutatesProject: true, acceptsArchive: false,
                          synopsis: "banny migrate <folder.bs> [--dry-run] [--if-hash SHA256]"),
        CommandCapability(name: "validate", mutatesProject: false, acceptsArchive: true,
                          synopsis: "banny validate <show.bs> [--json]"),
        CommandCapability(name: "info", mutatesProject: false, acceptsArchive: true,
                          synopsis: "banny info <show.bs> [--json]"),
        CommandCapability(name: "preview", mutatesProject: false, acceptsArchive: true,
                          synopsis: "banny preview <show.bs> <out.png> [--t SECONDS]"),
        CommandCapability(name: "ship", mutatesProject: false, acceptsArchive: true,
                          synopsis: "banny ship <show.bs> <out.mp4> [tier] [--range FROM TO]"),
        CommandCapability(name: "apply", mutatesProject: true, acceptsArchive: false,
                          synopsis: "banny apply <folder.bs> <patch.json|-> [--dry-run] [--if-hash SHA256]"),
        CommandCapability(name: "tts", mutatesProject: true, acceptsArchive: false,
                          synopsis: "banny tts <folder.bs> --character N [--text TEXT|--captions] [options]"),
        CommandCapability(name: "lipsync", mutatesProject: true, acceptsArchive: false,
                          synopsis: "banny lipsync <folder.bs> --character N --clip ID [--clear]"),
        CommandCapability(name: "media probe", mutatesProject: false, acceptsArchive: true,
                          synopsis: "banny media probe <file> [--json]"),
        CommandCapability(name: "media import", mutatesProject: true, acceptsArchive: false,
                          synopsis: "banny media import <folder.bs> <file> [target/options]"),
        CommandCapability(name: "pack", mutatesProject: false, acceptsArchive: false,
                          synopsis: "banny pack <folder.bs> <out.bs>"),
        CommandCapability(name: "unpack", mutatesProject: true, acceptsArchive: true,
                          synopsis: "banny unpack <in.bs> <folder.bs>"),
        CommandCapability(name: "import", mutatesProject: true, acceptsArchive: false,
                          synopsis: "banny import <v1.json> <out.bannyshow>"),
        CommandCapability(name: "stylize", mutatesProject: false, acceptsArchive: true,
                          synopsis: "banny stylize <in.png> <out.png> [gridWidth] [dither]"),
        CommandCapability(name: "skill", mutatesProject: true, acceptsArchive: true,
                          synopsis: "banny skill [print|install] [--target codex|claude|all]"),
    ]
    let value = ProductionCapabilities(
        cliVersion: BannyCLIContract.version,
        platform: "macOS",
        project: .init(
            schemaVersion: BannyCLIContract.schemaVersion,
            directoryExtension: ".bs",
            archiveExtension: ".bs",
            strictUnknownFields: true,
            mutationFormat: BannyCLIContract.patchStandard,
            atomicDocumentWrites: true,
            optimisticConcurrency: "SHA-256 of the current show.json via --if-hash"),
        commands: commands,
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
        "visible": {"type": "boolean"}
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
        "dur": {"type": "number", "exclusiveMinimum": 0}
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
