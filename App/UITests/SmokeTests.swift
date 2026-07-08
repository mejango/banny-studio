import XCTest

final class SmokeTests: XCTestCase {
    @MainActor
    func testLaunchNewDocumentAndScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        // Document apps may open an Open panel or an untitled window; force a new doc.
        app.typeKey("n", modifierFlags: .command)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "no document window appeared")
        sleep(2)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "editor"
        shot.lifetime = .keepAlways
        add(shot)
        // Space should toggle playback without crashing.
        app.typeKey(XCUIKeyboardKey.space, modifierFlags: [])
        sleep(1)
        XCTAssertTrue(app.state == .runningForeground)
        let shot2 = XCTAttachment(screenshot: app.screenshot())
        shot2.name = "playing"
        shot2.lifetime = .keepAlways
        add(shot2)
    }
}
