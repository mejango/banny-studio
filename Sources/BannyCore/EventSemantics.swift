/// Performable action codes, verbatim from the web app's KeyboardEvent.code vocabulary
/// so v1 documents import losslessly.
public enum EventCode: String, Codable, CaseIterable, Sendable {
    case arrowLeft = "ArrowLeft"
    case arrowRight = "ArrowRight"
    case arrowUp = "ArrowUp"
    case arrowDown = "ArrowDown"
    case comma = "Comma"
    case slash = "Slash"
    case period = "Period"
    case keyM = "KeyM"
    case keyT = "KeyT"
    case keyB = "KeyB"
    case keyJ = "KeyJ"
    case keyF = "KeyF"
    case keyD = "KeyD"
    // Not in the web v1 vocabulary — held like movement, integrated over time.
    case rotateLeft = "RotateLeft"
    case rotateRight = "RotateRight"
    case zoomIn = "ZoomIn"
    case zoomOut = "ZoomOut"
    // Instantaneous resets (chord gestures): snap spin→0 / zoom→1 at that time.
    case spinReset = "SpinReset"
    case zoomReset = "ZoomReset"

    public var group: EventGroup {
        switch self {
        case .arrowLeft, .arrowRight: return .move
        case .arrowUp, .arrowDown: return .depth
        case .keyT, .keyB: return .tilt
        case .keyM: return .talk
        case .comma, .slash, .period: return .blink
        case .keyJ, .keyF, .keyD: return .jump
        case .rotateLeft, .rotateRight, .spinReset: return .spin
        case .zoomIn, .zoomOut, .zoomReset: return .zoom
        }
    }
}

/// The recordable/armable event groups (order drives timeline sub-lane order).
public enum EventGroup: String, Codable, CaseIterable, Sendable {
    case move, depth, tilt, talk, blink, jump, spin, zoom
}

public enum EyeExpression: String, Sendable {
    case open, closed, brow1, brow2
}

public extension EventCode {
    /// Blink expression this code triggers while held, if any (web BLINK_KEY map).
    var blinkExpression: EyeExpression? {
        switch self {
        case .comma: return .closed
        case .slash: return .brow1
        case .period: return .brow2
        default: return nil
        }
    }
}
