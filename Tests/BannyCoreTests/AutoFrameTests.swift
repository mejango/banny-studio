import XCTest
@testable import BannyCore

final class AutoFrameTests: XCTestCase {
    func testSquareAssetSnapsDefaultFrameToOneToOne() {
        let r = Settings().autoFrame(assetPixelW: 1200, assetPixelH: 1200, hasBackgroundCues: false)
        XCTAssertEqual(r?.w, 1)
        XCTAssertEqual(r?.h, 1)
    }

    func testNonSquareAssetReducesRatio() {
        let r = Settings().autoFrame(assetPixelW: 1200, assetPixelH: 1390, hasBackgroundCues: false)
        XCTAssertEqual(r?.w, 120)
        XCTAssertEqual(r?.h, 139)
    }

    func testExistingBackgroundCuesLeaveFrameAlone() {
        XCTAssertNil(Settings().autoFrame(assetPixelW: 1200, assetPixelH: 1200, hasBackgroundCues: true))
    }

    func testExplicitFrameChoiceIsNeverOverridden() {
        var s = Settings()
        s.frameW = 9; s.frameH = 16
        XCTAssertNil(s.autoFrame(assetPixelW: 1200, assetPixelH: 1200, hasBackgroundCues: false))
        s.frameW = 1; s.frameH = 1
        XCTAssertNil(s.autoFrame(assetPixelW: 1920, assetPixelH: 1080, hasBackgroundCues: false))
    }

    func testDegenerateDimensionsDoNothing() {
        XCTAssertNil(Settings().autoFrame(assetPixelW: 0, assetPixelH: 1200, hasBackgroundCues: false))
        XCTAssertNil(Settings().autoFrame(assetPixelW: 1200, assetPixelH: 0, hasBackgroundCues: false))
    }
}
