import Foundation
import Observation
import BannyCore

enum CustomOutfitStorage {
    static var directory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Banny Studio", isDirectory: true)
            .appendingPathComponent("Outfits", isDirectory: true)
    }

    static func loadAll() -> [CustomOutfitBundle] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let decoder = JSONDecoder()
        return urls
            .filter { $0.pathExtension.lowercased() == "bannyoutfit" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let bundle = try? decoder.decode(CustomOutfitBundle.self, from: data),
                      let valid = try? bundle.validated()
                else { return nil }
                return valid
            }
    }

    static func write(_ bundle: CustomOutfitBundle) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(bundle.validated())
        try data.write(
            to: directory.appendingPathComponent(
                "\(bundle.manifest.id.lowercased()).bannyoutfit"),
            options: [.atomic]
        )
    }

    static func remove(id: String) throws {
        let url = directory.appendingPathComponent("\(id.lowercased()).bannyoutfit")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

@MainActor
@Observable
final class CustomOutfitLibrary {
    enum ImportStrategy: Equatable {
        case replace
        case keepBoth
    }

    static let shared = CustomOutfitLibrary()

    private(set) var outfits: [CustomOutfitBundle]

    private init() {
        outfits = CustomOutfitStorage.loadAll().sorted {
            $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending
        }
    }

    func bundle(named assetName: String) -> CustomOutfitBundle? {
        outfits.first { $0.assetName == assetName }
    }

    func bundle(id: String) -> CustomOutfitBundle? {
        outfits.first { $0.manifest.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    func contains(id: String) -> Bool {
        bundle(id: id) != nil
    }

    @discardableResult
    func save(_ proposed: CustomOutfitBundle) throws -> CustomOutfitBundle {
        let cleanName = proposed.manifest.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var bundle = proposed
        bundle.manifest.name = cleanName
        bundle.manifest.modifiedAt = Date()
        bundle = try bundle.validated()
        try CustomOutfitStorage.write(bundle)
        if let index = outfits.firstIndex(where: {
            $0.manifest.id.caseInsensitiveCompare(bundle.manifest.id) == .orderedSame
        }) {
            outfits[index] = bundle
        } else {
            outfits.append(bundle)
        }
        sort()
        register(bundle)
        return bundle
    }

    @discardableResult
    func importBundle(
        _ imported: CustomOutfitBundle,
        strategy: ImportStrategy
    ) throws -> CustomOutfitBundle {
        var bundle = try imported.validated()
        if contains(id: bundle.manifest.id), strategy == .keepBoth {
            let now = Date()
            bundle.manifest.id = UUID().uuidString.lowercased()
            bundle.manifest.name = uniqueName("\(bundle.manifest.name) Copy")
            bundle.manifest.createdAt = now
            bundle.manifest.modifiedAt = now
        }
        return try save(bundle)
    }

    func delete(id: String) throws {
        let removedAssetName = bundle(id: id)?.assetName
        try CustomOutfitStorage.remove(id: id)
        outfits.removeAll {
            $0.manifest.id.caseInsensitiveCompare(id) == .orderedSame
        }
        if let removedAssetName {
            // Keep the decoded image available to open projects, but remove
            // the deleted item from wardrobe pickers.
            SharedAssets.catalog.hideCustomOutfitFromPicker(removedAssetName)
        }
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(outfits.map { $0.manifest.name.lowercased() })
        if !names.contains(base.lowercased()) { return base }
        var number = 2
        while names.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    private func sort() {
        outfits.sort {
            $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending
        }
    }

    private func register(_ bundle: CustomOutfitBundle) {
        _ = SharedAssets.catalog.registerCustomOutfit(
            name: bundle.assetName,
            label: bundle.manifest.name,
            slot: bundle.manifest.category.rawValue,
            pngData: bundle.pngData
        )
    }
}
