import XCTest
#if os(macOS)
import AppKit
#endif

final class SmokeTests: XCTestCase {
    @MainActor
    func testLaunchNewDocumentAndScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        #if os(macOS)
        app.typeKey("n", modifierFlags: .command)
        #else
        let create = app.buttons["Create Document"]
        if create.waitForExistence(timeout: 8) { create.tap() }
        #endif

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "no window appeared")
        sleep(3)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "editor"
        shot.lifetime = .keepAlways
        add(shot)

        #if !os(macOS)
        // Talk button should exist on the touch deck (Stage mode default).
        XCTAssertTrue(app.staticTexts["TALK"].waitForExistence(timeout: 5), "performance deck missing")
        #endif
        XCTAssertEqual(app.state, .runningForeground)
    }

    #if os(macOS)
    @MainActor
    func testFileMenuOffersUpdateCheck() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 10), "File menu missing")
        fileMenu.click()
        XCTAssertTrue(app.menuItems["Check for Updates…"].waitForExistence(timeout: 3),
                      "Check for Updates command missing from File")
    }

    @MainActor
    func testAdvancedJSONEditorOpensFromCharacterInspector() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        if !app.windows.firstMatch.waitForExistence(timeout: 3) {
            app.typeKey("n", modifierFlags: .command)
        }
        let trackCard = app.windows.firstMatch.buttons["track-card-c-0"]
        XCTAssertTrue(trackCard.waitForExistence(timeout: 10), "character track card missing")
        trackCard.click()

        // SwiftUI maps an `.accessibilityElement(children: .contain)` container
        // to a Group, not an "other" element, so match on identifier alone.
        let drawer = app.descendants(matching: .any)["workspace-drawer"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 5), "shared inspector drawer did not open")
        // ADVANCED is the inspector's last section. Its row exists in the
        // hierarchy while still scrolled out of the drawer, and clicking it
        // there lands outside the window and toggles nothing — so scroll it
        // into reach first, then click.
        let inspectorScroll = drawer.scrollViews.firstMatch
        XCTAssertTrue(inspectorScroll.waitForExistence(timeout: 5), "inspector scroll view missing")
        let advanced = app.disclosureTriangles["advanced-disclosure"]
        let fallback = app.buttons["advanced-disclosure"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 3) || fallback.exists,
                      "advanced disclosure missing")
        let toggle = advanced.exists ? advanced : fallback
        for _ in 0..<10 where !toggle.isHittable { inspectorScroll.swipeUp() }
        XCTAssertTrue(toggle.isHittable, "ADVANCED never scrolled into reach")
        // Only the chevron toggles a macOS DisclosureGroup — clicking the label
        // does nothing. Worse, the row's accessibility frame sits ~25pt left of
        // where it draws, so clicking by fraction-of-element lands outside the
        // drawer entirely. Measure in from the drawer's own left edge instead.
        drawer.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 15, dy: toggle.frame.midY - drawer.frame.minY))
            .click()
        // `value` arrives as a number, not a string — compare its description.
        XCTAssertEqual("\(toggle.value ?? "")", "1", "ADVANCED did not expand")

        let editJSON = app.buttons["edit-advanced-json"]
        for _ in 0..<6 where !editJSON.exists { inspectorScroll.swipeUp() }
        XCTAssertTrue(editJSON.waitForExistence(timeout: 5), "advanced control missing")
        editJSON.click()

        let editor = app.textViews["advanced-json-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "JSON editor did not open")
        XCTAssertTrue(app.staticTexts["Valid JSON"].exists, "initial character JSON is invalid")
        XCTAssertFalse(app.buttons["Apply"].isEnabled, "unchanged JSON should not apply")
    }

    @MainActor
    func testWorkspaceKeepsBrowseAndInspectOnDemand() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        if !app.windows.firstMatch.waitForExistence(timeout: 3) {
            app.typeKey("n", modifierFlags: .command)
        }
        let browse = app.buttons["workspace-browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 10), "Browse control missing")
        browse.click()
        XCTAssertTrue(app.descendants(matching: .any)["workspace-drawer"]
            .waitForExistence(timeout: 5),
                      "Browse drawer did not open")
        XCTAssertTrue(app.descendants(matching: .any)["browser-cast"]
            .waitForExistence(timeout: 5),
                      "Cast browser missing")

        let outfits = app.descendants(matching: .any)["browser-section-outfits"]
        XCTAssertTrue(outfits.waitForExistence(timeout: 5),
                      "Top-level Outfits destination missing")
        outfits.click()
        XCTAssertTrue(app.descendants(matching: .any)["browser-outfits"]
            .waitForExistence(timeout: 5),
                      "Outfit library did not open")
        XCTAssertTrue(app.buttons["browse-create-outfit"].exists,
                      "Create Outfit action missing from Browse")
        XCTAssertTrue(app.buttons["browse-manage-outfits"].exists,
                      "Outfit management action missing from Browse")

        let inspect = app.buttons["workspace-inspect"]
        XCTAssertTrue(inspect.exists, "Inspect control missing")
        inspect.click()
        XCTAssertTrue(app.disclosureTriangles["dialogue-disclosure"].waitForExistence(timeout: 5)
                      || app.buttons["dialogue-disclosure"].exists,
                      "Contextual character inspector missing")

        let drawer = app.descendants(matching: .any)["workspace-drawer"]
        let stage = app.descendants(matching: .any)["studio-stage"]
        let timeline = app.descendants(matching: .any)["studio-timeline"]
        XCTAssertTrue(drawer.exists && stage.exists && timeline.exists,
                      "Workspace regions missing while inspector is open")
        XCTAssertLessThanOrEqual(stage.frame.maxX, drawer.frame.minX + 1,
                                 "Inspector must not cover the stage")
        XCTAssertLessThanOrEqual(timeline.frame.maxX, drawer.frame.minX + 1,
                                 "Inspector must not cover the timeline's right edge")
    }

    @MainActor
    func testCustomBackgroundStudioOpensFromSets() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        if !app.windows.firstMatch.waitForExistence(timeout: 3) {
            app.typeKey("n", modifierFlags: .command)
        }

        let browse = app.buttons["workspace-browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 10), "Browse control missing")
        browse.click()
        let sets = app.descendants(matching: .any)["browser-section-sets"]
        XCTAssertTrue(sets.waitForExistence(timeout: 5), "Sets destination missing")
        sets.click()

        let create = app.buttons["create-background"]
        XCTAssertTrue(create.waitForExistence(timeout: 5), "Create Background missing")
        XCTAssertTrue(app.buttons["manage-backgrounds"].exists,
                      "background import/export management missing")
        create.click()

        XCTAssertTrue(app.textFields["background-name"].waitForExistence(timeout: 5),
                      "background editor did not open")
        XCTAssertTrue(app.descendants(matching: .any)["background-paint-canvas"].exists,
                      "background paint canvas missing")
        XCTAssertTrue(app.descendants(matching: .any)["background-frame-strip"].exists,
                      "background frame strip missing")
        XCTAssertTrue(app.descendants(matching: .any)["background-frame-delay"].exists,
                      "background loop tempo control missing")
        XCTAssertFalse(app.buttons["background-save"].isEnabled,
                       "unnamed background should not save")
        let addFrame = app.descendants(matching: .any)["background-add-frame"]
        XCTAssertTrue(addFrame.exists, "add background frame control missing")
        addFrame.click()
        XCTAssertTrue(app.staticTexts["2 of 5 frames • loops forever"]
            .waitForExistence(timeout: 3), "second background frame was not added")
    }

    @MainActor
    func testCustomOutfitStudioOpensFromWardrobe() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        if !app.windows.firstMatch.waitForExistence(timeout: 3) {
            app.typeKey("n", modifierFlags: .command)
        }
        app.typeKey("n", modifierFlags: .command)

        let window = app.windows.firstMatch
        let trackCard = window.buttons["track-card-c-0"]
        XCTAssertTrue(trackCard.waitForExistence(timeout: 10), "character track card missing")
        trackCard.click()

        let dialogue = window.disclosureTriangles
            .matching(identifier: "dialogue-disclosure")
            .matching(NSPredicate(format: "label == %@", "DIALOGUE & VOICE"))
            .firstMatch
        let dialogueFallback = window.buttons
            .matching(identifier: "dialogue-disclosure")
            .matching(NSPredicate(format: "label == %@", "DIALOGUE & VOICE"))
            .firstMatch
        XCTAssertTrue(dialogue.waitForExistence(timeout: 5) || dialogueFallback.exists,
                      "character inspector missing")
        if dialogue.exists { dialogue.click() } else { dialogueFallback.click() }

        let wardrobe = app.descendants(matching: .any)["wardrobe-toggle"]
        XCTAssertTrue(wardrobe.waitForExistence(timeout: 5), "wardrobe control missing")
        if !wardrobe.isHittable {
            let scrollViews = window.scrollViews
            XCTAssertGreaterThan(scrollViews.count, 0, "inspector scroll view missing")
            scrollViews.element(boundBy: scrollViews.count - 1).swipeUp()
        }
        wardrobe.click()

        let create = app.descendants(matching: .any)["create-outfit"]
        XCTAssertTrue(create.waitForExistence(timeout: 5), "Create Outfit control missing")
        create.click()

        let outfitName = app.textFields["outfit-name"]
        XCTAssertTrue(outfitName.waitForExistence(timeout: 5),
                      "outfit editor did not open")
        let initialName = outfitName.value as? String
        XCTAssertTrue(initialName == "" || initialName == "Outfit name",
                      "new outfit unexpectedly restored the name \(initialName ?? "nil")")
        let clearCanvas = app.buttons["outfit-clear-canvas"]
        XCTAssertTrue(clearCanvas.exists, "Clear Canvas control missing")
        XCTAssertFalse(clearCanvas.isEnabled, "new outfit unexpectedly restored artwork")
        XCTAssertFalse(app.buttons["outfit-save"].isEnabled,
                       "blank new outfit should not be saveable")
        XCTAssertTrue(app.descendants(matching: .any)["outfit-category"].exists,
                      "category picker missing")
        XCTAssertTrue(app.descendants(matching: .any)["outfit-pixel-canvas"].exists,
                      "pixel canvas missing")
        XCTAssertTrue(app.buttons["outfit-zoom-in"].exists,
                      "precision zoom-in control missing")
        XCTAssertTrue(app.buttons["outfit-zoom-out"].exists,
                      "precision zoom-out control missing")
        XCTAssertTrue(app.buttons["outfit-zoom-fit"].exists,
                      "fit-canvas control missing")
        XCTAssertTrue(app.buttons["outfit-section-tool"].exists,
                      "contiguous pixel-section tool missing")
        XCTAssertTrue(app.checkBoxes["outfit-show-mannequin"].exists,
                      "mannequin guide toggle missing")
        XCTAssertTrue(app.descendants(matching: .any)["outfit-mannequin-body"].exists,
                      "mannequin body picker missing")
        XCTAssertTrue(app.descendants(matching: .any)["outfit-frame-strip"].exists,
                      "animated outfit frame strip missing")
        XCTAssertTrue(app.descendants(matching: .any)["outfit-frame-delay"].exists,
                      "outfit loop tempo control missing")
        XCTAssertTrue(app.descendants(matching: .any)["outfit-mannequin-wardrobe"].exists,
                      "compatible mannequin wardrobe controls missing")
        let copyExisting = app.buttons["copy-existing-outfit"]
        XCTAssertTrue(copyExisting.exists, "Copy Existing Outfit control missing")
        copyExisting.click()
        XCTAssertTrue(app.staticTexts["Copy Existing Outfit"]
            .waitForExistence(timeout: 5), "existing outfit picker did not open")
        let docCoat = app.buttons["Doc Coat"]
        XCTAssertTrue(docCoat.waitForExistence(timeout: 5),
                      "built-in outfits are not available as copy sources")
        docCoat.click()
        XCTAssertTrue(app.staticTexts["Place Copied Outfit"]
            .waitForExistence(timeout: 5), "copied outfit placement did not open")
        XCTAssertTrue(app.descendants(matching: .any)["starter-image-placement"].exists,
                      "copied outfit cannot be positioned directly")
        XCTAssertTrue(app.descendants(matching: .any)["starter-image-scale"].exists,
                      "copied outfit size control missing")
        XCTAssertTrue(app.descendants(matching: .any)["starter-image-rotation"].exists,
                      "copied outfit rotation control missing")
        let placeCopy = app.buttons["starter-apply"]
        XCTAssertTrue(placeCopy.exists, "copied outfit placement cannot be applied")
        placeCopy.click()
        let pixelCanvas = app.descendants(matching: .any)["outfit-pixel-canvas"]
        XCTAssertTrue(pixelCanvas.waitForExistence(timeout: 5),
                      "placed copy did not return to the pixel editor")
        XCTAssertTrue(clearCanvas.isEnabled, "placed outfit did not populate the canvas")

        // Doc Coat's centerline is transparent; target its painted left panel.
        pixelCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.39, dy: 0.5))
            .doubleClick()
        XCTAssertTrue(app.descendants(matching: .any)["outfit-selection-count"]
            .waitForExistence(timeout: 3),
                      "double-click did not select a connected same-color region")

        pixelCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.15)).click()
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(clearCanvas.isEnabled, "Command-Z did not undo a painted pixel")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertFalse(clearCanvas.isEnabled, "Command-Z did not undo the copied outfit")
        XCTAssertTrue(app.buttons["outfit-redo"].isEnabled,
                      "undo did not create redo history")
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(clearCanvas.isEnabled, "Shift-Command-Z did not restore the outfit")

        app.buttons["outfit-section-tool"].click()
        let selectionStart = pixelCanvas.coordinate(
            withNormalizedOffset: CGVector(dx: 0.37, dy: 0.38)
        )
        let selectionEnd = pixelCanvas.coordinate(
            withNormalizedOffset: CGVector(dx: 0.63, dy: 0.72)
        )
        selectionStart.press(forDuration: 0.1, thenDragTo: selectionEnd)
        XCTAssertTrue(app.descendants(matching: .any)["outfit-selection-count"]
            .waitForExistence(timeout: 3), "range drag did not select painted pixels")
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(app.buttons["outfit-undo"].isEnabled,
                      "arrow key did not move the selected pixels")
        app.typeKey("c", modifierFlags: .command)
        XCTAssertTrue(app.buttons["outfit-paste-pixels"].isEnabled,
                      "Command-C did not copy the selected pixel range")
        app.typeKey("p", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["outfit-selection-count"].exists,
                      "Command-P did not paste and select the copied pixel range")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "custom-outfit-studio"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testCharacterMuteAndSoloAreVisibleAndMutuallyExclusive() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        if !app.windows.firstMatch.waitForExistence(timeout: 3) {
            app.typeKey("n", modifierFlags: .command)
        }
        // DocumentGroup may restore the prior test's edited Untitled window.
        // Always create a pristine one so this test owns its character state.
        app.typeKey("n", modifierFlags: .command)

        let window = app.windows.firstMatch
        let browse = window.buttons["workspace-browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 10), "Browse control missing")
        browse.click()

        let castCard = window.buttons["cast-card-0"]
        if !castCard.waitForExistence(timeout: 3) {
            let add = window.buttons["cast-add"]
            XCTAssertTrue(add.waitForExistence(timeout: 3), "Cast Add control missing")
            add.click()
            let original = app.descendants(matching: .any)["cast-add-original"]
            XCTAssertTrue(original.waitForExistence(timeout: 3), "Original cast choice missing")
            original.click()
        }
        XCTAssertTrue(castCard.waitForExistence(timeout: 5), "character cast card missing")
        castCard.click()

        let inspect = window.buttons["workspace-inspect"]
        XCTAssertTrue(inspect.exists, "Inspect control missing")
        inspect.click()

        let mute = window.buttons["track-mute"]
        let solo = window.buttons["track-solo"]
        XCTAssertTrue(mute.waitForExistence(timeout: 5), "Mute control missing")
        XCTAssertTrue(solo.exists, "Solo control missing")

        mute.click()
        XCTAssertTrue(mute.label.contains("Muted"), "Mute did not become active")
        solo.click()
        XCTAssertTrue(solo.label.contains("Soloed"), "Solo did not become active")
        XCTAssertFalse(mute.label.contains("Muted"),
                       "Solo should clear Mute to avoid an ambiguous monitor state")
    }

    @MainActor
    func testCastBrowserOffersConfirmedUndoableCharacterRemoval() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        if !app.windows.firstMatch.waitForExistence(timeout: 3) {
            app.typeKey("n", modifierFlags: .command)
        }
        app.typeKey("n", modifierFlags: .command)

        let window = app.windows.firstMatch
        let browse = window.buttons["workspace-browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 10), "Browse control missing")
        browse.click()

        let actions = app.descendants(matching: .any)["cast-actions-0"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5), "Cast actions menu missing")
        actions.click()
        let remove = app.descendants(matching: .any)["cast-remove-0"]
        XCTAssertTrue(remove.waitForExistence(timeout: 3), "Remove Character action missing")
        remove.click()

        let confirm = window.sheets.firstMatch.buttons["Remove Character"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "Removal confirmation missing")
        confirm.click()
        XCTAssertTrue(app.staticTexts["Add a character to start performing."]
            .waitForExistence(timeout: 5), "Character remained after confirmed removal")

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["cast-actions-0"]
            .waitForExistence(timeout: 5), "Undo did not restore the removed character")
    }

    @MainActor
    func testCharacterRemovalFromInspectorDoesNotLeaveAStaleInspector() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        if !app.windows.firstMatch.waitForExistence(timeout: 3) {
            app.typeKey("n", modifierFlags: .command)
        }
        app.typeKey("n", modifierFlags: .command)

        let window = app.windows.firstMatch
        let browse = window.buttons["workspace-browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 10), "Browse control missing")
        browse.click()
        let castCard = window.buttons["cast-card-0"]
        if !castCard.waitForExistence(timeout: 3) {
            let add = window.buttons["cast-add"]
            XCTAssertTrue(add.waitForExistence(timeout: 3), "Cast Add control missing")
            add.click()
            let original = app.descendants(matching: .any)["cast-add-original"]
            XCTAssertTrue(original.waitForExistence(timeout: 3), "Original cast choice missing")
            original.click()
        }
        XCTAssertTrue(castCard.waitForExistence(timeout: 5), "character cast card missing")
        castCard.click()
        let inspect = window.buttons["workspace-inspect"]
        XCTAssertTrue(inspect.waitForExistence(timeout: 3), "Inspect control missing")
        inspect.click()

        let dialogue = window.disclosureTriangles["dialogue-disclosure"]
        let dialogueFallback = window.buttons["dialogue-disclosure"]
        XCTAssertTrue(dialogue.waitForExistence(timeout: 5) || dialogueFallback.exists,
                      "character inspector did not open")
        let delete = app.descendants(matching: .any)["track-delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "Delete character control missing")
        let scrollViews = window.scrollViews
        XCTAssertGreaterThan(scrollViews.count, 0, "Inspector scroll view missing")
        let inspectorScroll = scrollViews.element(boundBy: max(0, scrollViews.count - 1))
        for _ in 0..<6 where !delete.isHittable {
            inspectorScroll.swipeUp()
        }
        XCTAssertTrue(delete.isHittable, "Delete character control could not be reached")
        delete.click()

        let confirm = app.descendants(matching: .any)["track-delete-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "Removal confirmation missing")
        confirm.click()
        XCTAssertEqual(app.state, .runningForeground)
        browse.click()
        XCTAssertTrue(app.staticTexts["Add a character to start performing."]
            .waitForExistence(timeout: 5), "Character remained after inspector removal")

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(window.buttons["cast-card-0"].waitForExistence(timeout: 5),
                      "Undo did not restore the inspector-removed character")
    }

    /// The band, gutter, and playhead all read one scroll-offset source, and it
    /// has silently frozen twice when the measured subtree changed shape (see
    /// 7de8eeb). Frozen, the chrome welds to the viewport while the lanes scroll
    /// underneath. The track cards are real views and catch a dead offset; the
    /// gutter's names and pills are Canvas pixels, and only they catch a draw
    /// closure that never registered the offset as a dependency.
    @MainActor
    func testTimelineChromeTracksScrolling() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        openSampleShow(app)

        // DocumentGroup also opens an Untitled window at launch; both carry a
        // timeline, so every query has to name the one holding the show.
        let window = app.windows["ep1.bannyshow"]
        XCTAssertTrue(window.waitForExistence(timeout: 15), "sample show did not open")
        // A scroll aimed at a background window goes nowhere. Click the title
        // bar — not the content — to make sure this window is the one listening.
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 120, dy: 12)).click()
        let timeline = window.descendants(matching: .any)["studio-timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 15), "timeline missing")
        let card = window.buttons["track-card-c-0"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "character track card missing")

        let gutterBefore = strip(of: timeline, .gutter)
        attach(timeline.screenshot(), named: "timeline-before-scroll")
        XCTAssertTrue(scrollLanes(timeline, byDeltaX: 0, deltaY: -140),
                      "lanes never scrolled; the test proves nothing about the gutter")
        attach(timeline.screenshot(), named: "timeline-after-vertical-scroll")
        XCTAssertNotEqual(gutterBefore, strip(of: timeline, .gutter),
                          "gutter kept its last drawing while the lanes scrolled")

        // The ruler band rides the same offsets on the other axis, and it was
        // reported stuck alongside the gutter. Prove that half too.
        let bandBefore = strip(of: timeline, .band)
        XCTAssertTrue(scrollLanes(timeline, byDeltaX: -200, deltaY: 0),
                      "lanes never scrolled sideways; the band check proves nothing")
        attach(timeline.screenshot(), named: "timeline-after-horizontal-scroll")
        XCTAssertNotEqual(bandBefore, strip(of: timeline, .band),
                          "ruler band stayed welded to the viewport while the lanes scrolled")
    }

    /// Scrolls until the lane pixels actually move, and reports whether they
    /// did. The gesture silently no-ops when the window isn't key yet, and a
    /// still gutter beside still lanes is evidence about the gesture, not the
    /// gutter — so the caller asserts on this before reading the chrome.
    @MainActor
    private func scrollLanes(_ timeline: XCUIElement,
                             byDeltaX dx: CGFloat, deltaY dy: CGFloat) -> Bool {
        for _ in 0..<4 {
            let before = strip(of: timeline, .lanes)
            timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6))
                .scroll(byDeltaX: dx, deltaY: dy)
            sleep(1)
            if strip(of: timeline, .lanes) != before { return true }
        }
        return false
    }

    private enum TimelineStrip {
        /// The pinned label gutter, `laneLabelWidth` wide.
        case gutter
        /// Scrolling lane content, just right of the gutter.
        case lanes
        /// The pinned ruler band above the lanes.
        case band
    }

    @MainActor
    private func strip(of timeline: XCUIElement, _ which: TimelineStrip) -> Data? {
        let image = timeline.screenshot().image
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let scale = CGFloat(cg.width) / image.size.width
        // Start below the ruler so the playhead can't stand in for live pixels.
        let top = 60 * scale
        let height = min(CGFloat(cg.height) - top, 300 * scale)
        let box: CGRect
        switch which {
        case .gutter:
            box = CGRect(x: 0, y: top, width: 110 * scale, height: height)
        case .lanes:
            box = CGRect(x: 130 * scale, y: top, width: 400 * scale, height: height)
        case .band:
            box = CGRect(x: 130 * scale, y: 0, width: 400 * scale, height: 30 * scale)
        }
        guard let cropped = cg.cropping(to: box) else { return nil }
        return NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])
    }

    @MainActor
    private func attach(_ shot: XCUIScreenshot, named name: String) {
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Opens the repo's checked-in show, which has enough lanes to overflow the
    /// timeline vertically. A fresh document does not.
    @MainActor
    private func openSampleShow(_ app: XCUIApplication) {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UITests
            .deletingLastPathComponent()   // App
            .deletingLastPathComponent()   // repo root
        let show = repo.appendingPathComponent("ep1.bannyshow")

        let opened = app.windows["ep1.bannyshow"]
        if opened.exists { return }

        app.typeKey("o", modifierFlags: .command)
        // The open panel lands as a plain window, a dialog, or a sheet
        // depending on the document state; wait for the sidebar it always has.
        _ = app.staticTexts["Applications"].waitForExistence(timeout: 10)
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(show.path)
        app.typeKey(.return, modifierFlags: [])
        sleep(1)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(opened.waitForExistence(timeout: 15),
                      "sample show did not open; windows = \(app.windows.allElementsBoundByIndex.map(\.title))")
    }

    /// Native popover materials used to stay in the system appearance while
    /// Studio's semantic text switched themes, producing white text on a pale
    /// surface. Exercise both modes at the real presentation boundary and keep
    /// focused attachments for visual regression review.
    @MainActor
    func testPerformanceKeysPresentationInBothStudioThemes() throws {
        for (name, lightMode) in [("dark", "NO"), ("light", "YES")] {
            let app = XCUIApplication()
            app.launchArguments = [
                "-ApplePersistenceIgnoreState", "YES",
                "-studioLightMode", lightMode
            ]
            app.launch()
            if !app.windows.firstMatch.waitForExistence(timeout: 3) {
                app.typeKey("n", modifierFlags: .command)
            }

            let button = app.buttons["workspace-performance-keys"]
            XCTAssertTrue(button.waitForExistence(timeout: 10),
                          "Performance Keys button missing in \(name) mode")
            button.click()

            let guide = app.popovers.firstMatch
            XCTAssertTrue(guide.waitForExistence(timeout: 5),
                          "Performance Keys popover missing in \(name) mode")
            XCTAssertTrue(guide.staticTexts["PERFORMANCE KEYS"].exists,
                          "Performance Keys content missing in \(name) mode")
            let shot = XCTAttachment(screenshot: guide.screenshot())
            shot.name = "performance-keys-\(name)"
            shot.lifetime = .keepAlways
            add(shot)
            let windowShot = XCTAttachment(
                screenshot: app.windows.firstMatch.screenshot())
            windowShot.name = "studio-window-\(name)"
            windowShot.lifetime = .keepAlways
            add(windowShot)
            app.terminate()
        }
    }
    #endif
}

#if !os(macOS)
extension SmokeTests {
    /// App Review 2.1(a) regression: the original iOS submission could stop
    /// responding after the reviewer first tried to move a character. Exercise
    /// the real touch stick, prove it reaches the model, then immediately use a
    /// separate editor control. This runs unchanged on iPhone and iPad.
    @MainActor
    func testTouchMovementKeepsEditorResponsive() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        let create = app.buttons["Create Document"].firstMatch
        if create.waitForExistence(timeout: 8) { create.tap() }

        let stick = app.descendants(matching: .any)["performance-move-stick"]
        XCTAssertTrue(stick.waitForExistence(timeout: 10), "movement stick missing")
        XCTAssertTrue(stick.isHittable, "movement stick is not hittable")

        let center = stick.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let right = stick.coordinate(
            withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5))
        center.press(forDuration: 0.25, thenDragTo: right)

        XCTAssertEqual(stick.value as? String, "Movement active",
                       "touch movement never reached the character model")
        XCTAssertEqual(app.state, .runningForeground)

        if UIDevice.current.userInterfaceIdiom == .pad {
            let browse = app.buttons["workspace-browse"]
            XCTAssertTrue(browse.waitForExistence(timeout: 3),
                          "editor did not respond after movement")
            browse.tap()
            XCTAssertTrue(app.descendants(matching: .any)["workspace-drawer"]
                .waitForExistence(timeout: 3),
                          "Browse did not open after movement")
        } else {
            let timeline = app.buttons["Timeline"]
            XCTAssertTrue(timeline.waitForExistence(timeout: 3),
                          "editor did not respond after movement")
            timeline.tap()
            XCTAssertTrue(app.descendants(matching: .any)["studio-timeline"]
                .waitForExistence(timeout: 3),
                          "Timeline did not open after movement")
        }
    }

    /// Screenshot harness: open the seeded show (via BANNY_OPEN_DOC) and hold
    /// it on screen while the host grabs simctl screenshots.
    @MainActor
    func testHoldSeededShow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        if let doc = ProcessInfo.processInfo.environment["BANNY_OPEN_DOC"] {
            app.launchEnvironment["BANNY_OPEN_DOC"] = doc
        }
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        // Rotated remote-view taps are flaky on iPhone; shoot portrait there.
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        app.launch()
        func tap(_ e: XCUIElement, _ t: TimeInterval = 5) -> Bool {
            guard e.waitForExistence(timeout: t) else { return false }
            e.tap(); return true
        }
        // iPad launch scene: big Create Document button. iPhone: open the
        // seeded document through Browse (its + is unreliable to hit).
        var opened = tap(app.buttons["Create Document"].firstMatch, 6)
        if !opened {
            _ = tap(app.buttons["Browse"].firstMatch)
            _ = tap(app.staticTexts["On My iPhone"].firstMatch, 3)
            _ = tap(app.staticTexts["Banny Studio"].firstMatch, 3)
            opened = tap(app.staticTexts["ep1-beat1"].firstMatch, 5)
            if !opened { print("BROWSER DUMP: \(app.debugDescription)") }
        }
        sleep(75)
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Live mode is reached from the header, not the title bar, and its setup
    /// sheet must offer a model for the command-line agents.
    @MainActor
    func testLiveModeSelectorOpensSetupWithModelChoice() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        if !app.windows.firstMatch.waitForExistence(timeout: 3) {
            app.typeKey("n", modifierFlags: .command)
        }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "no window appeared")

        XCTAssertTrue(window.buttons["studio-mode-produce"].waitForExistence(timeout: 10),
                      "Produce control missing from the header")
        let liveControl = window.buttons["studio-mode-live"]
        XCTAssertTrue(liveControl.exists, "Live control missing from the header")
        liveControl.click()

        XCTAssertTrue(app.staticTexts["live-setup-title"].waitForExistence(timeout: 8),
                      "Live setup sheet did not open")
        let picker = app.popUpButtons["live-model-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5),
                      "no model choice for the command-line agent")
        // Claude Code is the first preset, so its aliases are what should be on
        // offer — the point of the picker, not merely that a control exists.
        picker.click()
        for alias in ["Default", "Opus", "Sonnet", "Fable", "Haiku"] {
            XCTAssertTrue(app.menuItems[alias].waitForExistence(timeout: 3),
                          "\(alias) missing from the model choices")
        }
        app.typeKey(.escape, modifierFlags: [])

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "live-setup"
        shot.lifetime = .keepAlways
        add(shot)
    }


    /// Two .fileImporter modifiers on one view leave only one working, which is
    /// how the backdrop button silently died. Prove it opens a panel.
    @MainActor
    func testLiveBackdropButtonOpensAPicker() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        if !app.windows.firstMatch.waitForExistence(timeout: 3) {
            app.typeKey("n", modifierFlags: .command)
        }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "no window appeared")
        window.buttons["studio-mode-live"].click()
        XCTAssertTrue(app.staticTexts["live-setup-title"].waitForExistence(timeout: 8),
                      "Live setup sheet did not open")

        let chooser = app.buttons["live-choose-backdrop"]
        XCTAssertTrue(chooser.waitForExistence(timeout: 5), "backdrop button missing")
        chooser.click()

        // A real NSOpenPanel is its own window carrying an Open button; a bare
        // "Cancel" match is not proof, several sheets have one.
        let panel = app.windows.containing(.button, identifier: "OKButton").firstMatch
        let openButton = app.buttons["OKButton"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 10),
                      "backdrop button did not open a file picker")
        XCTAssertTrue(panel.exists, "no open-panel window appeared")
        app.typeKey(.escape, modifierFlags: [])
    }


    /// Pressing Play runs a command-line agent through NSUserUnixTask. Every
    /// handle it is given must be backed by a real file descriptor, or encoding
    /// them for the task helper aborts the process — this drives that path.
    @MainActor
    func testLiveModePlayDoesNotCrash() throws {
        // A backdrop to choose. The picker is the only way in, and it grants the
        // sandbox access the scene builder then reads through.
        let backdrop = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("banny-live-test-backdrop.png")
        let image = NSImage(size: NSSize(width: 640, height: 360))
        image.lockFocus()
        NSColor.systemTeal.drawSwatch(in: NSRect(x: 0, y: 0, width: 640, height: 360))
        image.unlockFocus()
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: backdrop)
        }

        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        if !app.windows.firstMatch.waitForExistence(timeout: 3) {
            app.typeKey("n", modifierFlags: .command)
        }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "no window appeared")
        window.buttons["studio-mode-live"].click()
        XCTAssertTrue(app.staticTexts["live-setup-title"].waitForExistence(timeout: 8),
                      "Live setup sheet did not open")

        app.buttons["live-choose-backdrop"].click()
        XCTAssertTrue(app.buttons["OKButton"].waitForExistence(timeout: 10), "no file picker")
        // Go-to-folder is the reliable way to reach an arbitrary path.
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(backdrop.path)
        app.typeKey(.enter, modifierFlags: [])
        app.typeKey(.enter, modifierFlags: [])

        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 8), "Play button missing")
        XCTAssertTrue(play.isEnabled, "Play stayed disabled after choosing a backdrop")
        play.click()

        XCTAssertTrue(app.descendants(matching: .any)["live-transport"]
            .waitForExistence(timeout: 10), "live transport never appeared")
        // Waiting on an agent must look like waiting, not like a hang.
        XCTAssertTrue(app.descendants(matching: .any)["live-opening-curtain"]
            .waitForExistence(timeout: 10),
                      "no loading indicator while writing the opening")
        // The agent takes a while to answer; what matters is that asking it does
        // not take the app down.
        sleep(20)
        XCTAssertEqual(app.state, .runningForeground, "Live mode crashed after Play")
        // Report what the director actually did, so a green test cannot hide a
        // model that was never reached.
        let status = app.descendants(matching: .any)["live-status"]
        XCTAssertTrue(status.exists, "no status shown")
        let text = status.value as? String ?? status.label
        XCTAssertTrue(text.contains("Performing") || text.contains("Writing"),
                      "director never reached the model — status was: '\(text)'")
    }


    /// Writing stops after the first stretch so it can be judged — which means
    /// watching it. The controls to do that must be present and the playhead
    /// must go back to the top on its own.
    @MainActor
    func testLiveReviewOffersPlaybackOfTheWrittenStretch() throws {
        let backdrop = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("banny-live-review-backdrop.png")
        let image = NSImage(size: NSSize(width: 640, height: 360))
        image.lockFocus()
        NSColor.systemIndigo.drawSwatch(in: NSRect(x: 0, y: 0, width: 640, height: 360))
        image.unlockFocus()
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: backdrop)
        }

        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        if !app.windows.firstMatch.waitForExistence(timeout: 3) {
            app.typeKey("n", modifierFlags: .command)
        }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "no window appeared")
        window.buttons["studio-mode-live"].click()
        XCTAssertTrue(app.staticTexts["live-setup-title"].waitForExistence(timeout: 8),
                      "Live setup sheet did not open")
        app.buttons["live-choose-backdrop"].click()
        XCTAssertTrue(app.buttons["OKButton"].waitForExistence(timeout: 10), "no file picker")
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(backdrop.path)
        app.typeKey(.enter, modifierFlags: [])
        app.typeKey(.enter, modifierFlags: [])
        app.buttons["Play"].click()

        // The agent writes the first 30s; give it room, then expect the review.
        let review = app.descendants(matching: .any)["live-review"]
        XCTAssertTrue(review.waitForExistence(timeout: 300),
                      "never reached the review after the first stretch")

        XCTAssertTrue(app.buttons["live-replay"].exists, "no way to watch it again")
        XCTAssertTrue(app.buttons["live-replay-toggle"].exists, "no play/pause")
        XCTAssertTrue(app.sliders["live-scrubber"].exists, "the stretch is not scrubbable")
        XCTAssertTrue(app.buttons["live-extend"].exists, "no way to extend")
        XCTAssertTrue(app.buttons["live-rewrite"].exists, "no way to try again")

        // A section with nobody in it is not a scene, but the stage is a canvas
        // with no accessible children — so this is kept as a screenshot for a
        // person to look at rather than asserted on.
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "live-section"
        shot.lifetime = .keepAlways
        add(shot)

        // It should already be replaying from the top rather than sitting at the end.
        let scrubber = app.sliders["live-scrubber"]
        let position = (scrubber.value as? String).flatMap {
            Double($0.replacingOccurrences(of: "%", with: ""))
        } ?? 100
        XCTAssertLessThan(position, 90,
                          "the playhead stayed at the end instead of rewinding to watch")
    }


    /// Typing a name must not cost you the field after every letter. Identifying
    /// a cast row by its (editable) name did exactly that.
    @MainActor
    func testCastNameAcceptsContinuousTyping() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        if !app.windows.firstMatch.waitForExistence(timeout: 3) {
            app.typeKey("n", modifierFlags: .command)
        }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "no window appeared")
        window.buttons["studio-mode-live"].click()
        XCTAssertTrue(app.staticTexts["live-setup-title"].waitForExistence(timeout: 8),
                      "Live setup sheet did not open")

        // The first cast row's name field, whatever it is currently called.
        let row = app.descendants(matching: .any)["live-cast-row-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no cast row")
        let name = row.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5), "no name field")

        name.click()
        app.typeKey("a", modifierFlags: .command)      // select all
        // One letter at a time, as a person types. A single typeText() is
        // delivered too atomically to notice a row being rebuilt between keys.
        for letter in "Dara" {
            app.typeText(String(letter))
            usleep(120_000)
        }

        // One click, one word. Anything less means focus was lost mid-typing.
        XCTAssertEqual(name.value as? String, "Dara",
                       "typing dropped characters — the field lost focus")
    }

}
#endif
