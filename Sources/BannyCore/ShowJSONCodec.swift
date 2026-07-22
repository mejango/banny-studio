import Foundation

/// The canonical JSON bridge used by advanced editors and command-line tools.
///
/// `JSONDecoder` intentionally ignores unknown keys. That behavior is useful
/// for forward compatibility when opening a document, but surprising in a raw
/// editor: a misspelled field appears to apply and then silently disappears.
/// These editing decoders therefore reject keys the current schema cannot
/// round-trip.
public enum ShowJSONCodec {
    public struct UnsupportedDocumentVersionError: LocalizedError, Equatable, Sendable {
        public var version: Int

        public init(version: Int) {
            self.version = version
        }

        public var errorDescription: String? {
            "Advanced editing requires show schema version 3; found version \(version)."
        }
    }

    public struct UnsupportedFieldsError: LocalizedError, Equatable, Sendable {
        public var paths: [String]

        public init(paths: [String]) {
            self.paths = paths
        }

        public var errorDescription: String? {
            let noun = paths.count == 1 ? "field" : "fields"
            return "Unsupported JSON \(noun): \(paths.joined(separator: ", "))."
        }
    }

    public static func encode(document: ShowDocument) throws -> String {
        try encodeValue(document)
    }

    public static func encode(character: Character) throws -> String {
        try encodeValue(character)
    }

    public static func decodeDocument(_ text: String) throws -> ShowDocument {
        struct VersionEnvelope: Decodable { let version: Int }
        let version = try JSONDecoder().decode(VersionEnvelope.self,
                                               from: Data(text.utf8)).version
        guard version == 3 else {
            throw UnsupportedDocumentVersionError(version: version)
        }
        return try decodeValue(ShowDocument.self, from: text)
    }

    public static func decodeCharacter(_ text: String) throws -> Character {
        try decodeValue(Character.self, from: text)
    }

    /// A concise, coding-path-aware message suitable for an inline editor.
    public static func readableMessage(for error: Error) -> String {
        if let error = error as? LocalizedError, let message = error.errorDescription {
            return message
        }
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            return "Missing \(path(context.codingPath, appending: key)): \(context.debugDescription)"
        case DecodingError.typeMismatch(_, let context):
            return "Wrong value at \(path(context.codingPath)): \(context.debugDescription)"
        case DecodingError.valueNotFound(_, let context):
            return "Missing value at \(path(context.codingPath)): \(context.debugDescription)"
        case DecodingError.dataCorrupted(let context):
            return "Invalid value at \(path(context.codingPath)): \(context.debugDescription)"
        default:
            return error.localizedDescription
        }
    }

    private static func encodeValue<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return text
    }

    private static func decodeValue<T: Codable>(_ type: T.Type, from text: String) throws -> T {
        let data = Data(text.utf8)
        let value = try JSONDecoder().decode(type, from: data)

        // Compare only keys supplied by the user. Canonical output may add
        // omitted fields with defaults, which is valid and should not warn.
        let supplied = try JSONSerialization.jsonObject(with: data)
        let canonicalData = try JSONEncoder().encode(value)
        let canonical = try JSONSerialization.jsonObject(with: canonicalData)
        let unsupported = unsupportedPaths(in: supplied, canonical: canonical, path: "$")
        if !unsupported.isEmpty {
            throw UnsupportedFieldsError(paths: unsupported)
        }
        return value
    }

    private static func unsupportedPaths(in supplied: Any, canonical: Any,
                                         path: String) -> [String] {
        if let supplied = supplied as? [String: Any],
           let canonical = canonical as? [String: Any] {
            var paths: [String] = []
            for key in supplied.keys.sorted() {
                let childPath = path + "." + key
                guard let canonicalValue = canonical[key] else {
                    paths.append(childPath)
                    continue
                }
                paths.append(contentsOf: unsupportedPaths(in: supplied[key]!,
                                                          canonical: canonicalValue,
                                                          path: childPath))
            }
            return paths
        }
        if let supplied = supplied as? [Any], let canonical = canonical as? [Any] {
            return supplied.indices.flatMap { index in
                guard canonical.indices.contains(index) else { return ["\(path)[\(index)]"] }
                return unsupportedPaths(in: supplied[index], canonical: canonical[index],
                                        path: "\(path)[\(index)]")
            }
        }
        return []
    }

    private static func path(_ codingPath: [any CodingKey],
                             appending key: (any CodingKey)? = nil) -> String {
        var result = "$"
        for part in codingPath + (key.map { [$0] } ?? []) {
            if let index = part.intValue {
                result += "[\(index)]"
            } else {
                result += ".\(part.stringValue)"
            }
        }
        return result
    }
}
