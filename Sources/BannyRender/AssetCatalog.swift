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
    private struct CustomEntry {
        var slot: Int
        var label: String
        var image: CGImage
        var selectable: Bool
    }
    private var customOutfits: [String: CustomEntry] = [:]
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
        lock.lock()
        let custom = customOutfits[name]?.slot
        lock.unlock()
        return custom ?? catalog.outfits[name]?.slot
    }

    /// Whether `name` is a real selectable eye option. Rendering falls back to
    /// `default` for resilience, but validation must reject misspelled options.
    public func hasEyeOption(_ name: String) -> Bool {
        catalog.eyes[name] != nil
    }

    /// Whether `name` is a real selectable mouth option.
    public func hasMouthOption(_ name: String) -> Bool {
        catalog.mouths[name] != nil
    }

    public func outfitImage(_ name: String, body: Body) -> CGImage? {
        lock.lock()
        let custom = customOutfits[name]?.image
        lock.unlock()
        if let custom { return custom }
        return catalog.outfits[name]?.ref.file(for: body).flatMap(image(named:))
    }

    /// A picker-sized copy of an outfit part. Wardrobe grids can contain every
    /// catalog entry at once; decoding their 1600×1600 render sources eagerly
    /// consumes hundreds of megabytes and eventually makes ImageIO return nil.
    public func outfitThumbnail(_ name: String, body: Body) -> CGImage? {
        lock.lock()
        let custom = customOutfits[name]?.image
        lock.unlock()
        if let custom { return custom }
        return catalog.outfits[name]?.ref.file(for: body).flatMap(thumbnail(named:))
    }

    public func necklaceImage(body: Body) -> CGImage? {
        catalog.necklace.file(for: body).flatMap(image(named:))
    }

    /// Eye layer for an expression: open art, the option's blink art, or a shared brow frame.
    public func eyesImage(option: String, expression: EyeExpression, body: Body) -> CGImage? {
        eyesRef(option: option, expression: expression)?
            .file(for: body).flatMap(image(named:))
    }

    public func eyesThumbnail(option: String, expression: EyeExpression,
                              body: Body) -> CGImage? {
        eyesRef(option: option, expression: expression)?
            .file(for: body).flatMap(thumbnail(named:))
    }

    func mouth(option: String) -> MouthEntry? {
        catalog.mouths[option] ?? catalog.mouths["default"]
    }

    /// Whether this mouth option inverts the talk key (M closes instead of opens).
    public func mouthInverted(option: String) -> Bool {
        mouth(option: option)?.inverted ?? false
    }

    public func mouthImage(option: String, state: MouthState, body: Body) -> CGImage? {
        mouthRef(option: option, state: state)?
            .file(for: body).flatMap(image(named:))
    }

    public func mouthThumbnail(option: String, state: MouthState,
                               body: Body) -> CGImage? {
        mouthRef(option: option, state: state)?
            .file(for: body).flatMap(thumbnail(named:))
    }

    public func shadowImage() -> CGImage? {
        catalog.shadow.file.flatMap(image(named:))
    }

    public func sunImage() -> CGImage? {
        catalog.sun.file.flatMap(image(named:))
    }

    /// Human-readable slot name (web CATNAMES).
    public func slotName(_ slot: Int) -> String? {
        catalog.catNames[String(slot)]
    }

    /// Total outfit count (test/diagnostic).
    public var outfitCount: Int {
        lock.lock()
        let customCount = customOutfits.count
        lock.unlock()
        return catalog.outfits.count + customCount
    }

    /// All outfit names for a slot, for pickers.
    public func outfits(inSlot slot: Int) -> [(name: String, label: String)] {
        let bundled = catalog.outfits.filter { $0.value.slot == slot }
            .map { ($0.key, $0.value.label) }
        lock.lock()
        let custom = customOutfits.compactMap { name, entry in
            entry.slot == slot && entry.selectable ? (name, entry.label) : nil
        }
        lock.unlock()
        return (bundled + custom).sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    /// Adds a writable user or project outfit to this catalog. Custom entries
    /// are body-independent overlays and intentionally shadow no bundled name:
    /// their UUID-backed asset names make collisions vanishingly unlikely.
    @discardableResult
    public func registerCustomOutfit(
        name: String,
        label: String,
        slot: Int,
        pngData: Data
    ) -> Bool {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return false
        }
        lock.lock()
        customOutfits[name] = CustomEntry(
            slot: slot,
            label: label,
            image: image,
            selectable: true
        )
        lock.unlock()
        return true
    }

    public func hasCustomOutfit(_ name: String) -> Bool {
        lock.lock()
        let result = customOutfits[name] != nil
        lock.unlock()
        return result
    }

    public func unregisterCustomOutfit(_ name: String) {
        lock.lock()
        customOutfits.removeValue(forKey: name)
        lock.unlock()
    }

    /// Removes a deleted library item from wardrobe pickers without breaking
    /// an open project that is still rendering its embedded copy.
    public func hideCustomOutfitFromPicker(_ name: String) {
        lock.lock()
        customOutfits[name]?.selectable = false
        lock.unlock()
    }

    // MARK: - Image cache

    private func eyesRef(option: String, expression: EyeExpression) -> Ref? {
        switch expression {
        case .open:
            (catalog.eyes[option] ?? catalog.eyes["default"])?.open
        case .closed:
            (catalog.eyes[option] ?? catalog.eyes["default"])?.blink
        case .brow1:
            catalog.brows["brow1"]
        case .brow2:
            catalog.brows["brow2"]
        }
    }

    private func mouthRef(option: String, state: MouthState) -> Ref? {
        guard let entry = mouth(option: option) else { return nil }
        return switch state {
        case .open: entry.open
        case .tight: entry.tight
        case .closed: entry.closed
        }
    }

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

    private func thumbnail(named file: String) -> CGImage? {
        let maxPixelSize = 400
        let key = "\(file)#thumb-\(maxPixelSize)"
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        let url = pngDirectory.appendingPathComponent(file)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            src, 0, options as CFDictionary) else { return nil }
        cache[key] = image
        return image
    }

    // MARK: - Machine-readable summary (banny catalog)

    /// Everything an agent needs to pick wardrobe: names are the values that
    /// go into `baseOutfit` / outfit events; labels are for humans.
    public struct Summary: Codable, Sendable {
        public struct Outfit: Codable, Sendable {
            public var name: String
            public var label: String
        }
        public struct SlotEntry: Codable, Sendable {
            public var slot: Int
            public var name: String
            public var outfits: [Outfit]
        }
        public var bodies: [String]
        public var slots: [SlotEntry]
        public var eyes: [String]
        public var mouths: [String]
        /// Verbatim exclusivity table from the catalog (key → conflicting slots).
        public var exclusivity: [String: [Int]]
    }

    public func summary() -> Summary {
        let slotIDs = Set(catalog.outfits.values.map(\.slot)).sorted()
        return Summary(
            bodies: catalog.bodies.keys.sorted(),
            slots: slotIDs.map { id in
                Summary.SlotEntry(slot: id,
                                  name: slotName(id) ?? "slot \(id)",
                                  outfits: outfits(inSlot: id).map { Summary.Outfit(name: $0.name, label: $0.label) })
            },
            eyes: catalog.eyes.keys.sorted(),
            mouths: catalog.mouths.keys.sorted(),
            exclusivity: catalog.exclusivity)
    }
}
