import XCTest
@testable import BannyCLI

/// The installable skill is generated from the reviewed repository sources.
final class SkillMirrorTests: XCTestCase {
    func testEveryRepositorySkillFileMatchesTheBinaryEmbedding() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sourceRoot = root.appendingPathComponent("skills/banny-studio")
        let files = [
            "SKILL.md", "agents/openai.yaml",
            "references/media-stage.md", "references/performance.md",
            "references/project-format.md", "references/speech-audio.md",
        ]
        XCTAssertEqual(Set(files), Set(embeddedSkillFiles.keys))
        for path in files {
            let source = try String(
                contentsOf: sourceRoot.appendingPathComponent(path), encoding: .utf8)
            XCTAssertEqual(source, embeddedSkillFiles[path], "stale embedded file: \(path)")
        }
    }
}
