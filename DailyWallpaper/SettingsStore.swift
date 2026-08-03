import Foundation

@MainActor
final class SettingsStore {
    var onConfigurationChange: (() -> Void)?

    private enum Key {
        static let configurationMode = "displayConfigurationMode"
        static let sharedProfile = "sharedWallpaperProfile"
        static let displayAssignments = "displayAssignments"
        static let automaticDownload = "automaticDailyDownloadEnabled"
        static let automaticApply = "automaticDailyApplyEnabled"
        static let libraryRoots = "libraryRoots"
        static let activeRootID = "activeArchiveRootID"
        static let lastDays = "lastSuccessfulDayByConfiguration"
        static let currentImages = "currentImageByDisplayUUID"
        static let cachedImages = "cachedImageByConfiguration"
        static let lastUpdate = "lastSuccessfulUpdateAt"
        static let archiveReconciliationVersions = "archiveReconciliationVersionsByRoot"

        static let all = [
            configurationMode, sharedProfile, displayAssignments, automaticDownload,
            automaticApply, libraryRoots, activeRootID, lastDays, currentImages,
            cachedImages, lastUpdate, archiveReconciliationVersions
        ]

        static let requiredSnapshotKeys = all.filter {
            $0 != activeRootID && $0 != lastUpdate
        }
    }

    private enum SyncKey {
        static let revision = "settingsSnapshotRevision"
        static let updatedAt = "settingsSnapshotUpdatedAt"
        static let legacyMigrationCompleted = "settingsLegacyMigrationCompleted"
    }

    private enum EnvelopeKey {
        static let schemaVersion = "schemaVersion"
        static let revision = "revision"
        static let updatedAt = "updatedAt"
        static let settings = "settings"
        static let legacyMigrationCompleted = "legacyMigrationCompleted"
    }

    private enum SnapshotSource: Int {
        case legacyPreferences
        case sharedFile
        case currentDefaults
    }

    private struct SnapshotCandidate {
        let settings: [String: Any]
        let revision: UUID?
        let updatedAt: Date
        let isComplete: Bool
        let legacyMigrationCompleted: Bool
        let source: SnapshotSource
    }

    private let defaults: UserDefaults
    private let persistenceURL: URL?
    private let legacyPreferencesURL: URL?
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var persistenceDeferralDepth = 0
    private var persistenceNeedsWrite = false
    private var lastSnapshotUpdatedAt = Date.distantPast
    private(set) var configurationRevision: UInt64 = 0

    private static let snapshotSchemaVersion = 1

    init(
        defaults: UserDefaults = .standard,
        persistenceURL: URL? = nil,
        legacyPreferencesURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        self.persistenceURL = persistenceURL
        self.legacyPreferencesURL = legacyPreferencesURL
        self.fileManager = fileManager

        // GitHub 安装包和本地开发包可能被 macOS 分配到不同偏好域，先选取真正较新的合法配置。
        let shouldCreateSnapshot = restorePersistedSettingsIfNeeded()
        defaults.register(defaults: [
            Key.configurationMode: DisplayConfigurationMode.shared.rawValue,
            Key.automaticDownload: true,
            Key.automaticApply: true
        ])
        if automaticDailyApplyEnabled, !automaticDailyDownloadEnabled {
            defaults.set(true, forKey: Key.automaticDownload)
        }
        if shouldCreateSnapshot {
            persistSnapshotIfNeeded()
        }
    }

    static func defaultPersistenceURL(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(AppConstants.defaultArchiveFolderName, isDirectory: true)
            .appendingPathComponent(".dailywallpaper", isDirectory: true)
            .appendingPathComponent("settings.plist")
    }

    var configurationMode: DisplayConfigurationMode {
        get { DisplayConfigurationMode(rawValue: defaults.string(forKey: Key.configurationMode) ?? "") ?? .shared }
        set {
            guard newValue != configurationMode else { return }
            defaults.set(newValue.rawValue, forKey: Key.configurationMode)
            requestSnapshotPersistence()
            notifyConfigurationChange()
        }
    }

    var sharedProfile: WallpaperProfile {
        get { decode(WallpaperProfile.self, key: Key.sharedProfile) ?? .default }
        set {
            guard newValue != sharedProfile else { return }
            encode(newValue, key: Key.sharedProfile)
            notifyConfigurationChange()
        }
    }

    var displayAssignments: [String: WallpaperProfile] {
        get { decode([String: WallpaperProfile].self, key: Key.displayAssignments) ?? [:] }
        set {
            guard newValue != displayAssignments else { return }
            encode(newValue, key: Key.displayAssignments)
            notifyConfigurationChange()
        }
    }

    var automaticDailyDownloadEnabled: Bool {
        get { defaults.bool(forKey: Key.automaticDownload) }
        set {
            guard newValue != automaticDailyDownloadEnabled else { return }
            defaults.set(newValue, forKey: Key.automaticDownload)
            if !newValue {
                defaults.set(false, forKey: Key.automaticApply)
            }
            requestSnapshotPersistence()
            notifyConfigurationChange()
        }
    }

    var automaticDailyApplyEnabled: Bool {
        get { defaults.bool(forKey: Key.automaticApply) }
        set {
            guard newValue != automaticDailyApplyEnabled else { return }
            defaults.set(newValue, forKey: Key.automaticApply)
            if newValue {
                defaults.set(true, forKey: Key.automaticDownload)
            }
            requestSnapshotPersistence()
            notifyConfigurationChange()
        }
    }

    var libraryRoots: [LibraryRoot] {
        get { decode([LibraryRoot].self, key: Key.libraryRoots) ?? [] }
        set { encode(newValue, key: Key.libraryRoots) }
    }

    var activeArchiveRootID: UUID? {
        get { defaults.string(forKey: Key.activeRootID).flatMap(UUID.init(uuidString:)) }
        set {
            defaults.set(newValue?.uuidString, forKey: Key.activeRootID)
            requestSnapshotPersistence()
        }
    }

    var lastSuccessfulDayByConfiguration: [String: String] {
        get { decode([String: String].self, key: Key.lastDays) ?? [:] }
        set { encode(newValue, key: Key.lastDays) }
    }

    var currentImageByDisplayUUID: [String: CurrentWallpaperRecord] {
        get { decode([String: CurrentWallpaperRecord].self, key: Key.currentImages) ?? [:] }
        set { encode(newValue, key: Key.currentImages) }
    }

    var cachedImageByConfiguration: [String: CachedWallpaperRecord] {
        get { decode([String: CachedWallpaperRecord].self, key: Key.cachedImages) ?? [:] }
        set { encode(newValue, key: Key.cachedImages) }
    }

    var lastSuccessfulUpdateAt: Date? {
        get { defaults.object(forKey: Key.lastUpdate) as? Date }
        set {
            defaults.set(newValue, forKey: Key.lastUpdate)
            requestSnapshotPersistence()
        }
    }

    func archiveReconciliationVersion(for rootID: UUID) -> Int {
        let values = decode([String: Int].self, key: Key.archiveReconciliationVersions) ?? [:]
        return values[rootID.uuidString] ?? 0
    }

    func markArchiveReconciled(rootID: UUID, version: Int) {
        var values = decode([String: Int].self, key: Key.archiveReconciliationVersions) ?? [:]
        values[rootID.uuidString] = version
        encode(values, key: Key.archiveReconciliationVersions)
    }

    func removeArchiveReconciliationState(rootID: UUID) {
        var values = decode([String: Int].self, key: Key.archiveReconciliationVersions) ?? [:]
        values.removeValue(forKey: rootID.uuidString)
        encode(values, key: Key.archiveReconciliationVersions)
    }

    func profile(for displayUUID: String) -> WallpaperProfile {
        configurationMode == .shared ? sharedProfile : (displayAssignments[displayUUID] ?? .default)
    }

    func setProfile(_ profile: WallpaperProfile, for displayUUID: String) {
        var assignments = displayAssignments
        assignments[displayUUID] = profile
        displayAssignments = assignments
    }

    /// 设置页点击保存时一次性提交显示器配置，只发布一次配置变更，避免后台重复调度。
    func saveDisplayConfiguration(
        mode: DisplayConfigurationMode,
        sharedProfile: WallpaperProfile,
        displayAssignments: [String: WallpaperProfile]
    ) {
        let hasChanges = mode != configurationMode
            || sharedProfile != self.sharedProfile
            || displayAssignments != self.displayAssignments
        guard hasChanges else { return }

        withDeferredPersistence {
            defaults.set(mode.rawValue, forKey: Key.configurationMode)
            requestSnapshotPersistence()
            encode(sharedProfile, key: Key.sharedProfile)
            encode(displayAssignments, key: Key.displayAssignments)
        }
        notifyConfigurationChange()
    }

    /// 每日下载与自动更换存在联动关系，批量保存时也保持与单项 setter 相同的不变量。
    func saveAutomationConfiguration(downloadEnabled: Bool, applyEnabled: Bool) {
        let normalizedDownload = downloadEnabled || applyEnabled
        let normalizedApply = normalizedDownload && applyEnabled
        guard normalizedDownload != automaticDailyDownloadEnabled
            || normalizedApply != automaticDailyApplyEnabled
        else { return }

        defaults.set(normalizedDownload, forKey: Key.automaticDownload)
        defaults.set(normalizedApply, forKey: Key.automaticApply)
        requestSnapshotPersistence()
        notifyConfigurationChange()
    }

    /// 媒体库目录与活动目录 ID 必须作为一份配置提交，避免中途退出留下不一致快照。
    func saveLibraryConfiguration(roots: [LibraryRoot], activeRootID: UUID?) {
        guard roots != libraryRoots || activeRootID != activeArchiveRootID else { return }
        withDeferredPersistence {
            encode(roots, key: Key.libraryRoots)
            defaults.set(activeRootID?.uuidString, forKey: Key.activeRootID)
            requestSnapshotPersistence()
        }
        notifyChange()
    }

    func markDownloaded(configurationFingerprint: String, on dayKey: String) {
        withDeferredPersistence {
            var values = lastSuccessfulDayByConfiguration
            values[configurationFingerprint] = dayKey
            lastSuccessfulDayByConfiguration = values
            lastSuccessfulUpdateAt = Date()
        }
        notifyChange()
    }

    func wasDownloaded(configurationFingerprint: String, on dayKey: String) -> Bool {
        lastSuccessfulDayByConfiguration[configurationFingerprint] == dayKey
    }

    func setCurrentWallpaper(_ record: CurrentWallpaperRecord) {
        var values = currentImageByDisplayUUID
        values[record.displayUUID] = record
        currentImageByDisplayUUID = values
        notifyChange()
    }

    func setCachedWallpaper(_ record: CachedWallpaperRecord) {
        var values = cachedImageByConfiguration
        values[record.configurationFingerprint] = record
        cachedImageByConfiguration = values
        notifyChange()
    }

    func removeWallpaperReferences(toRootID rootID: UUID) {
        withDeferredPersistence {
            var current = currentImageByDisplayUUID
            current = current.filter { $0.value.rootID != rootID }
            currentImageByDisplayUUID = current

            var cached = cachedImageByConfiguration
            let removedFingerprints = Set(
                cached.compactMap { key, value in value.rootID == rootID ? key : nil }
            )
            cached = cached.filter { $0.value.rootID != rootID }
            cachedImageByConfiguration = cached

            if !removedFingerprints.isEmpty {
                var successfulDays = lastSuccessfulDayByConfiguration
                removedFingerprints.forEach { successfulDays.removeValue(forKey: $0) }
                lastSuccessfulDayByConfiguration = successfulDays
            }
        }
        notifyChange()
    }

    /// 删除单张媒体时只清理指向该文件的状态，不能影响同一目录中的其他壁纸。
    func removeWallpaperReferences(toRootID rootID: UUID, relativeImagePath: String) {
        withDeferredPersistence {
            var current = currentImageByDisplayUUID
            current = current.filter {
                $0.value.rootID != rootID || $0.value.relativeImagePath != relativeImagePath
            }
            currentImageByDisplayUUID = current

            var cached = cachedImageByConfiguration
            let removedFingerprints = Set(cached.compactMap { key, value in
                value.rootID == rootID && value.relativeImagePath == relativeImagePath ? key : nil
            })
            cached = cached.filter {
                $0.value.rootID != rootID || $0.value.relativeImagePath != relativeImagePath
            }
            cachedImageByConfiguration = cached

            if !removedFingerprints.isEmpty {
                var successfulDays = lastSuccessfulDayByConfiguration
                removedFingerprints.forEach { successfulDays.removeValue(forKey: $0) }
                lastSuccessfulDayByConfiguration = successfulDays
            }
        }
        notifyChange()
    }

    private func encode<T: Encodable>(_ value: T, key: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
        requestSnapshotPersistence()
    }

    private func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    /// 返回值表示启动后是否需要生成或刷新共享快照。
    private func restorePersistedSettingsIfNeeded() -> Bool {
        guard let persistenceURL else { return false }

        var candidates: [SnapshotCandidate] = []
        if let current = currentDefaultsCandidate() {
            candidates.append(current)
        }
        if let shared = try? readCandidate(at: persistenceURL, source: .sharedFile) {
            candidates.append(shared)
        }

        // 旧无沙盒偏好只允许参与一次迁移。迁移完成后即使旧 Debug 再次运行，也不能反向覆盖新版配置。
        let legacyMigrationWasCompleted = defaults.bool(forKey: SyncKey.legacyMigrationCompleted)
            || candidates.contains(where: { $0.legacyMigrationCompleted })
        if !legacyMigrationWasCompleted {
            for url in legacyPreferenceCandidates() where url.standardizedFileURL != persistenceURL.standardizedFileURL {
                if let candidate = try? readCandidate(at: url, source: .legacyPreferences) {
                    candidates.append(candidate)
                }
            }
        }

        // 先在当前偏好域记录迁移完成；共享文件写入失败时也不会反复导入旧配置。
        defaults.set(true, forKey: SyncKey.legacyMigrationCompleted)

        guard let selected = candidates.max(by: isOlderCandidate) else {
            // 全新安装或历史文件均损坏时，用注册后的默认值生成一份完整快照。
            return true
        }

        apply(settings: selected.settings, replacingMissingKeys: selected.isComplete)
        lastSnapshotUpdatedAt = selected.updatedAt
        if let revision = selected.revision {
            defaults.set(revision.uuidString, forKey: SyncKey.revision)
            defaults.set(selected.updatedAt, forKey: SyncKey.updatedAt)
        }

        let sharedRevision = candidates.first {
            $0.source == .sharedFile && $0.isComplete
        }?.revision
        let sharedMigrationWasCompleted = candidates.first {
            $0.source == .sharedFile && $0.isComplete
        }?.legacyMigrationCompleted == true
        // 当前偏好更晚、仍是旧格式或缺少一次性迁移标记时，立即刷新完整快照。
        return selected.revision == nil
            || selected.revision != sharedRevision
            || !sharedMigrationWasCompleted
    }

    private func currentDefaultsCandidate() -> SnapshotCandidate? {
        let raw = Key.all.reduce(into: [String: Any]()) { result, key in
            if let value = defaults.object(forKey: key) { result[key] = value }
        }
        guard
            let settings = try? validatedSettings(raw, requiresCompleteSnapshot: false),
            !settings.isEmpty
        else { return nil }

        return SnapshotCandidate(
            settings: settings,
            revision: defaults.string(forKey: SyncKey.revision).flatMap(UUID.init(uuidString:)),
            updatedAt: defaults.object(forKey: SyncKey.updatedAt) as? Date ?? .distantPast,
            isComplete: false,
            legacyMigrationCompleted: defaults.bool(forKey: SyncKey.legacyMigrationCompleted),
            source: .currentDefaults
        )
    }

    private func readCandidate(at url: URL, source: SnapshotSource) throws -> SnapshotCandidate {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let values = propertyList as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }

        if values[EnvelopeKey.schemaVersion] != nil {
            guard
                values[EnvelopeKey.schemaVersion] as? Int == Self.snapshotSchemaVersion,
                let revisionText = values[EnvelopeKey.revision] as? String,
                let revision = UUID(uuidString: revisionText),
                let updatedAt = values[EnvelopeKey.updatedAt] as? Date,
                let rawSettings = values[EnvelopeKey.settings] as? [String: Any]
            else { throw CocoaError(.propertyListReadCorrupt) }

            if let migrationValue = values[EnvelopeKey.legacyMigrationCompleted], !(migrationValue is Bool) {
                throw CocoaError(.propertyListReadCorrupt)
            }

            return SnapshotCandidate(
                settings: try validatedSettings(rawSettings, requiresCompleteSnapshot: true),
                revision: revision,
                updatedAt: updatedAt,
                isComplete: true,
                legacyMigrationCompleted: values[EnvelopeKey.legacyMigrationCompleted] as? Bool ?? false,
                source: source
            )
        }

        // 旧版共享快照和 UserDefaults plist 都是扁平字典，只合并其中合法且实际存在的键。
        let settings = try validatedSettings(values, requiresCompleteSnapshot: false)
        guard !settings.isEmpty else { throw CocoaError(.propertyListReadCorrupt) }
        let updatedAt = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            ?? .distantPast
        return SnapshotCandidate(
            settings: settings,
            revision: nil,
            updatedAt: updatedAt,
            isComplete: false,
            legacyMigrationCompleted: false,
            source: source
        )
    }

    private func isOlderCandidate(_ lhs: SnapshotCandidate, _ rhs: SnapshotCandidate) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
        if lhs.isComplete != rhs.isComplete { return !lhs.isComplete && rhs.isComplete }
        return lhs.source.rawValue < rhs.source.rawValue
    }

    private func validatedSettings(
        _ values: [String: Any],
        requiresCompleteSnapshot: Bool
    ) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for key in Key.all {
            guard let value = values[key] else { continue }
            switch key {
            case Key.configurationMode:
                guard
                    let rawValue = value as? String,
                    DisplayConfigurationMode(rawValue: rawValue) != nil
                else { throw CocoaError(.propertyListReadCorrupt) }
            case Key.sharedProfile:
                try validateData(value, as: WallpaperProfile.self)
            case Key.displayAssignments:
                try validateData(value, as: [String: WallpaperProfile].self)
            case Key.automaticDownload, Key.automaticApply:
                guard value is Bool else { throw CocoaError(.propertyListReadCorrupt) }
            case Key.libraryRoots:
                let roots = try decodedData(value, as: [LibraryRoot].self)
                guard Set(roots.map(\.id)).count == roots.count else {
                    throw CocoaError(.propertyListReadCorrupt)
                }
            case Key.activeRootID:
                guard let rawValue = value as? String, UUID(uuidString: rawValue) != nil else {
                    throw CocoaError(.propertyListReadCorrupt)
                }
            case Key.lastDays:
                try validateData(value, as: [String: String].self)
            case Key.currentImages:
                try validateData(value, as: [String: CurrentWallpaperRecord].self)
            case Key.cachedImages:
                try validateData(value, as: [String: CachedWallpaperRecord].self)
            case Key.lastUpdate:
                guard value is Date else { throw CocoaError(.propertyListReadCorrupt) }
            case Key.archiveReconciliationVersions:
                let versions = try decodedData(value, as: [String: Int].self)
                guard versions.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value >= 0 }) else {
                    throw CocoaError(.propertyListReadCorrupt)
                }
            default:
                throw CocoaError(.propertyListReadCorrupt)
            }
            result[key] = value
        }

        if requiresCompleteSnapshot {
            let missingKeys = Key.requiredSnapshotKeys.filter { result[$0] == nil }
            guard missingKeys.isEmpty else { throw CocoaError(.propertyListReadCorrupt) }
        }
        if
            let applyEnabled = result[Key.automaticApply] as? Bool,
            let downloadEnabled = result[Key.automaticDownload] as? Bool,
            applyEnabled,
            !downloadEnabled
        {
            throw CocoaError(.propertyListReadCorrupt)
        }
        if let rootsData = result[Key.libraryRoots] as? Data,
           let roots = try? decoder.decode([LibraryRoot].self, from: rootsData)
        {
            let activeRootID = (result[Key.activeRootID] as? String).flatMap(UUID.init(uuidString:))
            if let activeRootID, !roots.contains(where: { $0.id == activeRootID }) {
                throw CocoaError(.propertyListReadCorrupt)
            }
            if requiresCompleteSnapshot, !roots.isEmpty, activeRootID == nil {
                throw CocoaError(.propertyListReadCorrupt)
            }
        }
        return result
    }

    private func validateData<T: Decodable>(_ value: Any, as type: T.Type) throws {
        _ = try decodedData(value, as: type)
    }

    private func decodedData<T: Decodable>(_ value: Any, as type: T.Type) throws -> T {
        guard let data = value as? Data else { throw CocoaError(.propertyListReadCorrupt) }
        return try decoder.decode(type, from: data)
    }

    private func apply(settings: [String: Any], replacingMissingKeys: Bool) {
        for key in Key.all {
            if let value = settings[key] {
                defaults.set(value, forKey: key)
            } else if replacingMissingKeys {
                defaults.removeObject(forKey: key)
            }
        }
    }

    private func legacyPreferenceCandidates() -> [URL] {
        if let legacyPreferencesURL { return [legacyPreferencesURL] }
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return [] }

        var candidates: [URL] = []
        let preferencesFilename = "\(bundleIdentifier).plist"
        if let libraryURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first {
            candidates.append(
                libraryURL
                    .appendingPathComponent("Preferences", isDirectory: true)
                    .appendingPathComponent(preferencesFilename)
            )
        }

        // 沙盒中的 Library 指向容器；Pictures 则由专用 entitlement 授权，可反推出真实用户目录。
        if let picturesURL = fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first {
            let globalPreferences = picturesURL
                .deletingLastPathComponent()
                .appendingPathComponent("Library/Preferences", isDirectory: true)
                .appendingPathComponent(preferencesFilename)
            if !candidates.contains(globalPreferences) {
                candidates.append(globalPreferences)
            }
        }

        // 无沙盒旧版本还可以直接看到发布版容器，首次升级时把两个历史域一起纳入时间比较。
        let containerPreferences = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(bundleIdentifier)/Data/Library/Preferences", isDirectory: true)
            .appendingPathComponent(preferencesFilename)
        if !candidates.contains(containerPreferences) {
            candidates.append(containerPreferences)
        }
        return candidates
    }

    private func withDeferredPersistence(_ changes: () -> Void) {
        persistenceDeferralDepth += 1
        defer {
            persistenceDeferralDepth -= 1
            if persistenceDeferralDepth == 0, persistenceNeedsWrite {
                persistenceNeedsWrite = false
                persistSnapshotIfNeeded()
            }
        }
        changes()
    }

    private func requestSnapshotPersistence() {
        guard persistenceURL != nil else { return }
        if persistenceDeferralDepth > 0 {
            persistenceNeedsWrite = true
        } else {
            persistSnapshotIfNeeded()
        }
    }

    private func persistSnapshotIfNeeded() {
        guard let persistenceURL else { return }
        do {
            let updatedAt = max(Date(), lastSnapshotUpdatedAt.addingTimeInterval(0.001))
            let revision = UUID()
            let settings = try completeSnapshotSettings()
            let envelope: [String: Any] = [
                EnvelopeKey.schemaVersion: Self.snapshotSchemaVersion,
                EnvelopeKey.revision: revision.uuidString,
                EnvelopeKey.updatedAt: updatedAt,
                EnvelopeKey.settings: settings,
                EnvelopeKey.legacyMigrationCompleted: true
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: envelope,
                format: .binary,
                options: 0
            )

            // 先记录本偏好域的 revision。即使共享文件写入失败，下次启动也不会被旧快照回滚。
            defaults.set(revision.uuidString, forKey: SyncKey.revision)
            defaults.set(updatedAt, forKey: SyncKey.updatedAt)
            defaults.set(true, forKey: SyncKey.legacyMigrationCompleted)
            lastSnapshotUpdatedAt = updatedAt
            try fileManager.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            NSLog("DailyWallpaper 设置快照写入失败：%@", error.localizedDescription)
        }
    }

    private func completeSnapshotSettings() throws -> [String: Any] {
        var values: [String: Any] = [
            Key.configurationMode: configurationMode.rawValue,
            Key.sharedProfile: try encoder.encode(sharedProfile),
            Key.displayAssignments: try encoder.encode(displayAssignments),
            Key.automaticDownload: automaticDailyDownloadEnabled,
            Key.automaticApply: automaticDailyApplyEnabled,
            Key.libraryRoots: try encoder.encode(libraryRoots),
            Key.lastDays: try encoder.encode(lastSuccessfulDayByConfiguration),
            Key.currentImages: try encoder.encode(currentImageByDisplayUUID),
            Key.cachedImages: try encoder.encode(cachedImageByConfiguration),
            Key.archiveReconciliationVersions: try encoder.encode(
                decode([String: Int].self, key: Key.archiveReconciliationVersions) ?? [:]
            )
        ]
        if let activeArchiveRootID {
            values[Key.activeRootID] = activeArchiveRootID.uuidString
        }
        if let lastSuccessfulUpdateAt {
            values[Key.lastUpdate] = lastSuccessfulUpdateAt
        }
        return try validatedSettings(values, requiresCompleteSnapshot: true)
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .dailyWallpaperSettingsDidChange, object: self)
    }

    private func notifyConfigurationChange() {
        // 修订号只跟踪会改变下载或应用决策的用户配置，缓存状态更新不会触发重跑。
        configurationRevision &+= 1
        notifyChange()
        onConfigurationChange?()
    }
}
