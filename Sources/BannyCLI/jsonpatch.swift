import Foundation
import CryptoKit
import BannyCore
import BannyRender

// RFC 6902 support lives in the testable CLI library, not the process wrapper.

/// Codable JSON tree used for RFC 6902 edits without erasing the distinction
/// between booleans, numbers, nulls, arrays, and objects.
enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct JSONPatchOperation: Decodable, Sendable {
    let op: String
    let path: String
    let from: String?
    let value: JSONValue?
    let valueWasProvided: Bool

    private enum CodingKeys: String, CodingKey {
        case op, path, from, value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        op = try container.decode(String.self, forKey: .op)
        path = try container.decode(String.self, forKey: .path)
        from = try container.decodeIfPresent(String.self, forKey: .from)
        valueWasProvided = container.contains(.value)
        value = valueWasProvided ? try container.decode(JSONValue.self, forKey: .value) : nil
    }
}

enum JSONPatchError: Error, CustomStringConvertible {
    case invalidDocument(String)
    case invalidPatch(String)
    case operation(Int, String)

    var description: String {
        switch self {
        case .invalidDocument(let message): return "invalid JSON document: \(message)"
        case .invalidPatch(let message): return "invalid JSON Patch: \(message)"
        case .operation(let index, let message):
            return "JSON Patch operation \(index + 1) failed: \(message)"
        }
    }
}

enum JSONPatchEngine {
    static func decode(_ data: Data) throws -> [JSONPatchOperation] {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw JSONPatchError.invalidPatch(error.localizedDescription)
        }
        guard let entries = raw as? [[String: Any]] else {
            throw JSONPatchError.invalidPatch("the root must be an array of operation objects")
        }
        let allowed = Set(["op", "path", "from", "value"])
        for (index, entry) in entries.enumerated() {
            let unknown = Set(entry.keys).subtracting(allowed)
            guard unknown.isEmpty else {
                throw JSONPatchError.operation(
                    index, "unsupported fields: \(unknown.sorted().joined(separator: ", "))")
            }
        }
        do {
            return try JSONDecoder().decode([JSONPatchOperation].self, from: data)
        } catch {
            throw JSONPatchError.invalidPatch(error.localizedDescription)
        }
    }

    static func apply(_ operations: [JSONPatchOperation],
                      to input: JSONValue) throws -> JSONValue {
        var document = input
        for (index, operation) in operations.enumerated() {
            do {
                document = try apply(operation, to: document)
            } catch let error as JSONPatchError {
                if case .operation = error { throw error }
                throw JSONPatchError.operation(index, error.description)
            } catch {
                throw JSONPatchError.operation(index, String(describing: error))
            }
        }
        return document
    }

    private static func apply(_ operation: JSONPatchOperation,
                              to document: JSONValue) throws -> JSONValue {
        let path = try tokens(for: operation.path)
        switch operation.op {
        case "add":
            guard operation.valueWasProvided, let value = operation.value else {
                throw JSONPatchError.invalidPatch("add requires value")
            }
            return try adding(value, at: path, in: document)
        case "remove":
            return try removing(at: path, from: document).document
        case "replace":
            guard operation.valueWasProvided, let replacement = operation.value else {
                throw JSONPatchError.invalidPatch("replace requires value")
            }
            _ = try value(at: path, in: document)
            return try replacing(with: replacement, at: path, in: document)
        case "move":
            guard let from = operation.from else {
                throw JSONPatchError.invalidPatch("move requires from")
            }
            let source = try tokens(for: from)
            if source == path { return document }
            if path.count > source.count && Array(path.prefix(source.count)) == source {
                throw JSONPatchError.invalidPatch("cannot move a value into one of its children")
            }
            let removal = try removing(at: source, from: document)
            return try adding(removal.removed, at: path, in: removal.document)
        case "copy":
            guard let from = operation.from else {
                throw JSONPatchError.invalidPatch("copy requires from")
            }
            return try adding(try value(at: tokens(for: from), in: document),
                              at: path, in: document)
        case "test":
            guard operation.valueWasProvided, let expected = operation.value else {
                throw JSONPatchError.invalidPatch("test requires value")
            }
            guard try value(at: path, in: document) == expected else {
                throw JSONPatchError.invalidPatch("test did not match at \(operation.path)")
            }
            return document
        default:
            throw JSONPatchError.invalidPatch("unsupported operation \"\(operation.op)\"")
        }
    }

    private static func tokens(for pointer: String) throws -> [String] {
        guard !pointer.isEmpty else { return [] }
        guard pointer.first == "/" else {
            throw JSONPatchError.invalidPatch("JSON Pointer must be empty or begin with /")
        }
        return try pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .map { component in
                let source = String(component)
                var result = ""
                var index = source.startIndex
                while index < source.endIndex {
                    if source[index] == "~" {
                        let next = source.index(after: index)
                        guard next < source.endIndex else {
                            throw JSONPatchError.invalidPatch("invalid ~ escape in JSON Pointer")
                        }
                        switch source[next] {
                        case "0": result.append("~")
                        case "1": result.append("/")
                        default:
                            throw JSONPatchError.invalidPatch("invalid ~ escape in JSON Pointer")
                        }
                        index = source.index(after: next)
                    } else {
                        result.append(source[index])
                        index = source.index(after: index)
                    }
                }
                return result
            }
    }

    private static func arrayIndex(_ token: String, count: Int,
                                   allowEnd: Bool, allowAppend: Bool) throws -> Int {
        if allowAppend, token == "-" { return count }
        guard !token.isEmpty,
              token == "0" || !token.hasPrefix("0"),
              let index = Int(token),
              index >= 0,
              index < count || (allowEnd && index == count) else {
            throw JSONPatchError.invalidPatch("invalid array index \"\(token)\"")
        }
        return index
    }

    private static func value(at path: [String], in document: JSONValue) throws -> JSONValue {
        guard let head = path.first else { return document }
        let tail = Array(path.dropFirst())
        switch document {
        case .object(let object):
            guard let child = object[head] else {
                throw JSONPatchError.invalidPatch("path member \"\(head)\" does not exist")
            }
            return try value(at: tail, in: child)
        case .array(let array):
            let index = try arrayIndex(head, count: array.count,
                                       allowEnd: false, allowAppend: false)
            return try value(at: tail, in: array[index])
        default:
            throw JSONPatchError.invalidPatch("path crosses a scalar value")
        }
    }

    private static func adding(_ value: JSONValue, at path: [String],
                               in document: JSONValue) throws -> JSONValue {
        guard let head = path.first else { return value }
        let tail = Array(path.dropFirst())
        switch document {
        case .object(var object):
            if tail.isEmpty {
                object[head] = value
            } else {
                guard let child = object[head] else {
                    throw JSONPatchError.invalidPatch("path member \"\(head)\" does not exist")
                }
                object[head] = try adding(value, at: tail, in: child)
            }
            return .object(object)
        case .array(var array):
            let index = try arrayIndex(head, count: array.count,
                                       allowEnd: tail.isEmpty, allowAppend: tail.isEmpty)
            if tail.isEmpty {
                array.insert(value, at: index)
            } else {
                array[index] = try adding(value, at: tail, in: array[index])
            }
            return .array(array)
        default:
            throw JSONPatchError.invalidPatch("path crosses a scalar value")
        }
    }

    private static func replacing(with value: JSONValue, at path: [String],
                                  in document: JSONValue) throws -> JSONValue {
        guard let head = path.first else { return value }
        let tail = Array(path.dropFirst())
        switch document {
        case .object(var object):
            guard let child = object[head] else {
                throw JSONPatchError.invalidPatch("path member \"\(head)\" does not exist")
            }
            object[head] = tail.isEmpty
                ? value
                : try replacing(with: value, at: tail, in: child)
            return .object(object)
        case .array(var array):
            let index = try arrayIndex(head, count: array.count,
                                       allowEnd: false, allowAppend: false)
            array[index] = tail.isEmpty
                ? value
                : try replacing(with: value, at: tail, in: array[index])
            return .array(array)
        default:
            throw JSONPatchError.invalidPatch("path crosses a scalar value")
        }
    }

    private static func removing(at path: [String], from document: JSONValue)
        throws -> (document: JSONValue, removed: JSONValue) {
        guard let head = path.first else {
            throw JSONPatchError.invalidPatch("removing the document root is not supported")
        }
        let tail = Array(path.dropFirst())
        switch document {
        case .object(var object):
            guard let child = object[head] else {
                throw JSONPatchError.invalidPatch("path member \"\(head)\" does not exist")
            }
            if tail.isEmpty {
                object.removeValue(forKey: head)
                return (.object(object), child)
            }
            let result = try removing(at: tail, from: child)
            object[head] = result.document
            return (.object(object), result.removed)
        case .array(var array):
            let index = try arrayIndex(head, count: array.count,
                                       allowEnd: false, allowAppend: false)
            if tail.isEmpty {
                return (.array(array.enumerated()
                    .filter { $0.offset != index }
                    .map(\.element)), array[index])
            }
            let result = try removing(at: tail, from: array[index])
            array[index] = result.document
            return (.array(array), result.removed)
        default:
            throw JSONPatchError.invalidPatch("path crosses a scalar value")
        }
    }
}

private struct PatchReport: Codable {
    let project: String
    let operations: Int
    let dryRun: Bool
    let changed: Bool
    let beforeSHA256: String
    let afterSHA256: String
    let warnings: [String]
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func validatedSHA256(_ raw: String, option: String = "--if-hash") throws -> String {
    let lowered = raw.lowercased()
    let digest = lowered.hasPrefix("sha256:")
        ? String(lowered.dropFirst("sha256:".count))
        : lowered
    guard digest.count == 64,
          digest.unicodeScalars.allSatisfy({
              CharacterSet(charactersIn: "0123456789abcdef").contains($0)
          }) else {
        throw CLIError.invalid(
            "\(option) requires a 64-character SHA-256 hex digest")
    }
    return digest
}

func patchCommand(_ args: [String]) throws {
    let usage =
        "banny apply <project.bs> <patch.json|-> "
        + "[--dry-run] [--if-hash SHA256] [--json]"
    guard args.count >= 2 else {
        throw CLIError.usage(usage)
    }
    let projectPath = args[0]
    let patchPath = args[1]
    var options = CLIOptions(Array(args.dropFirst(2)))
    let expectedHash = try options.value("--if-hash")
    let dryRun = try options.flag("--dry-run")
    let json = try options.flag("--json")
    try options.finish(usage: usage)

    let (root, loadedContents) = try readEditablePackage(at: projectPath)
    let showURL = root.appendingPathComponent("show.json")
    let beforeData = try Data(contentsOf: showURL)
    let beforeHash = sha256Hex(beforeData)
    if let expectedHash {
        let expected = try validatedSHA256(expectedHash)
        guard expected == beforeHash else {
            throw CLIError.invalid(
                "project changed: expected SHA-256 \(expected), found \(beforeHash)")
        }
    }
    let patchData = patchPath == "-"
        ? FileHandle.standardInput.readDataToEndOfFile()
        : try Data(contentsOf: URL(fileURLWithPath: patchPath))
    let operations = try JSONPatchEngine.decode(patchData)
    let source: JSONValue
    do {
        source = try JSONDecoder().decode(JSONValue.self, from: beforeData)
    } catch {
        throw JSONPatchError.invalidDocument(error.localizedDescription)
    }
    let patched = try JSONPatchEngine.apply(operations, to: source)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let patchedData = try encoder.encode(patched)
    let document: ShowDocument
    do {
        document = try ShowJSONCodec.decodeDocument(
            String(decoding: patchedData, as: UTF8.self))
    } catch {
        throw CLIError.invalid(
            "patched show is invalid: \(ShowJSONCodec.readableMessage(for: error))")
    }

    var contents = loadedContents
    contents.document = document
    let catalog = try? AssetCatalog(assetsRoot: locateAssetsRoot())
    try requireEditableDocument(contents, catalog: catalog)
    let outputData = try canonicalDocumentData(document)
    let afterHash = sha256Hex(outputData)
    if !dryRun, beforeData != outputData {
        try outputData.write(to: showURL, options: .atomic)
    }

    let warnings = editableDiagnostics(for: contents, catalog: catalog)
        .filter { $0.severity == .warning }
        .map(\.message)
    let report = PatchReport(
        project: root.path,
        operations: operations.count,
        dryRun: dryRun,
        changed: beforeData != outputData,
        beforeSHA256: beforeHash,
        afterSHA256: afterHash,
        warnings: warnings)
    if json {
        try printJSON(report)
    } else {
        let verb = dryRun ? "would update" : (report.changed ? "updated" : "unchanged")
        print("\(verb) \(root.path) — \(operations.count) operations")
        print("sha256 \(beforeHash) → \(afterHash)")
        for warning in warnings { print("warning: \(warning)") }
    }
}
