import Foundation
import CoreGraphics
import ImageIO
import BannyCore

/// Loads the baked part catalog (Assets/catalog.json + Assets/png) produced by
/// tools/extract-assets.mjs + tools/bake-assets.sh, and resolves parts to CGImages.
///
/// A part is either body-independent (one file) or palette-classed (one file per body).
public final class AssetCatalog: @unchecked Sendable {

    /// `{file}` or `{perBody: {orange: file, ...}}` as written by the extractor.
    struct Ref: Decodable {
        var file: String?
        var perBody: [String: String]?

        func file(for body: Body) -> String? {
            file ?? perBody?[body.rawValue]
        }
    }

    struct BodyEntry: Decodable {
        var file: String
        var colors: [String: String]
    }

    struct OutfitEntry: Decodable {
        var slot: Int
        var label: String
        var file: String?
        var perBody: [String: String]?

        var ref: Ref { Ref(file: file, perBody: perBody) }
    }

    struct EyeEntry: Decodable {
        var label: String
        var open: Ref
        var blink: Ref
    }

    struct MouthEntry: Decodable {
        var label: String
        var lip: String?
        var inverted: Bool
        var open: Ref
        var tight: Ref
        var closed: Ref
    }

    struct CatalogFile: Decodable {
        var catNames: [String: String]
        var exclusivity: [String: [Int]]
        var headHidesFace: Bool
        var bodies: [String: BodyEntry]
        var outfits: [String: OutfitEntry]
        var eyes: [String: EyeEntry]
        var brows: [String: Ref]
        var mouths: [String: MouthEntry]
        var necklace: Ref
        var shadow: Ref
        var sun: Ref
    }

    let catalog: CatalogFile
    private let pngDirectory: URL
    private var cache: [String: CGImage] = [:]
    private let lock = NSLock()

    public init(catalogURL: URL, pngDirectory: URL) throws {
        self.catalog = try JSONDecoder().decode(CatalogFile.self, from: Data(contentsOf: catalogURL))
        self.pngDirectory = pngDirectory
    }

    /// Loads a catalog laid out as `<root>/catalog.json` + `<root>/png/`.
    public convenience init(assetsRoot: URL) throws {
        try self.init(catalogURL: assetsRoot.appendingPathComponent("catalog.json"),
                      pngDirectory: assetsRoot.appendingPathComponent("png"))
    }

    public enum MouthState: String, Sendable {
        case open, tight, closed
    }

    // MARK: - Resolution

    public func bodyImage(_ body: Body) -> CGImage? {
        catalog.bodies[body.rawValue].flatMap { image(named: $0.file) }
    }

    public func outfitSlot(_ name: String) -> Int? {
        catalog.outfits[name]?.slot
    }

    public func outfitImage(_ name: String, body: Body) -> CGImage? {
        catalog.outfits[name]?.ref.file(for: body).flatMap(image(named:))
    }

    public func necklaceImage(body: Body) -> CGImage? {
        catalog.necklace.file(for: body).flatMap(image(named:))
    }

    /// Eye layer for an expression: open art, the option's blink art, or a shared brow frame.
    public func eyesImage(option: String, expression: EyeExpression, body: Body) -> CGImage? {
        let ref: Ref?
        switch expression {
        case .open: ref = (catalog.eyes[option] ?? catalog.eyes["default"])?.open
        case .closed: ref = (catalog.eyes[option] ?? catalog.eyes["default"])?.blink
        case .brow1: ref = catalog.brows["brow1"]
        case .brow2: ref = catalog.brows["brow2"]
        }
        return ref?.file(for: body).flatMap(image(named:))
    }

    func mouth(option: String) -> MouthEntry? {
        catalog.mouths[option] ?? catalog.mouths["default"]
    }

    /// Whether this mouth option inverts the talk key (M closes instead of opens).
    public func mouthInverted(option: String) -> Bool {
        mouth(option: option)?.inverted ?? false
    }

    public func mouthImage(option: String, state: MouthState, body: Body) -> CGImage? {
        guard let entry = mouth(option: option) else { return nil }
        let ref: Ref
        switch state {
        case .open: ref = entry.open
        case .tight: ref = entry.tight
        case .closed: ref = entry.closed
        }
        return ref.file(for: body).flatMap(image(named:))
    }

    public func shadowImage() -> CGImage? {
        catalog.shadow.file.flatMap(image(named:))
    }

    public func sunImage() -> CGImage? {
        catalog.sun.file.flatMap(image(named:))
    }

    /// All outfit names for a slot, for pickers.
    public func outfits(inSlot slot: Int) -> [(name: String, label: String)] {
        catalog.outfits.filter { $0.value.slot == slot }
            .map { ($0.key, $0.value.label) }
            .sorted { $0.label < $1.label }
    }

    // MARK: - Image cache

    func image(named file: String) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[file] { return hit }
        let url = pngDirectory.appendingPathComponent(file)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        cache[file] = img
        return img
    }
}
