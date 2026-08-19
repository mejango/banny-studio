import Foundation

/// Runs a live scene: asks the model for the next stretch of script, compiles
/// it into a performance, and keeps the document one step ahead of the playhead.
///
/// Generation is slower than playback, so the director works to a lookahead: it
/// fetches the next batch while the current one is still being performed. If the
/// model falls behind, the scene simply holds — nobody is left mid-sentence.
@MainActor
public final class LiveDirector: ObservableObject {
    public enum State: Equatable {
        case idle
        case writing          // waiting on the model
        case performing       // enough script in hand
        /// The commissioned stretch is written. Nothing more is asked for until
        /// the director is told to extend or to try again.
        case awaitingReview
        case finished
        case failed(String)
    }

    /// A live scene is built half a minute at a time. Every stretch is judged
    /// before the next is written, and a rejected one is redone from where the
    /// last approved stretch ended — so the show grows as one continuous
    /// timeline while staying cheap to revise.
    public static let stretch: Double = 30

    @Published public private(set) var state: State = .idle
    @Published public private(set) var document: ShowDocument
    /// Everything said so far, newest last. Shown in the app and fed back to
    /// the model so the conversation carries.
    @Published public private(set) var transcript: [String] = []
    /// How far the written script reaches, in seconds.
    @Published public private(set) var writtenThrough: Double = 0

    /// How far the model has been commissioned to write.
    @Published public private(set) var commissioned: Double = LiveDirector.stretch
    /// Where the stretch under review begins. Everything before it is approved.
    @Published public private(set) var chunkStart: Double = 0
    /// Bumped whenever the scene is rewritten from the top, so the view knows to
    /// take the playhead back to zero.
    @Published public private(set) var generation = 0

    /// Revisable between sections: what the scene is and who is in it are
    /// answers the director may change their mind about after watching.
    @Published public private(set) var brief: LiveBrief
    /// Everything needed to put the scene back exactly as it stood when the
    /// last stretch was approved. A rewrite returns here rather than to the
    /// opening: earlier stretches have already been accepted.
    private struct Checkpoint {
        var document: ShowDocument
        var compiler: LiveCompiler
        var rng: LiveRandom
        var transcript: [String]
        var writtenThrough: Double
    }
    private var approved: Checkpoint
    /// What the user asked to be different, newest last. Handed to the model.
    private var notes: [String] = []
    /// What the user asked for next. Applies to the coming stretch only —
    /// unlike a correction, "now someone drops a glass" should not keep
    /// happening for the rest of the evening.
    private var direction: String?
    /// How long the section under review was asked to be, so redoing it asks
    /// for the same again rather than silently reverting to the default.
    private var lastAsked: Double = LiveDirector.stretch

    /// Respects a planned length when the scene has one.
    private func capped(_ t: Double) -> Double {
        brief.duration > 0 ? min(brief.duration, t) : t
    }

    /// A scene can grow, but not without limit: every extra body costs staging
    /// room and another voice to keep track of.
    public static let castLimit = 10
    private var seed: UInt64
    /// How the next stretch of script is fetched. A closure, not a client, so
    /// an HTTP model server and a command-line agent are interchangeable.
    private let fetch: @Sendable (String) async throws -> [LiveBeat]
    private var compiler: LiveCompiler
    private var rng: LiveRandom
    private var task: Task<Void, Never>?

    /// Keep this far ahead of the playhead before asking for more.
    public var lookahead: Double = 45
    /// Called after every batch, so the app can save the .bs as it is written.
    public var onBatch: ((ShowDocument) -> Void)?

    public init(brief: LiveBrief, document: ShowDocument,
                beats: @escaping @Sendable (String) async throws -> [LiveBeat],
                room: LiveSet? = nil, seed: UInt64 = 20260814) {
        self.brief = brief
        self.document = document
        self.fetch = beats
        var compiler = LiveCompiler(document: document)
        compiler.room = room
        self.compiler = compiler
        self.seed = seed
        self.rng = LiveRandom(seed: seed)
        self.approved = Checkpoint(document: document, compiler: compiler,
                                   rng: LiveRandom(seed: seed), transcript: [],
                                   writtenThrough: 0)
    }

    /// Starts writing. `playhead` is asked for the current playback position so
    /// the director can stay a lookahead ahead of it without racing to the end.
    public func start(playhead: @escaping @MainActor () -> Double) {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run(playhead: playhead)
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        if state != .finished { state = .idle }
    }

    private func run(playhead: @escaping @MainActor () -> Double) async {
        while !Task.isCancelled {
            // Only a scene with a planned length can run out; otherwise it
            // ends when the director stops asking for more.
            if brief.duration > 0, writtenThrough >= brief.duration {
                state = .finished
                return
            }
            // Written everything that was asked for: stop and wait to be told
            // whether to keep this stretch or try it again.
            if writtenThrough >= commissioned {
                state = .awaitingReview
                try? await Task.sleep(nanoseconds: 300_000_000)
                continue
            }
            // Stay ahead of the playhead, not ahead of the clock.
            let ahead = writtenThrough - playhead()
            if ahead > lookahead {
                state = .performing
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            state = .writing
            let remaining = commissioned - writtenThrough
            let ask = min(60, remaining)
            let prompt = LiveDirector.prompt(brief: brief, transcript: transcript,
                                             secondsToWrite: ask,
                                             elapsed: writtenThrough,
                                             notes: notes, direction: direction,
                                             cast: document.stage.characters.map(\.name),
                                             mayAddCast: brief.mayAddCast)
            do {
                let beats = try await fetch(prompt)
                apply(beats)
            } catch {
                // A model that stumbles should not end the party. Hold, and try
                // again; only a repeated failure stops the scene.
                state = .failed(error.localizedDescription)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
            }
        }
    }

    /// Compiles a batch into the document. Kept separate from the network so it
    /// can be driven directly by tests and by a scripted scene.
    public func apply(_ beats: [LiveBeat]) {
        var next = document
        // Anyone the script walks on who is not in the company yet joins it.
        // Only an entrance can do this, so a misspelt name in a line cannot
        // conjure a second copy of someone who is already on stage.
        for case let .enters(who, _) in beats
        where brief.mayAddCast
           && !next.stage.characters.contains(where: { $0.name == who })
           && next.stage.characters.count < LiveDirector.castLimit {
            let n = next.stage.characters.count
            let wing = n.isMultiple(of: 2) ? -0.2 : 1.2
            var newcomer = Character(body: Body.allCases[n % Body.allCases.count],
                                     x: wing, depth: 0.06, size: 1,
                                     face: n.isMultiple(of: 2) ? 1 : -1,
                                     name: who, speed: 110)
            newcomer.baseOutfit = Dictionary(uniqueKeysWithValues:
                LiveCastMember.defaultOutfit(n).compactMap { key, value in
                    Int(key).map { ($0, value) }
                })
            newcomer.presence = [VisibilityEvent(t: 0, visible: false)]
            newcomer.recStart = StartPose(x: wing, depth: 0.06,
                                          face: n.isMultiple(of: 2) ? 1 : -1)
            next.stage.characters.append(newcomer)
            compiler.register(name: who, index: n, x: wing, speed: 110)
        }
        let known = Set(next.stage.characters.map(\.name))
        let usable = beats.filter { $0.who.map(known.contains) ?? true }
        compiler.apply(usable, to: &next, rng: &rng)
        document = next
        writtenThrough = compiler.now
        for case let .line(who, text, _) in usable {
            transcript.append("\(who): \(text)")
        }
        onBatch?(next)
        // A direction applies to the stretch it was given for, and no further.
        direction = nil
        state = writtenThrough >= commissioned ? .awaitingReview : .performing
    }

    /// Picks the scene back up after it has been edited by hand.
    ///
    /// Prompting and fine-tuning are meant to alternate, so suspending a scene
    /// must not throw the evening away: the transcript, the notes and the
    /// approved mark all stand. What cannot stand is the compiler's belief
    /// about the stage, because the document has been edited since — so it is
    /// rebuilt from the document rather than trusted.
    public func resume(with document: ShowDocument) {
        self.document = document
        writtenThrough = max(writtenThrough, chunkStart)
        compiler.resync(with: document, at: writtenThrough)
        // What was written is what was approved: hand edits are never a draft
        // waiting to be thrown away by a later Try again.
        approved = Checkpoint(document: document, compiler: compiler, rng: rng,
                              transcript: transcript, writtenThrough: writtenThrough)
        chunkStart = writtenThrough
        commissioned = writtenThrough
        state = .awaitingReview
    }

    // MARK: - Review

    /// Accepts the stretch under review and commissions the next half minute.
    /// `direction` is free text for what should happen next, including asking
    /// for someone new to walk in.
    public func extend(seconds: Double = LiveDirector.stretch, direction: String = "") {
        let asked = direction.trimmingCharacters(in: .whitespacesAndNewlines)
        self.direction = asked.isEmpty ? nil : asked
        let wanted = max(5, seconds)
        lastAsked = wanted
        // What was just watched is now settled; a later rewrite starts here.
        approved = Checkpoint(document: document, compiler: compiler, rng: rng,
                              transcript: transcript, writtenThrough: writtenThrough)
        chunkStart = writtenThrough
        commissioned = capped(writtenThrough + wanted)
        if commissioned > writtenThrough { state = .writing }
    }

    /// Rewrites the brief itself — the premise, the cast, their descriptions.
    /// The section under review is discarded with it, because it was written to
    /// a brief that no longer stands.
    public func revise(_ brief: LiveBrief, redo: Bool = true) {
        self.brief = brief
        if redo { rewrite(feedback: "") }
    }

    /// Throws the current stretch away and writes it again, told what was wrong.
    /// Feedback accumulates: the third attempt still knows what the first two
    /// got wrong, which is the only way "less of that" means anything.
    public func rewrite(feedback: String) {
        let note = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { notes.append(note) }
        document = approved.document
        compiler = approved.compiler
        transcript = approved.transcript
        writtenThrough = approved.writtenThrough
        chunkStart = approved.writtenThrough
        seed &+= 7919                      // a different draw, not the same one
        rng = LiveRandom(seed: seed)
        commissioned = capped(approved.writtenThrough + lastAsked)
        generation += 1
        state = .writing
        onBatch?(document)
    }

    /// Every link in a piece of text, in the order they appear.
    static func urls(in text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult
            .CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap {
            $0.url.map(\.absoluteString)
        }
    }

    /// What there is to wear, and who is already dressed.
    ///
    /// The list comes from the real catalog, so the model cannot invent an item
    /// that does not exist — a made-up name simply leaves the slot empty.
    static func wardrobeBrief(_ brief: LiveBrief) -> String {
        let slotNames = [2: "backside", 3: "necklace", 4: "head", 6: "glasses",
                         8: "legs", 9: "suit", 10: "suit bottom", 11: "suit top",
                         12: "head top", 13: "hand"]
        let rows = brief.wardrobe.keys.compactMap(Int.init).sorted().compactMap { slot -> String? in
            guard let items = brief.wardrobe["\(slot)"], !items.isEmpty else { return nil }
            return "  \(slot) \(slotNames[slot] ?? "slot"): \(items.joined(separator: ", "))"
        }.joined(separator: "\n")

        let fixed = brief.cast.filter(\.outfitIsChosen).map(\.name)
        let leave = fixed.isEmpty ? ""
            : "\n\(fixed.joined(separator: ", ")) "
              + "\(fixed.count == 1 ? "is" : "are") dressed already — leave "
              + "\(fixed.count == 1 ? "that costume" : "those costumes") alone."

        return """


        WARDROBE
        Dress the cast for this scene before it starts: open with a `wardrobe` \
        beat for each of them, before anyone's first `enters`. They are out of \
        shot until they walk on, so nobody sees the change. Costume is a \
        character note — pick what the premise and their description ask for, \
        not what is nearest. One item per slot; leave a slot out to keep it \
        empty.\(leave)

        What there is to wear:
        \(rows)
        """
    }

    /// The evening as the company remembers it.
    ///
    /// A plain tail of the last N lines is not a memory — it is amnesia with a
    /// window, and it makes callbacks impossible. How the evening began is
    /// worth keeping whole, so the opening stays verbatim; the middle thins out
    /// the way the middle of an evening does; recent talk is kept in full
    /// because it is what is being answered.
    static func remembered(_ transcript: [String], keepingRecent recent: Int = 50,
                           andOpening opening: Int = 14) -> String {
        guard transcript.count > recent + opening else {
            return transcript.joined(separator: "\n")
        }
        let head = transcript.prefix(opening)
        let tail = transcript.suffix(recent)
        let middle = transcript.dropFirst(opening).dropLast(recent)
        // Every third line of the middle, so the shape of it survives without
        // the bulk — the way you recall some of an hour and not all of it.
        let hazy = middle.enumerated().filter { $0.offset % 3 == 0 }.map(\.element)
        return (head
                + ["", "(earlier on, as you half remember it)"]
                + hazy.suffix(30)
                + ["", "(and just now)"]
                + tail).joined(separator: "\n")
    }

    /// What the model is asked for. It is told what it controls and — just as
    /// importantly — what it does not: position, facing, spacing and timing are
    /// staged deterministically, so a script cannot break the blocking.
    public static func prompt(brief: LiveBrief, transcript: [String],
                              secondsToWrite: Double, elapsed: Double,
                              notes: [String] = [], direction: String? = nil,
                              cast onstage: [String] = [],
                              mayAddCast: Bool = true) -> String {
        // Only the first section dresses anyone: after that they are dressed.
        let dressing = (brief.mayDressCast && elapsed <= 0 && !brief.wardrobe.isEmpty)
            ? LiveDirector.wardrobeBrief(brief) : ""

        // Links are handed over whole. The agent can open them itself; a model
        // server cannot, and simply reads them as context. A link pasted into
        // the premise counts too — people put them where they are thinking,
        // not where a field expects them, and a link nobody explains how to
        // use is a link that gets recited aloud.
        let strays = LiveDirector.urls(in: brief.premise)
            .filter { !brief.references.contains($0) }
        let links = ([brief.references.trimmingCharacters(in: .whitespacesAndNewlines)]
                     + strays)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let reading = links.isEmpty ? "" : """


        WHAT THEY HAVE BEEN LOOKING AT
        Read these, and let them into the talk the way people bring up \
        something they saw earlier — in passing, half-remembered, argued about, \
        never recited. Nobody reads a link aloud or explains what a website is.
        \(links)
        """

        let cast = brief.cast.map { member in
            let wardrobe = member.mayChangeWardrobe
                ? "may change wardrobe, but only when the story earns it"
                : "wardrobe is fixed"
            return "- \(member.name): \(member.prompt) [\(wardrobe)]"
        }.joined(separator: "\n")

        let history = transcript.isEmpty
            ? "Nothing has happened yet. Open the scene quietly."
            : LiveDirector.remembered(transcript)

        // An open-ended scene never announces its own ending; the director
        // asks for one when they want it.
        let remaining = brief.duration > 0 ? brief.duration - elapsed : .infinity
        let stage = remaining < 90
            ? "This is the END of the scene. Start saying goodbye; let people leave."
            : (elapsed <= 0
               ? "This is the OPENING of the scene. Start quietly, with few people."
               : "The scene is already under way — carry straight on from the last line.")

        let standing = notes.isEmpty ? "" : """


        NOTES FROM THE DIRECTOR
        Earlier attempts were rejected. Every one of these still applies:
        \(notes.map { "- \($0)" }.joined(separator: "\n"))
        """

        let next = direction.map { """


        WHAT HAPPENS NEXT
        The director has asked for this in the stretch you are writing now:
        \($0)
        """ } ?? ""

        let company = onstage.isEmpty ? "" : """


        THE COMPANY SO FAR
        \(onstage.joined(separator: ", ")). Nobody is in the room until an
        `enters` beat walks them in — write one before anyone's first line, and
        again for anyone who left earlier.
        \(mayAddCast
          ? "Strangers may turn up: walk somebody on under a new name and they "
            + "will be dressed and staged for you. Give them a voice of their "
            + "own and keep it. At most \(castLimit) people in total."
          : "This is a closed cast — no one outside the list above ever appears.")
        """

        return """
        You are writing a wordless-film scene being performed live by pixel-art \
        characters. There is no audio: every line appears as a caption above \
        whoever says it. Return ONLY a JSON object, no prose, no code fence.

        THE SCENE
        \(brief.premise)

        THE CAST
        \(cast)\(reading)\(dressing)\(company)\(standing)\(next)

        SO FAR
        \(history)

        NOW
        \(stage) Write about \(Int(secondsToWrite)) seconds — roughly \
        \(max(5, Int(secondsToWrite / 4))) beats. Keep it moving: a pause is a \
        beat, not a gap, so never ask for more than two seconds of it. \(Int(elapsed))s have been \
        performed so far.

        HOW TO WRITE IT
        This is a real room, not a sketch. People talk the way they actually \
        do: mostly small talk, until something inside it opens and the thing \
        turns serious for a while, then closes again and the small talk \
        resumes. Let that happen by itself, out of whatever was just said — \
        nobody announces a subject or arrives carrying one.

        Every line answers the one before it. At least two of the cast are good \
        at "yes, and": they take what they were handed, accept its premise, and \
        add the next thing to it, so an offhand remark can grow into the best \
        exchange of the scene. The others deflect, understate, or change the \
        subject — that contrast is what makes the "yes, and" land.

        Every voice is its own. Keep the rhythms distinct: one long-winded, one \
        clipped, one who never quite finishes a sentence. A person should be \
        recognisable with their name covered.

        You remember all of it, not only the last thing said — and you \
        remember it the way people do, some parts far better than others. A \
        joke from earlier comes back. A small admission is quietly never \
        mentioned again. A nickname sticks. Reach back now and then, sparingly, \
        the way memory actually surfaces.

        Keep lines short enough to read at a glance — one thought each, rarely \
        more than a dozen words. Nobody narrates or describes the room.

        Never write the reversal — "That's not cheating, that's continuity", \
        "It isn't a bar, it's a waiting room", "not X, but Y". It is the \
        cadence of something clever rather than something said, every \
        character falls into it at once, and it is cut before it reaches the \
        screen. Say the second half and stop.

        COMING AND GOING
        Nobody blinks out of existence in the middle of a conversation. Someone \
        who wants to leave steps away from the group first — a `move` to \
        another zone — and goes from there, or waits until they are the last \
        one standing. The exception, and the usual case, is the Banny Vision \
        Pro, if the setting can carry it: a character puts the headset on \
        (`wardrobe`, slot 6, `banny-vision-pro`) and drops out of the room \
        without leaving it, present but gone.

        Use it the way people use a phone in a room. You put it on when you \
        are alone, or waiting, or cannot get into the conversation — it is \
        cover as much as distraction. You put it away when somebody comes over \
        to you, and before you speak; the studio does that for you, so do not \
        write it. What is worth writing is somebody choosing to take it off: \
        two people who have been behind their headsets all evening putting \
        them down at the same moment is an event, and needs no line to explain \
        it. The others may well have opinions either way.

        Somebody standing alone is not dead air — it is the best shot in the \
        show. Let one person be left on their own for a while, or the place be \
        briefly empty, especially at the start and end of a stretch. A scene \
        that is always crowded has no shape.

        You control WHO speaks, WHAT they say, and WHICH part of the room they \
        are in. You do NOT control where they stand, which way they face, how \
        they are spaced, or timing — all of that is staged for you.

        BEATS
        {"beat":"line","who":"NAME","text":"...","kind":"say|cut|over|quiet|laugh"}
          say  = an ordinary turn
          cut  = takes the floor before the last speaker finishes
          over = lands on top of a line that carries on
          quiet= a confidence — they lean in, meant for one person
          laugh= the room goes after it, rocking back

        `quiet` and `laugh` are how the bodies lean. They are the only things \
        that move a performer off the vertical, so use them when the line \
        earns it and not otherwise — a scene where everyone is permanently \
        leaning says nothing. Most lines are `say`.
        {"beat":"move","who":"NAME","zone":"front|middle|far"}
        {"beat":"enters","who":"NAME","zone":"front|middle|far"}
        {"beat":"exits","who":"NAME"}
        {"beat":"gesture","who":"NAME","name":"nod|listen|glance|sip|laugh|brow|squint|blink2|doubletake|eyeroll|shy|hesitate|secret|bellylaugh|recoil|greet|cheer"}
        {"beat":"hold","seconds":2}   (2s maximum — longer reads as a stall)
        {"beat":"wardrobe","who":"NAME","slot":6,"item":"banny-vision-pro"}

        A zone is a conversation, and the bodies show it: people in one zone \
        stand together and face each other. So everyone taking part in the same \
        exchange must be in the SAME zone — if someone answers from elsewhere, \
        the room reads as two separate conversations no matter what is said. \
        Use a different zone only for a genuinely separate conversation \
        happening at the same time, and keep at most two of those going.

        ANSWER
        {"beats":[ ... ]}
        """
    }
}
