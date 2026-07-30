import Foundation
import Testing
@testable import BannyCore

@Test func customOutfitCategoriesMatchRendererContractSlots() {
    #expect(OutfitCategory.allCases.map(\.rawValue) == [2, 3, 4, 6, 8, 9, 10, 11, 12, 13])
    #expect(OutfitCategory.head.layerExplanation.contains("hides"))
    #expect(OutfitCategory.suit.layerExplanation.contains("hides"))
}

@Test func customOutfitBundleRoundTripsAndKeepsAStableAssetName() throws {
    let id = "89DAB4E1-1EE8-4594-AF84-5A5E98B5ED5F"
    let png = Data([137, 80, 78, 71, 13, 10, 26, 10])
    let bundle = CustomOutfitBundle(
        manifest: CustomOutfitManifest(
            id: id,
            name: "Moon Jacket",
            category: .suitTop,
            gridSize: 100
        ),
        pngData: png
    )
    let valid = try bundle.validated()
    let decoded = try JSONDecoder().decode(
        CustomOutfitBundle.self,
        from: JSONEncoder().encode(valid)
    )
    #expect(decoded == valid)
    #expect(decoded.assetName == "custom-\(id.lowercased())")
}

@Test func customOutfitValidationRejectsUnsafeInput() {
    let badGrid = CustomOutfitBundle(
        manifest: CustomOutfitManifest(
            name: "Too Fine",
            category: .hand,
            gridSize: 999
        ),
        pngData: Data([137, 80, 78, 71, 13, 10, 26, 10])
    )
    #expect(throws: CustomOutfitError.unsupportedGridSize(999)) {
        try badGrid.validated()
    }
}

@Test func pixelSectionSelectsOnlyTheConnectedMatchingColor() {
    let red: UInt32 = 0xff0000ff
    let blue: UInt32 = 0x0000ffff
    let pixels: [UInt32] = [
        red, red, blue, red,
        blue, red, blue, red,
        red, blue, red, red,
    ]
    #expect(PixelSection.connectedIndices(
        in: pixels,
        width: 4,
        startingAt: 0
    ) == Set([0, 1, 5]))
    #expect(PixelSection.connectedIndices(
        in: pixels,
        width: 4,
        startingAt: 3
    ) == Set([3, 7, 10, 11]))
}
