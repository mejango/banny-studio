import Foundation

/// How Live mode reaches a model.
///
/// Banny Studio runs sandboxed, so it cannot launch `claude`, `codex` or any
/// other command-line agent as a subprocess — the sandbox forbids executing
/// binaries outside the app bundle. It can open network connections, so every
/// model is reached over HTTP — in practice a model server on the same machine,
/// such as LM Studio.
public struct LiveModelEndpoint: Codable, Equatable, Sendable, Identifiable {
    public enum Shape: String, Codable, Sendable {
        /// The OpenAI chat shape, which LM Studio and vLLM both speak.
        case openAIChat
        /// The `claude` CLI, reached through a user-installed bridge script.
        case claudeCode
        /// The `codex` CLI, likewise.
        case codex

        /// Script shapes run a command-line agent instead of opening a socket.
        /// A sandboxed app may only execute scripts the user has installed in
        /// its Application Scripts directory, so each has a fixed filename.
        public var scriptName: String? {
            switch self {
            case .claudeCode: return "banny-claude.sh"
            case .codex: return "banny-codex.sh"
            case .openAIChat: return nil
            }
        }

        /// Models worth offering for this agent, as (label, value to pass).
        /// An empty value means "whatever the agent is already configured to
        /// use" — the right default, and the only honest one for Codex, whose
        /// model names live in the user's own `~/.codex/config.toml`.
        public var suggestedModels: [(label: String, value: String)] {
            switch self {
            case .claudeCode:
                // Aliases rather than dated IDs: `claude --model` resolves each
                // to the current release, so these do not go stale.
                return [("Default", ""), ("Opus", "opus"), ("Sonnet", "sonnet"),
                        ("Fable", "fable"), ("Haiku", "haiku")]
            case .codex:
                // Codex model names live in the user's own config and move
                // often, so these are offered as suggestions beside Default
                // and Custom rather than as the whole truth.
                return [("Default", ""), ("GPT-5.6 Sol", "gpt-5.6-sol"),
                        ("GPT-5.5", "gpt-5.5"), ("GPT-5.4", "gpt-5.4"),
                        ("GPT-5.4 mini", "gpt-5.4-mini")]
            case .openAIChat:
                return []
            }
        }
    }

    public var id: String { name }
    public var name: String
    public var baseURL: URL
    public var model: String
    public var shape: Shape
    /// Sent as a bearer token when present. Local servers rarely need one.
    public var apiKey: String?

    public init(name: String, baseURL: URL, model: String,
                shape: Shape, apiKey: String? = nil) {
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.shape = shape
        self.apiKey = apiKey
    }

    /// The models worth offering by default. All local: two command-line
    /// agents the user very likely already has, and three model servers.
    public static func presets() -> [LiveModelEndpoint] {
        [
            // An empty model means the agent's own configured default.
            LiveModelEndpoint(name: "Claude Code",
                              baseURL: URL(string: "script://claude")!,
                              model: "", shape: .claudeCode),
            LiveModelEndpoint(name: "Codex",
                              baseURL: URL(string: "script://codex")!,
                              model: "", shape: .codex),
            LiveModelEndpoint(name: "LM Studio",
                              baseURL: URL(string: "http://127.0.0.1:1234")!,
                              model: "local-model", shape: .openAIChat),
        ]
    }

    var requestURL: URL {
        switch shape {
        case .openAIChat: return baseURL.appendingPathComponent("v1/chat/completions")
        default: return baseURL.appendingPathComponent("api/generate")
        }
    }

    func body(prompt: String) throws -> Data {
        switch shape {
        case .openAIChat:
            return try JSONSerialization.data(withJSONObject: [
                "model": model, "temperature": 0.9, "stream": false,
                "messages": [["role": "user", "content": prompt]],
            ])
        default:
            return try JSONSerialization.data(withJSONObject: [
                "model": model, "prompt": prompt, "stream": false,
                // Sampling is deliberately warm: a party should surprise us.
                "options": ["temperature": 0.9],
            ])
        }
    }

    func text(from data: Data) throws -> String {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        switch shape {
        case .openAIChat:
            guard let choices = root?["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let s = message["content"] as? String else {
                throw LiveModelError.unreadableAnswer
            }
            return s
        default:
            guard let s = root?["response"] as? String else {
                throw LiveModelError.unreadableAnswer
            }
            return s
        }
    }
}

public enum LiveModelError: LocalizedError, Equatable {
    case unreachable(String)
    case unreadableAnswer
    case noBeats(String)
    case scriptMissing(name: String, directory: String)
    case scriptFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .unreachable(detail):
            return "Could not reach the model server. \(detail)"
        case .unreadableAnswer:
            return "The model's answer was not in the expected shape."
        case let .noBeats(sample):
            return "The model did not return any beats. It said: \(sample)"
        case let .scriptMissing(name, directory):
            return "\(name) is not installed. Banny Studio is sandboxed, so it "
                 + "can only run agents through a script you place in \(directory)."
        case let .scriptFailed(detail):
            return "The agent did not answer. \(detail)"
        }
    }
}

/// Asks a model for the next stretch of script.
public struct LiveModelClient: Sendable {
    public var endpoint: LiveModelEndpoint
    private let session: URLSession

    public init(endpoint: LiveModelEndpoint, timeout: TimeInterval = 120) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: configuration)
    }

    public func beats(for prompt: String) async throws -> [LiveBeat] {
        var request = URLRequest(url: endpoint.requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = endpoint.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try endpoint.body(prompt: prompt)

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw LiveModelError.unreachable(error.localizedDescription)
        }
        return try LiveBeatBatch.parse(endpoint.text(from: data))
    }
}

extension LiveBeatBatch {
    /// Pulls a batch out of whatever a model said. Command-line agents print
    /// banners and progress before the answer, and chat models wrap it in
    /// prose or a code fence, so the JSON is found rather than assumed.
    public static func parse(_ answer: String) throws -> [LiveBeat] {
        for object in LiveJSON.objects(in: answer) {
            if let batch = try? JSONDecoder()
                .decode(LiveBeatBatch.self, from: Data(object.utf8)), !batch.beats.isEmpty {
                return batch.beats
            }
        }
        throw LiveModelError.noBeats(String(answer.suffix(300)))
    }
}

/// Models wrap JSON in prose, code fences and preambles however they like, and
/// command-line agents print their own braced banners first.
public enum LiveJSON {
    /// The outermost balanced object starting at `from`, ignoring braces that
    /// appear inside strings.
    public static func object(in text: String, from start: String.Index) -> String? {
        guard text[start] == "{" else { return nil }
        var depth = 0, inString = false, escaped = false
        var i = start
        while i < text.endIndex {
            let ch = text[i]
            if escaped { escaped = false }
            else if ch == "\\" && inString { escaped = true }
            else if ch == "\"" { inString.toggle() }
            else if !inString && ch == "{" { depth += 1 }
            else if !inString && ch == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...i]) }
            }
            i = text.index(after: i)
        }
        return nil
    }

    public static func firstObject(in text: String) -> String? {
        text.firstIndex(of: "{").flatMap { object(in: text, from: $0) }
    }

    /// Every top-level balanced object, in order, so a caller can try each
    /// until one decodes. Nested objects are skipped — only siblings are
    /// offered, which is what a banner-then-answer transcript looks like.
    public static func objects(in text: String) -> [String] {
        var found: [String] = []
        var i = text.startIndex
        while i < text.endIndex, found.count < 40 {
            guard text[i] == "{", let object = object(in: text, from: i) else {
                i = text.index(after: i)
                continue
            }
            found.append(object)
            i = text.index(i, offsetBy: object.count)
        }
        return found
    }
}
