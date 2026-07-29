import AppKit
import XCTest
@testable import DailyWallpaper

final class WindowLayoutPolicyTests: XCTestCase {
    func testOversizedRestoredFrameIsConstrainedToVisibleFrame() {
        let visibleFrame = NSRect(x: 100, y: 50, width: 1_200, height: 800)
        let result = constrainedWindowFrame(
            NSRect(x: -500, y: -300, width: 2_400, height: 1_600),
            inside: visibleFrame,
            minimumSize: NSSize(width: 1_000, height: 600)
        )

        XCTAssertEqual(result, visibleFrame)
    }

    func testNormalRestoredFrameIsPreserved() {
        let proposed = NSRect(x: 220, y: 140, width: 1_080, height: 700)
        let result = constrainedWindowFrame(
            proposed,
            inside: NSRect(x: 0, y: 0, width: 1_512, height: 949),
            minimumSize: NSSize(width: 1_000, height: 600)
        )

        XCTAssertEqual(result, proposed)
    }

    func testOffscreenRestoredFrameMovesBackIntoVisibleArea() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_512, height: 949)
        let result = constrainedWindowFrame(
            NSRect(x: 1_400, y: 900, width: 1_000, height: 600),
            inside: visibleFrame,
            minimumSize: NSSize(width: 1_000, height: 600)
        )

        XCTAssertEqual(result.maxX, visibleFrame.maxX)
        XCTAssertEqual(result.maxY, visibleFrame.maxY)
        XCTAssertGreaterThanOrEqual(result.minX, visibleFrame.minX)
        XCTAssertGreaterThanOrEqual(result.minY, visibleFrame.minY)
    }

    func testInvalidRestoredFrameFallsBackToFinitePositiveSize() {
        let visibleFrame = NSRect(x: 100, y: 50, width: 1_200, height: 800)
        let result = constrainedWindowFrame(
            NSRect(x: CGFloat.nan, y: CGFloat.infinity, width: -20, height: 0),
            inside: visibleFrame,
            minimumSize: NSSize(width: 1_000, height: 600)
        )

        let values: [CGFloat] = [result.minX, result.minY, result.width, result.height]
        XCTAssertTrue(values.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(result.width, 0)
        XCTAssertGreaterThan(result.height, 0)
        XCTAssertTrue(visibleFrame.contains(result))
    }
}
