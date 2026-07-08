import Foundation

/// One-way importer for web v1 studio JSON (the staging/exports files):
/// top-level `{studio, bg, audio}` with base64 data-URL media.
public enum V1Importer {

    public struct Result {
        public var document: ShowDocument
        /// clipId → decoded audio bytes + file extension.
        public var audioFiles: [String: (data: Data, ext: String)]
        /// sceneId → decoded background media.
        public var backgroundFiles: [String: (data: Data, ext: String)]
    }

    public enum ImportError: Error, Equatable {
        case notV1JSON
    }

    public static func importStudio(json: Data) throws -> Result {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let studio = root["studio"] as? [String: Any],
              let rawScenes = studio["scenes"] as? [[String: Any]] else {
            throw ImportError.notV1JSON
        }

        let bgMap = root["bg"] as? [String: Any] ?? [:]
        let audioMap = root["audio"] as? [String: Any] ?? [:]

        var audioFiles: [String: (data: Data, ext: String)] = [:]
        for (key, value) in audioMap {
            guard key.hasPrefix("audio:"), let url = value as? String,
                  let media = decodeDataURL(url) else { continue }
            audioFiles[String(key.dropFirst("audio:".count))] = media
        }

        var backgroundFiles: [String: (data: Data, ext: String)] = [:]
        var scenes: [Scene] = []
        for (i, raw) in rawScenes.enumerated() {
            let id = raw["id"] as? String ?? "scene\(i)"
            var state = SceneState()
            if let s = raw["state"] as? [String: Any] {
                state = importSceneState(s)
            }
            // Background: v1 keeps the spec (and inline media) in the bg map keyed by scene id.
            if let spec = bgMap["bg:\(id)"] as? [String: Any] {
                let crop = Crop(rawValue: spec["crop"] as? String ?? "") ?? .cover
                let type = spec["type"] as? String
                if let dataURL = spec["data"] as? String, let media = decodeDataURL(dataURL) {
                    backgroundFiles[id] = media
                    let file = "\(id).\(media.ext)"
                    state.background = type == "video" ? .video(file: file, crop: crop)
                                                       : .image(file: file, crop: crop)
                }
                // type "scene" (built-in preset) had an empty catalog in the source build — dropped.
            }
            scenes.append(Scene(id: id, name: raw["name"] as? String ?? "Scene \(i + 1)", state: state))
        }

        var show: [ShowSegment] = []
        for seg in studio["show"] as? [[String: Any]] ?? [] {
            guard let sceneID = seg["scene"] as? String else { continue }
            show.append(ShowSegment(sceneID: sceneID,
                                    name: seg["name"] as? String ?? "",
                                    from: num(seg["from"]),
                                    to: num(seg["to"])))
        }

        let doc = ShowDocument(
            scenes: scenes,
            show: show,
            settings: Settings(activeScene: (studio["active"] as? NSNumber)?.intValue ?? 0,
                               lightSize: num(studio["lightSize"])))
        return Result(document: doc, audioFiles: audioFiles, backgroundFiles: backgroundFiles)
    }

    // MARK: - Scene state

    private static func importSceneState(_ s: [String: Any]) -> SceneState {
        var state = SceneState()
        state.gScale = num(s["gScale"], default: 0.6)
        state.gravity = num(s["gravity"], default: 1)
        state.gSize = num(s["gSize"], default: 1)
        state.cropAnchors = (s["cropAnchors"] as? [Any])?.map { num($0) } ?? []
        // v1 lights are stage px; normalize against the reference 1600x900 stage, clamp to 0..1.
        state.lights = (s["lights"] as? [[String: Any]])?.map {
            Light(x: min(1, max(0, num($0["x"]) / 1600)), y: min(1, max(0, num($0["y"]) / 900)))
        } ?? []
        state.characters = (s["bannys"] as? [[String: Any]] ?? []).enumerated().map { i, b in
            importCharacter(b, index: i)
        }
        state.audioTracks = (s["audioTracks"] as? [[String: Any]] ?? []).enumerated().map { i, t in
            AudioTrack(id: t["id"] as? String ?? "track\(i)",
                       name: t["name"] as? String ?? "Audio",
                       fx: importFx(t["fx"], default: .defaultTrack),
                       clips: importClips(t["clips"]))
        }
        return state
    }

    private static func importCharacter(_ b: [String: Any], index: Int) -> Character {
        var events: [PerfEvent] = []
        for e in b["events"] as? [[String: Any]] ?? [] {
            let t = num(e["t"])
            if e["code"] as? String == "outfit" {
                events.append(.outfit(t: t, slot: (e["cat"] as? NSNumber)?.intValue ?? 0,
                                      name: e["name"] as? String))
            } else if let code = EventCode(rawValue: e["code"] as? String ?? "") {
                events.append(.key(t: t, code: code, down: e["type"] as? String == "d"))
            }
        }
        events.sort { $0.t < $1.t }

        var baseOutfit: [Int: String] = [:]
        for (k, v) in b["sel"] as? [String: Any] ?? [:] {
            if let slot = Int(k), let name = v as? String { baseOutfit[slot] = name }
        }

        var recStart: StartPose?
        if let rs = b["recStart"] as? [String: Any] {
            recStart = StartPose(x: normX(num(rs["x"])), depth: num(rs["depth"]),
                                 face: (rs["face"] as? NSNumber)?.intValue ?? 1)
        }

        let armed = (b["arm"] as? [String])?.compactMap(EventGroup.init(rawValue:))

        return Character(
            body: Body(rawValue: b["body"] as? String ?? "") ?? .orange,
            x: normX(num(b["x"], default: 0.5)),
            depth: num(b["depth"]),
            size: num(b["size"], default: 1),
            face: (b["face"] as? NSNumber)?.intValue ?? 1,
            baseOutfit: baseOutfit,
            subs: (b["subs"] as? [[String: Any]])?.map {
                Subtitle(text: $0["text"] as? String ?? "", start: num($0["start"]), dur: num($0["dur"]))
            } ?? [],
            clips: importClips(b["clips"]),
            events: events,
            armedGroups: armed.map(Set.init) ?? Set(EventGroup.allCases),
            name: b["name"] as? String ?? "",
            trackFx: importFx(b["fx"], default: .defaultTrack),
            recStart: recStart)
        // speed/wobble: v1 never persisted them; Character defaults (320/7) match every v1 replay.
    }

    private static func importClips(_ raw: Any?) -> [AudioClip] {
        (raw as? [[String: Any]])?.compactMap { c in
            guard let id = c["id"] as? String else { return nil }
            let dur = num(c["dur"])
            return AudioClip(id: id,
                             name: c["name"] as? String ?? "",
                             start: num(c["start"]),
                             dur: dur,
                             offset: num(c["offset"]),
                             srcDur: num(c["srcDur"], default: dur),
                             fx: importFx(c["fx"], default: .defaultClip))
        } ?? []
    }

    private static func importFx(_ raw: Any?, default def: Fx) -> Fx {
        guard let f = raw as? [String: Any] else { return def }
        var pan = def.pan
        if let s = f["pan"] as? String {
            switch s {
            case "follow": pan = .follow
            case "narrow": pan = .narrow
            case "wide": pan = .wide
            default: break
            }
        } else if let n = f["pan"] as? NSNumber {
            pan = .value(n.doubleValue)
        }
        return Fx(gain: num(f["gain"], default: 1), low: num(f["low"]), mid: num(f["mid"]),
                  high: num(f["high"]), reverb: num(f["reverb"]), pan: pan)
    }

    // MARK: - Helpers

    /// v1 x values are fractions, but legacy saves stored absolute px (>1.5) against the
    /// web's 900px fallback width.
    private static func normX(_ x: Double) -> Double {
        x > 1.5 ? x / 900 : x
    }

    private static func num(_ v: Any?, default def: Double = 0) -> Double {
        (v as? NSNumber)?.doubleValue ?? def
    }

    static func decodeDataURL(_ url: String) -> (data: Data, ext: String)? {
        guard url.hasPrefix("data:"),
              let comma = url.firstIndex(of: ",") else { return nil }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
        let payload = String(url[url.index(after: comma)...])
        let parts = header.split(separator: ";")
        let mime = parts.first.map(String.init) ?? "application/octet-stream"
        let data: Data?
        if parts.contains("base64") {
            data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        } else {
            data = payload.removingPercentEncoding.map { Data($0.utf8) }
        }
        guard let data else { return nil }
        return (data, ext(forMime: mime))
    }

    static func ext(forMime mime: String) -> String {
        switch mime.lowercased() {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/aac": return "m4a"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/ogg": return "ogg"
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/svg+xml": return "svg"
        case "video/mp4": return "mp4"
        case "video/webm": return "webm"
        case "video/quicktime": return "mov"
        default: return "bin"
        }
    }
}
