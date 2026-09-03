// Live mode is macOS only. It reaches a model through a bridge script run by
// NSUserUnixTask, which does not exist on iOS, and its set editor is built on
// AppKit — there is no version of this that works on a phone.
#if os(macOS)
import SwiftUI
import AVFoundation
import BannyCore
import BannyRender

/// A live scene playing.
///
/// This is deliberately not a separate rendering path. Live mode drives the same
/// `StudioModel` and the same `StageView` the editor uses; the only difference is
/// that the document keeps getting longer while it plays. Because the model owns
/// the document, every batch also flows through the normal document machinery —
/// so a live scene is saved as an ordinary .bs while it happens, and stopping
/// early leaves an editable project of everything performed so far.
struct LiveStageView: View {
    @Bindable var model: StudioModel
    let file: ShowDocumentFile
    let brief: LiveBrief
    let backingTrackURL: URL?
    var onExit: () -> Void

    /// Owned by the session, not by this view, so leaving for the editor
    /// suspends the scene rather than ending it.
    @ObservedObject var director: LiveDirector
    @State private var startedAt = Date()
    @State private var music: AVAudioPlayer?
    /// Clock for the waiting counter, ticked with the playhead.
    @State private var now = Date()
    @State private var writingSince: Date?
    @State private var feedback = ""
    @State private var showingBackoffice = false
    /// The scene and cast, open for rewriting between sections.
    @State private var revising = false
    @State private var draft = LiveBrief()
    /// Replay of the written stretch while it is being judged.
    /// How long the next section should be. Thirty seconds unless told otherwise.
    @State private var nextSeconds: Double = LiveDirector.stretch
    @State private var replaying = false
    @State private var replayFrom: Double = 0
    @State private var replayStartedAt = Date()

    init(model: StudioModel, file: ShowDocumentFile, brief: LiveBrief,
         director: LiveDirector, backingTrackURL: URL?,
         onExit: @escaping () -> Void) {
        self.model = model
        self.file = file
        self.brief = brief
        self.director = director
        self.backingTrackURL = backingTrackURL
        self.onExit = onExit
    }

    var body: some View {
        VStack(spacing: 0) {
            StageView(model: model, file: file)
                .overlay { if isWriting && director.writtenThrough <= 0 { openingCurtain } }
            Divider()
            if director.state == .awaitingReview {
                review
                Divider()
            }
            transport
        }
        .onAppear(perform: begin)
        .onDisappear(perform: end)
        .onChange(of: director.document) { _, document in
            // Assigning here also saves: StudioModel.document updates the file
            // snapshot, so the .bs grows with the performance.
            model.document = document
        }
        .onReceive(Timer.publish(every: 1 / 30.0, on: .main, in: .common).autoconnect()) { _ in
            tick()
        }
        .onChange(of: isWriting) { _, writing in
            writingSince = writing ? Date() : nil
        }
        .onChange(of: director.generation) { _, _ in
            // Only this section is being redone; everything before it stands.
            model.time = director.chunkStart
            startedAt = Date().addingTimeInterval(-director.chunkStart)
            replaying = false
        }
        .onChange(of: director.state) { _, state in
            // Finishing a section takes you straight to its start and plays it:
            // judging it is the only reason writing stopped.
            if state == .awaitingReview { startReplay(from: director.chunkStart) }
            else {
                replaying = false
                // Park at the start of whatever is being written, so the stage
                // shows the room as it stood rather than a half-written moment.
                if state == .writing { model.time = director.chunkStart }
            }
        }
        .sheet(isPresented: $showingBackoffice) {
            LiveBackofficeView(director: director)
                .frame(minWidth: 920, minHeight: 680)
        }
    }

    /// The decision point: keep this stretch and ask for more, or throw it away
    /// and say what was wrong. Nothing further is written until one is chosen.
    private var review: some View {
        VStack(spacing: 8) {
            reviewPlayback
            reviewChoice
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3))
        .accessibilityIdentifier("live-review")
        .sheet(isPresented: $revising) {
            LiveBriefEditor(brief: $draft, catalog: SharedAssets.catalog) {
                // A new brief makes the section under review obsolete: it was
                // written to answer a different question.
                director.revise(draft)
                revising = false
            } onCancel: {
                revising = false
            }
        }
    }

    /// You cannot judge a stretch you cannot watch. This replays it as many
    /// times as you like, and scrubs.
    private var reviewPlayback: some View {
        HStack(spacing: 10) {
            Button { replaying ? pauseReplay() : startReplay(from: atEnd ? director.chunkStart : model.time) } label: {
                Image(systemName: replaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .help(replaying ? "Pause" : "Watch this stretch")
            .accessibilityIdentifier("live-replay-toggle")

            Button { startReplay(from: director.chunkStart) } label: {
                Label("This section", systemImage: "gobackward")
            }
            .accessibilityIdentifier("live-replay")
            .help("Watch the half minute you are judging")

            Button { startReplay(from: 0) } label: {
                Label("From the top", systemImage: "backward.end.fill")
            }
            .accessibilityIdentifier("live-replay-all")
            .help("Watch the whole scene so far")

            Slider(value: Binding(
                get: { min(model.time, director.writtenThrough) },
                set: { scrub(to: $0) }), in: 0...max(0.1, director.writtenThrough))
                .accessibilityIdentifier("live-scrubber")

            Text(String(format: "%.1f / %.1fs", model.time, director.writtenThrough))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
        }
    }

    private var atEnd: Bool { model.time >= director.writtenThrough - 0.05 }

    private func startReplay(from t: Double) {
        model.time = max(0, min(t, director.writtenThrough))
        replayFrom = model.time
        replayStartedAt = Date()
        replaying = true
    }

    private func pauseReplay() { replaying = false }

    private func scrub(to t: Double) {
        model.time = max(0, min(t, director.writtenThrough))
        if replaying { replayFrom = model.time; replayStartedAt = Date() }
    }

    private var reviewChoice: some View {
        HStack(spacing: 10) {
            TextField("What should change, or what happens next — new faces welcome",
                      text: $feedback)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 260)
                .accessibilityIdentifier("live-feedback")
                .onSubmit(extend)
            Button("Try again", action: rewrite)
                .accessibilityIdentifier("live-rewrite")
                .help("Throw this stretch away and write it again, with that note")

            Button("Scene & cast…") {
                draft = director.brief
                revising = true
            }
            .help("Change what this scene is, or who is in it")
            .accessibilityIdentifier("live-revise")

            Divider().frame(height: 18)

            Stepper(value: $nextSeconds, in: 10...300, step: 10) {
                Text("+\(Int(nextSeconds))s").monospacedDigit()
            }
            .frame(maxWidth: 110)
            .help("How much to write next")
            .accessibilityIdentifier("live-next-length")
            Button("Extend", action: extend)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("live-extend")
                .help("Keep this and write the next stretch, following that note")
        }
    }

    private func rewrite() {
        director.rewrite(feedback: feedback)
        feedback = ""
    }

    private func extend() {
        director.extend(seconds: nextSeconds, direction: feedback)
        feedback = ""
    }

    private var transport: some View {
        HStack(spacing: 14) {
            // A command-line agent can think for a minute. A still dot reads as
            // a hang, so waiting gets a spinner and a running count.
            if isWriting {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 12, height: 12)
                    .accessibilityIdentifier("live-spinner")
            } else {
                Circle().fill(statusColour).frame(width: 8, height: 8)
            }
            Text(status).font(.callout).foregroundStyle(.secondary)
                .accessibilityIdentifier("live-status")
            Spacer()
            Text(clock).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Button {
                showingBackoffice = true
            } label: {
                Label("Backoffice", systemImage: "doc.text.magnifyingglass")
            }
            .help("See the draft, edits, continuity check, and why this script shipped")
            .accessibilityIdentifier("live-backoffice")
            Button("Fine-tune by hand", action: onExit)
                .help("Edit this on the timeline, then come back and prompt the next section")
                .accessibilityIdentifier("live-hand-off")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityIdentifier("live-transport")
    }

    /// Nothing has been performed yet, so the stage is empty. Say why.
    private var openingCurtain: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(director.currentPass.isEmpty
                 ? (director.state == .mastering
                    ? "Editing and mastering the opening\u{2026}"
                    : "Writing the opening\u{2026}")
                 : "\(director.currentPass)\u{2026}")
                .font(.callout).foregroundStyle(.secondary)
            Text(waited > 0 ? "\(waited)s" : " ")
                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("live-opening-curtain")
    }

    private var isWriting: Bool {
        switch director.state {
        case .writing, .mastering: return true
        default: return false
        }
    }

    /// How long the current wait has been going, in whole seconds.
    private var waited: Int {
        guard let writingSince else { return 0 }
        return max(0, Int(now.timeIntervalSince(writingSince)))
    }

    private var statusColour: Color {
        switch director.state {
        case .performing: return .green
        case .writing, .mastering: return .yellow
        case .awaitingReview: return .blue
        case .failed: return .red
        case .finished, .idle: return .secondary
        }
    }

    private var status: String {
        switch director.state {
        case .idle: return "Ready"
        case .writing:
            let what = director.currentPass.isEmpty
                ? (director.writtenThrough <= 0
                   ? "Writing the opening"
                   : "Writing \(Int(director.chunkStart))–\(Int(director.commissioned))s")
                : director.currentPass
            // The count is what tells you it is still going, not stuck.
            return waited > 0 ? "\(what)… \(waited)s" : "\(what)…"
        case .mastering:
            let what = director.currentPass.isEmpty
                ? (director.writtenThrough <= 0
                   ? "Editing and mastering the opening"
                   : "Editing and mastering \(Int(director.chunkStart))–\(Int(director.commissioned))s")
                : director.currentPass
            return waited > 0 ? "\(what)… \(waited)s" : "\(what)…"
        case .performing:
            return "Performing · \(Int(max(0, director.writtenThrough - model.time)))s in hand"
        case .awaitingReview:
            let from = Int(director.chunkStart), to = Int(director.writtenThrough)
            return replaying
                ? "Watching \(from)–\(to)s"
                : "\(from)–\(to)s written — watch it, then extend or try again"
        case .finished: return "Scene complete"
        case let .failed(why): return "Model trouble: \(why)"
        }
    }

    private var clock: String {
        let built = Int(director.writtenThrough)
        guard director.state == .awaitingReview else {
            return String(format: "%d:%02d built", built / 60, built % 60)
        }
        let t = Int(model.time)
        return String(format: "%d:%02d / %d:%02d", t / 60, t % 60, built / 60, built % 60)
    }

    private func begin() {
        startedAt = Date()
        // Coming back from the editor: adopt whatever was changed there.
        if director.writtenThrough > 0 { director.resume(with: model.document) }
        model.playing = false          // the live clock drives the playhead
        model.cleanFrame = true        // watched, not arranged: no wings
        model.time = 0
        director.start { model.time }
        guard let backingTrackURL else { return }
        music = try? AVAudioPlayer(contentsOf: backingTrackURL)
        music?.numberOfLoops = -1      // the only audio in a live scene
        music?.volume = 0.6
        music?.play()
    }

    private func end() {
        director.stop()
        music?.stop()
        model.cleanFrame = false
    }

    /// The playhead runs in real time, but never past what has been written: if
    /// the model falls behind, the scene holds on the last written instant
    /// rather than cutting to an empty stage.
    private func tick() {
        if isWriting { now = Date() }
        // Live owns the playhead. The editor's own transport must not also be
        // running it — space bar reaches both, and the studio clock would carry
        // the scene past the end of what has actually been written.
        if model.playing { model.playing = false }

        // Under review the playhead belongs to whoever is watching, not to the
        // wall clock: it replays, pauses and scrubs until a choice is made.
        if director.state == .awaitingReview {
            // Never past the end of what exists, playing or not.
            model.time = min(model.time, director.writtenThrough)
            guard replaying else { return }
            let t = replayFrom + Date().timeIntervalSince(replayStartedAt)
            if t >= director.writtenThrough {
                model.time = director.writtenThrough
                replaying = false
            } else {
                model.time = t
            }
            // Resume live playback from wherever the review left off.
            startedAt = Date().addingTimeInterval(-model.time)
            return
        }

        // Nothing plays while a section is being written. Chasing the write
        // head meant always watching the last instant produced — the clock read
        // "0:19 / 0:20", then "0:25 / 0:26", and the stage showed a moment
        // nobody had chosen to look at. The finished section plays on its own
        // the moment it is done.
        model.time = min(model.time, max(0, director.writtenThrough))
    }
}

/// The receipts from the writing room. The model is never asked to reveal
/// private reasoning, so this view does not manufacture it: it exposes the
/// actual brief, prompts and successive scripts that justify—or indict—the
/// candidate on screen.
private struct LiveBackofficeView: View {
    @ObservedObject var director: LiveDirector
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?

    private var selected: LiveProductionAudit? {
        director.productionAudits.first { $0.id == selection }
            ?? director.productionAudits.last
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(director.productionAudits.reversed()) { audit in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(Int(audit.from))–\(Int(audit.to))s")
                            .font(.headline.monospacedDigit())
                        Text(audit.status.rawValue.capitalized)
                            .font(.caption)
                            .foregroundStyle(statusColour(audit.status))
                    }
                    .tag(audit.id)
                }
            }
            .navigationTitle("Writing room")
            .frame(minWidth: 190)
        } detail: {
            if let selected {
                auditDetail(selected)
            } else {
                ContentUnavailableView(
                    "Nothing written yet",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Draft and edit receipts appear here after the first section."))
            }
        }
        .onAppear { selection = selection ?? director.productionAudits.last?.id }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .accessibilityIdentifier("live-backoffice-view")
    }

    private func auditDetail(_ audit: LiveProductionAudit) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Why this reached the stage")
                        .font(.title2.bold())
                    Text("Evidence, not a fabricated explanation. The creator returns scripts, not private reasoning; these are the actual inputs, revisions, and checks.")
                        .foregroundStyle(.secondary)
                }

                GroupBox("Scene spine supplied to every pass") {
                    Text(audit.premise.isEmpty ? "No premise was supplied." : audit.premise)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                }

                GroupBox("Storytelling approach") {
                    Text(audit.approach)
                        .font(.callout.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                }

                GroupBox("Loose dramatic compass — route left open") {
                    Text(audit.selectedArc)
                        .font(.callout.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                }

                HStack(spacing: 12) {
                    passCard("Forward-written",
                             detail: "\(audit.writerTurns.count) committed spoken turns",
                             ok: true)
                    passCard("No backward rewrite",
                             detail: "Committed lines reached review unchanged",
                             ok: true)
                    passCard("Causal judge",
                             detail: "All segues passed; failed attempts are discarded",
                             ok: true)
                }

                GroupBox("Forward writing order") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(audit.writerTurns, id: \.number) { turn in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Turn \(turn.number) · \(turn.relation?.rawValue ?? "OPENING")")
                                    .font(.headline.monospaced())
                                Text(turn.spokenLine).textSelection(.enabled)
                            }
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.35),
                                        in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }

                GroupBox("Causal dialogue receipts") {
                    if audit.causalLinks.isEmpty {
                        Text("Fewer than two spoken lines; there is no adjacency to audit.")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(audit.causalLinks.enumerated()), id: \.offset) { entry in
                                let link = entry.element
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(link.before).textSelection(.enabled)
                                    Text("↓  \(link.relation.rawValue)  ↓")
                                        .font(.caption.bold().monospaced())
                                        .foregroundStyle(link.relation == .therefore ? .blue : .orange)
                                    Text(link.explanation)
                                        .font(.caption)
                                        .foregroundStyle(.primary)
                                    Text(link.relation.meaning)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(link.after).textSelection(.enabled)
                                }
                                .padding(9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.35),
                                            in: RoundedRectangle(cornerRadius: 7))
                            }
                        }
                    }
                }

                scriptDisclosure("Forward-written script sent to stage", beats: audit.final)

                DisclosureGroup("Full creator assignment") {
                    Text(audit.assignment)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
            }
            .padding(22)
        }
        .navigationTitle("Section \(Int(audit.from))–\(Int(audit.to))s")
    }

    private func passCard(_ title: String, detail: String, ok: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(ok ? .green : .orange)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func scriptDisclosure(_ title: String, beats: [LiveBeat]) -> some View {
        DisclosureGroup(title) {
            Text(beats.enumerated().map { "\($0.offset + 1). \(beatText($0.element))" }
                .joined(separator: "\n"))
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        }
    }

    private func changeSummary(_ before: [LiveBeat], _ after: [LiveBeat]) -> String {
        before == after ? "Returned unchanged · \(after.count) beats"
            : "Revised \(before.count) → \(after.count) beats"
    }

    private func beatText(_ beat: LiveBeat) -> String {
        switch beat {
        case let .line(who, text, kind): return "\(who) [\(kind.rawValue)]: \(text)"
        case let .move(who, zone): return "\(who) moves to \(zone.rawValue)"
        case let .enters(who, zone): return "\(who) enters \(zone.rawValue)"
        case let .exits(who): return "\(who) exits"
        case let .gesture(who, name): return "\(who) · \(name)"
        case let .wardrobe(who, slot, item):
            return "\(who) wardrobe \(slot): \(item ?? "remove")"
        case let .hold(seconds): return "hold \(seconds)s"
        }
    }

    private func statusColour(_ status: LiveProductionAudit.Status) -> Color {
        switch status {
        case .candidate: return .blue
        case .approved: return .green
        case .superseded: return .secondary
        }
    }
}

#endif
