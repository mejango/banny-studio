import Foundation

/// Contract-compatible wardrobe categories. Custom eyes and mouths retain the
/// same performance semantics as their built-in counterparts: eye art blinks,
/// and mouth art responds to talking states.
public enum OutfitCategory: Int, Codable, CaseIterable, Identifiable, Sendable {
    case backside = 2
    case necklace = 3
    case head = 4
    case eyes = 5
    case glasses = 6
    case mouth = 7
    case legs = 8
    case suit = 9
    case suitBottom = 10
    case suitTop = 11
    case headTop = 12
    case hand = 13

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .backside: "Backside"
        case .necklace: "Necklace"
        case .head: "Head"
        case .eyes: "Eyes"
        case .glasses: "Glasses"
        case .mouth: "Mouth"
        case .legs: "Legs"
        case .suit: "Suit"
        case .suitBottom: "Suit Bottom"
        case .suitTop: "Suit Top"
        case .headTop: "Head Top"
        case .hand: "Hand"
        }
    }

    public var layerExplanation: String {
        switch self {
        case .backside:
            "Draws behind the Banny body."
        case .necklace:
            "Draws above the body and replaces the default necklace."
        case .head:
            "Replaces the whole head and hides the face, glasses, and head-top items."
        case .eyes:
            "Replaces the Banny’s default eyes and still blinks during performances."
        case .glasses:
            "Draws above the eyes and below the mouth."
        case .mouth:
            "Replaces the Banny’s default mouth and still opens for M-key and speech timing."
        case .legs:
            "Draws over the body and face, before clothing."
        case .suit:
            "Draws over the legs and hides separate Suit Top and Suit Bottom items."
        case .suitBottom:
            "Draws above a Suit, below a Suit Top."
        case .suitTop:
            "Draws above Suit Bottom."
        case .headTop:
            "Draws near the front for hair, hats, and head accessories."
        case .hand:
            "The frontmost layer, intended for held items and props."
        }
    }

    public var iconName: String {
        switch self {
        case .backside: "rectangle.behind.rectangle"
        case .necklace: "circle.dotted"
        case .head: "person.crop.circle"
        case .eyes: "eye"
        case .glasses: "eyeglasses"
        case .mouth: "mouth"
        case .legs: "figure.walk"
        case .suit: "person.fill"
        case .suitBottom: "rectangle.bottomhalf.inset.filled"
        case .suitTop: "tshirt"
        case .headTop: "graduationcap"
        case .hand: "hand.raised"
        }
    }
}

public struct CustomOutfitManifest: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public static let supportedGridSizes = [50, 100, 200]

    public var formatVersion: Int
    public var id: String
    public var name: String
    public var category: OutfitCategory
    public var gridSize: Int
    /// Shared duration for each optional animation frame. Older single-frame
    /// outfits decode with nil and use the 0.2 second editor default.
    public var frameDelay: Double?
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        id: String = UUID().uuidString.lowercased(),
        name: String,
        category: OutfitCategory,
        gridSize: Int = 100,
        frameDelay: Double? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.category = category
        self.gridSize = gridSize
        self.frameDelay = frameDelay
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    /// The collision-resistant name stored in ShowDocument wardrobe events.
    public var assetName: String { "custom-\(id.lowercased())" }
}

/// A portable `.bannyoutfit` file. PNG data remains lossless and transparent;
/// JSON's Codable representation makes the single-file format easy to inspect,
/// validate, and migrate.
public struct CustomOutfitBundle: Codable, Equatable, Identifiable, Sendable {
    public var manifest: CustomOutfitManifest
    public var pngData: Data
    /// Optional lossless frames. `pngData` remains frame one for backwards
    /// compatibility with older Studio builds and external tooling.
    public var framePNGData: [Data]?

    public init(
        manifest: CustomOutfitManifest,
        pngData: Data,
        framePNGData: [Data]? = nil
    ) {
        self.manifest = manifest
        self.pngData = pngData
        self.framePNGData = framePNGData
    }

    public var assetName: String { manifest.assetName }
    public var id: String { manifest.id }
    public var frames: [Data] {
        guard let framePNGData, !framePNGData.isEmpty else { return [pngData] }
        return Array(framePNGData.prefix(5))
    }
    public var frameDelay: Double { manifest.frameDelay ?? 0.2 }

    public func validated() throws -> CustomOutfitBundle {
        guard manifest.formatVersion == CustomOutfitManifest.currentFormatVersion else {
            throw CustomOutfitError.unsupportedVersion(manifest.formatVersion)
        }
        guard UUID(uuidString: manifest.id) != nil else {
            throw CustomOutfitError.invalidIdentifier
        }
        guard !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CustomOutfitError.missingName
        }
        guard CustomOutfitManifest.supportedGridSizes.contains(manifest.gridSize) else {
            throw CustomOutfitError.unsupportedGridSize(manifest.gridSize)
        }
        guard (1...5).contains(frames.count),
              (0.04...2).contains(frameDelay),
              frames.reduce(0, { $0 + $1.count }) <= 64 * 1_024 * 1_024 else {
            throw CustomOutfitError.imageTooLarge
        }
        let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard frames.allSatisfy({ data in
            data.count >= pngSignature.count
                && Array(data.prefix(pngSignature.count)) == pngSignature
        }) else {
            throw CustomOutfitError.invalidPNG
        }
        return self
    }
}

public enum CustomOutfitError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case invalidIdentifier
    case missingName
    case unsupportedGridSize(Int)
    case invalidPNG
    case imageTooLarge

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "This outfit uses unsupported format version \(version)."
        case .invalidIdentifier:
            "The outfit has an invalid identifier."
        case .missingName:
            "Give the outfit a name before saving."
        case .unsupportedGridSize(let size):
            "The \(size)×\(size) grid is not supported."
        case .invalidPNG:
            "The outfit does not contain a valid PNG image."
        case .imageTooLarge:
            "The outfit image is too large."
        }
    }
}

/// Exact-color, four-way-connected pixel selection used by the outfit
/// editor's Section tool.
public enum PixelSection {
    public static func connectedIndices(
        in pixels: [UInt32],
        width: Int,
        startingAt start: Int
    ) -> Set<Int> {
        guard width > 0,
              pixels.count.isMultiple(of: width),
              pixels.indices.contains(start)
        else { return [] }
        let height = pixels.count / width
        let target = pixels[start]
        var selected: Set<Int> = [start]
        var queue = [start]
        var cursor = 0
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            let x = index % width
            let y = index / width
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                let next = ny * width + nx
                if pixels[next] == target, selected.insert(next).inserted {
                    queue.append(next)
                }
            }
        }
        return selected
    }
}
