import Foundation
import XCTest
@testable import DailyWallpaper

@MainActor
final class SettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: SettingsStore!

    override func setUp() async throws {
        suiteName = "DailyWallpaperTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        settings = SettingsStore(defaults: defaults)
    }

    override func tearDown() async throws {
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

    func testPreferenceDraftMergeKeepsOnlyActuallyEditedFields() {
        // 未编辑字段应采用菜单栏刚保存的新值。
        XCTAssertFalse(mergePreferenceDraftValue(
            draft: true,
            previousBaseline: true,
            persisted: false
        ))

        // 用户明确改过的字段应继续保留草稿，等待点击“保存更改”。
        XCTAssertFalse(mergePreferenceDraftValue(
            draft: false,
            previousBaseline: true,
            persisted: true
        ))
    }

    func testRemovingSingleWallpaperReferencesKeepsOtherImages() {
        let rootID = UUID()
        settings.setCurrentWallpaper(CurrentWallpaperRecord(
            displayUUID: "display-first",
            rootID: rootID,
            relativeImagePath: "first.jpg",
            contentSHA256: "first",
            title: "first",
            copyrightText: "",
            scaling: .fill,
            updatedAt: Date()
        ))
        settings.setCurrentWallpaper(CurrentWallpaperRecord(
            displayUUID: "display-second",
            rootID: rootID,
            relativeImagePath: "second.jpg",
            contentSHA256: "second",
            title: "second",
            copyrightText: "",
            scaling: .fill,
            updatedAt: Date()
        ))
        settings.setCachedWallpaper(CachedWallpaperRecord(
            configurationFingerprint: "profile-first",
            rootID: rootID,
            relativeImagePath: "first.jpg",
            contentSHA256: "first",
            title: "first",
            copyrightText: "",
            cachedAt: Date()
        ))
        settings.setCachedWallpaper(CachedWallpaperRecord(
            configurationFingerprint: "profile-second",
            rootID: rootID,
            relativeImagePath: "second.jpg",
            contentSHA256: "second",
            title: "second",
            copyrightText: "",
            cachedAt: Date()
        ))
        settings.markDownloaded(configurationFingerprint: "profile-first", on: "2026-07-29")
        settings.markDownloaded(configurationFingerprint: "profile-second", on: "2026-07-29")

        settings.removeWallpaperReferences(toRootID: rootID, relativeImagePath: "first.jpg")

        XCTAssertNil(settings.currentImageByDisplayUUID["display-first"])
        XCTAssertNotNil(settings.currentImageByDisplayUUID["display-second"])
        XCTAssertNil(settings.cachedImageByConfiguration["profile-first"])
        XCTAssertNotNil(settings.cachedImageByConfiguration["profile-second"])
        XCTAssertNil(settings.lastSuccessfulDayByConfiguration["profile-first"])
        XCTAssertEqual(settings.lastSuccessfulDayByConfiguration["profile-second"], "2026-07-29")
    }
}
