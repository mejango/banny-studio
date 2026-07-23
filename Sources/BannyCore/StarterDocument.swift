public extension ShowDocument {
    /// Minimal valid document for `banny new`: N bannys spread across the
    /// stage facing center, everything else default. Agents edit show.json
    /// from here instead of authoring from a blank page.
    static func starter(characterCount: Int = 2) -> ShowDocument {
        let bodies: [Body] = [.orange, .pink, .alien, .original]
        let n = max(1, min(4, characterCount))
        let characters = (0..<n).map { i -> Character in
            let x = n == 1 ? 0.5 : 0.25 + 0.5 * Double(i) / Double(n - 1)
            return Character(body: bodies[i % bodies.count],
                             x: x,
                             face: x <= 0.5 ? 1 : -1,
                             name: "Banny \(i + 1)")
        }
        return ShowDocument(stage: SceneState(
            characters: characters,
            backgroundTracks: [
                BackgroundTrack(id: "scenes", name: "Scenes"),
            ],
            rowOrder: ["scenes"] + characters.indices.map { "c-\($0)" }))
    }
}
