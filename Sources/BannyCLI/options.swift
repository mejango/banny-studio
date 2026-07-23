import Foundation
import BannyCore

// Strict option parsing prevents automation typos from changing intent.

/// Small strict option reader. Every command consumes its supported flags and
/// calls `finish`; misspellings therefore fail instead of silently changing
/// production intent.
struct CLIOptions {
    private(set) var tokens: [String]

    init(_ tokens: [String]) {
        self.tokens = tokens
    }

    mutating func flag(_ name: String) throws -> Bool {
        let matches = tokens.indices.filter { tokens[$0] == name }
        guard matches.count <= 1 else {
            throw CLIError.invalid("option \(name) was provided more than once")
        }
        guard let index = matches.first else { return false }
        tokens.remove(at: index)
        return true
    }

    mutating func value(_ name: String) throws -> String? {
        let matches = tokens.indices.filter { tokens[$0] == name }
        guard matches.count <= 1 else {
            throw CLIError.invalid("option \(name) was provided more than once")
        }
        guard let index = matches.first else { return nil }
        guard tokens.indices.contains(index + 1) else {
            throw CLIError.invalid("option \(name) requires a value")
        }
        let value = tokens[index + 1]
        tokens.removeSubrange(index...index + 1)
        return value
    }

    mutating func pair(_ name: String) throws -> (String, String)? {
        let matches = tokens.indices.filter { tokens[$0] == name }
        guard matches.count <= 1 else {
            throw CLIError.invalid("option \(name) was provided more than once")
        }
        guard let index = matches.first else { return nil }
        guard tokens.indices.contains(index + 2) else {
            throw CLIError.invalid("option \(name) requires two values")
        }
        let pair = (tokens[index + 1], tokens[index + 2])
        tokens.removeSubrange(index...index + 2)
        return pair
    }

    mutating func requiredValue(_ name: String) throws -> String {
        guard let value = try value(name) else {
            throw CLIError.invalid("missing required option \(name)")
        }
        return value
    }

    mutating func int(_ name: String) throws -> Int? {
        guard let raw = try value(name) else { return nil }
        guard let value = Int(raw) else {
            throw CLIError.invalid("\(name) requires an integer; found \(raw)")
        }
        return value
    }

    mutating func double(_ name: String) throws -> Double? {
        guard let raw = try value(name) else { return nil }
        guard let value = Double(raw), value.isFinite else {
            throw CLIError.invalid("\(name) requires a finite number; found \(raw)")
        }
        return value
    }

    func finish(usage: String) throws {
        guard tokens.isEmpty else {
            throw CLIError.invalid(
                "unsupported argument\(tokens.count == 1 ? "" : "s"): "
                    + tokens.joined(separator: " ")
                    + "\nusage: \(usage)")
        }
    }
}

func newMediaID(prefix: String) -> String {
    "\(prefix)-\(UUID().uuidString.lowercased())"
}

func validatedCharacterIndex(_ oneBased: Int, in document: ShowDocument) throws -> Int {
    let index = oneBased - 1
    guard document.stage.characters.indices.contains(index) else {
        throw CLIError.invalid(
            "character \(oneBased) does not exist; valid range is 1...\(document.stage.characters.count)")
    }
    return index
}
