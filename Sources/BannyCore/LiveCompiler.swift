import Foundation

/// Turns a model's beats into a performance.
///
/// Everything here is a rule the script must not be trusted to hold by itself.
/// The compiler owns position, facing, walk safety and caption placement; the
/// model owns only who speaks and what they say. It appends to a document, so a
/// live scene can be written while it plays.
public struct LiveCompiler {
    /// Characters a walk speed and a place in the room.
    private struct Performer {
        var index: Int
        var x: Double
        /// How far back they are standing *now*. Kept here because the document
        /// cannot answer it: `character.depth` is overruled by the recorded
        /// start pose, so the only depth the simulator honours is the one the
        /// arrow keys walked them to.
        var depth: Double
        var zone: LiveZone
        var speed: Double
        var onstage: Bool
        var walkEnd: Double
        /// End of the last visible caption. A performer never starts walking
        /// while their words are still on screen.
        var captionEnd: Double
        /// (t, target x) facing intents, resolved once at the end of a batch.
        var looks: [(Double, Double)] = []
        /// (start, end, fromX, toX) so position at any instant is known.
        var walks: [(Double, Double, Double, Double)] = []
        /// True when the script named this zone — an entrance or a move — as
        /// opposed to the studio parking them somewhere so a line had a body.
        /// A place the director chose is not the studio's to undo.
        var placed = false
        /// Behind the Banny Vision Pro: present, but not in the room.
        var wearingVisor = false
        /// Whatever was in the glasses slot before it went on, so taking it off
        /// gives them their own face back rather than a bare one.
        var glasses: String?
    }

    public private(set) var now: Double
    /// The stage as read from the backdrop, when one was read. Nil means the
    /// built-in staging, which is what every scene used before rooms existed.
    public var room: LiveSet?
    /// True when the scene itself arranges the room — "a doorman in front, a
    /// queue in middle". Then a zone the script names is a decision, and the
    /// studio stops gathering people into one huddle to make a conversation
    /// read as one. Off, the zones are incidental and the gathering rule holds:
    /// two people trading lines from opposite ends read as two conversations
    /// whatever the dialogue says, and that was a real complaint before it
    /// existed. The premise decides which of those a scene is.
    public var directedZones = false
    /// Set just before an entrance to offer it a fuzz-in, if the room allows.
    private var dissolveNext = false
    private var cast: [String: Performer] = [:]
    private var order: [String] = []
    private let framesPerSecond = 30.0

    /// How fast a banny talks, in characters a second. This is a reading speed
    /// as much as a speaking one: the caption is on screen exactly as long as
    /// the mouth moves.
    ///
    /// It was slower, to buy reading time back from captions that slid across
    /// the frame with their speaker. They no longer move, so the time is no
    /// longer owed, and nine characters a second reads as a room of people
    /// choosing their words unusually carefully.
    public static let charactersPerSecond = 11.0
    /// A caption stays up after the mouth stops, so the last words are not
    /// snatched away the instant the line ends.
    public static let captionHangover = 0.9
    /// However short the line, its caption is on screen at least this long.
    ///
    /// Reading time is not the only cost: a caption has to be *noticed* first,
    /// and an eye following a walk or finishing somebody else's line arrives
    /// late. Timed purely from its own text, "Yeah, exactly." was up for two
    /// seconds and gone. The mouth still moves for as long as the line takes —
    /// only the words linger, over the top of whoever is talking next.
    public static let minimumCaptionOnScreen = 2.8
    /// Two frames at the export rate. Any mouth state shorter than this
    /// flickers or is skipped between samples.
    public static let minMouthState = 2.0 / 30.0

    public init(document: ShowDocument, startingAt t: Double = 0) {
        self.now = t
        for (i, c) in document.stage.characters.enumerated() {
            var performer = Performer(index: i, x: c.x,
                                      depth: c.recStart?.depth ?? c.depth,
                                      zone: .offstage,
                                      speed: c.speed, onstage: false,
                                      walkEnd: -1, captionEnd: t)
            performer.glasses = c.baseOutfit[LiveCompiler.glassesSlot]
            cast[c.name] = performer
            order.append(c.name)
        }
    }

    /// Walks someone on from the wings into a zone.
    private mutating func walkOn(_ who: String, zone: LiveZone, at t: Double,
                                 document: inout ShowDocument) {
        guard var p = cast[who], !p.onstage else { return }
        p.onstage = true
        p.zone = zone
        // No teleport. A performer walks on from wherever they are actually
        // standing — the wing the document parked them in, or the one they
        // walked off into. Assuming a side the simulator does not share sends
        // them the wrong way and straight into the edge clamp.
        cast[who] = p
        // Arriving into an empty part of the room can be a fuzz-in rather than
        // a walk — nobody is standing there to be interrupted by it.
        let quiet = mayDissolve(who)
        noticeArrival(in: zone, except: who, at: t, document: &document)
        reshare(zone, at: t, document: &document)
        setPresence(who, visible: true, at: t, document: &document,
                    fade: quiet && dissolveNext ? LiveCompiler.dissolve : nil)
        dissolveNext = false
    }

    /// Re-agrees with a document that has been edited by hand.
    ///
    /// The compiler carries its own belief about where everyone is standing,
    /// and every bug worth the name in this system came from that belief
    /// drifting from the simulator's. Once a scene has been fine-tuned in the
    /// editor — somebody dragged, an event trimmed — the belief is stale, so it
    /// is thrown away and rebuilt from what the simulator actually reports at
    /// `t`. Nothing here guesses: it asks.
    public mutating func resync(with document: ShowDocument, at t: Double) {
        now = t
        let sim = SceneSimulator(state: document.stage)
        for (i, character) in document.stage.characters.enumerated() {
            let pose = sim.pose(characterIndex: i, at: t)
            let visible = character.presence.opacity(at: t) > 0.5
            var performer = cast[character.name]
                ?? Performer(index: i, x: pose.x, depth: pose.depth, zone: .offstage,
                             speed: character.speed, onstage: false, walkEnd: -1,
                             captionEnd: t)
            performer.index = i
            performer.x = pose.x
            // Where the simulation actually left them, not where we last aimed.
            performer.depth = pose.depth
            performer.speed = character.speed
            performer.onstage = visible
            if !visible { performer.zone = .offstage }
            // No walk is in flight at a moment the user chose to stop at.
            performer.walkEnd = t
            performer.captionEnd = max(t, character.subs
                .filter { $0.start <= t + 0.001 }
                .map { $0.start + $0.dur }.max() ?? t)
            performer.walks = []
            performer.looks = []
            // Whatever is on their face now is what taking the headset off
            // should give them back.
            let worn = pose.outfit[LiveCompiler.glassesSlot]
            performer.wearingVisor = worn == LiveCompiler.visor
            if !performer.wearingVisor { performer.glasses = worn }
            cast[character.name] = performer
            if !order.contains(character.name) { order.append(character.name) }
        }
    }

    /// Brings someone into the company mid-scene. They start offstage, exactly
    /// as the opening cast does, and walk on when the script says so.
    public mutating func register(name: String, index: Int, x: Double, speed: Double,
                                  depth: Double = 0.06) {
        guard cast[name] == nil else { return }
        cast[name] = Performer(index: index, x: x, depth: depth, zone: .offstage,
                               speed: speed, onstage: false, walkEnd: -1,
                               captionEnd: now)
        order.append(name)
    }

    /// Where a zone puts its nth occupant. Sharing a zone evenly matters: fixed
    /// slots sized for a crowd leave the first arrivals stacked in a corner of
    /// the band while the rest of it sits empty.
    static func positions(in zone: LiveZone, count: Int,
                          room: LiveSet? = nil) -> [Double] {
        let span = room?.span(for: zone) ?? zone.span
        guard count > 1 else { return [(span.lowerBound + span.upperBound) / 2] }
        // Spread across the zone, and past it if the zone alone cannot hold
        // everyone a body-width apart. A crowd that spills a little is far
        // easier to read than a crowd standing inside each other.
        let needed = minimumGap * Double(count - 1)
        let width = max(span.upperBound - span.lowerBound, needed)
        let centre = (span.lowerBound + span.upperBound) / 2
        // The same bounds the zones themselves use, or the outermost group is
        // pushed a fraction outside its own zone to satisfy a tighter guard.
        let start = max(LiveCompiler.stageEdge,
                        min(1 - LiveCompiler.stageEdge - width, centre - width / 2))
        let step = width / Double(count - 1)
        return (0..<count).map { start + Double($0) * step }
    }

    /// How close to the frame edge a performer may be placed. Matches the
    /// outer bounds of the front and far zones.
    static let stageEdge = 0.03

    /// A banny is roughly this much of the frame across, so anything closer
    /// than this reads as one shape rather than two people.
    static let minimumGap = 0.17

    /// Whether a premise arranges the room by name. Written as a word, so "a
    /// farm" and "the middleman" are not directions; "people waiting in
    /// \"middle\"" is.
    public static func arrangesTheRoom(_ premise: String) -> Bool {
        let words = premise.lowercased().split(whereSeparator: { !$0.isLetter })
        return words.contains { ["front", "middle", "far"].contains(String($0)) }
    }

    /// Depth for the nth person in a zone. Alternating in front of and behind
    /// the zone line keeps a pair from sharing an outline.
    ///
    /// The offsets are a share of the room to the nearest other band, never a
    /// fixed amount. A fixed one used to be ±0.18 — wider than the gap between
    /// three bands drawn close together, so the second person in `front` stood
    /// deeper than the whole of `middle` and the arrangement drawn on the
    /// picture came out shuffled. Bands placed a hair apart are a hair apart in
    /// the scene; that they are close is not permission to ignore the order.
    ///
    /// This is decoration, not collision avoidance: `positions` already spaces
    /// a zone's occupants a body-width apart in x, whatever the crowd.
    static func depth(in zone: LiveZone, index: Int,
                      room: LiveSet? = nil) -> Double {
        // In units of the allowance, so nobody sits on the zone's own line but
        // the first person to stand on it.
        let pattern: [Double] = [0, 0.5, -0.28, 0.78, 0.22, 1.0]
        let base = room?.depth(for: zone) ?? zone.depth
        let neighbours = LiveZone.allCases
            .filter { $0 != zone && $0 != .offstage }
            .map { abs((room?.depth(for: $0) ?? $0.depth) - base) }
        // Half the way to the nearest neighbour is the furthest anyone can
        // stray without trespassing on a band that belongs to somebody else.
        let allowance = min(0.1, max(0.015, (neighbours.min() ?? 0.2) / 2))
        return max(-0.1, min(0.85,
                             base + pattern[index % pattern.count] * allowance))
    }

    /// How long a line takes to say.
    public static func duration(of line: String) -> Double {
        // Even three words need a beat to land; a long one may take its time.
        min(8.0, max(1.2, Double(line.count) / charactersPerSecond))
    }

    // MARK: - Compiling

    /// Applies a batch of beats to `document`, advancing the clock.
    /// Returns the time the batch ends.
    @discardableResult
    public mutating func apply(_ beats: [LiveBeat], to document: inout ShowDocument,
                               rng: inout LiveRandom) -> Double {
        let batchStart = now
        var lastSpeaker: String?
        /// When the previous line finished, so a reply can be told from a new
        /// subject started somewhere else in the room.
        var lastLineEnded = -100.0
        for beat in beats {
            switch beat {
            case let .hold(seconds):
                // A pause is a beat, not an interval. Six seconds of a still
                // room reads as the scene having stopped.
                now += min(2.5, max(0.2, seconds))

            case let .enters(who, zone):
                // Whether this arrival may be a fuzz-in is decided here, where
                // the random draw is available.
                dissolveNext = rng.next(in: 0...1) < 0.4
                walkOn(who, zone: zone, at: now, document: &document)
                cast[who]?.placed = directedZones

            case let .exits(who):
                guard var p = cast[who], p.onstage else { break }
                // Alone, they can simply fuzz out where they stand; with
                // company, they walk off so nobody is zapped mid-conversation.
                if mayDissolve(who), rng.next(in: 0...1) < 0.45 {
                    setPresence(who, visible: false, at: now, document: &document,
                                fade: LiveCompiler.dissolve)
                    now += LiveCompiler.dissolve
                    let leftBehind = p.zone
                    p.onstage = false
                    p.zone = .offstage
                    cast[who] = p
                    reshare(leftBehind, at: now, document: &document)
                    break
                }
                let target = p.x < 0.5 ? -0.2 : 1.2
                walk(who, to: target, at: now, document: &document)
                // Whose ranks close behind them — captured before they leave it.
                let leftBehind = p.zone
                p = cast[who]!
                p.onstage = false
                p.zone = .offstage
                cast[who] = p
                reshare(leftBehind, at: now, document: &document)

            case let .move(who, zone):
                guard cast[who] != nil else { break }
                let previous = cast[who]!.zone
                // A move is always deliberate, directed scene or not.
                cast[who]!.zone = zone
                cast[who]!.placed = true
                reshare(zone, at: now, document: &document)
                if previous != zone { reshare(previous, at: now, document: &document) }

            case let .gesture(who, name):
                guard let p = cast[who], p.onstage else { break }
                addReaction(name, to: p.index, at: now, document: &document, rng: &rng)

            case let .wardrobe(who, slot, item):
                guard let p = cast[who] else { break }
                // An onstage transformation is a readable performance beat.
                // Never dissolve an outfit while its wearer is walking or while
                // their caption is still asking the audience to watch their face.
                let changeAt: Double
                if p.onstage {
                    changeAt = max(now,
                                   p.walkEnd + LiveCompiler.speechSettle,
                                   p.captionEnd + 0.05)
                    now = changeAt
                } else {
                    changeAt = now
                }
                if slot == LiveCompiler.glassesSlot {
                    var updated = p
                    if item == LiveCompiler.visor {
                        // `glasses` already holds the face underneath; leave it
                        // alone so taking the headset off restores it.
                        updated.wearingVisor = true
                    } else {
                        updated.wearingVisor = false
                        updated.glasses = item
                    }
                    cast[who] = updated
                }
                document.stage.characters[p.index].events.append(
                    .outfit(t: round3(changeAt), slot: slot, name: item))
                // Opening costumes and props are put on in the wings at the
                // same instant. An onstage change remains a visible beat.
                if p.onstage { now = changeAt + 0.6 }

            case let .line(who, rawText, kind):
                guard cast[who] != nil else { break }
                // Strike the tics before anybody says them out loud.
                let text = LiveVoice.tidy(rawText)
                // You take it off before you speak: nobody addresses a room
                // from behind the headset.
                putVisorAway(who, at: now - 0.4, document: &document)
                // A script that gives somebody a line has decided they are here.
                // Dropping it because no `enters` was written loses the entire
                // scene — an empty room where dialogue should be.
                if !cast[who]!.onstage {
                    walkOn(who, zone: .middle, at: now, document: &document)
                    now += 0.8
                }
                let speaker = cast[who]!
                var at = now
                switch kind {
                case .cut:
                    at = max(0, now - rng.next(in: 0.2...0.4))
                case .over:
                    at = max(0, now - rng.next(in: 0.4...0.9) - LiveCompiler.duration(of: text))
                default:
                    break
                }
                at = settledSpeechStart(for: who, proposed: at)
                // Answering somebody is what makes it one conversation, and the
                // bodies have to say so. Standing in separate huddles while
                // trading lines reads as two conversations however good the
                // dialogue is — so a reply pulls the replier into the speaker's
                // group, and both turn to each other.
                if let previous = lastSpeaker, previous != who,
                   let them = cast[previous], them.onstage,
                   at - lastLineEnded < 4.0 {
                    // Only gather people the studio placed itself. A bouncer at
                    // the door and a queue further back are two places in one
                    // conversation, and dragging the queue onto the doorstep is
                    // the studio overruling the direction. They turn to each
                    // other instead, and talk across the gap.
                    if them.zone != cast[who]!.zone, !cast[who]!.placed,
                       occupancy(of: them.zone) < 4 {
                        cast[who]!.zone = them.zone
                        let leaving = speaker.zone
                        reshare(them.zone, at: at - 1.2, document: &document)
                        reshare(leaving, at: at - 1.2, document: &document)
                    }
                    // Gathering the reply into the conversation may itself
                    // have scheduled a walk. The line waits for that too.
                    at = settledSpeechStart(for: who, proposed: at)
                    cast[who]!.looks.append((at - 0.2, cast[previous]!.x))
                    cast[previous]!.looks.append((at - rng.next(in: 0...0.3),
                                                  cast[who]!.x))
                }
                // Everyone standing with them looks over; the speaker addresses
                // the group. Facing is only recorded here — a walk written later
                // may happen earlier on the clock, so it is resolved at the end.
                let peers = onstagePeers(of: who)
                let here = cast[who]!.x
                for peer in peers {
                    cast[peer]!.looks.append((at - rng.next(in: 0...0.3), here))
                }
                if !peers.isEmpty {
                    let mid = peers.reduce(0.0) { $0 + cast[$1]!.x } / Double(peers.count)
                    cast[who]!.looks.append((at - 0.15, mid))
                }
                let dur = LiveCompiler.duration(of: text)
                // Tilts are reserved for intent. A confidence leans in, a laugh
                // rocks back, an interruption knocks the other person back on
                // their heels — and nothing else in the scene uses the channel.
                switch kind {
                case .quiet:
                    addReaction("secret", to: speaker.index, at: at - 0.3,
                                document: &document, rng: &rng)
                    if let nearest = peers.first {
                        addReaction("secret", to: cast[nearest]!.index, at: at - 0.1,
                                    document: &document, rng: &rng)
                    }
                case .cut:
                    if let interrupted = lastSpeaker, interrupted != who,
                       let them = cast[interrupted], them.onstage,
                       rng.next(in: 0...1) < 0.6 {
                        addReaction("recoil", to: them.index, at: at + 0.1,
                                    document: &document, rng: &rng)
                    }
                case .say, .over:
                    // A listener agreeing is a nod, not a permanent posture.
                    if let peer = peers.first, rng.next(in: 0...1) < 0.22 {
                        addReaction("nod", to: cast[peer]!.index, at: at + dur * 0.6,
                                    document: &document, rng: &rng)
                    }
                case .laugh:
                    break        // the room rocks back below
                }
                speak(who, from: at, for: dur, document: &document, rng: &rng)
                caption(who, text: text, from: at,
                        for: dur + LiveCompiler.captionHangover, document: &document)
                if kind == .laugh {
                    for peer in peers {
                        addReaction("bellylaugh", to: cast[peer]!.index,
                                    at: at + dur + 0.2, document: &document, rng: &rng)
                    }
                }
                lastSpeaker = who
                lastLineEnded = at + LiveCompiler.duration(of: text)
                // Room to breathe between turns. Real conversation has pauses,
                // and without them the captions become a wall to keep up with.
                now = at + dur + (kind == .cut || kind == .over
                                  ? rng.next(in: 0.3...0.65) : rng.next(in: 0.7...1.3))
            }
        }
        _ = lastSpeaker
        fillIdleTime(from: batchStart, to: now, document: &document, rng: &rng)
        resolveFacing(document: &document)
        sortEvents(&document)
        return now
    }

    /// Longest anyone may stand doing nothing at all.
    static let idleLimit = 3.2

    /// Small business in the gaps.
    ///
    /// Dialogue alone leaves a room of statues between lines: the pauses that
    /// make speech readable make the picture look stopped. Anyone with nothing
    /// to do for more than a few seconds sips, glances, blinks or shifts — the
    /// gestures are eyes-and-tilt only, so they never fight a line or a walk.
    private mutating func fillIdleTime(from t0: Double, to t1: Double,
                                       document: inout ShowDocument,
                                       rng: inout LiveRandom) {
        guard t1 > t0 + 1 else { return }
        // Eyes and mouth only. A lean is emphasis; sprinkling one every few
        // seconds as filler is how it stops reading as anything at all.
        let idle = ["glance", "sip", "blink2", "listen", "brow", "squint",
                    "shy", "eyeroll"]
        for name in order {
            guard let p = cast[name], p.onstage else { continue }
            let character = document.stage.characters[p.index]

            // Everything already occupying this performer.
            var busy: [(Double, Double)] = p.walks.map { ($0.0, $0.1) }
            busy += character.subs.map { ($0.start, $0.start + $0.dur) }
            busy += character.reactions.map { ($0.start, $0.start + $0.dur) }
            // Only after they are actually visible.
            let arrived = character.presence
                .filter(\.visible).map(\.t).min() ?? t0
            busy.sort { $0.0 < $1.0 }

            var cursor = max(t0, arrived)
            var guardCount = 0
            while cursor < t1, guardCount < 40 {
                guardCount += 1
                // How long they are free from `cursor`.
                let next = busy.first { $0.0 > cursor }?.0 ?? t1
                let free = next - cursor
                if free < LiveCompiler.idleLimit {
                    cursor = max(next, cursor + 0.1)
                    // Skip past whatever occupies them next.
                    if let span = busy.first(where: { $0.1 > cursor && $0.0 <= cursor }) {
                        cursor = span.1
                    }
                    continue
                }
                let at = cursor + rng.next(in: 0.4...min(2.0, free - 1.2))
                let gesture = idle[rng.int(in: 0...(idle.count - 1))]
                addReaction(gesture, to: p.index, at: at, document: &document, rng: &rng)
                busy.append((at, at + 2.0))
                busy.sort { $0.0 < $1.0 }
                cursor = at + rng.next(in: 2.0...4.0)
            }
        }
    }

    // MARK: - Staging

    private func occupancy(of zone: LiveZone) -> Int {
        order.filter { cast[$0]!.onstage && cast[$0]!.zone == zone }.count
    }

    private func onstagePeers(of who: String) -> [String] {
        guard let me = cast[who] else { return [] }
        return order.filter {
            $0 != who && cast[$0]!.onstage && cast[$0]!.zone == me.zone
        }
    }

    /// Re-shares a zone between everyone standing in it.
    private mutating func reshare(_ zone: LiveZone, at t: Double,
                                  document: inout ShowDocument) {
        guard zone != .offstage else { return }
        let members = order.filter { cast[$0]!.onstage && cast[$0]!.zone == zone }
        guard !members.isEmpty else { return }
        let xs = LiveCompiler.positions(in: zone, count: members.count, room: room)
        for (i, name) in members.enumerated() {
            // Two people at the same depth and a similar x share one silhouette;
            // a step apart in depth never does.
            walk(name, to: xs[i],
                 depth: LiveCompiler.depth(in: zone, index: i, room: room),
                 at: t + Double(i) * 0.3, document: &document)
            // A sideways shuffle leaves them facing the way they walked, which
            // for half the group is out of the conversation.
            let others = xs.enumerated().filter { $0.offset != i }.map(\.element)
            if !others.isEmpty {
                let mid = others.reduce(0, +) / Double(others.count)
                cast[name]!.looks.append((cast[name]!.walkEnd + 0.15, mid))
            }
        }
    }

    /// Walks someone across the stage and, when asked, into or out of the room.
    ///
    /// Depth used to be written straight onto the character. It never took: a
    /// performer with a recorded start pose is simulated from *that* depth and
    /// the field is ignored, so a scene staged to a picture stood its whole
    /// cast at the depth they walked on at, however carefully the zones were
    /// placed. Depth is held keys like everything else, and holding both axes
    /// at once is a diagonal — somebody crossing to the back of the room walks
    /// there rather than arriving in a smaller size.
    ///
    /// Never starts while their previous walk is running: two holds share an
    /// arrow key, and the second key-up releases both.
    private mutating func walk(_ who: String, to x: Double, depth z: Double? = nil,
                               at t: Double, document: inout ShowDocument) {
        guard var p = cast[who] else { return }
        // Words and walking are mutually exclusive in generated scenes. Wait
        // for both the prior walk and the prior caption to clear.
        let start = max(t, p.walkEnd + 0.05, p.captionEnd + 0.05)
        let target = z ?? p.depth
        let across = abs(x - p.x), back = abs(target - p.depth)
        guard across > 1e-4 || back > 1e-4 else {
            p.walkEnd = max(p.walkEnd, start)
            cast[who] = p
            return
        }
        var hold = 0.0
        if across > 1e-4 {
            let seconds = across / (p.speed / 900)
            let code: EventCode = x > p.x ? .arrowRight : .arrowLeft
            document.stage.characters[p.index].events.append(
                .key(t: round3(start), code: code, down: true))
            document.stage.characters[p.index].events.append(
                .key(t: round3(start + seconds), code: code, down: false))
            p.walks.append((start, start + seconds, p.x, x))
            p.x = x
            hold = max(hold, seconds)
        }
        if back > 1e-4 {
            // The engine's own rate, so the keys are released exactly where the
            // simulation arrives. Deriving it here again would drift.
            let rate = simDepthRate(speed: p.speed, gScale: document.stage.gScale)
            let seconds = back / rate
            // ArrowUp goes away from the camera.
            let code: EventCode = target > p.depth ? .arrowUp : .arrowDown
            document.stage.characters[p.index].events.append(
                .key(t: round3(start), code: code, down: true))
            document.stage.characters[p.index].events.append(
                .key(t: round3(start + seconds), code: code, down: false))
            p.depth = target
            hold = max(hold, seconds)
        }
        p.walkEnd = start + hold
        cast[who] = p
    }

    /// Mouth movement. The talk channel is open exactly while its key is held,
    /// so this rhythm is the performance — there is no auto-flap.
    private mutating func speak(_ who: String, from t: Double, for dur: Double,
                                document: inout ShowDocument, rng: inout LiveRandom) {
        guard let p = cast[who] else { return }
        var cursor = t
        let end = t + dur
        while cursor < end - 0.08 {
            for _ in 0..<rng.int(in: 1...4) {
                let on = max(LiveCompiler.minMouthState, rng.next(in: 0.07...0.15))
                if cursor + on > end { break }
                document.stage.characters[p.index].events.append(
                    .key(t: round3(cursor), code: .keyM, down: true))
                document.stage.characters[p.index].events.append(
                    .key(t: round3(cursor + on), code: .keyM, down: false))
                cursor += on + max(LiveCompiler.minMouthState, rng.next(in: 0.05...0.10))
            }
            cursor += rng.next(in: 0.10...0.24)
            if rng.next(in: 0...1) < 0.18 { cursor += rng.next(in: 0.25...0.5) }
        }
    }

    /// Dialogue begins only after the speaker has visibly come to rest.
    static let speechSettle = 0.25

    private func settledSpeechStart(for who: String, proposed t: Double) -> Double {
        guard let p = cast[who] else { return t }
        return max(t, p.walkEnd + LiveCompiler.speechSettle)
    }

    /// A caption sits over its speaker, in its own box, so two conversations can
    /// be captioned at once and each line is attributable.
    private mutating func caption(_ who: String, text: String, from t: Double,
                                  for dur: Double, document: inout ShowDocument) {
        guard var p = cast[who] else { return }
        // No position is recorded. A speaker who walks mid-line — or gets
        // reseated when someone joins the group — would otherwise leave the
        // caption hanging over the spot they were standing in when the line was
        // written. The renderer anchors it from the live pose instead.
        let shownFor = round3(max(LiveCompiler.minimumCaptionOnScreen, dur))
        let start = round3(t)
        document.stage.characters[p.index].subs.append(
            Subtitle(text: text, start: start, dur: shownFor,
                     size: 0.62, width: 0.20, follow: true))
        p.captionEnd = max(p.captionEnd, start + shownFor)
        cast[who] = p
    }

    private mutating func addReaction(_ name: String, to index: Int, at t: Double,
                                      document: inout ShowDocument,
                                      rng: inout LiveRandom) {
        guard let definition = document.stage.reactionLibrary.first(where: { $0.id == name })
        else { return }
        document.stage.characters[index].reactions.append(
            ReactionInstance(id: "live-\(index)-\(document.stage.characters[index].reactions.count)",
                             reactionID: name, start: round3(t),
                             dur: definition.dur, intensity: rng.next(in: 0.7...1.1)))
    }

    private mutating func setPresence(_ who: String, visible: Bool, at t: Double,
                                      document: inout ShowDocument,
                                      fade: Double? = nil) {
        guard let p = cast[who] else { return }
        document.stage.characters[p.index].presence.append(
            VisibilityEvent(t: round3(t), visible: visible, fade: fade))
    }

    /// How long a performer takes to fuzz in or out.
    static let dissolve = 0.8

    /// The glasses slot, and the thing you hide behind in it.
    static let glassesSlot = 6
    public static let visor = "banny-vision-pro"

    /// Taking it off is an event, not a tidy-up.
    ///
    /// The headset is how somebody leaves a room without leaving it, so it is
    /// governed by the same courtesies as a phone: you put it away when
    /// somebody comes over to you, and you put it away before you speak.
    /// Leaving it on while being talked to reads as rudeness the scene never
    /// intended.
    private mutating func putVisorAway(_ who: String, at t: Double,
                                       document: inout ShowDocument) {
        guard var p = cast[who], p.wearingVisor else { return }
        p.wearingVisor = false
        cast[who] = p
        document.stage.characters[p.index].events.append(
            .outfit(t: round3(max(0, t)), slot: LiveCompiler.glassesSlot,
                    name: p.glasses))
    }

    /// Anyone in this zone who is hiding behind the headset puts it away.
    private mutating func noticeArrival(in zone: LiveZone, except who: String,
                                        at t: Double, document: inout ShowDocument) {
        for name in order
        where name != who && cast[name]!.onstage && cast[name]!.zone == zone
           && cast[name]!.wearingVisor {
            // A beat to look up, then it comes off.
            putVisorAway(name, at: t + 1.0, document: &document)
        }
    }

    /// True when this performer can appear or vanish without anyone noticing
    /// them do it. The rule from the sunset bar: never zap somebody who is
    /// standing with company — they step away first, or go when they are the
    /// last one there.
    func mayDissolve(_ who: String) -> Bool {
        guard let me = cast[who] else { return false }
        return !order.contains {
            $0 != who && cast[$0]!.onstage && cast[$0]!.zone == me.zone
        }
    }

    /// Facing cannot be decided while compiling a beat: a walk emitted later may
    /// happen earlier on the clock and overwrite a turn. Intents are replayed
    /// against the finished timeline, and a pivot that would land inside a walk
    /// is moved clear rather than dropped — dropping it desyncs this model from
    /// the simulator permanently.
    private mutating func resolveFacing(document: inout ShowDocument) {
        for name in order {
            guard var p = cast[name], !p.looks.isEmpty else { continue }
            let walks = p.walks.sorted { $0.0 < $1.0 }
            let marks = walks.compactMap { w -> (Double, Int)? in
                abs(w.3 - w.2) < 1e-9 ? nil : (w.0, w.3 > w.2 ? 1 : -1)
            }
            var face = document.stage.characters[p.index].face
            var mark = 0
            var lastEnd = -1.0
            for (t, target) in p.looks.sorted(by: { $0.0 < $1.0 }) {
                while mark < marks.count && marks[mark].0 <= t {
                    face = marks[mark].1
                    mark += 1
                }
                let want = target > xAt(t, p) ? 1 : -1
                guard want != face else { continue }
                var at = max(t, lastEnd + 0.05)
                var placed = false
                for _ in 0..<8 {
                    // The pivot occupies [at, at+0.08]; both ends must clear
                    // every walk or its key-up releases one still running.
                    if let hit = walks.first(where: {
                        at <= $0.1 + 0.05 && at + 0.08 >= $0.0 - 0.05
                    }) {
                        at = max(hit.1 + 0.07, lastEnd + 0.05)
                    } else {
                        placed = true
                        break
                    }
                }
                guard placed else { continue }
                let code: EventCode = want > 0 ? .arrowRight : .arrowLeft
                document.stage.characters[p.index].events.append(
                    .key(t: round3(at), code: code, down: true))
                document.stage.characters[p.index].events.append(
                    .key(t: round3(at + 0.08), code: code, down: false))
                face = want
                lastEnd = at + 0.08
            }
            p.looks.removeAll()
            cast[name] = p
        }
    }

    /// Puts every performer's events back in time order.
    ///
    /// The simulator walks the array by index and stops at the first event
    /// later than now, so an out-of-order press is not merely late — it is
    /// swallowed whole, together with its release. This used to happen inside
    /// facing resolution, which skips anyone with no turn to make, so it was
    /// really "sorted if they happened to look at somebody": a performer who
    /// walked on and said nothing kept a scrambled timeline. It cost the depth
    /// walk entirely — the hold was appended after a longer sideways hold, and
    /// the whole press-and-release fell into a single step that netted zero.
    private func sortEvents(_ document: inout ShowDocument) {
        for name in order {
            guard let p = cast[name] else { continue }
            document.stage.characters[p.index].events.sort {
                $0.t == $1.t ? (eventRank($0) < eventRank($1)) : ($0.t < $1.t)
            }
        }
    }

    private func xAt(_ t: Double, _ p: Performer) -> Double {
        var x = p.walks.first?.2 ?? p.x
        for (a, b, x0, x1) in p.walks.sorted(by: { $0.0 < $1.0 }) {
            if t <= a { break }
            x = t >= b ? x1 : x0 + (x1 - x0) * (t - a) / max(1e-6, b - a)
        }
        return x
    }
}

private func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

/// Key-downs sort before key-ups at the same instant, so a press is never
/// swallowed by the release of the previous one.
private func eventRank(_ e: PerfEvent) -> Int {
    if case let .key(_, _, down) = e { return down ? 0 : 1 }
    return 2
}

/// Deterministic randomness. A live scene must replay identically from its
/// written .bs, so the performance jitter cannot come from the system RNG.
public struct LiveRandom {
    private var state: UInt64
    public init(seed: UInt64 = 0x9E3779B97F4A7C15) { self.state = seed | 1 }

    public mutating func nextBits() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    public mutating func next(in range: ClosedRange<Double>) -> Double {
        let unit = Double(nextBits() % 1_000_000) / 1_000_000
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }

    public mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(nextBits() % span)
    }
}
