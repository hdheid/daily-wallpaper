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
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private(set) var configurationRevision: UInt64 = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.configurationMode: DisplayConfigurationMode.shared.rawValue,
            Key.automaticDownload: true,
            Key.automaticApply: true
        ])
    }

    var configurationMode: DisplayConfigurationMode {
        get { DisplayConfigurationMode(rawValue: defaults.string(forKey: Key.configurationMode) ?? "") ?? .shared }
        set {
            guard newValue != configurationMode else { return }
            defaults.set(newValue.rawValue, forKey: Key.configurationMode)
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
            notifyConfigurationChange()
        }
    }

    var libraryRoots: [LibraryRoot] {
        get { decode([LibraryRoot].self, key: Key.libraryRoots) ?? [] }
        set { encode(newValue, key: Key.libraryRoots) }
    }

    var activeArchiveRootID: UUID? {
        get { defaults.string(forKey: Key.activeRootID).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: Key.activeRootID) }
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
        set { defaults.set(newValue, forKey: Key.lastUpdate) }
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

        defaults.set(mode.rawValue, forKey: Key.configurationMode)
        encode(sharedProfile, key: Key.sharedProfile)
        encode(displayAssignments, key: Key.displayAssignments)
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
        notifyConfigurationChange()
    }

    func markDownloaded(configurationFingerprint: String, on dayKey: String) {
        var values = lastSuccessfulDayByConfiguration
        values[configurationFingerprint] = dayKey
        lastSuccessfulDayByConfiguration = values
        lastSuccessfulUpdateAt = Date()
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
        notifyChange()
    }

    /// 删除单张媒体时只清理指向该文件的状态，不能影响同一目录中的其他壁纸。
    func removeWallpaperReferences(toRootID rootID: UUID, relativeImagePath: String) {
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
        notifyChange()
    }

    private func encode<T: Encodable>(_ value: T, key: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
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
