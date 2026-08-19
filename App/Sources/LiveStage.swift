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

    @StateObject private var director: LiveDirector
    @State private var startedAt = Date()
    @State private var music: AVAudioPlayer?
    /// Clock for the waiting counter, ticked with the playhead.
    @State private var now = Date()
    @State private var writingSince: Date?
    @State private var feedback = ""
    /// Replay of the written stretch while it is being judged.
    /// How long the next section should be. Thirty seconds unless told otherwise.
    @State private var nextSeconds: Double = LiveDirector.stretch
    @State private var replaying = false
    @State private var replayFrom: Double = 0
    @State private var replayStartedAt = Date()

    init(model: StudioModel, file: ShowDocumentFile, brief: LiveBrief,
         beats: @escaping @Sendable (String) async throws -> [LiveBeat],
         backingTrackURL: URL?, room: LiveSet? = nil,
         onExit: @escaping () -> Void) {
        self.model = model
        self.file = file
        self.brief = brief
        self.backingTrackURL = backingTrackURL
        self.onExit = onExit
        _director = StateObject(wrappedValue: LiveDirector(
            brief: brief, document: model.document, beats: beats, room: room))
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
            Button("Stop", action: onExit)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityIdentifier("live-transport")
    }

    /// Nothing has been performed yet, so the stage is empty. Say why.
    private var openingCurtain: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Writing the opening\u{2026}")
                .font(.callout).foregroundStyle(.secondary)
            Text(waited > 0 ? "\(waited)s" : " ")
                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("live-opening-curtain")
    }

    private var isWriting: Bool {
        if case .writing = director.state { return true }
        return false
    }

    /// How long the current wait has been going, in whole seconds.
    private var waited: Int {
        guard let writingSince else { return 0 }
        return max(0, Int(now.timeIntervalSince(writingSince)))
    }

    private var statusColour: Color {
        switch director.state {
        case .performing: return .green
        case .writing: return .yellow
        case .awaitingReview: return .blue
        case .failed: return .red
        case .finished, .idle: return .secondary
        }
    }

    private var status: String {
        switch director.state {
        case .idle: return "Ready"
        case .writing:
            let what = director.writtenThrough <= 0
                ? "Writing the opening"
                : "Writing \(Int(director.chunkStart))–\(Int(director.commissioned))s"
            // The count is what tells you it is still going, not stuck.
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

#endif
