import BannyCore
import BannyRender

/// Fast, side-effect-free checks that should pass before allocating an export
/// writer. Missing library items only matter when the timeline references them.
public enum ShowExportPreflight {
    public static func errors(document: ShowDocument,
                              availableAudioIDs: Set<String>,
                              availableAssetIDs: Set<String>,
                              catalog: AssetCatalog?) -> [String] {
        let stage = document.stage
        let referencedAssetIDs = Set(
            stage.backgroundTracks.flatMap(\.cues).map(\.assetID)
                + stage.imageTracks.flatMap(\.cues).map(\.assetID)
                + stage.audioTracks.flatMap(\.cues).map(\.assetID))
        let unusedAssetIDs = Set(document.assets.map(\.id))
            .subtracting(referencedAssetIDs)

        return ShowLint.check(
            document: document,
            audioIDs: availableAudioIDs,
            assetFileIDs: availableAssetIDs.union(unusedAssetIDs),
            catalog: catalog,
            profile: .editableShow)
            .filter { $0.severity == .error }
            .map(\.message)
    }
}
