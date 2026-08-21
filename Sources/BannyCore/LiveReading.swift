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

        public init(name: String, body: String, prompt: String) {
            self.name = name
            self.body = body
            self.prompt = prompt
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
                              premise: String = "") -> String {
        let given = premise.trimmingCharacters(in: .whitespacesAndNewlines)
        let scene = given.isEmpty
            ? "Say what kind of place this is and what is happening in it, in one "
              + "or two sentences, as a premise for a scene."
            : "The scene has already been described as: \"\(given)\". Keep that "
              + "word for word as the premise."

        return """
        Look at the image at \(imagePath). It is the set for a wordless scene \
        performed by pixel-art characters.

        \(scene)

        Then cast \(wanted) people who belong in this place. For each, give a \
        name that suits them, a body from exactly this list — original, orange, \
        pink, alien — and one line on who they are and how they behave in a \
        room. Make them different from each other: different rhythms, different \
        reasons for being here, at least one who is not the clever one.

        Nobody is described by their clothes; the studio dresses them.

        Return ONLY this JSON, no prose:
        {"premise":"...",
         "cast":[{"name":"...","body":"original","prompt":"..."}]}
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
                    prompt: person.prompt)
            }
            if !reading.cast.isEmpty { return reading }
        }
        return nil
    }

    /// The reading as cast members, keeping anything the director already set.
    public func castMembers(mergingInto existing: [LiveCastMember]) -> [LiveCastMember] {
        cast.enumerated().map { index, person in
            let known = existing.first { $0.name == person.name }
            return LiveCastMember(
                name: person.name,
                body: Body(rawValue: person.body) ?? Body.allCases[index % Body.allCases.count],
                outfit: known?.outfit ?? [:],
                prompt: known?.prompt.isEmpty == false ? known!.prompt : person.prompt,
                mayChangeWardrobe: known?.mayChangeWardrobe ?? false,
                speed: known?.speed ?? 110,
                outfitIsChosen: known?.outfitIsChosen ?? false)
        }
    }
}
