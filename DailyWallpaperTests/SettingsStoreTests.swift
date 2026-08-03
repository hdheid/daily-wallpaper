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

    func testSettingsSnapshotRestoresAcrossDifferentPreferenceDomains() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let snapshotURL = base.appendingPathComponent(".dailywallpaper/settings.plist")
        let missingLegacyURL = base.appendingPathComponent("missing.plist")
        let firstSuite = "DailyWallpaperTests.Snapshot.First.\(UUID().uuidString)"
        let secondSuite = "DailyWallpaperTests.Snapshot.Second.\(UUID().uuidString)"
        let firstDefaults = try XCTUnwrap(UserDefaults(suiteName: firstSuite))
        let secondDefaults = try XCTUnwrap(UserDefaults(suiteName: secondSuite))
        defer {
            firstDefaults.removePersistentDomain(forName: firstSuite)
            secondDefaults.removePersistentDomain(forName: secondSuite)
            try? FileManager.default.removeItem(at: base)
        }

        let first = SettingsStore(
            defaults: firstDefaults,
            persistenceURL: snapshotURL,
            legacyPreferencesURL: missingLegacyURL
        )
        var sharedProfile = WallpaperProfile.default
        sharedProfile.market = "ja-JP"
        var displayProfile = WallpaperProfile.default
        displayProfile.scaling = .fit
        let customRoot = LibraryRoot(
            id: UUID(),
            displayName: "Archive",
            kind: .securityScoped,
            bookmarkData: Data([1, 2, 3]),
            isActiveWriteRoot: true
        )
        first.saveDisplayConfiguration(
            mode: .individual,
            sharedProfile: sharedProfile,
            displayAssignments: ["display-1": displayProfile]
        )
        first.saveAutomationConfiguration(downloadEnabled: false, applyEnabled: false)
        first.saveLibraryConfiguration(roots: [customRoot], activeRootID: customRoot.id)

        let restored = SettingsStore(
            defaults: secondDefaults,
            persistenceURL: snapshotURL,
            legacyPreferencesURL: missingLegacyURL
        )

        XCTAssertEqual(restored.configurationMode, .individual)
        XCTAssertEqual(restored.sharedProfile, sharedProfile)
        XCTAssertEqual(restored.displayAssignments["display-1"], displayProfile)
        XCTAssertFalse(restored.automaticDailyDownloadEnabled)
        XCTAssertFalse(restored.automaticDailyApplyEnabled)
        XCTAssertEqual(restored.libraryRoots, [customRoot])
        XCTAssertEqual(restored.activeArchiveRootID, customRoot.id)
    }

    func testFirstSnapshotMigrationUsesNewerLegacyPreferences() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let snapshotURL = base.appendingPathComponent("shared/settings.plist")
        let legacyURL = base.appendingPathComponent("legacy.plist")
        let migrationSuite = "DailyWallpaperTests.Migration.\(UUID().uuidString)"
        let migrationDefaults = try XCTUnwrap(UserDefaults(suiteName: migrationSuite))
        defer {
            migrationDefaults.removePersistentDomain(forName: migrationSuite)
            try? FileManager.default.removeItem(at: base)
        }

        let encoder = JSONEncoder()
        var legacyProfile = WallpaperProfile.default
        legacyProfile.market = "en-US"
        var assignedProfile = WallpaperProfile.default
        assignedProfile.scaling = .fit
        let legacyRoot = LibraryRoot(
            id: UUID(),
            displayName: "Previous Archive",
            kind: .securityScoped,
            bookmarkData: Data([4, 5, 6]),
            isActiveWriteRoot: true
        )
        let legacyValues: [String: Any] = [
            "displayConfigurationMode": DisplayConfigurationMode.individual.rawValue,
            "sharedWallpaperProfile": try encoder.encode(legacyProfile),
            "displayAssignments": try encoder.encode(["display-old": assignedProfile]),
            "automaticDailyDownloadEnabled": false,
            "automaticDailyApplyEnabled": false,
            "libraryRoots": try encoder.encode([legacyRoot]),
            "activeArchiveRootID": legacyRoot.id.uuidString
        ]
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let legacyData = try PropertyListSerialization.data(
            fromPropertyList: legacyValues,
            format: .binary,
            options: 0
        )
        try legacyData.write(to: legacyURL, options: .atomic)

        // 当前域没有同步时间，迁移时采用修改时间更晚的旧偏好文件。
        migrationDefaults.set(
            try encoder.encode([String: WallpaperProfile]()),
            forKey: "displayAssignments"
        )
        let migrated = SettingsStore(
            defaults: migrationDefaults,
            persistenceURL: snapshotURL,
            legacyPreferencesURL: legacyURL
        )

        XCTAssertEqual(migrated.configurationMode, .individual)
        XCTAssertEqual(migrated.sharedProfile, legacyProfile)
        XCTAssertEqual(migrated.displayAssignments["display-old"], assignedProfile)
        XCTAssertFalse(migrated.automaticDailyDownloadEnabled)
        XCTAssertFalse(migrated.automaticDailyApplyEnabled)
        XCTAssertEqual(migrated.libraryRoots, [legacyRoot])
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))
    }

    func testCompletedLegacyMigrationDoesNotReimportNewerLegacyPreferences() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let snapshotURL = base.appendingPathComponent("shared/settings.plist")
        let legacyURL = base.appendingPathComponent("legacy.plist")
        let firstSuite = "DailyWallpaperTests.LegacyOnce.First.\(UUID().uuidString)"
        let secondSuite = "DailyWallpaperTests.LegacyOnce.Second.\(UUID().uuidString)"
        let firstDefaults = try XCTUnwrap(UserDefaults(suiteName: firstSuite))
        let secondDefaults = try XCTUnwrap(UserDefaults(suiteName: secondSuite))
        defer {
            firstDefaults.removePersistentDomain(forName: firstSuite)
            secondDefaults.removePersistentDomain(forName: secondSuite)
            try? FileManager.default.removeItem(at: base)
        }

        let encoder = JSONEncoder()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var originalLegacyProfile = WallpaperProfile.default
        originalLegacyProfile.market = "en-US"
        let originalLegacyData = try PropertyListSerialization.data(
            fromPropertyList: ["sharedWallpaperProfile": try encoder.encode(originalLegacyProfile)],
            format: .binary,
            options: 0
        )
        try originalLegacyData.write(to: legacyURL, options: .atomic)

        let first = SettingsStore(
            defaults: firstDefaults,
            persistenceURL: snapshotURL,
            legacyPreferencesURL: legacyURL
        )
        XCTAssertEqual(first.sharedProfile, originalLegacyProfile)

        // 新版保存后再运行旧 Debug：旧 plist 的时间虽更新，也不能覆盖已迁移的新设置。
        var currentProfile = WallpaperProfile.default
        currentProfile.market = "zh-CN"
        first.sharedProfile = currentProfile

        var laterLegacyProfile = WallpaperProfile.default
        laterLegacyProfile.market = "de-DE"
        let laterLegacyData = try PropertyListSerialization.data(
            fromPropertyList: ["sharedWallpaperProfile": try encoder.encode(laterLegacyProfile)],
            format: .binary,
            options: 0
        )
        try laterLegacyData.write(to: legacyURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(300)],
            ofItemAtPath: legacyURL.path
        )

        let restored = SettingsStore(
            defaults: secondDefaults,
            persistenceURL: snapshotURL,
            legacyPreferencesURL: legacyURL
        )
        XCTAssertEqual(restored.sharedProfile, currentProfile)
    }

    func testNewerCurrentPreferencesAreNotOverwrittenByOlderSharedSnapshot() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let snapshotURL = base.appendingPathComponent("shared/settings.plist")
        let missingLegacyURL = base.appendingPathComponent("missing.plist")
        let oldSuite = "DailyWallpaperTests.Snapshot.Old.\(UUID().uuidString)"
        let currentSuite = "DailyWallpaperTests.Snapshot.Current.\(UUID().uuidString)"
        let oldDefaults = try XCTUnwrap(UserDefaults(suiteName: oldSuite))
        let currentDefaults = try XCTUnwrap(UserDefaults(suiteName: currentSuite))
        defer {
            oldDefaults.removePersistentDomain(forName: oldSuite)
            currentDefaults.removePersistentDomain(forName: currentSuite)
            try? FileManager.default.removeItem(at: base)
        }

        var oldProfile = WallpaperProfile.default
        oldProfile.market = "en-US"
        let oldStore = SettingsStore(
            defaults: oldDefaults,
            persistenceURL: snapshotURL,
            legacyPreferencesURL: missingLegacyURL
        )
        oldStore.sharedProfile = oldProfile

        var currentProfile = WallpaperProfile.default
        currentProfile.market = "zh-CN"
        currentDefaults.set(try JSONEncoder().encode(currentProfile), forKey: "sharedWallpaperProfile")
        currentDefaults.set(UUID().uuidString, forKey: "settingsSnapshotRevision")
        currentDefaults.set(Date().addingTimeInterval(60), forKey: "settingsSnapshotUpdatedAt")

        let restored = SettingsStore(
            defaults: currentDefaults,
            persistenceURL: snapshotURL,
            legacyPreferencesURL: missingLegacyURL
        )
        XCTAssertEqual(restored.sharedProfile, currentProfile)
    }

    func testIncompleteVersionedSnapshotDoesNotClearHealthyPreferences() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let snapshotURL = base.appendingPathComponent("shared/settings.plist")
        let missingLegacyURL = base.appendingPathComponent("missing.plist")
        let suite = "DailyWallpaperTests.Snapshot.Incomplete.\(UUID().uuidString)"
        let healthyDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            healthyDefaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: base)
        }

        var healthyProfile = WallpaperProfile.default
        healthyProfile.market = "ja-JP"
        healthyDefaults.set(try JSONEncoder().encode(healthyProfile), forKey: "sharedWallpaperProfile")
        let incompleteEnvelope: [String: Any] = [
            "schemaVersion": 1,
            "revision": UUID().uuidString,
            "updatedAt": Date().addingTimeInterval(120),
            "settings": ["displayConfigurationMode": DisplayConfigurationMode.individual.rawValue]
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: incompleteEnvelope,
            format: .binary,
            options: 0
        )
        try FileManager.default.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: snapshotURL, options: .atomic)

        let restored = SettingsStore(
            defaults: healthyDefaults,
            persistenceURL: snapshotURL,
            legacyPreferencesURL: missingLegacyURL
        )
        XCTAssertEqual(restored.sharedProfile, healthyProfile)
        XCTAssertEqual(restored.configurationMode, .shared)
    }

    func testFailedSharedSnapshotWriteCannotRollBackCurrentPreferenceDomain() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let blockedParent = base.appendingPathComponent("not-a-directory")
        let snapshotURL = blockedParent.appendingPathComponent("settings.plist")
        let missingLegacyURL = base.appendingPathComponent("missing.plist")
        let suite = "DailyWallpaperTests.Snapshot.WriteFailure.\(UUID().uuidString)"
        let currentDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            currentDefaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: base)
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("blocked".utf8).write(to: blockedParent)

        var expectedProfile = WallpaperProfile.default
        expectedProfile.market = "de-DE"
        let first = SettingsStore(
            defaults: currentDefaults,
            persistenceURL: snapshotURL,
            legacyPreferencesURL: missingLegacyURL
        )
        first.sharedProfile = expectedProfile

        let relaunched = SettingsStore(
            defaults: currentDefaults,
            persistenceURL: snapshotURL,
            legacyPreferencesURL: missingLegacyURL
        )
        XCTAssertEqual(relaunched.sharedProfile, expectedProfile)
    }

    func testDefaultLibraryRootUsesStableIdentity() {
        XCTAssertEqual(LibraryRoot.defaultRoot().id, LibraryRoot.defaultRoot().id)
        XCTAssertEqual(LibraryRoot.defaultRoot().id, LibraryRoot.defaultRootID)
    }
}
