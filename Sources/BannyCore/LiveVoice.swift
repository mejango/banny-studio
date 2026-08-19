import Foundation

/// Tics the writing must not have, removed before anyone says them.
///
/// A prompt is a request, not a guarantee: asked often enough, a model will
/// still reach for its favourite shapes. The worst offender is the antithesis —
/// "That's not cheating. That's continuity." — which sounds like writing but is
/// a reflex, and which every character in a scene will start doing at once.
///
/// The fix is not to drop the line. The second half is the line; the negation
/// in front of it is the tic. Strike the negation and what is left is what the
/// character actually meant.
public enum LiveVoice {
    /// Openers that begin an antithesis, and the pronoun they belong to.
    private static let openers = [
        "that's not ", "that is not ", "that isn't ",
        "it's not ", "it is not ", "it isn't ",
        "this is not ", "this isn't ",
        "you're not ", "you are not ", "you aren't ",
        "we're not ", "we are not ", "we aren't ",
        "i'm not ", "i am not ",
    ]

    /// Sentence starts that complete one.
    private static let answers = [
        "that's ", "that is ", "it's ", "it is ", "this is ",
        "you're ", "you are ", "we're ", "we are ", "i'm ", "i am ",
    ]

    /// Splits into clauses. A full stop ends one; so does the dash that stands
    /// in for one; and so does a comma when what follows it opens an answer —
    /// "That's not thirst, that's a signal" is the same construction wearing a
    /// smaller mark, and splitting only on full stops walks straight past it.
    private static func clauses(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            // An em or en dash between two clauses does the work of a full stop.
            if c == "—" || c == "–" {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                i = line.index(after: i)
                continue
            }
            current.append(c)
            if c == "." || c == "!" || c == "?" {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else if c == "," {
                // Only where an answer begins; every other comma is just a
                // comma, and breaking on those would shred ordinary lines.
                let rest = line[line.index(after: i)...]
                    .drop(while: { $0 == " " })
                if answers.contains(where: { rest.lowercased().hasPrefix($0) }) {
                    out.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                }
            }
            i = line.index(after: i)
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out.append(tail) }
        return out.filter { !$0.isEmpty }
    }

    /// Restores a capital where a clause now begins a sentence.
    private static func capitalised(_ clause: String) -> String {
        guard let first = clause.first, first.isLowercase else { return clause }
        return clause.replacingCharacters(
            in: clause.startIndex...clause.startIndex,
            with: String(first).uppercased())
    }

    private static func begins(_ clause: String, withAnyOf list: [String]) -> Bool {
        let lower = clause.lowercased()
        return list.contains { lower.hasPrefix($0) }
    }

    /// True when this line is the construction we never want to hear.
    public static func isAntithesis(_ line: String) -> Bool {
        let parts = clauses(line)
        guard parts.count >= 2 else { return false }
        for (a, b) in zip(parts, parts.dropFirst())
        where begins(a, withAnyOf: openers) && begins(b, withAnyOf: answers) {
            return true
        }
        return false
    }

    /// The line with any antithesis reduced to the half that says something.
    /// A line without one comes back exactly as it was.
    public static func tidy(_ line: String) -> String {
        let parts = clauses(line)
        guard parts.count >= 2 else { return line }

        // Which clauses are the negation half of a reversal.
        var dropped = Set<Int>()
        for index in parts.indices.dropLast()
        where begins(parts[index], withAnyOf: openers)
           && begins(parts[index + 1], withAnyOf: answers) {
            dropped.insert(index)
        }
        // Nothing to do is the common case, and it must be a no-op: a filter
        // that quietly repunctuates ordinary dialogue is worse than the tic.
        guard !dropped.isEmpty else { return line }

        var rebuilt: [String] = []
        for (index, clause) in parts.enumerated() where !dropped.contains(index) {
            var piece = clause
            // A comma was leaning on the clause just removed; it now ends a
            // sentence instead.
            if dropped.contains(index + 1), piece.hasSuffix(",") {
                piece.removeLast()
                piece += "."
            }
            let startsSentence = rebuilt.last.map {
                $0.hasSuffix(".") || $0.hasSuffix("!") || $0.hasSuffix("?")
            } ?? true
            if startsSentence { piece = capitalised(piece) }
            rebuilt.append(piece)
        }
        let tidied = rebuilt.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        // Never hand back nothing.
        return tidied.isEmpty ? line : tidied
    }
}
