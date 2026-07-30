import XCTest

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

        let drawer = app.otherElements["workspace-drawer"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 5), "shared inspector drawer did not open")
        let advanced = app.disclosureTriangles["advanced-disclosure"]
        if advanced.waitForExistence(timeout: 2) {
            advanced.click()
        } else {
            let fallback = app.buttons["advanced-disclosure"]
            XCTAssertTrue(fallback.waitForExistence(timeout: 3), "advanced disclosure missing")
            fallback.click()
        }

        let editJSON = app.buttons["edit-advanced-json"]
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

        XCTAssertTrue(app.textFields["outfit-name"].waitForExistence(timeout: 5),
                      "outfit editor did not open")
        XCTAssertTrue(app.descendants(matching: .any)["outfit-category"].exists,
                      "category picker missing")
        XCTAssertTrue(app.descendants(matching: .any)["outfit-pixel-canvas"].exists,
                      "pixel canvas missing")
        XCTAssertTrue(app.buttons["outfit-section-tool"].exists,
                      "contiguous pixel-section tool missing")
        XCTAssertTrue(app.checkBoxes["outfit-show-mannequin"].exists,
                      "mannequin guide toggle missing")
        let copyExisting = app.buttons["copy-existing-outfit"]
        XCTAssertTrue(copyExisting.exists, "Copy Existing Outfit control missing")
        copyExisting.click()
        XCTAssertTrue(app.staticTexts["Copy Existing Outfit"]
            .waitForExistence(timeout: 5), "existing outfit picker did not open")
        XCTAssertTrue(app.buttons["Doc Coat"].waitForExistence(timeout: 5),
                      "built-in outfits are not available as copy sources")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.descendants(matching: .any)["outfit-pixel-canvas"]
            .waitForExistence(timeout: 5), "copy picker did not dismiss")

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
}
#endif
