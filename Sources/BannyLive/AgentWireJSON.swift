import Foundation

/// Wire models declare explicit snake-case coding keys. Keeping this codec
/// plain avoids `.convertFromSnakeCase` corrupting acronym properties such as
/// `requestID`/`participantID` during strict decode.
enum BannyAgentWireJSON {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var decoder: JSONDecoder { JSONDecoder() }
}
