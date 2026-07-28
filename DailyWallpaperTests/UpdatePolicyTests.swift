import XCTest
@testable import DailyWallpaper

final class UpdatePolicyTests: XCTestCase {
    private func display(id: String, width: Int, height: Int) -> DisplayDescriptor {
        DisplayDescriptor(
            uuid: id,
            localizedName: id,
            isMain: id == "a",
            logicalWidth: width / 2,
            logicalHeight: height / 2,
            pixelWidth: width,
            pixelHeight: height,
            isConnected: true
        )
    }

    func testSharedModeProducesOneRequestForTwoDisplays() {
        let requests = UpdatePlanBuilder.buildRequests(
            mode: .shared,
            sharedProfile: .default,
            assignments: [:],
            displays: [display(id: "a", width: 1_920, height: 1_080), display(id: "b", width: 3_840, height: 2_160)]
        )
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].variant, .uhd)
        XCTAssertEqual(Set(requests[0].targetDisplayUUIDs), ["a", "b"])
    }

    func testIndependentEquivalentProfilesAreMerged() {
        let requests = UpdatePlanBuilder.buildRequests(
            mode: .individual,
            sharedProfile: .default,
            assignments: ["a": .default, "b": .default],
            displays: [display(id: "a", width: 1_920, height: 1_080), display(id: "b", width: 1_920, height: 1_080)]
        )
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(Set(requests[0].targetDisplayUUIDs), ["a", "b"])
    }

    func testRetryScheduleStopsAfterThirdRetry() {
        XCTAssertEqual(RetrySchedule.entry(afterFailure: 1)?.delay, 900)
        XCTAssertEqual(RetrySchedule.entry(afterFailure: 3)?.delay, 10_800)
        XCTAssertNil(RetrySchedule.entry(afterFailure: 4))
    }

    func testPendingTriggerKeepsHighestPriorityWithinSameCategory() {
        XCTAssertEqual(UpdateTriggerCoalescer.merge(.wake, with: .settingsChanged), .settingsChanged)
        XCTAssertEqual(UpdateTriggerCoalescer.merge(.manualDownload, with: .manualDownloadAndApply), .manualDownloadAndApply)
        XCTAssertEqual(UpdateTriggerCoalescer.merge(.screensChanged, with: .sessionActive), .screensChanged)
    }
}
