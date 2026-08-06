import Foundation

// The repository skill is the source of truth. tools/embed-skill.swift turns
// that directory into GeneratedSkillResources.swift for the single binary.

private struct SkillPrintReport: Codable {
    let name: String
    let content: String
    let files: [String]
}

private struct SkillInstallReport: Codable {
    let target: String
    let destinations: [String]
    let files: [String]
}

func skillCommand(_ args: [String]) throws {
    let action = args.first ?? "print"
    var options = CLIOptions(args.isEmpty ? [] : Array(args.dropFirst()))
    let json = try options.flag("--json")
    switch action {
    case "print":
        try options.finish(usage: "banny skill print [--json]")
        let markdown = embeddedSkillFiles["SKILL.md"]!
        if json {
            try printJSON(SkillPrintReport(
                name: "banny-studio", content: markdown,
                files: embeddedSkillFiles.keys.sorted()))
        } else {
            print(markdown, terminator: "")
        }
    case "install":
        let target = try options.value("--target") ?? "all"
        try options.finish(
            usage: "banny skill install [--target codex|claude|all] [--json]")
        guard ["codex", "claude", "all"].contains(target) else {
            throw CLIError.invalid("--target must be codex, claude, or all")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var destinations: [(url: URL, codex: Bool)] = []
        if target == "claude" || target == "all" {
            destinations.append((
                home.appendingPathComponent(".claude/skills/banny-studio"),
                false))
        }
        if target == "codex" || target == "all" {
            let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
                .map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".codex")
            destinations.append((
                codexHome.appendingPathComponent("skills/banny-studio"),
                true))
        }
        var installedFiles = Set<String>()
        for destination in destinations {
            for (path, contents) in embeddedSkillFiles.sorted(by: { $0.key < $1.key }) {
                if path.hasPrefix("agents/") && !destination.codex { continue }
                let fileURL = destination.url.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try contents.write(to: fileURL, atomically: true, encoding: .utf8)
                installedFiles.insert(path)
            }
            if !json { print("installed \(destination.url.path)") }
        }
        if json {
            try printJSON(SkillInstallReport(
                target: target,
                destinations: destinations.map(\.url.path),
                files: installedFiles.sorted()))
        }
    default:
        throw CLIError.usage(
            "banny skill [print|install] [--target codex|claude|all] [--json]")
    }
}
