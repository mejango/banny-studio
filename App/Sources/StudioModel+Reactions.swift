import Foundation
import BannyCore

extension StudioModel {
    func selectReaction(character: Int, id: String) {
        selectedReaction = ReactionSelection(character: character, id: id)
        selectedMarks = []
        selectedClips = []
        selectedImageCue = nil
        selectedBackgroundCue = nil
        selectedBackgroundCues = []
        selectedLightCue = nil
        selectedOutfitEvent = nil
        selectedMotionEvent = nil
        selectedMouthCue = nil
    }

    var selectedReactionValue: (definition: ReactionDefinition, instance: ReactionInstance)? {
        guard let selectedReaction,
              scene.characters.indices.contains(selectedReaction.character),
              let instance = scene.characters[selectedReaction.character].reactions
                .first(where: { $0.id == selectedReaction.id }),
              let definition = scene.reactionLibrary.first(where: { $0.id == instance.reactionID })
        else { return nil }
        return (definition, instance)
    }

    func canCaptureReaction(characterIndex: Int) -> Bool {
        scene.characters[safe: characterIndex]?.locked == false
            && !selectedMarks.isEmpty
            && selectedMarks.allSatisfy { $0.character == characterIndex }
    }

    func suggestedReactionName() -> String {
        "Reaction \(scene.reactionLibrary.count + 1)"
    }

    /// Turns the selected held-performance marks into one reusable block.
    /// Outfit changes inside the selected time span are captured as owned
    /// wardrobe channels and removed from the raw stream with the marks.
    @discardableResult
    func captureReaction(name rawName: String, characterIndex: Int) -> String? {
        guard canCaptureReaction(characterIndex: characterIndex) else { return nil }
        let marks = selectedMarks.filter { $0.character == characterIndex }
        guard let t0 = marks.map(\.start).min(), let t1 = marks.map(\.end).max(), t1 > t0,
              scene.characters.indices.contains(characterIndex) else { return nil }

        let duration = max(0.04, t1 - t0)
        var captured: [PerfEvent] = []
        for mark in marks {
            captured.append(.key(t: mark.start - t0, code: mark.code, down: true))
            captured.append(.key(t: mark.end - t0, code: mark.code, down: false))
        }
        let sourceEvents = scene.characters[characterIndex].events
        for event in sourceEvents {
            guard case .outfit(let t, let slot, let name) = event,
                  t >= t0 - 1e-9, t < t1 - 1e-9 else { continue }
            captured.append(.outfit(t: max(0, t - t0), slot: slot, name: name))
        }
        captured.sort { lhs, rhs in
            if lhs.t != rhs.t { return lhs.t < rhs.t }
            func rank(_ event: PerfEvent) -> Int {
                if case .key(_, _, false) = event { return 0 }
                if case .key(_, _, true) = event { return 2 }
                return 1
            }
            return rank(lhs) < rank(rhs)
        }

        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let definition = ReactionDefinition(
            id: ShowDocumentFile.newID(),
            name: trimmed.isEmpty ? suggestedReactionName() : trimmed,
            dur: duration,
            events: captured)
        let block = ReactionInstance(id: ShowDocumentFile.newID(), reactionID: definition.id,
                                     start: t0, dur: duration)

        registerUndoSnapshot(label: "Create Reaction")
        scene.reactionLibrary.append(definition)
        scene.characters[characterIndex].events = sourceEvents.filter { event in
            switch event {
            case .key(let t, let code, _):
                return !marks.contains { mark in
                    mark.code == code && t >= mark.start - 1e-6 && t <= mark.end + 1e-6
                }
            case .outfit(let t, _, _):
                return !(t >= t0 - 1e-9 && t < t1 - 1e-9)
            case .motion:
                return true
            }
        }
        scene.characters[characterIndex].reactions.append(block)
        scene.characters[characterIndex].reactions.sort { $0.start < $1.start }
        selectReaction(character: characterIndex, id: block.id)
        return block.id
    }

    @discardableResult
    func insertReaction(_ reactionID: String, characterIndex: Int,
                        at start: Double? = nil) -> String? {
        guard scene.characters.indices.contains(characterIndex),
              !scene.characters[characterIndex].locked,
              let definition = scene.reactionLibrary.first(where: { $0.id == reactionID }) else { return nil }
        registerUndoSnapshot(label: "Insert Reaction")
        let block = ReactionInstance(id: ShowDocumentFile.newID(), reactionID: reactionID,
                                     start: max(0, start ?? time), dur: definition.dur)
        scene.characters[characterIndex].reactions.append(block)
        scene.characters[characterIndex].reactions.sort { $0.start < $1.start }
        selectReaction(character: characterIndex, id: block.id)
        return block.id
    }

    func setReactionBlock(character: Int, id: String, start: Double, dur: Double) {
        guard scene.characters.indices.contains(character),
              !scene.characters[character].locked,
              let index = scene.characters[character].reactions.firstIndex(where: { $0.id == id })
        else { return }
        scene.characters[character].reactions[index].start = max(0, start)
        scene.characters[character].reactions[index].dur = max(0.08, dur)
        scene.characters[character].reactions.sort { $0.start < $1.start }
    }

    func setSelectedReactionIntensity(_ intensity: Double) {
        guard let selectedReaction,
              scene.characters.indices.contains(selectedReaction.character),
              !scene.characters[selectedReaction.character].locked,
              let index = scene.characters[selectedReaction.character].reactions
                .firstIndex(where: { $0.id == selectedReaction.id }) else { return }
        scene.characters[selectedReaction.character].reactions[index].intensity = min(4, max(0, intensity))
    }

    func setSelectedReactionDuration(_ duration: Double) {
        guard let selectedReaction,
              scene.characters.indices.contains(selectedReaction.character),
              !scene.characters[selectedReaction.character].locked,
              let index = scene.characters[selectedReaction.character].reactions
                .firstIndex(where: { $0.id == selectedReaction.id }) else { return }
        scene.characters[selectedReaction.character].reactions[index].dur = max(0.08, duration)
    }

    func renameReaction(id: String, to rawName: String) {
        guard let index = scene.reactionLibrary.firstIndex(where: { $0.id == id }) else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        registerUndoSnapshot(label: "Rename Reaction")
        scene.reactionLibrary[index].name = name
    }

    @discardableResult
    func duplicateReactionBlock(
        character: Int,
        id: String,
        registerUndo: Bool = true
    ) -> String? {
        guard scene.characters.indices.contains(character),
              !scene.characters[character].locked,
              let source = scene.characters[character].reactions.first(where: { $0.id == id })
        else { return nil }
        if registerUndo {
            registerUndoSnapshot(label: "Duplicate Reaction")
        }
        var copy = source
        copy.id = ShowDocumentFile.newID()
        copy.start += 0.05
        scene.characters[character].reactions.append(copy)
        scene.characters[character].reactions.sort { $0.start < $1.start }
        selectReaction(character: character, id: copy.id)
        return copy.id
    }

    func deleteReactionDefinition(id: String) {
        guard !scene.characters.contains(where: { character in
            character.reactions.contains { $0.reactionID == id }
        }) else { return }
        registerUndoSnapshot(label: "Delete Reaction")
        scene.reactionLibrary.removeAll { $0.id == id }
    }

    /// Replaces a block with its time-scaled raw key/outfit events. Outfit
    /// slots are restored at the block end so expanding keeps their temporary
    /// reaction behavior while making every change editable.
    func expandReactionBlock(character: Int, id: String) {
        guard scene.characters.indices.contains(character),
              !scene.characters[character].locked,
              let blockIndex = scene.characters[character].reactions.firstIndex(where: { $0.id == id })
        else { return }
        let block = scene.characters[character].reactions[blockIndex]
        guard let definition = scene.reactionLibrary.first(where: { $0.id == block.reactionID }),
              definition.dur > 0 else { return }

        var stateWithoutBlock = scene
        stateWithoutBlock.characters[character].reactions.remove(at: blockIndex)
        let blockEnd = block.start + block.dur
        let underlyingOutfit = SceneSimulator(state: stateWithoutBlock)
            .pose(characterIndex: character, at: blockEnd + 1e-7).outfit
        let rate = block.dur / definition.dur
        var expanded = definition.events.map { event -> PerfEvent in
            let shifted = block.start + event.t * rate
            switch event {
            case .key(_, let code, let down): return .key(t: shifted, code: code, down: down)
            case .outfit(_, let slot, let name): return .outfit(t: shifted, slot: slot, name: name)
            case .motion(_, let speed, let rotationSpeed, let wobble, let size):
                return .motion(t: shifted, speed: speed, rotationSpeed: rotationSpeed,
                               wobble: wobble, size: size)
            }
        }
        for slot in definition.outfitSlots {
            expanded.append(.outfit(t: blockEnd, slot: slot,
                                    name: underlyingOutfit[slot]))
        }

        registerUndoSnapshot(label: "Expand Reaction")
        scene.characters[character].reactions.remove(at: blockIndex)
        scene.characters[character].events.append(contentsOf: expanded)
        scene.characters[character].events.sort { $0.t < $1.t }
        selectedReaction = nil
        selectedMarks = Set(TimelineMath.marks(for: expanded, character: character,
                                               duration: block.start + block.dur))
    }
}
