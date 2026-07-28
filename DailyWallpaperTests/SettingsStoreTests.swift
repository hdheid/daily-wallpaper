import Foundation
import XCTest
@testable import DailyWallpaper

@MainActor
final class SettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: SettingsStore!

    override func setUp() {
        suiteName = "DailyWallpaperTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        settings = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testEnablingAutomaticApplyAlsoEnablesDownload() {
        settings.automaticDailyDownloadEnabled = false
        settings.automaticDailyApplyEnabled = true
        XCTAssertTrue(settings.automaticDailyDownloadEnabled)
        XCTAssertTrue(settings.automaticDailyApplyEnabled)
    }

    func testDisablingDownloadAlsoDisablesApply() {
        settings.automaticDailyApplyEnabled = true
        settings.automaticDailyDownloadEnabled = false
        XCTAssertFalse(settings.automaticDailyDownloadEnabled)
        XCTAssertFalse(settings.automaticDailyApplyEnabled)
    }

    func testConfigurationRevisionOnlyTracksDecisionChanges() {
        var callbackCount = 0
        settings.onConfigurationChange = { callbackCount += 1 }

        var profile = settings.sharedProfile
        profile.scaling = .fit
        settings.sharedProfile = profile
        XCTAssertEqual(settings.configurationRevision, 1)
        XCTAssertEqual(callbackCount, 1)

        // 重复写入相同值以及缓存状态变化都不应安排额外更新任务。
        settings.sharedProfile = profile
        settings.markDownloaded(configurationFingerprint: "test", on: "2026-07-27")
        XCTAssertEqual(settings.configurationRevision, 1)
        XCTAssertEqual(callbackCount, 1)
    }

    func testSavingDisplayConfigurationCommitsAllValuesWithOneNotification() {
        var callbackCount = 0
        settings.onConfigurationChange = { callbackCount += 1 }
        var sharedProfile = WallpaperProfile.default
        sharedProfile.market = "ja-JP"
        var displayProfile = WallpaperProfile.default
        displayProfile.scaling = .fit
        let assignments = ["display-1": displayProfile]

        settings.saveDisplayConfiguration(
            mode: .individual,
            sharedProfile: sharedProfile,
            displayAssignments: assignments
        )

        XCTAssertEqual(settings.configurationMode, .individual)
        XCTAssertEqual(settings.sharedProfile, sharedProfile)
        XCTAssertEqual(settings.displayAssignments, assignments)
        XCTAssertEqual(settings.configurationRevision, 1)
        XCTAssertEqual(callbackCount, 1)
    }

    func testSavingAutomationConfigurationPreservesDependencyWithOneNotification() {
        settings.saveAutomationConfiguration(downloadEnabled: false, applyEnabled: false)
        var callbackCount = 0
        settings.onConfigurationChange = { callbackCount += 1 }

        settings.saveAutomationConfiguration(downloadEnabled: false, applyEnabled: true)

        XCTAssertTrue(settings.automaticDailyDownloadEnabled)
        XCTAssertTrue(settings.automaticDailyApplyEnabled)
        XCTAssertEqual(settings.configurationRevision, 2)
        XCTAssertEqual(callbackCount, 1)
    }
}
