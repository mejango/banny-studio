import Foundation
import BannyCore

/// Running a command-line agent from a sandboxed app.
///
/// Banny Studio is sandboxed, so it cannot spawn `claude` or `codex` directly —
/// `Process` is denied outright. The one sanctioned route is `NSUserUnixTask`,
/// which runs scripts the *user* has installed in the app's Application Scripts
/// directory. That directory is outside the sandbox's writable area on purpose:
/// the app can execute what is there but can never put anything there itself,
/// so nothing runs that the user did not deliberately install.
///
/// The bridge scripts are one line each. `install` below is the text to hand
/// the user; the app only ever reads it out.
enum LiveScriptRunner {
    #if os(macOS)
    static var directory: URL? {
        try? FileManager.default.url(for: .applicationScriptsDirectory,
                                     in: .userDomainMask, appropriateFor: nil, create: false)
    }

    static func isInstalled(_ name: String) -> Bool {
        directory.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path) }
            ?? false
    }

    /// Bumped whenever the bridge script itself has to change. An older bridge
    /// still runs, but silently behaves differently — ignoring the chosen model,
    /// or letting the agent roam the home folder — so the app asks for a
    /// reinstall rather than lie about what is happening.
    static let bridgeVersion = "banny-bridge 6"

    /// Where the picture will be. The app writes this token into the prompt and
    /// the bridge swaps in the real path, because only the bridge knows it: the
    /// file is written by the script, in the script's own scratch folder.
    static let imageToken = "@SET@"

    static func isCurrent(_ name: String) -> Bool {
        guard let directory,
              let text = try? String(contentsOf: directory.appendingPathComponent(name),
                                     encoding: .utf8)
        else { return false }
        return text.contains(bridgeVersion)
    }

    /// Feeds `prompt` to the script on stdin and returns everything it printed.
    /// `model` is passed as the one argument; empty means the agent's default.
    /// `image`, when given, travels on stdin ahead of the prompt and is written
    /// out by the bridge; `imageToken` in the prompt becomes its path. The agent
    /// therefore only ever opens a file in its own scratch folder. Pointing it
    /// at the picture where the picture actually lives cannot work: a backdrop
    /// is unpacked into the app's container, and reading an app's container is
    /// precisely what macOS interrupts to ask about.
    static func run(script name: String, prompt: String, model: String,
                    extraArguments: [String] = [], image: Data? = nil) async throws -> String {
        guard let directory else {
            throw LiveModelError.scriptMissing(name: name, directory: "~/Library/Application Scripts")
        }
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LiveModelError.scriptMissing(name: name, directory: directory.path)
        }

        // Files, not pipes. NSUserUnixTask hands these handles to a helper
        // process over XPC, and a pipe's ends are live objects being read and
        // written on other threads while that encoding happens — which is what
        // took the app down mid-Play. Plain files have none of that: nothing to
        // drain concurrently, no buffer to deadlock on when a prompt or an
        // answer outgrows 64K, and no handle whose state can change underneath
        // the encoder.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("banny-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let inURL = scratch.appendingPathComponent("prompt")
        let outURL = scratch.appendingPathComponent("answer")
        let errURL = scratch.appendingPathComponent("complaints")
        var stdin = Data()
        if let image {
            stdin += Data("banny-image:\(image.base64EncodedString())\n".utf8)
        }
        stdin += Data(prompt.utf8)
        try stdin.write(to: inURL)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)

        let task = try NSUserUnixTask(url: url)
        task.standardInput = try FileHandle(forReadingFrom: inURL)
        task.standardOutput = try FileHandle(forWritingTo: outURL)
        task.standardError = try FileHandle(forWritingTo: errURL)

        do {
            try await task.execute(withArguments: [model] + extraArguments)
        } catch {
            throw LiveModelError.scriptFailed(error.localizedDescription)
        }

        let answer = String(decoding: (try? Data(contentsOf: outURL)) ?? Data(), as: UTF8.self)
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let why = String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self)
            throw LiveModelError.scriptFailed(why.isEmpty
                ? "\(name) printed nothing." : String(why.suffix(300)))
        }
        return answer
    }

    /// The shell command that installs a bridge, ready to paste into Terminal.
    static func install(_ shape: LiveModelEndpoint.Shape) -> String? {
        guard let name = shape.scriptName else { return nil }
        let folder = directory?.path ?? "~/Library/Application Scripts/<bundle id>"
        // No login shell. Sourcing the user's shell startup pulled in whatever
        // their setup touches — including other apps' support folders — and
        // macOS raised a "data from other apps" prompt against Banny Studio,
        // which is merely the process responsible for it. The install command
        // resolves the agent's real path once, in the user's own terminal,
        // and the bridge then runs it directly with a minimal environment.
        // $1 is the model, empty for the agent's own default.
        //
        // The `cd` matters. A command-line agent treats its working directory as
        // the project it is working on and reads around in it, and the task
        // helper starts wherever it likes — often the home folder. That makes
        // the agent wander into Desktop and Documents, and macOS raises those
        // permission prompts against Banny Studio, which spawned it. Writing a
        // scene needs no files at all, so it runs in an empty scratch folder.
        let tool: String, invocation: String
        switch shape {
        case .claudeCode:
            tool = "claude"
            // "\$@" carries any extra flags the app passes — used to hand the
            // set-reading pass a Read-only tool list so looking at one picture
            // cannot become anything else.
            invocation = #""\$AGENT" -p --output-format text \$M "\$@""#
        case .codex:
            tool = "codex"
            invocation = #""\$AGENT" exec \$M "\$@" -"#
        case .openAIChat:
            return nil
        }
        let flag = shape == .claudeCode ? "--model" : "-m"
        // The heredoc is unquoted on purpose: AGENT and BIN are resolved now,
        // in the user's shell, and baked into the script.
        return """
        mkdir -p "\(folder)"
        AGENT="$(command -v \(tool))" || { echo "\(tool) is not on your PATH"; exit 1; }
        BIN="$(dirname "$AGENT")"
        NODE="$(command -v node 2>/dev/null)" && BIN="$BIN:$(dirname "$NODE")"
        cat > "\(folder)/\(name)" <<SH
        #!/bin/sh
        # \(bridgeVersion)
        PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
        export PATH
        AGENT="$AGENT"
        # One folder per run. Sharing one meant two calls raced: the set read
        # and the cast read overlap, and whichever started second deleted the
        # picture the first was still looking at.
        SCRATCH="\\${TMPDIR:-/tmp}/banny-live-agent.\\$\\$"
        mkdir -p "\\$SCRATCH" && cd "\\$SCRATCH" || exit 1
        trap 'rm -f "\\$SCRATCH"/set.png; rmdir "\\$SCRATCH" 2>/dev/null' EXIT
        [ -n "\\$1" ] && M="\(flag) \\$1" || M=""
        shift 2>/dev/null || true
        # The set arrives as the first line of stdin, base64, and is written
        # here. Nothing outside this folder is ever opened, so looking at the
        # picture needs no permission wherever the picture really lives.
        IFS= read -r L
        case "\\$L" in
        banny-image:*) printf %s "\\${L#banny-image:}" | base64 -d > set.png; L="" ;;
        esac
        { printf '%s\\n' "\\$L"; cat; } | sed "s|@SET@|\\$SCRATCH/set.png|g" | \(invocation)
        SH
        chmod +x "\(folder)/\(name)"
        """
    }
    #endif
}

extension LiveModelEndpoint {
    /// The narrowest session that can still do the job.
    ///
    /// A command-line agent started plainly is a full working session: it loads
    /// the user's MCP servers, hooks and plugins, and those reach into other
    /// applications' data — which macOS then asks about, naming Banny Studio.
    /// Writing dialogue needs none of it. Only the tools the task actually
    /// requires are allowed, and no MCP servers are loaded at all.
    static func confinement(needsWeb: Bool, needsFiles: Bool) -> [String] {
        // A plain session loads the user's hooks, plugins and editor
        // integrations, and hunts for IDEs in other applications' support
        // folders — which macOS then asks about, naming Banny Studio. Writing
        // dialogue needs none of it, so the session is given its own empty
        // settings as well as its own empty MCP config.
        var flags = ["--mcp-config", #"{"mcpServers":{}}"#, "--strict-mcp-config",
                     "--settings",
                     #"{"hooks":{},"enabledPlugins":{},"enableAllProjectMcpServers":false}"#]
        var tools: [String] = []
        if needsWeb { tools += ["WebFetch"] }
        if needsFiles { tools += ["Read"] }
        // Never an empty list: the flag wants a value, and a task with nothing
        // to fetch still has nothing to gain from a shell.
        flags += ["--allowedTools"] + (tools.isEmpty ? ["Read"] : tools)
        return flags
    }

    /// One way in for the director, whichever kind of model this is.
    func beats(for prompt: String) async throws -> [LiveBeat] {
        #if os(macOS)
        if let script = shape.scriptName {
            // Only a scene carrying links has any business on the network.
            let hasLinks = prompt.contains("WHAT THEY HAVE BEEN LOOKING AT")
            let flags = shape == .claudeCode
                ? LiveModelEndpoint.confinement(needsWeb: hasLinks, needsFiles: false)
                : []
            return try LiveBeatBatch.parse(
                await LiveScriptRunner.run(script: script, prompt: prompt,
                                           model: model, extraArguments: flags))
        }
        #endif
        return try await LiveModelClient(endpoint: self).beats(for: prompt)
    }

    /// True when this model is ready to run right now.
    var isReachable: Bool {
        #if os(macOS)
        if let script = shape.scriptName { return LiveScriptRunner.isInstalled(script) }
        #endif
        return true
    }
}
