import Foundation

/// A scene and a company, read off the backdrop.
///
/// Describing a room you have already chosen a picture of is work the picture
/// can do. Leaving the premise and the cast empty is therefore a legitimate way
/// to start: the agent looks at the set, says what kind of place it is and who
/// would be in it, and that becomes an ordinary editable brief — not a hidden
/// decision. Everything it proposes is shown back and can be rewritten.
public struct LiveReading: Codable, Equatable, Sendable {
    public struct Person: Codable, Equatable, Sendable {
        public var name: String
        public var body: String
        public var prompt: String
        /// Slot number to catalog item name. Optional so readings made by an
        /// older prompt still decode and fall back to the studio's house look.
        public var outfit: [String: String]?

        public init(name: String, body: String, prompt: String,
                    outfit: [String: String]? = nil) {
            self.name = name
            self.body = body
            self.prompt = prompt
            self.outfit = outfit
        }
    }

    public var premise: String
    public var cast: [Person]

    public init(premise: String = "", cast: [Person] = []) {
        self.premise = premise
        self.cast = cast
    }

    /// What the agent is asked, once, when the brief is left blank.
    public static func prompt(imagePath: String, wanted: Int = 3,
                              premise: String = "",
                              wardrobe: [String: [String]] = [:]) -> String {
        let given = premise.trimmingCharacters(in: .whitespacesAndNewlines)
        let scene = given.isEmpty
            ? "Write a playable two- or three-sentence scene premise, not an image caption. "
              + "Ground it in visible evidence from this backdrop. Name one of the cast "
              + "members you are about to create, what they specifically want here and now, "
              + "what or who blocks them, and what becomes possible or costly if they act. "
              + "End with one dramatic question the scene can build and eventually answer. "
              + "Do not merely say that people are talking, waiting, hanging out, or working."
            : "The scene has already been described as: \"\(given)\". Keep that "
              + "word for word as the premise."

        let slotNames = [2: "backside", 3: "necklace", 4: "head", 6: "glasses",
                         8: "legs", 9: "suit", 10: "suit bottom", 11: "suit top",
                         12: "head top", 13: "hand"]
        let clothes = wardrobe.keys.compactMap(Int.init).sorted().compactMap { slot -> String? in
            guard let items = wardrobe["\(slot)"], !items.isEmpty else { return nil }
            return "  \(slot) \(slotNames[slot] ?? "slot"): \(items.joined(separator: ", "))"
        }.joined(separator: "\n")
        let dressing = clothes.isEmpty
            ? "Leave outfit empty; no wardrobe catalog was provided."
            : """
              Interpret the visible backdrop as part of casting. Dress each person in a few \
              items that make them feel native to this particular place, activity, and story. \
              Use only exact item names from the catalog below, at most one item per slot. \
              Do not merely give everyone a loud or generic costume. A hand item is a prop: \
              use one only when the setting or the person's immediate business earns it. \
              When you choose one, make the person's prompt say what they are doing with it \
              or why it matters, so the scene writer receives an opportunity rather than decoration.

              WARDROBE CATALOG
              \(clothes)
              """

        return """
        Look at the image at \(imagePath). It is the set for a wordless scene \
        performed by pixel-art characters.

        \(scene)

        Then cast \(wanted) people who belong in this place. For each, give a \
        name that suits them, a body from exactly this list — original, orange, \
        pink, alien — and one line on who they are and how they behave in a \
        room. Make them different from each other: different rhythms, different \
        reasons for being here, at least one who is not the clever one.

        \(dressing)

        Return ONLY this JSON, no prose:
        {"premise":"...",
         "cast":[{"name":"...","body":"original","prompt":"...",
                  "outfit":{"12":"exact-catalog-item","11":"exact-catalog-item"}}]}
        """
    }

    /// Pulls a reading out of whatever the agent said, ignoring anything that
    /// is not usable rather than failing the lot.
    public static func parse(_ answer: String) -> LiveReading? {
        for object in LiveJSON.objects(in: answer) {
            guard var reading = try? JSONDecoder()
                .decode(LiveReading.self, from: Data(object.utf8)) else { continue }
            // A name is all that is required. An invented body is not a reason
            // to lose the person — the studio picks one by position — and
            // dropping them quietly shrinks the company, which is the whole
            // family of bugs this scene has already been through: a cast of one
            // leaves the model writing a two-hander and half of it on the floor.
            reading.cast = reading.cast.compactMap { person in
                let name = person.name.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return nil }
                return LiveReading.Person(
                    name: name,
                    body: Body(rawValue: person.body.lowercased())?.rawValue ?? "",
                    prompt: person.prompt,
                    outfit: person.outfit)
            }
            if !reading.cast.isEmpty { return reading }
        }
        return nil
    }

    /// The reading as cast members, keeping anything the director already set.
    public func castMembers(mergingInto existing: [LiveCastMember],
                            wardrobe: [String: [String]] = [:]) -> [LiveCastMember] {
        cast.enumerated().map { index, person in
            let known = existing.first { $0.name == person.name }
            let proposed = person.outfit ?? [:]
            // The prompt receives the real catalog, but its answer is still
            // untrusted. An invented item never reaches the renderer.
            let usable = wardrobe.isEmpty ? proposed : proposed.filter { slot, item in
                wardrobe[slot]?.contains(item) == true
            }
            let outfit = known?.outfit.isEmpty == false ? known!.outfit : usable
            return LiveCastMember(
                name: person.name,
                body: Body(rawValue: person.body) ?? Body.allCases[index % Body.allCases.count],
                outfit: outfit,
                prompt: known?.prompt.isEmpty == false ? known!.prompt : person.prompt,
                mayChangeWardrobe: known?.mayChangeWardrobe ?? false,
                speed: known?.speed ?? 110,
                outfitIsChosen: known?.outfitIsChosen ?? !usable.isEmpty)
        }
    }
}
