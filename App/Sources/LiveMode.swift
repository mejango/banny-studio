// Live mode is macOS only. It reaches a model through a bridge script run by
// NSUserUnixTask, which does not exist on iOS, and its set editor is built on
// AppKit — there is no version of this that works on a phone.
#if os(macOS)
import SwiftUI
import BannyCore
import BannyRender
import UniformTypeIdentifiers

/// Banny Studio has two top-level modes.
///
/// Produce is the editor: you place every event yourself and ship an mp4.
/// Live is a scene you describe once and then watch — a model writes the script
/// as it plays, the studio stages it, and the result is written to a .bs as it
/// goes, so a live scene always ends up as an ordinary editable project.
/// Two ways of producing the same show, meant to alternate rather than to be
/// chosen once: prompt a section, fine-tune it on the timeline, prompt the next.
enum StudioMode: String, CaseIterable, Identifiable {
    case produce, live
    var id: String { rawValue }
    var title: String { self == .produce ? "By hand" : "Prompt" }
    var blurb: String {
        self == .produce
            ? "Place every beat yourself on the timeline."
            : "Describe what happens next and let a model write it."
    }
}

// MARK: - Setup

/// The Live setup sheet: everything needed before pressing play.
struct LiveSetupView: View {
    @Binding var brief: LiveBrief
    @Binding var endpoint: LiveModelEndpoint
    @Binding var backgroundURL: URL?
    @Binding var backingTrackURL: URL?
    var catalog: AssetCatalog?
    /// Set while the set is being prepared, so the sheet says what is happening
    /// rather than sitting there looking broken.
    var preparing: String?
    /// The staging for this backdrop, editable before the scene starts.
    @Binding var set: LiveSet?
    @Binding var handPlaced: Bool
    var backdropImage: NSImage?
    var readingSet: Bool
    var onReadSet: () -> Void
    var onPlay: () -> Void
    var onCancel: () -> Void

    @State private var showingBackgroundPicker = false
    @State private var showingTrackPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    sceneSection
                    modelSection
                    castSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 560)
        .overlay {
            if let preparing {
                ZStack {
                    Rectangle().fill(.regularMaterial)
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.large)
                        Text(preparing)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 380)
                        Text("This takes a moment; it happens once.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(28)
                }
                .accessibilityIdentifier("live-preparing")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Live scene").font(.title2.weight(.semibold))
                .accessibilityIdentifier("live-setup-title")
            Text("Describe it once. The model performs it; the studio stages it.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var sceneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("The scene")
            TextEditor(text: $brief.premise)
                .font(.body)
                .frame(minHeight: 70)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.quaternary))
                .overlay(alignment: .topLeading) {
                    if brief.premise.isEmpty {
                        Text("A beach bar at sunset, the last evening of the "
                             + "season. Paste a link and they will have read it.")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5).padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }

            // Each importer hangs off the button that triggers it, so the two
            // presentations never share a view.
            HStack(spacing: 12) {
                LabeledContent("Backdrop") {
                    Button(backgroundURL?.lastPathComponent ?? "Choose image or video…") {
                        showingBackgroundPicker = true
                    }
                    .accessibilityIdentifier("live-choose-backdrop")
                    .fileImporter(isPresented: $showingBackgroundPicker,
                                  allowedContentTypes: [.image, .movie]) { result in
                        if case let .success(url) = result { backgroundURL = url }
                    }
                }
                LabeledContent("Backing track") {
                    Button(backingTrackURL?.lastPathComponent ?? "Optional…") {
                        showingTrackPicker = true
                    }
                    .accessibilityIdentifier("live-choose-track")
                    .fileImporter(isPresented: $showingTrackPicker,
                                  allowedContentTypes: [.audio]) { result in
                        if case let .success(url) = result { backingTrackURL = url }
                    }
                }
            }
            Text("The backing track is the only audio. Characters mime; what they "
                 + "say appears as captions.")
                .font(.caption).foregroundStyle(.secondary)

            if backdropImage != nil {
                LiveSetEditor(set: $set, handPlaced: $handPlaced,
                              backdrop: backdropImage,
                              reading: readingSet, onReadAgain: onReadSet)
                    .coordinateSpace(name: "set")
            }

            Text("The scene runs as long as you keep extending it, half a minute "
                 + "at a time.")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Toggle("Make the lights twinkle", isOn: $brief.shimmerBackdrop)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("live-shimmer")
                Text("Finds the point lights in a still backdrop and animates "
                     + "them. Leaves video and GIFs alone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Model")
            Picker("Server", selection: Binding(
                get: { endpoint.name },
                set: { name in
                    if let preset = LiveModelEndpoint.presets().first(where: { $0.name == name }) {
                        endpoint = preset
                    }
                })) {
                ForEach(LiveModelEndpoint.presets()) { Text($0.name).tag($0.name) }
            }
            .pickerStyle(.segmented)

            if endpoint.shape.scriptName == nil {
                HStack(spacing: 12) {
                    LabeledContent("Address") {
                        TextField("http://127.0.0.1:1234", text: Binding(
                            get: { endpoint.baseURL.absoluteString },
                            set: { if let u = URL(string: $0) { endpoint.baseURL = u } }))
                    }
                    LabeledContent("Model") {
                        TextField("local-model", text: $endpoint.model)
                    }
                }
                Text("A model server on this machine. Run LM Studio and point "
                     + "at it here.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LiveAgentModelPicker(endpoint: $endpoint)
                LiveAgentBridgeNote(shape: endpoint.shape)
            }
        }
    }

    private var castSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("Cast")
                Spacer()
                Button {
                    let n = brief.cast.count
                    brief.cast.append(LiveCastMember(
                        name: "Banny \(n + 1)",
                        body: BannyCore.Body.allCases[n % BannyCore.Body.allCases.count],
                        outfit: LiveCastMember.defaultOutfit(n)))
                } label: { Label("Add", systemImage: "plus") }
            }
            if brief.cast.isEmpty {
                Text("Add the people at this party, and say who they are.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Toggle("Let strangers turn up", isOn: $brief.mayAddCast)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("live-may-add-cast")
                Text("The scene can bring on people you did not cast, up to "
                     + "\(LiveDirector.castLimit) in the room.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Toggle("Let the scene dress the cast", isOn: $brief.mayDressCast)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("live-may-dress-cast")
                Text("Costumes chosen for the premise. Anything you pick "
                     + "yourself is left alone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // By position, not by name. Identifying a row by a field you can
            // edit means every keystroke in the name changes the row's identity,
            // so SwiftUI tears it down and rebuilds it — and the focus goes with
            // it, one letter at a time.
            ForEach(brief.cast.indices, id: \.self) { i in
                LiveCastRow(member: $brief.cast[i], sceneDresses: brief.mayDressCast,
                            catalog: catalog) {
                    brief.cast.remove(at: i)
                }
                .accessibilityIdentifier("live-cast-row-\(i)")
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(readiness).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("live-cancel")
            Button("Play", action: onPlay)
                .keyboardShortcut(.defaultAction)
                .disabled(!isReady || preparing != nil)
        }
        .padding(20)
    }

    private var isReady: Bool {
        !brief.cast.isEmpty && backgroundURL != nil && !brief.premise.isEmpty
    }

    private var readiness: String {
        if brief.cast.isEmpty { return "Add at least one character." }
        if backgroundURL == nil { return "Choose a backdrop." }
        if brief.premise.isEmpty { return "Describe the scene." }
        return "\(brief.cast.count) in the cast"
    }
}

/// Which model the agent runs. Claude's aliases are offered by name; Codex
/// names live in the user's own config, so "Default" follows it and anything
/// else is typed in.
private struct LiveAgentModelPicker: View {
    @Binding var endpoint: LiveModelEndpoint
    @State private var custom = false

    private var suggestions: [(label: String, value: String)] {
        endpoint.shape.suggestedModels
    }

    var body: some View {
        HStack(spacing: 12) {
            Picker("Model", selection: Binding(
                get: {
                    custom || !suggestions.contains(where: { $0.value == endpoint.model })
                        ? "\u{1}custom" : endpoint.model
                },
                set: { choice in
                    custom = choice == "\u{1}custom"
                    if !custom { endpoint.model = choice }
                })) {
                ForEach(suggestions, id: \.value) { Text($0.label).tag($0.value) }
                Divider()
                Text("Custom…").tag("\u{1}custom")
            }
            .frame(maxWidth: 260)
            .accessibilityIdentifier("live-model-picker")

            if custom || !suggestions.contains(where: { $0.value == endpoint.model }) {
                TextField(endpoint.shape == .codex ? "gpt-5-codex" : "claude-opus-5",
                          text: $endpoint.model)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .onChange(of: endpoint.shape) { _, _ in
            // Switching agents must not carry the other one's model name over.
            custom = false
            endpoint.model = ""
        }
        if endpoint.model.isEmpty {
            Text(endpoint.shape == .codex
                 ? "Default follows the model in your ~/.codex/config.toml."
                 : "Default follows whatever `claude` is set to use.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Claude Code and Codex are command-line agents, and a sandboxed app may only
/// run scripts the user installed itself. This says so plainly and hands over
/// the one command that does it.
private struct LiveAgentBridgeNote: View {
    let shape: LiveModelEndpoint.Shape
    @State private var copied = false

    private var installed: Bool {
        #if os(macOS)
        return shape.scriptName.map(LiveScriptRunner.isInstalled) ?? true
        #else
        return false
        #endif
    }

    /// An older bridge still runs, but not the way the app now describes it.
    private var outdated: Bool {
        #if os(macOS)
        return installed && !(shape.scriptName.map(LiveScriptRunner.isCurrent) ?? true)
        #else
        return false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if outdated {
                Label("This bridge is an older version — it may ignore the model "
                      + "you pick, and let the agent read your home folder. "
                      + "Reinstall it:",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                installCommand
            } else if installed {
                Label("Bridge installed — this will use your \(shape == .claudeCode ? "Claude" : "ChatGPT") "
                      + "subscription, no API key.", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                Text("Banny Studio is sandboxed, so it cannot launch a command-line "
                     + "agent itself. It can run a script you install. Paste this in "
                     + "Terminal once:")
                    .font(.caption).foregroundStyle(.secondary)
                installCommand
            }
        }
    }

    @ViewBuilder private var installCommand: some View {
        #if os(macOS)
        if let command = LiveScriptRunner.install(shape) {
            ScrollView(.horizontal) {
                Text(command)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxHeight: 96)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            Button(copied ? "Copied" : "Copy command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            }
            .font(.caption)
        }
        #endif
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// One character: who they are, what they are wearing, and whether the story is
/// allowed to change it.
private struct LiveCastRow: View {
    @Binding var member: LiveCastMember
    var sceneDresses: Bool
    var catalog: AssetCatalog?
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("Name", text: $member.name).frame(width: 130)
                Picker("", selection: $member.body) {
                    ForEach(BannyCore.Body.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .labelsHidden().frame(width: 120)
                Spacer()
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
            }
            TextField("Who they are, and how they behave in a room",
                      text: $member.prompt, axis: .vertical)
                .lineLimit(1...3)
            HStack {
                Toggle("May change wardrobe", isOn: $member.mayChangeWardrobe)
                    .toggleStyle(.checkbox)
                Text("Rare, and only when the story earns it.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                LiveWardrobeButton(outfit: $member.outfit,
                                   chosen: $member.outfitIsChosen,
                                   sceneDresses: sceneDresses,
                                   catalog: catalog)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Dressing a cast member. Every slot the catalog knows about, with whatever
/// it holds — no invented item names, and nothing to remember.
private struct LiveWardrobeButton: View {
    @Binding var outfit: [String: String]
    @Binding var chosen: Bool
    var sceneDresses: Bool
    var catalog: AssetCatalog?
    @State private var showing = false

    /// Slots worth offering, in the order they read on the body.
    private let slots = [12, 4, 6, 11, 9, 10, 3, 13, 8, 2]

    private var summary: String {
        if chosen { return outfit.values.sorted().joined(separator: ", ") }
        return sceneDresses ? "dressed by the scene"
                            : (outfit.isEmpty ? "no wardrobe"
                               : outfit.values.sorted().joined(separator: ", "))
    }

    var body: some View {
        Button {
            showing = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "tshirt")
                Text(summary).lineLimit(1).truncationMode(.tail)
            }
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("live-wardrobe")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(slots, id: \.self) { slot in
                    let items = catalog?.outfits(inSlot: slot) ?? []
                    if !items.isEmpty {
                        LabeledContent(catalog?.slotName(slot) ?? "Slot \(slot)") {
                            Picker("", selection: Binding(
                                get: { outfit["\(slot)"] ?? "" },
                                set: { name in
                                    // An empty choice clears the slot: the schema
                                    // wants the key gone, not set to nothing.
                                    if name.isEmpty { outfit["\(slot)"] = nil }
                                    else { outfit["\(slot)"] = name }
                                    // Touching it makes it yours; the scene
                                    // will not overrule a deliberate choice.
                                    chosen = true
                                })) {
                                Text("—").tag("")
                                ForEach(items, id: \.name) { Text($0.label).tag($0.name) }
                            }
                            .labelsHidden()
                            .frame(width: 190)
                        }
                    }
                }
                Divider()
                HStack {
                    Button("Clear all") { outfit = [:]; chosen = true }
                    if sceneDresses {
                        Button("Let the scene choose") { outfit = [:]; chosen = false }
                    }
                }
                .font(.caption)
            }
            .padding(14)
            .frame(width: 340)
        }
    }
}

#endif
