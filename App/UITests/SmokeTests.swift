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
        XCTAssertTrue(app.otherElements["workspace-drawer"].waitForExistence(timeout: 5),
                      "Browse drawer did not open")
        XCTAssertTrue(app.otherElements["browser-cast"].waitForExistence(timeout: 5),
                      "Cast browser missing")

        let inspect = app.buttons["workspace-inspect"]
        XCTAssertTrue(inspect.exists, "Inspect control missing")
        inspect.click()
        XCTAssertTrue(app.disclosureTriangles["dialogue-disclosure"].waitForExistence(timeout: 5)
                      || app.buttons["dialogue-disclosure"].exists,
                      "Contextual character inspector missing")
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
