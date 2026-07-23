import XCTest

/// skills/banny-studio/SKILL.md must stay in lockstep with the string
/// embedded in the banny binary (Sources/BannyCLI/skill.swift).
final class SkillMirrorTests: XCTestCase {
    func testRepoSkillMatchesEmbeddedSkill() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let mirror = try String(contentsOf: root.appendingPathComponent("skills/banny-studio/SKILL.md"), encoding: .utf8)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/BannyCLI/skill.swift"), encoding: .utf8)
        guard let open = source.range(of: "#\"\"\"\n"),
              let close = source.range(of: "\n\"\"\"#") else {
            return XCTFail("raw string literal not found in skill.swift")
        }
        let embedded = String(source[open.upperBound..<close.lowerBound])
        XCTAssertEqual(mirror, embedded,
                       "regenerate with: swift run banny skill print > skills/banny-studio/SKILL.md")
    }
}
