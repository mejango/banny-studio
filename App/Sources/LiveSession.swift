// Live mode is macOS only. It reaches a model through a bridge script run by
// NSUserUnixTask, which does not exist on iOS, and its set editor is built on
// AppKit — there is no version of this that works on a phone.
#if os(macOS)
import SwiftUI
import BannyCore
import BannyRender
import UniformTypeIdentifiers
import ImageIO
import BannyMedia

/// Everything a running live scene needs, once setup is done.
///
/// The director is held here rather than by the view, so switching to By hand
/// suspends the scene instead of ending it: the transcript, the notes and the
/// approved mark are all still there when prompting resumes.
struct LiveSession: Equatable {
    var brief: LiveBrief
    var endpoint: LiveModelEndpoint
    var backingTrack: URL?
    /// The stage as read from the backdrop, when the scene read it.
    var room: LiveSet?
    var director: LiveDirector

    static func == (a: LiveSession, b: LiveSession) -> Bool {
        a.director === b.director && a.brief == b.brief
    }
}

/// The Produce/Live control, sitting in the header beside the project name
/// because it switches what the whole window is, not what the document says.
/// Live takes over for this document; Produce puts the editor back exactly
/// where it was.
struct StudioModeSelector: View {
    @Bindable var model: StudioModel
    let file: ShowDocumentFile
    @Binding var live: LiveSession?
    @Binding var suspended: LiveSession?

    @State private var setup = LiveSetup()

    var body: some View {
        // One button, outlined rather than filled. There is no mode to choose
        // between: the editor is where you already are, and this is the door
        // to the other way of working. Leaving a live scene is offered where
        // it belongs, on the live transport.
        Button {
            if let suspended {
                live = suspended
                self.suspended = nil
            } else {
                setup.open(from: model.document, file: file)
            }
        } label: {
            Text(suspended == nil ? "Prompt" : "Resume prompting")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.alienGreen)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.alienGreen.opacity(0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(suspended == nil
              ? "Describe what happens and let a model write it"
              : "Pick the scene back up where you left it")
        .accessibilityIdentifier("studio-mode-live")
        .liveSetup($setup, model: model, file: file, live: $live)
    }
}

extension Color {
    /// The alien banny's own body green, from the catalog (`b1` of body-alien).
    /// Borrowing a colour the cast already wears beats inventing one.
    static let alienGreen = Color(red: 0x67 / 255, green: 0xD7 / 255, blue: 0x57 / 255)
}

/// The same control as a toolbar item, for layouts with no header bar.
struct LiveModeButton: View {
    @Bindable var model: StudioModel
    let file: ShowDocumentFile
    @Binding var live: LiveSession?

    @State private var setup = LiveSetup()

    var body: some View {
        Button { setup.open(from: model.document, file: file) } label: {
            Label("Live", systemImage: "dot.radiowaves.left.and.right")
        }
        .help("Describe a scene and let a model perform it")
        .liveSetup($setup, model: model, file: file, live: $live)
    }
}

/// Everything the setup sheet needs to remember between openings.
struct LiveSetup {
    var showing = false
    var brief = LiveBrief()
    var endpoint = LiveModelEndpoint.presets()[0]
    var backgroundURL: URL?
    var backingTrackURL: URL?
    var problem: String?
    /// Set while the set is being prepared, so the sheet can say what is
    /// happening instead of appearing to hang.
    var preparing: String?
    /// The staging for the chosen backdrop, read once and then editable.
    var set: LiveSet?
    var backdropImage: NSImage?
    var readingSet = false
    /// True once a band has been dragged. A reading in flight loses to it.
    var handPlaced = false
    /// Which backdrop the picture and bands on screen belong to. Without it,
    /// "already loaded" is indistinguishable from "loaded something else".
    var loadedBackdrop: URL?

    /// True when the stage still holds nothing but the banny every new show
    /// opens with.
    ///
    /// That placeholder is not a cast, and reading it as one is how a scene
    /// prompted from a picture came out as one banny standing still for half a
    /// minute: a company of one leaves the model writing a two-hander, and
    /// every line belonging to the voice that was never cast is dropped on the
    /// way to the stage. A document is somebody's work once they have named
    /// them, dressed them, given them a line or made them do something.
    static func isUntouched(_ document: ShowDocument) -> Bool {
        guard document.stage.characters.count <= 1 else { return false }
        guard let only = document.stage.characters.first else { return true }
        return only.baseOutfit.isEmpty && only.subs.isEmpty && only.events.isEmpty
            && only.reactions.isEmpty && only.clips.isEmpty
            // "Banny 1" is the name older shows and the timeline itself give a
            // placeholder; it is no more a cast than an unnamed one.
            && ["", "Banny", "Banny 1"].contains(only.name)
    }

    /// Opens the sheet on the show that is already here.
    ///
    /// Prompting is not a fresh start — it is a thing you reach for partway
    /// through. Arriving at a starter cast and a stock backdrop when the
    /// document already has its own people and its own set means retyping what
    /// is on screen behind the sheet.
    mutating func open(from document: ShowDocument, file: ShowDocumentFile) {
        if !LiveSetup.isUntouched(document) {
            brief.cast = document.stage.characters.map { character in
                let outfit = Dictionary(uniqueKeysWithValues:
                    character.baseOutfit.map { (String($0.key), $0.value) })
                return LiveCastMember(
                    name: character.name, body: character.body, outfit: outfit,
                    // Keep whatever description they already had for this name.
                    prompt: brief.cast.first { $0.name == character.name }?.prompt ?? "",
                    speed: character.speed,
                    // Costumes already on the cast are the director's choice.
                    outfitIsChosen: !outfit.isEmpty)
            }
        }
        // Nothing is invented for the sheet. An unwritten cast is a request to
        // read one off the set, and prefilling would answer it before it was
        // asked; the fallback happens at Play, when the reading has had its go.
        // The set the show is already playing on, ahead of any default.
        if let existing = LiveSetup.backdrop(of: document, in: file) {
            backgroundURL = existing
        }
        // Open on a real room. An empty set editor teaches nobody anything,
        // and this is the one we know stages well.
        if backgroundURL == nil { backgroundURL = BuiltInBackdrops.sunsetBar }
        // What there is to wear, straight from the catalog, so the scene can
        // only dress people in things that actually exist.
        if brief.wardrobe.isEmpty {
            let catalog = SharedAssets.catalog
            var rack: [String: [String]] = [:]
            for slot in [2, 3, 4, 6, 8, 9, 10, 11, 12, 13] {
                let items = catalog.outfits(inSlot: slot).map(\.name)
                if !items.isEmpty { rack["\(slot)"] = items }
            }
            brief.wardrobe = rack
        }
        // A fallback shape only. The backdrop decides the real frame; this
        // covers a video backdrop, whose size is not read here.
        #if os(macOS)
        if let screen = NSScreen.main?.frame, screen.height > 0 {
            brief.frameW = Double(screen.width)
            brief.frameH = Double(screen.height)
        }
        #endif
        showing = true
    }
}

extension LiveSetup {
    /// The backdrop a document is already using, written somewhere the file
    /// picker's world can see it. The bytes live inside the package, and the
    /// sheet works in file URLs.
    static func backdrop(of document: ShowDocument, in file: ShowDocumentFile) -> URL? {
        guard let cue = document.stage.backgroundTracks.first?.cues.first,
              let asset = document.assets.first(where: { $0.id == cue.assetID }),
              let media = file.assetsMedia[asset.id]
        else { return nil }
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("banny-current-set-\(asset.id).\(media.1)")
        if !FileManager.default.fileExists(atPath: out.path) {
            try? media.0.write(to: out)
        }
        return FileManager.default.fileExists(atPath: out.path) ? out : nil
    }
}

private struct LiveSetupModifier: ViewModifier {
    @Binding var setup: LiveSetup
    @Bindable var model: StudioModel
    let file: ShowDocumentFile
    @Binding var live: LiveSession?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $setup.showing) {
                LiveSetupView(brief: $setup.brief, endpoint: $setup.endpoint,
                              backgroundURL: $setup.backgroundURL,
                              backingTrackURL: $setup.backingTrackURL,
                              catalog: SharedAssets.catalog,
                              preparing: setup.preparing,
                              set: $setup.set,
                              handPlaced: $setup.handPlaced,
                              backdropImage: setup.backdropImage,
                              readingSet: setup.readingSet,
                              onReadSet: { readSet(force: true) },
                              onPlay: { start() },
                              onCancel: { setup.showing = false })
                .onAppear { prepareBackdrop() }
                .onChange(of: setup.backgroundURL) { _, _ in prepareBackdrop() }
                .onChange(of: setup.set) { _, set in
                    if let url = setup.backgroundURL { LiveSetStore.save(set, for: url) }
                }
            }
            .alert("Could not start the scene", isPresented: Binding(
                get: { setup.problem != nil },
                set: { if !$0 { setup.problem = nil } })) {
                Button("OK", role: .cancel) { setup.problem = nil }
            } message: {
                Text(setup.problem ?? "")
            }
    }

    /// Loads the chosen backdrop for the editor: its picture, the staging you
    /// last gave it, and — only if it has none — a reading of the room.
    private func prepareBackdrop() {
        guard let url = setup.backgroundURL else { return }
        // Only skip the work when it is the same picture as the one on screen.
        if setup.loadedBackdrop != url || setup.backdropImage == nil {
            setup.loadedBackdrop = url
            setup.backdropImage = LiveSceneBuilder.thumbnail(url)
            // A different set starts a fresh argument about where people stand.
            setup.set = LiveSetStore.load(for: url)
            setup.handPlaced = setup.set != nil
        }
        if setup.set == nil { readSet(force: false) }
    }

    /// Looks at the backdrop and proposes where people can stand. Runs when a
    /// backdrop is chosen rather than at Play, so the answer can be corrected
    /// before it matters.
    private func readSet(force: Bool) {
        guard let url = setup.backgroundURL,
              setup.endpoint.shape.scriptName != nil,
              force || setup.set == nil, !setup.readingSet
        else { return }
        setup.readingSet = true
        // Asking for a reading is choosing to start over; anything else loses
        // to whatever the hand has done since.
        if force { setup.handPlaced = false }
        let brief = setup.brief, endpoint = setup.endpoint
        Task { @MainActor in
            let read = await LiveSceneBuilder.readRoom(url, brief: brief, endpoint: endpoint)
            setup.readingSet = false
            // A failed read leaves whatever was there, including the built-in
            // staging — never a worse answer than the one it replaced. And a
            // reading that lands after the bands have been moved is thrown
            // away: it was racing an answer the user already gave.
            // Three ways this answer can be stale by the time it lands: the
            // bands were dragged, another reading was asked for, or — since a
            // reading takes the better part of a minute — the backdrop it was
            // about is no longer the one on screen.
            guard let read, !setup.handPlaced, setup.backgroundURL == url
            else { return }
            setup.set = read
        }
    }

    /// Replaces the document with the live scene's opening state, then hands it
    /// to the director. Everything the model adds lands on top of this.
    ///
    /// Two optional passes happen here rather than during the scene, because
    /// both change the set itself: reading the room, which needs the model to
    /// look at the backdrop, and shimmering it, which re-encodes the art.
    private func start() {
        guard let backgroundURL = setup.backgroundURL else {
            setup.problem = "Choose a backdrop first."
            return
        }
        let brief = setup.brief
        let endpoint = setup.endpoint
        let track = setup.backingTrackURL
        let staging = setup.set
        let needsReading = brief.cast.isEmpty || brief.premise.isEmpty
        setup.preparing = needsReading
            ? "Reading the set — who is here, and what kind of place this is"
            : "Preparing the set"

        Task { @MainActor in
            let room = staging
            // An empty brief is filled from the picture, then shown back: the
            // reading becomes an ordinary brief the director can rewrite, not a
            // decision taken quietly on their behalf.
            var brief = brief
            if needsReading, endpoint.shape.scriptName != nil,
               let reading = await LiveSceneBuilder.readCast(backgroundURL, brief: brief,
                                                             endpoint: endpoint) {
                if brief.premise.isEmpty { brief.premise = reading.premise }
                if brief.cast.isEmpty {
                    brief.cast = reading.castMembers(mergingInto: brief.cast)
                }
                setup.brief = brief
            }
            // Only now, with the picture asked and answered: somebody has to be
            // on stage, so an unread cast falls back to three placeless people.
            if brief.cast.isEmpty {
                brief.cast = LiveBrief.starter().cast
                setup.brief = brief
            }
            let art = brief.shimmerBackdrop
                ? LiveSceneBuilder.shimmered(backgroundURL) : backgroundURL
            defer { setup.preparing = nil }
            do {
                // The builder shapes the frame to the backdrop; do not overwrite it.
                let document = try LiveSceneBuilder.opening(
                    brief: brief, backgroundURL: art, file: file, room: room)
                model.document = document
                model.time = 0
                setup.showing = false
                live = LiveSession(brief: brief, endpoint: endpoint,
                                   backingTrack: track, room: room,
                                   director: LiveDirector(
                                       brief: brief, document: document,
                                       beats: endpoint.beats(for:), room: room))
            } catch {
                setup.problem = error.localizedDescription
            }
        }
    }
}

extension View {
    func liveSetup(_ setup: Binding<LiveSetup>, model: StudioModel,
                   file: ShowDocumentFile, live: Binding<LiveSession?>) -> some View {
        modifier(LiveSetupModifier(setup: setup, model: model, file: file, live: live))
    }
}

/// Builds the document a live scene starts from: the cast standing offstage,
/// the backdrop imported, and the gesture vocabulary loaded.
enum LiveSceneBuilder {
    /// The backdrop at a size worth drawing on.
    static func thumbnail(_ url: URL) -> NSImage? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    /// The set, small enough to hand over and still be looked at. A 4K backdrop
    /// is megabytes of base64 for a question about where the floor is, and the
    /// answer is the same at 1200 across. Nil for a moving backdrop, and for
    /// anything that will not open — an unread set is no worse than none.
    static func picture(of url: URL, across: Int = 1200) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let frame = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: across,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }
        return NSBitmapImageRep(cgImage: frame)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    /// Asks the agent who is in this place, when the director has not said.
    /// Returns nil on any trouble; an empty brief is still playable, it just
    /// leaves the writing with less to go on.
    static func readCast(_ url: URL, brief: LiveBrief,
                         endpoint: LiveModelEndpoint) async -> LiveReading? {
        guard let picture = picture(of: url) else { return nil }
        let prompt = LiveReading.prompt(imagePath: LiveScriptRunner.imageToken,
                                        wanted: max(2, min(4, brief.cast.count == 0
                                                           ? 3 : brief.cast.count)),
                                        premise: brief.premise)
        let flags = endpoint.shape == .claudeCode
            ? LiveModelEndpoint.confinement(needsWeb: false, needsFiles: true) : []
        guard let script = endpoint.shape.scriptName,
              let answer = try? await LiveScriptRunner.run(script: script, prompt: prompt,
                                                           model: endpoint.model,
                                                           extraArguments: flags,
                                                           image: picture)
        else { return nil }
        return LiveReading.parse(answer)
    }

    /// Asks the agent to look at the backdrop and say where people can stand.
    /// A failed or nonsensical read simply returns nil, and the scene is staged
    /// exactly as it was before rooms existed.
    static func readRoom(_ url: URL, brief: LiveBrief,
                         endpoint: LiveModelEndpoint) async -> LiveSet? {
        guard let picture = picture(of: url) else { return nil }
        let prompt = LiveSet.prompt(imagePath: LiveScriptRunner.imageToken,
                                     premise: brief.premise,
                                     cast: max(2, brief.cast.count))
        // Looking at one picture needs to read one file and nothing else.
        let readOnly = endpoint.shape == .claudeCode
            ? LiveModelEndpoint.confinement(needsWeb: false, needsFiles: true) : []
        guard let script = endpoint.shape.scriptName,
              let answer = try? await LiveScriptRunner.run(script: script,
                                                          prompt: prompt,
                                                          model: endpoint.model,
                                                          extraArguments: readOnly,
                                                          image: picture)
        else { return nil }
        return LiveSet.parse(answer)
    }

    /// Turns the point lights in a still into a slow twinkle. Returns the GIF,
    /// or the original when there is nothing to shimmer.
    static func shimmered(_ url: URL) -> URL {
        guard !["gif", "mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
        else { return url }
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("banny-live-shimmer-\(UUID().uuidString).gif")
        do {
            _ = try ShimmerEncoder.encode(source: url, to: out)
            return out
        } catch {
            return url          // a backdrop with no point lights stays still
        }
    }

    static func opening(brief: LiveBrief, backgroundURL: URL,
                        file: ShowDocumentFile, room: LiveSet? = nil) throws -> ShowDocument {
        var document = ShowDocument(stage: SceneState(
            characters: brief.cast.enumerated().map { i, member in
                // Wait in alternating wings so entrances come from both sides.
                let wing = i.isMultiple(of: 2) ? -0.2 : 1.2
                var character = Character(
                    body: member.body, x: wing, depth: 0.06, size: 1,
                    face: i.isMultiple(of: 2) ? 1 : -1,
                    name: member.name, speed: member.speed)
                // Nobody performs undressed, however they were added to the cast.
                let outfit = member.outfit.isEmpty
                    ? LiveCastMember.defaultOutfit(i) : member.outfit
                character.baseOutfit = Dictionary(
                    uniqueKeysWithValues: outfit.compactMap { key, value in
                        Int(key).map { ($0, value) }
                    })
                // Everyone starts out of shot; the model brings them on.
                character.presence = [VisibilityEvent(t: 0, visible: false)]
                character.recStart = StartPose(x: wing, depth: 0.06,
                                               face: i.isMultiple(of: 2) ? 1 : -1)
                return character
            },
            backgroundTracks: [BackgroundTrack(id: "scenes", name: "Scenes")]))

        document.stage.reactionLibrary = LiveReactionLibrary.standard
        // Wings let performers walk fully out of shot rather than blink away.
        document.stage.wings = 0.3
        // The room decides the scale when it was read; otherwise the default.
        document.stage.gSize = room?.gSize.map { min(3.0, max(0.6, $0)) } ?? 1.7

        let id = "image-live-backdrop"
        let ext = backgroundURL.pathExtension.lowercased()
        // The backdrop comes from the file picker, so it lives outside the
        // sandbox and has to be opened through its security scope.
        let scoped = backgroundURL.startAccessingSecurityScopedResource()
        defer { if scoped { backgroundURL.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: backgroundURL)
        file.assetsMedia[id] = (data, ext)
        document.settings.frameW = brief.frameW      // fallback for a video
        document.settings.frameH = brief.frameH
        // The frame takes its shape from the backdrop. Fitting a differently
        // shaped image inside it cannot work: the camera clamp zooms in until
        // no empty space shows, which crops away the very edges that `fit` was
        // meant to keep. Matching the shape means the whole image is on screen
        // at full width, and the window letterboxes what is left over.
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Double,
           let h = props[kCGImagePropertyPixelHeight] as? Double, w > 0, h > 0 {
            document.settings.frameW = w
            document.settings.frameH = h
        }
        document.assets = [Asset(id: id, name: "Backdrop",
                                 kind: ["mp4", "mov", "m4v"].contains(ext) ? .video : .image,
                                 file: "\(id).\(ext)")]
        document.stage.backgroundTracks = [BackgroundTrack(
            id: "scenes", name: "Scenes",
            cues: [BackgroundCue(id: "live-scene", assetID: id, start: 0,
                                 // Fit, not cover: the whole backdrop is shown
                                 // at full width and any spare height is black,
                                 // rather than cropping the sides away.
                                 dur: 24 * 60 * 60, crop: .fit,
                                 camFrom: CameraState(x: 0.5, y: 0.5, zoom: 1),
                                 camTo: CameraState(x: 0.5, y: 0.5, zoom: 1))])]
        // A live scene has no planned end, so the segment simply never runs out.
        // A zero-length one leaves the stage empty: nothing is inside the show.
        document.show = [ShowSegment(name: "Live scene", from: 0, to: 24 * 60 * 60)]
        return document
    }
}

extension LiveBrief {
    /// The cast of last resort: nobody was named, and nobody could be read off
    /// the picture either — no agent installed, or it had nothing to say.
    ///
    /// Deliberately placeless. This used to be a bar, and a prefilled bar is
    /// worse than an empty sheet: it is never empty, so the set is never read,
    /// and three people stand in someone's kitchen holding pints. Wardrobe is
    /// left blank so the scene dresses them once it knows where it is.
    static func starter() -> LiveBrief {
        LiveBrief(
            background: "", duration: 900, model: "local", premise: "",
            cast: [
                LiveCastMember(name: "Ozzy", body: .orange, outfit: [:],
                               prompt: "genial, keeps things moving, quietly "
                                     + "anxious everyone is enjoying themselves",
                               speed: 120),
                LiveCastMember(name: "Rue", body: .original, outfit: [:],
                               prompt: "here often; dry, clipped, says less "
                                     + "than he means",
                               speed: 115),
                LiveCastMember(name: "Vic", body: .alien, outfit: [:],
                               prompt: "deadpan; punctures anything that sounds "
                                     + "like a story getting bigger",
                               speed: 115),
            ])
    }
}

#endif
