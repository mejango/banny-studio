import Foundation

/// The only two story-bearing relationships allowed between successive lines.
/// These are editorial labels; they are stripped before dialogue reaches the stage.
public enum LiveCausalRelation: String, Equatable, Sendable {
    case therefore = "THEREFORE"
    case but = "BUT"

    public var meaning: String {
        switch self {
        case .therefore:
            return "The next line is a direct consequence that advances the same story."
        case .but:
            return "The next line creates direct narrative tension and turns the story."
        }
    }
}

public struct LiveCausalLink: Equatable, Sendable {
    public let before: String
    public let relation: LiveCausalRelation
    public let after: String
    /// The independent judge's concrete account of why this particular segue passes.
    public let explanation: String

    public init(before: String, relation: LiveCausalRelation, after: String,
                explanation: String = "") {
        self.before = before
        self.relation = relation
        self.after = after
        self.explanation = explanation
    }
}

/// The committed order of a forward-written exchange. Richer causal explanations
/// come from the later adversarial judge instead of a private writer schema.
public struct LiveWriterTurnReceipt: Equatable, Sendable {
    public let number: Int
    public let relation: LiveCausalRelation?
    public let spokenLine: String

    public init(number: Int, relation: LiveCausalRelation?, spokenLine: String) {
        self.number = number
        self.relation = relation
        self.spokenLine = spokenLine
    }
}

/// What actually happened in the writing room for one generated stretch.
/// This is production evidence, not invented chain-of-thought: the brief,
/// scripts before and after each pass, and whether a pass returned usable work.
public struct LiveProductionAudit: Identifiable, Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case candidate
        case approved
        case superseded
    }

    public let id: UUID
    public var status: Status
    public let from: Double
    public let to: Double
    public let premise: String
    public let approach: String
    public let assignment: String
    public let arcCandidates: [String]
    public let selectedArc: String
    public let writerTurns: [LiveWriterTurnReceipt]
    public let final: [LiveBeat]
    public let causalLinks: [LiveCausalLink]
    public let causalJudgePasses: Int

    public init(id: UUID = UUID(), status: Status = .candidate,
                from: Double, to: Double, premise: String, approach: String,
                assignment: String, arcCandidates: [String], selectedArc: String,
                writerTurns: [LiveWriterTurnReceipt],
                final: [LiveBeat], causalLinks: [LiveCausalLink],
                causalJudgePasses: Int) {
        self.id = id
        self.status = status
        self.from = from
        self.to = to
        self.premise = premise
        self.approach = approach
        self.assignment = assignment
        self.arcCandidates = arcCandidates
        self.selectedArc = selectedArc
        self.writerTurns = writerTurns
        self.final = final
        self.causalLinks = causalLinks
        self.causalJudgePasses = causalJudgePasses
    }
}

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
        case writing          // waiting on the first draft
        case mastering        // editing the draft before anyone sees it
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
    /// The concrete desk in the writing room currently doing work. This keeps
    /// a multi-pass generation honest in the UI instead of one vague spinner.
    @Published public private(set) var currentPass: String = ""
    @Published public private(set) var document: ShowDocument
    /// Everything said so far, newest last. Shown in the app and fed back to
    /// the model so the conversation carries.
    @Published public private(set) var transcript: [String] = []
    /// Drafts and edits retained so the director can inspect why a candidate
    /// reached the stage instead of receiving a post-hoc story about it.
    @Published public private(set) var productionAudits: [LiveProductionAudit] = []
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
    /// A structural provocation for this version of the scene. It stays put as
    /// the scene extends, so sections cohere, but changes when the director
    /// asks for a genuinely new attempt.
    private var creativeLens: String
    /// How the next stretch of script is fetched. A closure, not a client, so
    /// an HTTP model server and a command-line agent are interchangeable.
    private let fetch: @Sendable (String) async throws -> [LiveBeat]
    private var compiler: LiveCompiler
    private var rng: LiveRandom
    private var task: Task<Void, Never>?
    private let retryDelayNanoseconds: UInt64

    /// Keep this far ahead of the playhead before asking for more.
    public var lookahead: Double = 45
    /// Called after every batch, so the app can save the .bs as it is written.
    public var onBatch: ((ShowDocument) -> Void)?

    public convenience init(
        brief: LiveBrief, document: ShowDocument,
        beats: @escaping @Sendable (String) async throws -> [LiveBeat],
        room: LiveSet? = nil, seed: UInt64 = 20260814
    ) {
        self.init(brief: brief, document: document, beats: beats, room: room,
                  seed: seed, retryDelayNanoseconds: 3_000_000_000)
    }

    init(brief: LiveBrief, document: ShowDocument,
         beats: @escaping @Sendable (String) async throws -> [LiveBeat],
         room: LiveSet? = nil, seed: UInt64 = 20260814,
         retryDelayNanoseconds: UInt64) {
        self.brief = brief
        self.document = document
        self.fetch = beats
        var compiler = LiveCompiler(document: document)
        compiler.room = room
        compiler.directedZones = LiveCompiler.arrangesTheRoom(brief.premise)
        self.compiler = compiler
        self.seed = seed
        self.creativeLens = LiveDirector.creativeLens(seed: seed)
        self.rng = LiveRandom(seed: seed)
        self.retryDelayNanoseconds = retryDelayNanoseconds
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
        currentPass = ""
        if state != .finished { state = .idle }
    }

    private func run(playhead: @escaping @MainActor () -> Double) async {
        var consecutiveFailures = 0
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
            let sectionStart = writtenThrough
            let currentOutfits = LiveDirector.currentOutfits(
                in: document, at: writtenThrough)
            let prompt = LiveDirector.prompt(brief: brief, transcript: transcript,
                                             secondsToWrite: ask,
                                             elapsed: writtenThrough,
                                             notes: notes, direction: direction,
                                             cast: document.stage.characters.map(\.name),
                                             mayAddCast: brief.mayAddCast,
                                             creativeLens: creativeLens,
                                             currentOutfits: currentOutfits)
            do {
                currentPass = "Finding a loose dramatic compass"
                let arcEnvelope = try await fetch(
                    LiveDirector.planningPrompt(assignment: prompt))
                let selectedArc = try LiveDirector.parseDramaticCompass(arcEnvelope)
                let arcCandidates = [selectedArc]
                let productionAssignment = LiveDirector.plannedAssignment(
                    assignment: prompt, plan: selectedArc)
                currentPass = "Writing forward, one spoken turn at a time"
                let forwardEnvelope = try await fetch(
                    LiveDirector.forwardWritingPrompt(
                        assignment: productionAssignment,
                        targetTurns: max(5, Int(ask / 5))))
                let forwardDraft = try LiveDirector.parseForwardDraft(forwardEnvelope)
                if Task.isCancelled { return }
                state = .mastering
                let mastered: [LiveBeat]
                let causalLinks: [LiveCausalLink]
                let causalJudgePasses = 1
                let tagged = forwardDraft.beats
                let certified = try LiveDirector.certifyCausalSegues(tagged)
                currentPass = "Independently judging every segue"
                let verdictEnvelope = try await fetch(LiveDirector.causalJudgePrompt(
                    assignment: productionAssignment, taggedScript: tagged))
                let verdicts = try LiveDirector.parseCausalVerdicts(
                    verdictEnvelope, expected: certified.links)
                guard verdicts.allSatisfy(\.passed) else {
                    // Do not retrofit a failed improvisation. A new attempt writes
                    // forward again from the same loose arc and prior transcript.
                    throw CausalCertificationError.judgeRejected
                }
                mastered = certified.beats
                causalLinks = zip(certified.links, verdicts).map { link, verdict in
                    LiveCausalLink(before: link.before, relation: link.relation,
                                   after: link.after, explanation: verdict.explanation)
                }
                if Task.isCancelled { return }
                apply(mastered)
                consecutiveFailures = 0
                productionAudits.append(LiveProductionAudit(
                    from: sectionStart, to: writtenThrough,
                    premise: brief.premise, approach: creativeLens,
                    assignment: prompt, arcCandidates: arcCandidates,
                    selectedArc: selectedArc, writerTurns: forwardDraft.receipts,
                    final: mastered, causalLinks: causalLinks,
                    causalJudgePasses: causalJudgePasses))
            } catch {
                currentPass = ""
                consecutiveFailures += 1
                state = .failed(error.localizedDescription)
                // A transient malformed answer gets another chance. A broken
                // provider must not leave an empty stage retrying forever.
                if consecutiveFailures >= 3 { return }
                try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
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
        let openingDressing = writtenThrough <= 0 && brief.mayDressCast
        let wardrobePermission = brief.cast.reduce(into: [String: Bool]()) {
            $0[$1.name] = $1.mayChangeWardrobe
        }
        let usable = beats.filter { beat in
            guard beat.who.map(known.contains) ?? true else { return false }
            guard case let .wardrobe(who, slot, item) = beat else { return true }

            // The headset is an always-available social prop, including taking
            // it back off. Every other timed costume change needs the explicit
            // performer permission (opening dressing is the one exception).
            let isVisorAction = slot == LiveCompiler.glassesSlot
                && (item == LiveCompiler.visor || item == nil)
            guard isVisorAction || openingDressing || wardrobePermission[who] == true
            else { return false }

            // Model output is untrusted. A misspelt or invented wardrobe asset
            // must never become a silent, invisible event in the performance.
            guard let item else { return true }
            return isVisorAction || brief.wardrobe["\(slot)"]?.contains(item) == true
        }
        compiler.apply(usable, to: &next, rng: &rng)
        document = next
        writtenThrough = compiler.now
        for case let .line(who, text, _) in usable {
            transcript.append("\(who): \(text)")
        }
        onBatch?(next)
        // A direction applies to the stretch it was given for, and no further.
        direction = nil
        currentPass = ""
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
        if let i = productionAudits.lastIndex(where: { $0.status == .candidate }) {
            productionAudits[i].status = .approved
        }
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
        if let i = productionAudits.lastIndex(where: { $0.status == .candidate }) {
            productionAudits[i].status = .superseded
        }
        document = approved.document
        compiler = approved.compiler
        transcript = approved.transcript
        writtenThrough = approved.writtenThrough
        chunkStart = approved.writtenThrough
        seed &+= 7919                      // a different draw, not the same one
        creativeLens = LiveDirector.creativeLens(seed: seed)
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

        Slot 13 is not decorative clothing; it puts a visible object in a \
        Banny's hand. Consider giving one or two characters an apt hand prop \
        when it creates a concrete action, obstacle, temptation, misunderstanding, \
        exchange, or comic consequence for this exact scene. Do not give everyone \
        an object, and do not choose one the dialogue and action will ignore. A \
        chosen prop becomes an established story fact from its first appearance.

        What there is to wear:
        \(rows)
        """
    }

    /// The exact costume vocabulary available to performers who are allowed to
    /// change during the scene. Unlike opening wardrobe, this remains in every
    /// writing pass so a later turn can actually execute an earned disguise,
    /// uniform change, reveal, or removal without inventing an asset name.
    static func wardrobeChangeBrief(_ brief: LiveBrief) -> String {
        let slotNames = [2: "backside", 3: "necklace", 4: "head", 6: "glasses",
                         8: "legs", 9: "suit", 10: "suit bottom", 11: "suit top",
                         12: "head top", 13: "hand"]
        let rows = brief.wardrobe.keys.compactMap(Int.init).sorted().compactMap {
            slot -> String? in
            guard let items = brief.wardrobe["\(slot)"], !items.isEmpty else { return nil }
            return "  \(slot) \(slotNames[slot] ?? "slot"): \(items.joined(separator: ", "))"
        }.joined(separator: "\n")
        let names = brief.cast.filter(\.mayChangeWardrobe).map(\.name).joined(separator: ", ")

        return """


        STORY-EARNED COSTUME CHANGES
        \(names) may change outfit during the scene. Everyone else keeps their current \
        clothes. A change is a visible action, not decoration: use it only when changing, \
        removing, revealing, exchanging, or putting on an item advances the active story \
        or creates a payoff. Put the `wardrobe` beat after the line or event that causes \
        the decision and before the line that reacts to the new appearance. Studio waits \
        for that Banny to finish moving and speaking, performs the visible change, then \
        lets their next line begin.

        Use the exact slot and item below. `item:null` removes the current item in that \
        slot. One beat changes one slot; use multiple consecutive beats for a complete \
        transformation. Do not re-announce an outfit the audience can already see.

        Available changes:
        \(rows)
        """
    }

    /// Turns a seed into a storytelling approach, not a plot. The previous
    /// version independently sampled pressure, relationships and an opening;
    /// novelty came at the cost of three competing scenes. Here the model must
    /// derive one spine from the actual premise and merely vary how it unfolds.
    public static func creativeLens(seed: UInt64) -> String {
        let approaches = [
            "Let a promise gather consequences until keeping it requires a choice.",
            "Let the meaning of one existing detail change as characters act on it.",
            "Let shifting status expose what each person actually wants.",
            "Let two sincere but incompatible solutions tighten the same problem.",
            "Let withheld information surface through behavior, not explanation.",
            "Let a comic commitment become emotionally or practically binding.",
            "Let an attempted solution worsen the exact problem it was meant to solve.",
            "Let separate conversations converge on the same dramatic question.",
            "Let the least powerful character gain leverage through a concrete choice.",
            "Let a practical decision reveal a philosophical or emotional divide.",
        ]

        // SplitMix64-style mixing keeps adjacent seeds from walking adjacent
        // entries and making Try again feel like a lightly shuffled template.
        func mixed(_ value: UInt64) -> UInt64 {
            var z = value &+ 0x9E3779B97F4A7C15
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        let a = mixed(seed)
        let approach = approaches[Int(a % UInt64(approaches.count))]

        return """
        STORYTELLING APPROACH FOR THIS VERSION — key \(String(a, radix: 16))
        This varies the telling, not the story. First derive ONE fixed scene spine \
        solely from THE SCENE, the cast, and what has already happened:
        "[character] wants [specific outcome], BUT [specific obstacle], THEREFORE \
        they [first consequential action]; the scene asks [one dramatic question]."

        Approach: \(approach)

        Use the approach only when it serves that spine. Never import a stock \
        crisis, a second premise, or unrelated relationship machinery. Once the \
        spine is chosen, every section develops the same dramatic question until \
        it is answered; continuation means consequence, not reinvention.
        """
    }

    private static let planFields = [
        "OBJECTIVE —", "OBSTACLE —", "STAKES —", "FOCUS —",
        "QUESTION —", "DIRECTION —",
    ]

    enum ProductionPipelineError: LocalizedError {
        case malformedPlans
        case malformedSelection
        case malformedForwardDraft
        case malformedVerdicts

        var errorDescription: String? {
            switch self {
            case .malformedPlans:
                return "The story planner did not return three complete concrete plans."
            case .malformedSelection:
                return "The story planner did not return one complete dramatic compass."
            case .malformedForwardDraft:
                return "The forward writer did not return at least two causally tagged spoken turns."
            case .malformedVerdicts:
                return "The causal judge did not provide a concrete verdict for every segue."
            }
        }
    }

    /// A small compass is established before dialogue. It deliberately omits a
    /// route and ending so the forward writer can discover both through speech.
    public static func planningPrompt(assignment: String) -> String {
        """
        You are the story planner, not the dialogue writer. Produce ONE loose dramatic \
        compass for the exact assignment below. Do not write dialogue. \
        Do not add a stock crisis unrelated to the backdrop, cast, or existing story.

        This is a compass, not a route. Make its dramatic question understandable and contain:
        OBJECTIVE — who wants what observable result now
        OBSTACLE — the specific person, fact, rule, or cost stopping them
        STAKES — the concrete consequence of failure
        FOCUS — one grounded object, task, place, or decision the audience can track
        QUESTION — the live question whose answer the conversation may discover
        DIRECTION — one possible pressure to explore, explicitly not a required turn or ending

        Do NOT plan future lines, a beat chain, a twist, or an ending. The writer must be \
        able to discover those by responding to what the characters actually say.

        Any hand prop listed in the assignment is a visible, established object. Consider \
        whether using it makes the FOCUS, obstacle, or immediate action more concrete. Never \
        ignore it and then write as though the character's hand were empty.

        Clarity is mandatory. Name objects before using pronouns. Mystery may conceal an \
        answer, never the basic question. Avoid unnamed lists, machines, rooms, plans, \
        boxes, secrets, or vague "it/that/this" placeholders. Every plan must grow from \
        details already available in the assignment.

        Return ONLY this beat-shaped JSON envelope, with exactly one line beat:
        {"beats":[{"beat":"line","who":"DRAMATIC COMPASS","text":"OBJECTIVE — ... | OBSTACLE — ... | STAKES — ... | FOCUS — ... | QUESTION — ... | DIRECTION — ..."}]}

        ASSIGNMENT
        \(assignment)
        """
    }

    static func parseDramaticCompass(_ beats: [LiveBeat]) throws -> String {
        guard beats.count == 1,
              case let .line(who, text, _) = beats[0],
              who == "DRAMATIC COMPASS",
              planFields.allSatisfy({ text.contains($0) }) else {
            throw ProductionPipelineError.malformedSelection
        }
        return text
    }

    static func parsePlanCandidates(_ beats: [LiveBeat]) throws -> [String] {
        guard beats.count == 3 else { throw ProductionPipelineError.malformedPlans }
        var plans: [String] = []
        for (offset, beat) in beats.enumerated() {
            guard case let .line(who, text, _) = beat,
                  who == "ARC \(offset + 1)",
                  planFields.allSatisfy({ text.contains($0) }) else {
                throw ProductionPipelineError.malformedPlans
            }
            plans.append(text)
        }
        return plans
    }

    public static func planSelectionPrompt(assignment: String,
                                           candidates: [String]) -> String {
        let listed = candidates.enumerated()
            .map { "ARC \($0.offset + 1)\n\($0.element)" }
            .joined(separator: "\n\n")
        return """
        You are an independent story producer. Select the strongest of the three arcs. \
        Judge clarity, causal escalation, originality, payoff, backdrop relevance, and \
        continuity with what has already happened. Reject cryptic plans whose audience \
        must invent missing facts. Prefer surprising consequences of established details \
        over arbitrary twists. You may tighten the winning arc, but may not combine arcs, \
        add a beat chain, choose its turn, or predetermine its ending.

        Return ONLY one beat-shaped JSON line. Its text must retain every named field:
        {"beats":[{"beat":"line","who":"SELECTED ARC","text":"OBJECTIVE — ... | OBSTACLE — ... | STAKES — ... | FOCUS — ... | QUESTION — ... | DIRECTION — ..."}]}

        ASSIGNMENT
        \(assignment)

        CANDIDATES
        \(listed)
        """
    }

    static func parseSelectedPlan(_ beats: [LiveBeat]) throws -> String {
        guard beats.count == 1,
              case let .line(who, text, _) = beats[0],
              who == "SELECTED ARC",
              planFields.allSatisfy({ text.contains($0) }) else {
            throw ProductionPipelineError.malformedSelection
        }
        return text
    }

    static func plannedAssignment(assignment: String, plan: String) -> String {
        """
        \(assignment)

        DRAMATIC COMPASS — FACTS STAY TRUE, THE ROUTE STAYS OPEN
        \(plan)
        """
    }

    struct ForwardDraft: Equatable {
        let beats: [LiveBeat]
        let receipts: [LiveWriterTurnReceipt]
    }

    /// The dialogue is authored in response order inside one uninterrupted model
    /// response. Only performable beats cross the model boundary; no brittle private
    /// metadata schema can prevent otherwise valid dialogue from reaching review.
    public static func forwardWritingPrompt(assignment: String,
                                            targetTurns: Int) -> String {
        """
        You are the forward scene writer. You have a dramatic compass, not a plotted \
        route. Write exactly \(targetTurns) spoken turns in order. Invent only the \
        current turn, commit it, then let that committed line determine what becomes \
        possible next. Never outline future lines, work backward from an ending, or \
        force the DIRECTION to happen. It is permission, not destiny.

        Before writing each spoken line, silently decide four concrete things: why this \
        character speaks now; whether it follows the previous line by THEREFORE or BUT; \
        what choice, knowledge, cost, commitment, status, or action it changes; and what \
        it leaves for the next character to accept, resist, misunderstand, exploit, or \
        transform. Do not output those decisions or any private receipts. Output only \
        performable staging and dialogue beats.

        Write turn 1's spoken text unmarked. Prefix every later spoken text with exactly \
        `[THEREFORE] ` or `[BUT] ` according to its relationship with the previous spoken \
        line. Earlier turns are immutable: do not go back, revise, reorder, polish, or \
        repair them after seeing where the exchange goes.

        Respond backward and open forward. A mere answer, quip, agreement, topic match, \
        or unexplained revelation is not a turn. Each line must be short and immediately \
        readable while altering the live situation. Remember that the audience has never \
        seen the compass, premise, or cast descriptions: make each needed fact audible \
        before relying on it, through conflict and intention rather than a synopsis. \
        Ground every new fact in something \
        established or in an action the audience can see. Let the strongest unexpected \
        consequence of the committed dialogue become important. The scene may find a \
        turn or an ending, but only if prior lines earn it; otherwise finish on charged \
        possibility. Preserve all staging, cast, wardrobe, and beat rules below.

        Return ONLY one ordinary beat JSON envelope. Never emit `WRITER TURN`, planning, \
        analysis, explanations, or fields outside the assignment vocabulary. For example:
        {"beats":[
          {"beat":"enters","who":"NAME","zone":"middle"},
          {"beat":"line","who":"NAME","text":"...","kind":"say"},
          {"beat":"line","who":"NAME","text":"[BUT] ...","kind":"say"}
        ]}

        PRODUCTION ASSIGNMENT
        \(assignment)
        """
    }

    static func parseForwardDraft(_ envelope: [LiveBeat]) throws -> ForwardDraft {
        var beats: [LiveBeat] = []
        var receipts: [LiveWriterTurnReceipt] = []

        for beat in envelope {
            // Tolerate and discard receipts returned by an older cached prompt.
            if case let .line(who, _, _) = beat, who.hasPrefix("WRITER TURN ") {
                continue
            }

            if case let .line(who, text, kind) = beat {
                let number = receipts.count + 1
                let relation: LiveCausalRelation?
                let cleaned: String
                let normalized: LiveBeat
                if number == 1 {
                    relation = nil
                    if text.hasPrefix("[THEREFORE] ") {
                        cleaned = String(text.dropFirst("[THEREFORE] ".count))
                    } else if text.hasPrefix("[BUT] ") {
                        cleaned = String(text.dropFirst("[BUT] ".count))
                    } else {
                        cleaned = text
                    }
                    normalized = .line(who: who, text: cleaned, kind: kind)
                } else {
                    let hasTherefore = text.hasPrefix("[THEREFORE] ")
                    let hasBut = text.hasPrefix("[BUT] ")
                    guard hasTherefore != hasBut else {
                        throw ProductionPipelineError.malformedForwardDraft
                    }
                    relation = hasTherefore ? .therefore : .but
                    cleaned = String(text.dropFirst(hasTherefore
                        ? "[THEREFORE] ".count : "[BUT] ".count))
                    normalized = beat
                }
                guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ProductionPipelineError.malformedForwardDraft
                }
                receipts.append(LiveWriterTurnReceipt(
                    number: number, relation: relation,
                    spokenLine: "\(who): \(cleaned)"))
                beats.append(normalized)
                continue
            }
            beats.append(beat)
        }

        guard receipts.count >= 2 else {
            throw ProductionPipelineError.malformedForwardDraft
        }
        return ForwardDraft(beats: beats, receipts: receipts)
    }

    public static func draftingPrompt(assignment: String) -> String {
        """
        You are the scene writer. Write the planned scene now, using only the valid beat \
        vocabulary and JSON answer format specified by the assignment. The locked plan \
        is a factual contract, not material to quote or explain. Dramatize its causal \
        chain through concrete choices, behavior, and distinct voices.

        Ground the objective, focus, and resistance in the first two spoken lines. By \
        line four, the audience must understand the cost of failure. Introduce every \
        object and rule before shorthand or pronouns refer to it. Mystery may withhold \
        the answer, never what the characters are doing or why it matters. Every line \
        must change a choice, fact, cost, commitment, status, or immediate action. Keep \
        wit, but remove cryptic fragments and atmosphere posing as subtext.

        Return ONLY the finished beat JSON. Do not include planning or commentary.

        PRODUCTION ASSIGNMENT
        \(assignment)
        """
    }

    /// A second, independent room pass before a generated section is exposed.
    /// The first call invents; this one is explicitly allowed to throw weak
    /// invention away. Keeping the complete assignment here prevents an edit
    /// from improving dialogue while accidentally dropping an entrance,
    /// costume, director note, or staging rule.
    public static func masteringPrompt(assignment: String, draft: [LiveBeat]) -> String {
        let encoded = (try? JSONEncoder().encode(LiveBeatBatch(beats: draft)))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"beats":[]}"#

        return """
        You are the senior story editor on an original scene. A writer has made \
        a first draft from the assignment below. Do a real rewrite before the \
        audience sees it. Do not praise, explain, annotate, or imitate lines \
        from an existing film, television episode, play, or writer. Return ONLY \
        the finished JSON object in the assignment's beat vocabulary.

        MASTERING PASS
        Read the whole draft twice. First find its dramatic engine; then rewrite.

        - Give every active character an immediate want, even if tiny. Put those \
          wants into useful conflict, alliance, temptation, or misunderstanding.
        - Make the stretch turn on a concrete choice, discovery, cost, or reversal \
          caused by a character. An abstract idea matters only when somebody must \
          do something because of it.
        - Ratchet up invention without breaking the story. Find one bold, specific \
          turn latent in the room, cast, active problem, or earlier detail. Make it \
          surprising in prospect and inevitable in retrospect. Do not import a \
          random new crisis or replace the plot already under way.
        - Build pressure by "therefore" and "but", never a pile of "and then". \
          Each escalation changes the available choices or the status in the room.
        - Perform a mandatory causal-line audit after rewriting. Classify EVERY segue \
          between successive spoken lines as exactly one relationship: THEREFORE when \
          the later line is a direct story-advancing consequence; BUT when tension \
          caused by the prior line creates a story-advancing obstacle or turn. Never \
          claim both. Mere reply, topical adjacency, chronology, agreement, or generic \
          contrast fails. If neither is true, rewrite or remove the later line. A \
          gesture, movement, cut, or pause does not reset this test. Do not return \
          the JSON until every exchange passes.
        - Let comedy come from committed characters, precise behavior, status, and \
          consequences. A joke should reveal character or alter what happens next; \
          cut interchangeable quips and references that merely announce cleverness.
        - Use subtext. Let people argue about the reachable thing when the dangerous \
          thing is underneath it. Give the hardest character one flash of humanity \
          and the most reasonable character one inconvenient contradiction.
        - Plant and pay off. Reuse one detail, gesture, promise, image, or earlier \
          line with changed meaning. Do not manufacture a callback where none fits.
        - Protect distinct voices. Cut greetings, throat-clearing, repeated premises, \
          explanations, moral summaries, and any line another character could say.
        - Shape the ending of this stretch. It may be a laugh, wound, decision, \
          reveal, ominous image, or charged silence, but it must leave the situation \
          different and make the next stretch feel necessary.
        - Keep the assignment's continuity, cast limits, wardrobe, entrances, zones, \
          readable line length, approximate duration, and valid beat vocabulary. \
          Preserve strong material; replace anything merely serviceable.

        ORIGINAL ASSIGNMENT
        \(assignment)

        FIRST DRAFT — PRIVATE, NOT YET SHOWN
        \(encoded)

        ANSWER
        {"beats":[ ... ]}
        """
    }

    /// The creative edit gets its own editor; this final pass gets a continuity
    /// editor with no authority to invent. Separating those jobs prevents the
    /// attempt to make a draft more interesting from severing its causal spine.
    public static func continuityPrompt(assignment: String, draft: [LiveBeat]) -> String {
        let encoded = (try? JSONEncoder().encode(LiveBeatBatch(beats: draft)))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"beats":[]}"#

        return """
        You are the final continuity editor and causal certifier. This scene has already been written \
        and creatively edited. You may tighten, reorder, remove, or rewrite beats, \
        but you MUST NOT introduce a new plot, subject, character goal, twist, \
        relationship, object, or crisis. Return ONLY the corrected JSON object.

        CONTINUITY CHECK — DO NOT SKIP
        1. State silently one spine from the existing scene: who wants what, BUT \
           what blocks them, THEREFORE what they do, and the dramatic question.
        2. Remove or rewrite every beat that does not pursue, obstruct, reveal, \
           complicate, decide, or pay off that exact spine.
        3. Classify EVERY segue between successive spoken lines in final scene order \
           as exactly one of these mutually exclusive relationships:
           - THEREFORE: the later line is a direct consequence of the prior line, \
             and that consequence drives the same story forward.
           - BUT: direct narrative tension arises from the prior line, so the later \
             line blocks, contradicts, raises a cost, or reveals a complication that \
             turns events and advances the same story in an altered direction.
           Topical adjacency, agreement, a reply, chronology, contrast without a new \
           consequence, and generic banter do not pass. "And then" never passes.
        4. Encode the classification for validation. Leave the first spoken line \
           unmarked. Prefix EVERY later spoken line's text with exactly `[THEREFORE] ` \
           or `[BUT] `. These are private editorial labels, not dialogue; Studio \
           removes them before performance. If neither label truthfully describes \
           the segue, rewrite or remove the later line. Movement, gesture, pause, \
           speaker change, conversation cut, or subject change does not reset it.
        5. Confirm one continuous movement: setup of the present want, increasing \
           resistance, a decision/discovery/reversal, and its immediate consequence.
        6. Keep all continuity, staging, cast, wardrobe, timing, and beat-vocabulary \
           constraints in the original assignment. Preserve the strongest lines. \
           Do not add commentary or expose the private spine.

        ORIGINAL ASSIGNMENT
        \(assignment)

        EDITED SCRIPT TO CHECK
        \(encoded)

        ANSWER
        {"beats":[ ... ]}
        """
    }

    struct CertifiedCausalScript: Equatable {
        let beats: [LiveBeat]
        let links: [LiveCausalLink]
    }

    enum CausalCertificationError: LocalizedError {
        case emptyScript
        case insufficientDialogue
        case markerOnFirstLine
        case missingOrAmbiguousMarker(line: Int)
        case judgeRejected

        var errorDescription: String? {
            switch self {
            case .emptyScript: return "The continuity editor returned no beats."
            case .insufficientDialogue:
                return "The section needs at least two causally connected spoken lines."
            case .markerOnFirstLine: return "The first spoken line must not carry a causal marker."
            case let .missingOrAmbiguousMarker(line):
                return "Spoken line \(line) was not certified as exactly THEREFORE or BUT."
            case .judgeRejected:
                return "The independent causal judge still rejected one or more segues after repair."
            }
        }
    }

    /// Validates the editor's private causal labels and removes them before performance.
    /// Non-dialogue beats never reset adjacency: the next spoken line still has to follow
    /// causally from the previous spoken line in final scene order.
    static func certifyCausalSegues(_ beats: [LiveBeat]) throws -> CertifiedCausalScript {
        guard !beats.isEmpty else { throw CausalCertificationError.emptyScript }
        let therefore = "[THEREFORE] "
        let but = "[BUT] "
        var spoken = 0
        var previous: String?
        var links: [LiveCausalLink] = []
        var clean: [LiveBeat] = []
        clean.reserveCapacity(beats.count)

        for beat in beats {
            guard case let .line(who, text, kind) = beat else {
                clean.append(beat)
                continue
            }
            spoken += 1
            let hasTherefore = text.hasPrefix(therefore)
            let hasBut = text.hasPrefix(but)
            if spoken == 1 {
                guard !hasTherefore, !hasBut else {
                    throw CausalCertificationError.markerOnFirstLine
                }
                previous = "\(who): \(text)"
                clean.append(beat)
                continue
            }
            guard hasTherefore != hasBut else {
                throw CausalCertificationError.missingOrAmbiguousMarker(line: spoken)
            }
            let relation: LiveCausalRelation = hasTherefore ? .therefore : .but
            let prefix = hasTherefore ? therefore : but
            let cleanedText = String(text.dropFirst(prefix.count))
            guard !cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let prior = previous else {
                throw CausalCertificationError.missingOrAmbiguousMarker(line: spoken)
            }
            let rendered = "\(who): \(cleanedText)"
            links.append(LiveCausalLink(before: prior, relation: relation, after: rendered))
            clean.append(.line(who: who, text: cleanedText, kind: kind))
            previous = rendered
        }
        guard spoken >= 2 else { throw CausalCertificationError.insufficientDialogue }
        return CertifiedCausalScript(beats: clean, links: links)
    }

    struct CausalVerdict: Equatable {
        let passed: Bool
        let relation: LiveCausalRelation
        let explanation: String
    }

    public static func causalJudgePrompt(assignment: String,
                                         taggedScript: [LiveBeat]) -> String {
        let encoded = encode(taggedScript)
        return """
        You are an independent, adversarial causal editor. You did not write this \
        script. Do not improve it and do not defer to its `[THEREFORE]` or `[BUT]` \
        claims. Judge every segue between successive spoken lines in final order.

        PASS THEREFORE only when the later line is a direct consequence of the prior \
        line and changes a choice, fact, cost, commitment, status, or action in the \
        same story. PASS BUT only when tension caused by the prior line creates a \
        specific obstacle, contradiction, raised cost, or revelation that turns the \
        same story. A reply, shared topic, chronology, mood, generic disagreement, \
        unexplained new fact, or clever fragment fails.

        Apply the clarity gate: every object and rule is grounded before shorthand; \
        every pronoun has one obvious antecedent; the objective and stakes are legible; \
        mystery may conceal an answer but not the basic question. For each verdict, \
        explain the actual bridge in one concrete sentence. The explanation MUST reuse \
        at least one distinctive word or action from each of the two lines. Never return \
        a generic definition such as "creates tension" or "advances the story."

        COMEDY GATE: use the `COMEDY ENGINE — MANDATORY` requirement in the assignment. \
        The complete stretch fails unless it contains the required number of distinct, \
        earned comic turns. Each must be funny because of a character's committed tactic, \
        behavior, status, or consequence, and must also alter or expose the same story. \
        At least one later turn must escalate, reverse, or pay off earlier comic material. \
        Do not count puns, references, random incongruity, generic sarcasm, or a detachable \
        quip. If this gate fails, mark the weakest segue FAIL and explain specifically how \
        those two lines missed an available comic consequence while still referring to both.

        OPENING GATE: when the production assignment contains `OPENING HOOK — MANDATORY`, \
        judge the complete script before returning pair verdicts. First perform an \
        audience-blind reading using ONLY the spoken text in TAGGED SCRIPT TO JUDGE. \
        Do not use THE SCENE, THE CAST, the dramatic compass, or any other production \
        assignment fact to fill a gap. From the dialogue alone, by line four a new \
        viewer must be able to state the present situation, every active speaker's \
        functional role or relationship to it, the immediate want, the resistance, \
        and the cost. Those facts must emerge through characters using information \
        against or for each other—not recited biographies or a synopsis.

        The opening also fails unless it creates grounded curiosity immediately, makes \
        the want and resistance \
        legible by line two, discovers a consequential turn from established material, \
        and ends with a changed situation that makes another stretch desirable. Cryptic \
        fragments, arbitrary danger, unexplained revelations, and mere loudness fail. \
        If the complete opening fails this gate, return FAIL for every segue and make \
        each explanation name the concrete missing dramatic movement while still \
        referring specifically to both lines.

        Return ONLY one line beat per segue, in order. `who` must be exactly `PASS \
        THEREFORE`, `PASS BUT`, `FAIL THEREFORE`, or `FAIL BUT`; `text` is the specific \
        explanation. Return no staging beats and do not return the script.

        TAGGED SCRIPT TO JUDGE
        \(encoded)

        PRODUCTION ASSIGNMENT — consult only after the audience-blind reading, and only \
        to detect contradictions or continuity errors; never use it to supply missing \
        audience knowledge
        \(assignment)
        """
    }

    static func parseCausalVerdicts(_ beats: [LiveBeat],
                                    expected: [LiveCausalLink]) throws -> [CausalVerdict] {
        guard beats.count == expected.count else {
            throw ProductionPipelineError.malformedVerdicts
        }
        var verdicts: [CausalVerdict] = []
        for (beat, link) in zip(beats, expected) {
            guard case let .line(who, rawExplanation, _) = beat else {
                throw ProductionPipelineError.malformedVerdicts
            }
            let words = who.split(separator: " ").map(String.init)
            guard words.count == 2,
                  let relation = LiveCausalRelation(rawValue: words[1]),
                  relation == link.relation,
                  words[0] == "PASS" || words[0] == "FAIL" else {
                throw ProductionPipelineError.malformedVerdicts
            }
            let explanation = rawExplanation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard explanation.count >= 24,
                  concreteReference(in: explanation, to: link.before),
                  concreteReference(in: explanation, to: link.after) else {
                throw ProductionPipelineError.malformedVerdicts
            }
            verdicts.append(CausalVerdict(passed: words[0] == "PASS",
                                          relation: relation,
                                          explanation: explanation))
        }
        return verdicts
    }

    private static func concreteReference(in explanation: String, to line: String) -> Bool {
        let dialogue = line.split(separator: ":", maxSplits: 1)
            .dropFirst().first.map(String.init) ?? line
        let stop: Set<String> = [
            "the", "and", "but", "for", "that", "this", "with", "from", "then",
            "they", "their", "there", "what", "when", "where", "which", "your",
            "you", "are", "was", "were", "has", "have", "had", "not", "its",
            "into", "line", "prior", "later", "because", "direct", "story",
        ]
        func tokens(_ value: String) -> Set<String> {
            Set(value.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 && !stop.contains($0) })
        }
        let source = tokens(dialogue)
        return !source.isEmpty && !source.isDisjoint(with: tokens(explanation))
    }

    public static func causalRepairPrompt(assignment: String,
                                          taggedScript: [LiveBeat],
                                          verdicts: [LiveBeat]) -> String {
        """
        You are a surgical dialogue repair editor. An independent judge rejected one \
        or more causal segues. Repair the rejected line and any immediately dependent \
        lines; preserve passing material wherever possible. Do not introduce a new plot, \
        object, goal, relationship, or twist. Restore clarity by naming concrete objects, \
        actions, wants, and costs rather than adding explanation or cryptic atmosphere.

        Every final segue must truthfully be exactly THEREFORE or BUT under the locked \
        plan. Leave the first spoken line unmarked and prefix every later spoken line \
        with exactly `[THEREFORE] ` or `[BUT] `. Return ONLY the complete corrected \
        beat JSON in the assignment vocabulary; never include verdicts or commentary.

        PRODUCTION ASSIGNMENT
        \(assignment)

        TAGGED SCRIPT
        \(encode(taggedScript))

        INDEPENDENT VERDICTS
        \(encode(verdicts))
        """
    }

    private static func encode(_ beats: [LiveBeat]) -> String {
        (try? JSONEncoder().encode(LiveBeatBatch(beats: beats)))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"beats":[]}"#
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
                              mayAddCast: Bool = true,
                              currentOutfits: [String: [String: String]] = [:]) -> String {
        prompt(brief: brief, transcript: transcript,
               secondsToWrite: secondsToWrite, elapsed: elapsed,
               notes: notes, direction: direction, cast: onstage,
               mayAddCast: mayAddCast, creativeLens: "",
               currentOutfits: currentOutfits)
    }

    /// Live sessions use the same stable prompt contract plus a per-version
    /// dramatic lens. Kept as an overload so tools and older callers of the
    /// public prompt API remain source- and binary-compatible.
    public static func prompt(brief: LiveBrief, transcript: [String],
                              secondsToWrite: Double, elapsed: Double,
                              notes: [String] = [], direction: String? = nil,
                              cast onstage: [String] = [],
                              mayAddCast: Bool = true,
                              creativeLens: String,
                              currentOutfits: [String: [String: String]] = [:]) -> String {
        // Only the first section dresses anyone: after that they are dressed.
        let dressing = (brief.mayDressCast && elapsed <= 0 && !brief.wardrobe.isEmpty)
            ? LiveDirector.wardrobeBrief(brief) : ""
        let changing = (!brief.wardrobe.isEmpty
                        && brief.cast.contains(where: \.mayChangeWardrobe))
            ? LiveDirector.wardrobeChangeBrief(brief) : ""

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

        let slotNames = [2: "backside", 3: "necklace", 4: "head", 6: "glasses",
                         8: "legs", 9: "suit", 10: "suit bottom", 11: "suit top",
                         12: "head top", 13: "hand"]
        func outfitDescription(_ outfit: [String: String]) -> String {
            outfit.keys.compactMap(Int.init).sorted().compactMap { slot in
                guard let item = outfit[String(slot)] else { return nil }
                return slot == 13 ? "carrying \(item)"
                    : "\(slotNames[slot] ?? "slot \(slot)") \(item)"
            }.joined(separator: ", ")
        }
        let cast = brief.cast.map { member in
            let wardrobe = member.mayChangeWardrobe
                ? "may change wardrobe, but only when the story earns it"
                : "wardrobe is fixed"
            let outfit = currentOutfits[member.name] ?? member.outfit
            let visible = outfitDescription(outfit)
            let appearance = visible.isEmpty ? "" : "; visible now: \(visible)"
            return "- \(member.name): \(member.prompt) [\(wardrobe)\(appearance)]"
        }.joined(separator: "\n")

        let carriedPairs: [(String, String)] = currentOutfits.isEmpty
            ? brief.cast.compactMap { member in
                member.outfit["13"].map { (member.name, $0) }
            }
            : currentOutfits.compactMap { name, outfit in
                outfit["13"].map { (name, $0) }
            }
        let carried = carriedPairs.reduce(into: [String: String]()) {
            $0[$1.0] = $1.1
        }
        let propFacts = carried.isEmpty ? "" : """


        VISIBLE HAND PROPS — ESTABLISHED STORY FACTS
        \(carried.keys.sorted().map { "- \($0) is carrying \(carried[$0]!)." }
            .joined(separator: "\n"))
        The audience can see these objects even though nobody narrates the image. Keep \
        every holder and object consistent. Create opportunities to use, protect, offer, \
        withhold, misuse, inspect, lose, or react to them when that advances the same \
        story. Reveal importance through what a character tries to do with the object, \
        not a line that merely describes what everyone can see.
        """

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

        let openingHook = elapsed <= 0 ? """


        OPENING HOOK — MANDATORY
        These first thirty seconds must earn the next thirty. Quiet does not mean \
        uneventful. The first visible action or spoken line creates immediate, grounded \
        curiosity through a want, risk, contradiction, temptation, unusual behavior, \
        or consequential question—not a greeting, topic announcement, or explanation.

        By the second spoken line, the audience can tell who wants what now and what \
        resists them. Let the exchange discover one surprising consequence that grows \
        from what was actually said or done. By the final turn, the situation has \
        changed and one specific choice, danger, promise, question, or comic consequence \
        makes stopping feel premature. Clarity comes before mystery: never substitute \
        cryptic fragments, arbitrary emergencies, or loudness for a hook.
        """ : ""

        let variation = creativeLens.isEmpty ? "" : "\n\n\(creativeLens)"

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
        \(cast)\(propFacts)\(reading)\(dressing)\(changing)\(company)\(standing)\(next)\(openingHook)\(variation)

        SO FAR
        \(history)

        NOW
        \(stage) Write about \(Int(secondsToWrite)) seconds — roughly \
        \(max(5, Int(secondsToWrite / 4))) beats. Keep it moving: a pause is a \
        beat, not a gap, so never ask for more than two seconds of it. \(Int(elapsed))s have been \
        performed so far.

        HOW TO WRITE IT
        Before writing any beats, silently fix the scene spine in this form: \
        "[character] wants [specific outcome], BUT [specific obstacle], THEREFORE \
        they [first consequential action]; the scene asks [one dramatic question]." \
        Derive every blank from THE SCENE, the cast, and SO FAR. For later sections, \
        recover the same spine from SO FAR; never choose a new one.

        AUDIENCE-BLIND DIALOGUE — THE BRIEF IS PRIVATE. The audience never reads \
        THE SCENE or THE CAST. Pretend they receive only the spoken captions, with \
        no synopsis, character biography, or job label. Every fact needed to understand \
        the present situation, the characters' roles in it, the immediate want, the \
        resistance, and the cost must enter the dialogue before the story depends on it. \
        In an opening, by spoken line four a new viewer can explain what is happening, \
        what each active speaker has to do with it, who wants what, and why it matters.

        Reveal context through dramatic use: a demand names the task, a refusal names \
        the pressure, a correction exposes the relationship, an accusation reveals \
        history, or a proposal establishes the stakes. Never make characters recite \
        biographies, tell each other facts they both know for the audience's benefit, \
        or deliver a synopsis. Natural exposition is information somebody uses to get \
        something from somebody else. Do not rely on a fact that exists only in this brief.

        This is a real room, not a sketch, but do not spend the scene warming \
        up. People enter already wanting, avoiding, attempting, hiding, testing, \
        or deciding something. Small talk is occasional camouflage, friction, \
        or a pressure valve — a line or two whose subtext advances the active \
        situation — never the main substance and never a long runway before the \
        plot begins. Nobody announces a subject or arrives to explain one.

        CAUSAL LINE RULE — MANDATORY: every segue between successive spoken lines \
        in final scene order must be exactly one of two relationships. THEREFORE \
        means the later line is a direct consequence of the prior line and drives \
        the same story forward. BUT means direct narrative tension arises from the \
        prior line, so the later line blocks, contradicts, raises a cost, or reveals \
        a complication that turns events and advances the same story in an altered \
        direction. Test with one word, never both. Topical adjacency, mere reply, \
        chronology, generic agreement, and contrast without consequence do not pass. \
        If neither relationship is true, rewrite or remove the later line. Gesture, \
        movement, pause, speaker change, conversation cut, and subject change do not \
        reset the test. Avoid "and then": sequence alone has no rhythm and no scene.

        At least two of the cast are good at "yes, and": they accept what they \
        were handed, but add a consequence rather than merely another thing. An \
        offhand remark can therefore grow into the best exchange of the scene. \
        The others deflect, understate, or change the subject — that contrast is \
        what makes the "yes, and" land.

        Across the stretch, let the company build one shared situation together: \
        a plan, worry, dare, secret, disagreement, or expectation that gathers \
        consequences as different people touch it. Give it a little drama — \
        pressure rises, loyalties or intentions become clearer, and what they do \
        next follows from what they have made together. Keep the banter, one-offs, \
        and occasional subject changes; use them as texture, then return to the \
        shared thread and advance it instead of resetting the scene.

        Give the stretch a dramatic engine, not merely a topic. Each active \
        character wants something now, however small, and somebody or something \
        makes getting it costly. Put big questions into concrete choices: loyalty, \
        reality, power, love, dignity, or freedom becomes compelling when a person \
        must risk, conceal, surrender, or choose. Let status move between people. \
        Let a comic choice create a real consequence, and let a serious pressure \
        expose something absurd. The laugh and the drama should tighten the same \
        situation rather than taking turns in separate sketches.

        COMEDY ENGINE — MANDATORY. This stretch needs at least \
        \(max(2, Int(secondsToWrite / 15))) distinct comic turns. A comic turn does \
        two jobs at once: it is genuinely funny in the moment AND reveals character, \
        changes status, worsens a problem, creates a commitment, or alters what someone \
        does next. Put one in the first half of the stretch, then let a later line \
        escalate, reverse, or pay off something funny that has already happened.

        Find humor in committed behavior: dry underreaction to real pressure, misplaced \
        professionalism, an over-literal promise, a disproportionate practical solution, \
        status changing hands, somebody protecting dignity badly, or a specific physical \
        choice another character cannot ignore. Serious scenes may be dark or restrained, \
        but they are not humorless. Puns, references, random weirdness, generic sarcasm, \
        and detachable one-liners do not count. Never pause the story to make a joke; \
        make the joke become the next story problem.

        Be creatively ambitious and causally strict. The ordinary backdrop can \
        hold a conspiracy, impossible bargain, romantic risk, identity problem, \
        social trap, heist logic, betrayal, metaphysical doubt, or escalating \
        farce when the characters and details earn it. Prefer one surprising, \
        specific turn that transforms what is already happening over several \
        arbitrary twists. Once it lands, follow its consequences; do not abandon \
        it for a fresh premise. New sections deepen, complicate, or pay off the \
        active story rather than rebooting it.

        BUILD THE STRETCH AS ONE MOVEMENT. In its first one or two lines, make the \
        current want and resistance legible through behavior. Increase pressure \
        through attempts and consequences. Force one decision, discovery, sacrifice, \
        or reversal. End on its immediate consequence, which must alter the same \
        situation and pull us toward the next movement. Every line must pursue, \
        obstruct, reveal, complicate, decide, or pay off the spine. Cut orphan lines.

        More than one conversation may be alive on screen when the room and cast \
        make that natural. Give each conversation its own group and thread, and \
        cut between them. The cut must still be exactly THEREFORE or BUT: one \
        exchange directly causes or consequentially complicates the other. Let \
        the threads brush against each other, collide, or feed the shared \
        situation; do not alternate between unrelated chatter just to create motion.

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
        Pro: it is always available as a phone-like prop, whatever the setting. \
        A character puts the headset on (`wardrobe`, slot 6, \
        `banny-vision-pro`) and drops out of the room without leaving it, \
        present but gone.

        Use it the way people use a phone in a room. A Banny puts it on when \
        bored, alone, waiting, unable to get into the conversation, wanting to \
        look something up, or interacting with an AI. It is ordinary social \
        behavior — cover, tool, and distraction — not automatically a science-\
        fiction event. They put it away when somebody comes over and before \
        speaking; the studio does that for you, so do not write it. What is \
        worth writing is somebody choosing to take it off: two people who have \
        been behind their headsets all evening putting them down at the same \
        moment is an event, and needs no line to explain it. The others may \
        well have opinions either way.

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
        {"beat":"wardrobe","who":"NAME","slot":13,"item":"exact-hand-item"}
        {"beat":"wardrobe","who":"NAME","slot":11,"item":"exact-suit-top"}
          A wardrobe beat can change any available slot. Use only an exact item made \
          available for that slot. `item:null` removes that slot. Except for the \
          always-available Banny Vision Pro, only a cast member marked "may change \
          wardrobe" can change after the opening dressing.

        The three zones are places in the room, not slots: front is nearest the \
        camera, far is deepest into the picture. People in one zone stand \
        together and face each other. One conversation normally shares a zone; \
        separate zones may deliberately hold separate conversations at the same \
        time. Do not accidentally split one exchange across the room, and do not \
        gather distinct conversations into one unreadable huddle.

        THE SCENE outranks that. When it says where people are — a doorman in \
        front, a queue in middle, someone on their own in far — put them there \
        and LEAVE them there. When one conversation intentionally crosses that \
        gap, they turn toward each other and the distance is the point. Otherwise \
        each group keeps its own conversation. Only move someone with a `move` \
        beat, when they have a reason to cross the room, and expect them to walk \
        it in full view.

        ANSWER
        {"beats":[ ... ]}
        """
    }

    /// The wardrobe actually visible at the next writing boundary. This keeps
    /// carried props and outfit changes in the writer's memory across sections.
    static func currentOutfits(in document: ShowDocument,
                               at time: Double) -> [String: [String: String]] {
        let sim = SceneSimulator(state: document.stage)
        return document.stage.characters.enumerated().reduce(into: [:]) {
            result, pair in
            let (index, character) = pair
            let outfit = sim.pose(characterIndex: index, at: time).outfit
            result[character.name] = Dictionary(uniqueKeysWithValues:
                outfit.map { (String($0.key), $0.value) })
        }
    }
}
