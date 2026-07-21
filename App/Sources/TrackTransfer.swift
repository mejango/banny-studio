import Foundation
import SwiftUI
import UniformTypeIdentifiers
import BannyCore

extension UTType {
    static let bannyTrack = UTType(exportedAs: "com.banny.studio-track", conformingTo: .data)
}

/// SwiftUI bridge for reading and writing the single-file `.bannytrack` archive.
struct BannyTrackFile: FileDocument {
    static let readableContentTypes: [UTType] = [.bannyTrack]

    var track: PortableTrack

    init(track: PortableTrack) {
        self.track = track
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        track = try PortableTrack(data: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try track.encoded())
    }

    static func read(from url: URL) throws -> PortableTrack {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try PortableTrack(data: Data(contentsOf: url))
    }
}

enum TrackTransferError: Error, LocalizedError {
    case characterLimit
    case missingDocumentMedia

    var errorDescription: String? {
        switch self {
        case .characterLimit:
            return "This project already has the maximum of 10 characters."
        case .missingDocumentMedia:
            return "The track's media could not be added to this project."
        }
    }
}

extension StudioModel {
    /// Captures one track and just the audio/assets reachable from it.
    func portableTrack(for kind: TrackRowKind) throws -> PortableTrack {
        let payload: PortableTrack.Payload
        switch kind {
        case .character(let index):
            guard let character = scene.characters[safe: index] else {
                throw CocoaError(.fileReadUnknown)
            }
            payload = .character(character)
        case .audio(let index):
            guard let track = scene.audioTracks[safe: index] else {
                throw CocoaError(.fileReadUnknown)
            }
            payload = .audio(track)
        case .image(let index):
            guard let track = scene.imageTracks[safe: index] else {
                throw CocoaError(.fileReadUnknown)
            }
            payload = .image(track)
        case .light(let index):
            guard let track = scene.lightTracks[safe: index] else {
                throw CocoaError(.fileReadUnknown)
            }
            payload = .light(track)
        case .background(let index):
            guard let track = scene.backgroundTracks[safe: index] else {
                throw CocoaError(.fileReadUnknown)
            }
            payload = .background(track)
        }

        var audio: [String: PortableTrack.MediaFile] = [:]
        for id in payload.referencedAudioIDs.sorted() {
            guard let media = file?.audio[id] else {
                throw PortableTrackError.missingAudio(id)
            }
            audio[id] = PortableTrack.MediaFile(data: media.data, fileExtension: media.ext)
        }

        let assetIDs = payload.referencedAssetIDs
        let assets = document.assets.filter { assetIDs.contains($0.id) }
        var assetMedia: [String: PortableTrack.MediaFile] = [:]
        for id in assetIDs.sorted() {
            guard let media = file?.assetsMedia[id] else {
                throw PortableTrackError.missingAssetMedia(id)
            }
            assetMedia[id] = PortableTrack.MediaFile(data: media.data,
                                                     fileExtension: media.ext)
        }

        let archive = PortableTrack(payload: payload, assets: assets,
                                    audio: audio, assetMedia: assetMedia)
        try archive.validate()
        return archive
    }

    /// Adds a portable track as an independent copy. Scenes remain the one
    /// special singleton track: imported scene cues merge into the project's
    /// existing Scenes row instead of creating a second background stack.
    @discardableResult
    func importPortableTrack(_ archive: PortableTrack) throws -> String {
        if case .character = archive.payload, scene.characters.count >= 10 {
            throw TrackTransferError.characterLimit
        }
        if (!archive.audio.isEmpty || !archive.assetMedia.isEmpty), file == nil {
            throw TrackTransferError.missingDocumentMedia
        }

        let imported = try archive.remapped { ShowDocumentFile.newID() }
        registerUndoSnapshot(label: "Import Track")

        document.assets.append(contentsOf: imported.assets)
        for (id, media) in imported.audio {
            file?.audio[id] = (media.data, media.fileExtension)
        }
        for (id, media) in imported.assetMedia {
            file?.assetsMedia[id] = (media.data, media.fileExtension)
        }

        let selectedKey: String
        switch imported.payload {
        case .character(let character):
            scene.characters.append(character)
            let index = scene.characters.count - 1
            selection = [index]
            selectedKey = "c-\(index)"
        case .audio(let track):
            scene.audioTracks.append(track)
            selectedImageCue = track.cues.first?.id
            selectedKey = track.id
        case .image(let track):
            scene.imageTracks.append(track)
            selectedImageCue = track.cues.first?.id
            selectedKey = track.id
        case .light(let track):
            scene.lightTracks.append(track)
            selectedLightCue = track.cues.first?.id
            selectedKey = track.id
        case .background(let track):
            if scene.backgroundTracks.isEmpty || scene.backgroundTracks[0].cues.isEmpty {
                if scene.backgroundTracks.isEmpty {
                    scene.backgroundTracks = [track]
                } else {
                    // Preserve the singleton row's identity so a custom
                    // timeline row order keeps Scenes in the same place.
                    var replacement = track
                    replacement.id = scene.backgroundTracks[0].id
                    scene.backgroundTracks[0] = replacement
                }
            } else {
                scene.backgroundTracks[0].cues.append(contentsOf: track.cues)
                scene.backgroundTracks[0].cues.sort { $0.start < $1.start }
            }
            selectedBackgroundCue = track.cues.first?.id
            selectedKey = scene.backgroundTracks[0].id
            backgroundRevision += 1
        }
        selectedTrackKey = selectedKey
        return selectedKey
    }
}
