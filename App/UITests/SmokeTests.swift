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
}
