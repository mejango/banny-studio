import Foundation
import XCTest
import BannyCore
@testable import BannyLive

final class SunsetBarPerformancePresetTests: XCTestCase {
    func testReactionLibraryIsUniqueBalancedAndLeavesLocomotionAndTalkFree() throws {
        let reactions = SunsetBarPerformancePreset.reactionLibrary
        let expectedIDs = [
            "glance", "listen", "blink2", "brow", "squint", "eyeroll", "sip",
            "doubletake", "laugh", "greet", "cheer", "lean-in", "bellylaugh",
            "recoil", "nod", "hesitate", "shy",
        ]

        XCTAssertEqual(reactions.map(\.id), expectedIDs)
        XCTAssertEqual(Set(reactions.map(\.id)).count, reactions.count)
        for reaction in reactions {
            XCTAssertTrue(reaction.dur.isFinite)
            XCTAssertGreaterThan(reaction.dur, 0)
            XCTAssertFalse(reaction.events.isEmpty)
            XCTAssertTrue(reaction.ownedGroups.isDisjoint(with: [.move, .depth, .talk]))
            XCTAssertEqual(reaction.events.map(\.t), reaction.events.map(\.t).sorted())

            var heldCodes = Set<EventCode>()
            for event in reaction.events {
                XCTAssertGreaterThanOrEqual(event.t, 0, reaction.id)
                XCTAssertLessThanOrEqual(event.t, reaction.dur, reaction.id)
                guard case .key(_, let code, let down) = event else {
                    return XCTFail("\(reaction.id) contains a non-key event")
                }
                if down {
                    XCTAssertTrue(heldCodes.insert(code).inserted, "\(reaction.id) double-pressed \(code)")
                } else {
                    XCTAssertNotNil(heldCodes.remove(code), "\(reaction.id) released idle \(code)")
                }
            }
            XCTAssertTrue(heldCodes.isEmpty, "\(reaction.id) leaves keys held")
        }
    }

    func testPhysicalHelpersAreDeterministicAndFacingTapDoesNotWalk() {
        XCTAssertEqual(
            SunsetBarPerformancePreset.listenerAction(seed: 42, style: .rowdy),
            SunsetBarPerformancePreset.listenerAction(seed: 42, style: .rowdy))
        XCTAssertEqual(
            SunsetBarPerformancePreset.idleAction(seed: 99),
            SunsetBarPerformancePreset.idleAction(seed: 99))

        XCTAssertNil(SunsetBarPerformancePreset.facingAction(
            currentX: 0.25, currentFace: .right, targetX: 0.75))
        XCTAssertEqual(
            SunsetBarPerformancePreset.facingAction(
                currentX: 0.75, currentFace: .right, targetX: 0.25),
            .move(direction: .left, durationMS: 80))
        XCTAssertNil(SunsetBarPerformancePreset.facingAction(
            currentX: 0.5, currentFace: .left, targetX: 0.5))
        XCTAssertNil(SunsetBarPerformancePreset.facingAction(
            currentX: .nan, currentFace: .left, targetX: 0.5))
    }

    func testLiveRoomConstraintsExposeThePresetReactionIDs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "banny-sunset-preset-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("recording.bs", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let room = try LiveRoom(
            id: "sunset-preset",
            title: "Sunset preset",
            maxOccupancy: 1,
            draftDocument: ShowDocument(stage: SceneState(
                characters: [],
                reactionLibrary: SunsetBarPerformancePreset.reactionLibrary)),
            packageURL: package)
        let receipt = try await room.join(
            identity: "guest",
            displayName: "Guest",
            character: Character(body: .orange),
            nowMS: 0)
        let context = try await room.nextDecision(
            participantID: receipt.participantID,
            nowMS: 1)

        XCTAssertEqual(
            context.context.constraints.allowedReactionIDs,
            SunsetBarPerformancePreset.reactionLibrary.map(\.id).sorted())
    }
}
